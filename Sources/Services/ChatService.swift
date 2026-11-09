import Foundation
import Combine

// MARK: - Chat Service Protocol

@MainActor
protocol ChatServiceProtocol {
    func sendMessage(messages: [[String: String]]) async throws -> String
    var isProcessing: Bool { get }
}

// MARK: - Chat Service Manager

@MainActor
class ChatServiceManager: ObservableObject {
    static let shared = ChatServiceManager()
    
    @Published var isProcessing: Bool = false
    @Published var currentProvider: ChatProvider = .deepseek
    
    private var currentService: ChatServiceProtocol?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        updateProvider()
        
        ConfigManager.shared.$config
            .sink { [weak self] _ in
                self?.updateProvider()
            }
            .store(in: &cancellables)
    }
    
    private func updateProvider() {
        let provider = ConfigManager.shared.config.chat.provider
        currentProvider = provider
        
        switch provider {
        case .deepseek:
            currentService = DeepSeekChatService()
        case .localLlm:
            currentService = LocalLLMChatService()
        }
    }
    
    func sendMessage(_ message: String) async throws -> String {
        guard ConfigManager.shared.config.chat.enabled else {
            throw ChatError.disabled
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        // PetController 在调用前就把用户消息写进了历史，这里统一构造请求消息，
        // 既能保证 system 永远在第一条，也避免同一条 user 消息被发送两次。
        let history = ChatHistoryManager.shared.getMessagesForAPI()
        let messages = Self.makeMessages(
            systemPrompt: ConfigManager.shared.config.chat.systemPrompt,
            history: history,
            userMessage: message
        )
        return try await currentService?.sendMessage(messages: messages) ?? ""
    }
    
    func sendMessageWithContext(_ message: String, context: String) async throws -> String {
        guard ConfigManager.shared.config.chat.enabled else {
            throw ChatError.disabled
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        let history = ChatHistoryManager.shared.getMessagesForAPI()
        let messages = Self.makeMessages(
            systemPrompt: ConfigManager.shared.config.chat.systemPrompt,
            extraContext: context,
            history: history,
            userMessage: message
        )
        return try await currentService?.sendMessage(messages: messages) ?? ""
    }
    
    /// 统一构造 OpenAI 兼容的 messages 数组。
    /// 1. 第一条永远是 system（配置里的系统提示词，按当前 provider 取）；
    /// 2. 历史里的 system 合并进第一条，其余历史保持原顺序；
    /// 3. 最后一条 user 前面再贴一次系统设定，兼容会吞掉 system 角色的第三方网关。
    private static func makeMessages(
        systemPrompt: String,
        extraContext: String? = nil,
        history: [[String: String]],
        userMessage: String
    ) -> [[String: String]] {
        let historySystem = history
            .compactMap { $0["role"] == "system" ? $0["content"] : nil }
            .joined(separator: "\n\n")
        
        let systemContent = [systemPrompt, extraContext ?? "", historySystem]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        
        var messages: [[String: String]] = []
        
        // 第一条必须是 system
        if !systemContent.isEmpty {
            messages.append(["role": "system", "content": systemContent])
        }
        
        // 历史里只保留 user/assistant，避免出现多条 system；
        // 同时去掉调用方可能已经写入历史的“当前这条用户消息”。
        var historyForRequest: [[String: String]] = []
        for item in history where item["role"] != "system" {
            historyForRequest.append(item)
        }
        if let last = historyForRequest.last,
           last["role"] == "user",
           last["content"] == userMessage {
            historyForRequest.removeLast()
        }
        messages.append(contentsOf: historyForRequest)
        
        // 兜底：部分网关（例如 Vercel 代理）会丢弃 system 角色，
        // 因此把同一段设定以 user 身份贴在本次问题前面。
        if systemContent.isEmpty {
            messages.append(["role": "user", "content": userMessage])
        } else {
            messages.append([
                "role": "user",
                "content": "【系统设定】\n\(systemContent)\n\n【用户消息】\n\(userMessage)"
            ])
        }
        
        return messages
    }
}

// MARK: - DeepSeek Chat Service

@MainActor
class DeepSeekChatService: ChatServiceProtocol {
    var isProcessing: Bool = false
    
    func sendMessage(messages: [[String: String]]) async throws -> String {
        let config = ConfigManager.shared.config.chat.deepseek
        
        guard !config.apiKey.isEmpty else {
            throw ChatError.invalidConfiguration
        }
        guard let url = URL(string: config.apiUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ChatError.apiError("API 地址无效：\(config.apiUrl)")
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // OpenAI 兼容格式：所有服务（OpenAI / Gemini / NVIDIA / Vercel 代理）统一 Bearer Key
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.networkError
        }
        
        guard httpResponse.statusCode == 200 else {
            if let message = Self.errorMessage(from: data) {
                throw ChatError.apiError(message)
            }
            throw ChatError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.parseError
        }
        guard let content = Self.content(from: json) else {
            throw ChatError.parseError
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChatError.parseError
        }
        return trimmed
    }
    
    // MARK: - OpenAI 兼容响应解析
    
    /// 统一读取 choices[0].message.content（兼容 content 为字符串或分段数组、以及 choices[0].text）
    private static func content(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        
        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content
            }
            if let parts = message["content"] as? [[String: Any]] {
                let joined = parts.compactMap { $0["text"] as? String }.joined()
                if !joined.isEmpty { return joined }
            }
        }
        if let text = first["text"] as? String {
            return text
        }
        return nil
    }
    
    /// 兼容 OpenAI（error.message）、部分代理（error / detail / message 字符串）的错误结构
    private static func errorMessage(from data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let error = object["error"] as? String { return error }
        if let detail = object["detail"] as? String { return detail }
        if let message = object["message"] as? String { return message }
        return nil
    }
}

// MARK: - Local LLM Chat Service (Ollama/OpenAI compatible)

@MainActor
class LocalLLMChatService: ChatServiceProtocol {
    var isProcessing: Bool = false
    
    func sendMessage(messages: [[String: String]]) async throws -> String {
        let config = ConfigManager.shared.config.chat.localLlm
        
        guard !config.apiUrl.isEmpty else {
            throw ChatError.invalidConfiguration
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]
        
        let url = URL(string: config.apiUrl)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.networkError
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ChatError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.parseError
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Chat Errors

enum ChatError: LocalizedError {
    case disabled
    case invalidConfiguration
    case networkError
    case apiError(String)
    case parseError
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .disabled: return "Chat is disabled"
        case .invalidConfiguration: return "Chat configuration is invalid"
        case .networkError: return "Network error"
        case .apiError(let msg): return "API error: \(msg)"
        case .parseError: return "Failed to parse response"
        case .timeout: return "Request timeout"
        }
    }
}