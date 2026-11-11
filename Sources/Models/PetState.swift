import Foundation
import SwiftUI

// MARK: - Pet Activity

enum PetActivity: String {
    case idle
    case walk
    case jump
    case sleep
    case eat
    case explore
    case sweep
}

// MARK: - Pet State

@MainActor
class PetState: ObservableObject {
    static let shared = PetState()
    
    @Published var happiness: Int = 100
    @Published var hunger: Int = 0
    @Published var energy: Int = 100
    @Published var isSleeping: Bool = false
    @Published var currentAnimation: String = "IDLE"
    @Published var position: CGPoint = CGPoint(x: 100, y: 100)
    @Published var isDragging: Bool = false
    @Published var lastInteraction: Date = Date()
    @Published var wakeTargetEnergy: Int = 0

    // 行为树运行时状态（不持久化：旧 pet_state.json 缺这些键也不影响解码）
    @Published var boredom: Double = 0
    @Published var affection: Double = 50
    @Published var currentActivity: PetActivity = .idle
    @Published var isAngry: Bool = false
    var consecutivePokes: Int = 0
    
    private let stateURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        // 统一使用标准的 Application Support 目录
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupportDir.appendingPathComponent("DebuSeek").path
        // 确保目录存在
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        
        stateURL = URL(fileURLWithPath: configDir).appendingPathComponent("pet_state.json")
        loadState()
    }
    
    func loadState() {
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do {
                let data = try Data(contentsOf: stateURL)
                let state = try decoder.decode(PetStateData.self, from: data)
                happiness = state.happiness
                hunger = state.hunger
                energy = state.energy
                isSleeping = state.isSleeping
                position = CGPoint(x: state.positionX, y: state.positionY)
                lastInteraction = state.lastInteraction ?? Date()
                wakeTargetEnergy = state.wakeTargetEnergy
                print("✅ Pet state loaded")
            } catch {
                print("❌ Failed to load pet state: \(error)")
                resetState()
            }
        } else {
            resetState()
        }
    }
    
    func saveState() {
        let data = PetStateData(
            happiness: happiness,
            hunger: hunger,
            energy: energy,
            isSleeping: isSleeping,
            positionX: position.x,
            positionY: position.y,
            lastInteraction: lastInteraction,
            wakeTargetEnergy: wakeTargetEnergy
        )
        do {
            let encoded = try encoder.encode(data)
            try encoded.write(to: stateURL, options: .atomic)
        } catch {
            print("❌ Failed to save pet state: \(error)")
        }
    }
    
    func resetState() {
        happiness = 100
        hunger = 0
        energy = 100
        isSleeping = false
        currentAnimation = "IDLE"
        position = CGPoint(x: 100, y: 100)
        boredom = 0
        affection = 50
        currentActivity = .idle
        isAngry = false
        consecutivePokes = 0
        wakeTargetEnergy = 0
        lastInteraction = Date()
        saveState()
    }
    
    func updateHappiness(_ delta: Int) {
        happiness = max(0, min(100, happiness + delta))
        saveState()
    }
    
    func updateHunger(_ delta: Int) {
        hunger = max(0, min(100, hunger + delta))
        saveState()
    }
    
    func updateEnergy(_ delta: Int) {
        energy = max(0, min(100, energy + delta))
        saveState()
        if energy == 0 {
            NotificationCenter.default.post(name: NSNotification.Name("PetEnergyDepleted"), object: nil)
        }
    }
    
    func setAnimation(_ animation: String) {
        currentAnimation = animation
    }
    
    func setPosition(_ pos: CGPoint) {
        position = pos
        if ConfigManager.shared.config.pet.position.rememberPosition {
            saveState()
        }
    }
    
    func setDragging(_ dragging: Bool) {
        isDragging = dragging
    }
    
    func updateLastInteraction() {
        lastInteraction = Date()
    }
    
    /// 精力归零即昏厥：鼠标/聊天都会被拦截，只能睡觉恢复。
    /// wakeTargetEnergy > 0 表示正在强制恢复中，此时仍视为昏厥，防止精力刚回到 1 点就能被点击。
    var isFainted: Bool { energy <= 0 || wakeTargetEnergy > 0 }

    var mood: PetMood {
        if isSleeping { return .sleeping }
        if happiness > 70 { return .happy }
        if happiness > 40 { return .normal }
        if happiness > 20 { return .sad }
        return .verySad
    }
    
    var needsAttention: Bool {
        hunger > 70 || happiness < 30 || energy < 20
    }
}

