import Foundation
import Combine

// MARK: - Debug Log Entry

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let provider: String
    let requestJSON: String
    let responseJSON: String
    let promptTokens: Int
    let completionTokens: Int
    let cacheMissTokens: Int
}

// MARK: - Chat Debug Logger

/// 最近 20 次聊天请求的调试快照，只在内存中保留，不写盘。
@MainActor
final class ChatDebugLogger: ObservableObject {
    static let shared = ChatDebugLogger()

    @Published private(set) var logs: [DebugLogEntry] = []
    /// 默认关闭：不抓包时 ChatService 连 JSON 字符串都不构造。
    @Published var isEnabled: Bool = false

    private init() {}

    func log(provider: String, requestJSON: String, responseJSON: String, usage: ChatUsage) {
        guard isEnabled else { return }
        let entry = DebugLogEntry(
            timestamp: Date(),
            provider: provider,
            requestJSON: requestJSON,
            responseJSON: responseJSON,
            promptTokens: max(0, usage.totalTokens - usage.outputTokens),
            completionTokens: max(0, usage.outputTokens),
            cacheMissTokens: max(0, usage.cacheMissTokens)
        )
        logs.append(entry)
        if logs.count > 20 {
            logs.removeFirst(logs.count - 20)
        }
    }

    func clear() {
        logs.removeAll()
    }
}
