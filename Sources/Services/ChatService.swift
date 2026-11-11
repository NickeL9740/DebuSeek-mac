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
        // KV Cache 关键：只发送上次压缩后的新消息，不再带全量历史。
        let history = ChatHistoryManager.shared.messagesSinceLastSummary().map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
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

    /// 摘要专用原始请求：只带独立的摘要 system prompt，不经过 makeMessages。
    /// 因此不会注入大肥鱼人设、旧回忆录或 Token 提示，避免记忆被自我污染。
    func sendSummarizationRequest(systemPrompt: String, transcript: String) async throws -> String {
        guard ConfigManager.shared.config.chat.enabled else {
            throw ChatError.disabled
        }

        isProcessing = true
        defer { isProcessing = false }

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": transcript]
        ]
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
        
        let chat = ConfigManager.shared.config.chat
        var systemParts: [String] = [systemPrompt]

        // 长期回忆录紧跟在人设之后，保持 systemPrompt -> 回忆录 -> 额外上下文 -> 历史 system 的顺序
        if chat.enableMemorySummarization {
            let memory = chat.memorySummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memory.isEmpty {
                systemParts.append("【过往回忆录】\n\(memory)")
            }
        }
        if let extraContext = extraContext {
            systemParts.append(extraContext)
        }
        if !historySystem.isEmpty {
            systemParts.append(historySystem)
        }
        let nickname = chat.userNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nickname.isEmpty {
            systemParts.append("【用户称呼】\n请称呼用户为：\(nickname)")
        }

        let systemContent = systemParts
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
        for item in history where item["role"] != "system" && item["role"] != "system_note" {
            historyForRequest.append(item)
        }
        if let last = historyForRequest.last,
           last["role"] == "user",
           last["content"] == userMessage {
            historyForRequest.removeLast()
        }
        messages.append(contentsOf: historyForRequest)
        
        // 最后只追加纯粹的当前用户消息。
        // 不再把 systemContent 拼进 user：那会让同一段设定在 system + user 里各算一次 Token，
        // 并在多轮历史中反复放大。system 角色仍由上面的 messages[0] 负责。
        messages.append(["role": "user", "content": userMessage])
        
        // Token 提示只拼在本次请求的最后一条 user 消息上，
        // ChatHistoryManager / UI 里永远没有这条隐藏内容。
        if chat.injectTokenUsage,
           var last = messages.last,
           last["role"] == "user" {
            let note = "[系统提示：今日已消耗 Token: \(UsageManager.shared.todayTokens)]"
            last["content"] = ((last["content"] ?? "") + "\n" + note)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            messages[messages.count - 1] = last
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
        let debugEnabled = ChatDebugLogger.shared.isEnabled
        let requestJSON = debugEnabled
            ? (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            : ""
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let responseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = responseObject.map { ChatUsageParser.usage(from: $0) }
            ?? ChatUsage(totalTokens: 0, cacheMissTokens: 0, outputTokens: 0)
        if debugEnabled {
            let responseJSON = String(data: data, encoding: .utf8) ?? ""
            ChatDebugLogger.shared.log(
                provider: "DeepSeek",
                requestJSON: requestJSON,
                responseJSON: responseJSON,
                usage: usage
            )
        }
        
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
        UsageManager.shared.add(ChatUsageParser.usage(from: json))
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
        
        guard let url = URL(string: config.apiUrl) else {
            throw ChatError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        let debugEnabled = ChatDebugLogger.shared.isEnabled
        let requestJSON = debugEnabled
            ? (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            : ""
        
        let (data, response) = try await URLSession.shared.data(for: request)
        let responseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = responseObject.map { ChatUsageParser.usage(from: $0) }
            ?? ChatUsage(totalTokens: 0, cacheMissTokens: 0, outputTokens: 0)
        if debugEnabled {
            let responseJSON = String(data: data, encoding: .utf8) ?? ""
            ChatDebugLogger.shared.log(
                provider: "Local LLM",
                requestJSON: requestJSON,
                responseJSON: responseJSON,
                usage: usage
            )
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.networkError
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ChatError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.parseError
        }
        UsageManager.shared.add(ChatUsageParser.usage(from: json))

        guard let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ChatError.parseError
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Usage Parsing

struct ChatUsage: Equatable {
    let totalTokens: Int
    let cacheMissTokens: Int
    let outputTokens: Int
}

enum ChatUsageParser {
    /// 兼容 OpenAI / DeepSeek 的 usage（JSONSerialization 可能给 Int / Double / NSNumber）。
    /// 优先 DeepSeek 的 prompt_cache_miss_tokens；缺失时按 OpenAI 的
    /// prompt_tokens - prompt_tokens_details.cached_tokens 推算；再缺失则按全部未命中处理。
    static func usage(from json: [String: Any]) -> ChatUsage {
        guard let usage = json["usage"] as? [String: Any] else {
            return ChatUsage(totalTokens: 0, cacheMissTokens: 0, outputTokens: 0)
        }
        let output = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"]) ?? 0
        let prompt = intValue(usage["prompt_tokens"]) ?? 0
        let total = intValue(usage["total_tokens"]) ?? (prompt + output)

        // 1) 原厂优先：DeepSeek 直接给出 prompt_cache_miss_tokens。
        let cacheMiss: Int
        if let deepSeekMiss = intValue(usage["prompt_cache_miss_tokens"]) {
            cacheMiss = deepSeekMiss
        } else {
            // 2) OpenAI / Vercel / Fireworks 等兼容网关：
            //    用 prompt_tokens - prompt_tokens_details.cached_tokens 推算未命中。
            let details = usage["prompt_tokens_details"] as? [String: Any]
            let cached = intValue(details?["cached_tokens"]) ?? 0
            // 3) 最后兜底：拿不到 cached_tokens 就当全部输入都未命中。
            //    若 prompt_tokens 本身也缺失，则 prompt 为 0。
            cacheMiss = max(0, prompt - cached)
        }

        return ChatUsage(totalTokens: max(0, total), cacheMissTokens: max(0, cacheMiss), outputTokens: max(0, output))
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
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