struct PetStateData: Codable {
    var happiness: Int
    var hunger: Int
    var energy: Int
    var isSleeping: Bool
    var positionX: Double
    var positionY: Double
    /// 旧 pet_state.json 没有这个字段；用可选值保证兼容。
    var lastInteraction: Date?
    var wakeTargetEnergy: Int = 0
}

enum PetMood {
    case happy
    case normal
    case sad
    case verySad
    case sleeping
    
    var emoji: String {
        switch self {
        case .happy: return "😊"
        case .normal: return "😐"
        case .sad: return "😢"
        case .verySad: return "😭"
        case .sleeping: return "😴"
        }
    }
    
    var color: Color {
        switch self {
        case .happy: return .green
        case .normal: return .blue
        case .sad: return .orange
        case .verySad: return .red
        case .sleeping: return .purple
        }
    }
}

// MARK: - Chat History

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    
    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    /// 仅用于 UI 的“上下文已压缩”分隔标记，不发送给 API。
    case systemNote = "system_note"
}

@MainActor
class ChatHistoryManager: ObservableObject {
    static let shared = ChatHistoryManager()
    
    @Published var messages: [ChatMessage] = []
    
    private let historyURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxHistory: Int
    
    private init() {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupportDir.appendingPathComponent("DebuSeek").path
        // 确保目录存在
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        
        historyURL = URL(fileURLWithPath: configDir).appendingPathComponent("chat_history.json")
        maxHistory = ConfigManager.shared.config.data.maxHistory
        loadHistory()
    }
    
    func loadHistory() {
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let data = try Data(contentsOf: historyURL)
                messages = try decoder.decode([ChatMessage].self, from: data)
                if messages.count > maxHistory {
                    messages = Array(messages.suffix(maxHistory))
                }
                print("✅ Chat history loaded: \(messages.count) messages")
            } catch {
                print("❌ Failed to load chat history: \(error)")
            }
        }
    }
    
    func saveHistory() {
        guard ConfigManager.shared.config.data.saveChatHistory else { return }
        do {
            let data = try encoder.encode(messages)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("❌ Failed to save chat history: \(error)")
        }
    }
    
    func addMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > maxHistory {
            messages.removeFirst(messages.count - maxHistory)
        }
        saveHistory()
    }
    
    func clearHistory() {
        messages.removeAll()
        saveHistory()
    }

    /// 只删除摘要快照里的旧消息，保留摘要期间新产生的对话。
    func removeOldest(_ count: Int) {
        guard count > 0, !messages.isEmpty else { return }
        messages.removeFirst(min(count, messages.count))
        saveHistory()
    }

    /// 最近一次“已压缩”分隔标记之后的对话；没有标记时返回全部历史。
    /// 自动压缩阈值和下一次摘要都只看这一段，避免不删历史后每轮重复压缩。
    func messagesSinceLastSummary() -> [ChatMessage] {
        let start: Int
        if let lastNote = messages.lastIndex(where: { $0.role == .systemNote }) {
            start = messages.index(after: lastNote)
        } else {
            start = messages.startIndex
        }
        guard start < messages.endIndex else { return [] }
        return messages[start...].filter { $0.role != .systemNote }
    }

    // MARK: - Export

    func exportHistoryJSON(to url: URL) throws {
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        let data = try exportEncoder.encode(messages)
        try data.write(to: url, options: .atomic)
    }

    func exportHistoryTXT(to url: URL) throws {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let petName = ConfigManager.shared.config.pet.name
        var lines: [String] = []
        var currentDay: String?

        for message in messages {
            let day = dayFormatter.string(from: message.timestamp)
            if day != currentDay {
                if currentDay != nil { lines.append("") }
                lines.append("[\(day)]")
                currentDay = day
            }

            let time = timeFormatter.string(from: message.timestamp)
            switch message.role {
            case .user:
                lines.append("[\(time)] 用户: \(message.content)")
            case .assistant:
                lines.append("[\(time)] \(petName): \(message.content)")
            case .system:
                lines.append("[\(time)] 系统: \(message.content)")
            case .systemNote:
                lines.append("[\(time)] \(message.content)")
            }
        }

        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func getRecentMessages(limit: Int = 10) -> [ChatMessage] {
        Array(messages.suffix(limit))
    }
    
    func getMessagesForAPI() -> [[String: String]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    }
}