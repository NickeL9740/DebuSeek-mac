import Foundation
import SwiftUI

// MARK: - Pet Activity

enum PetActivity: String {
    case idle
    case walk
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
    var energy: Int = 100
    @Published var isSleeping: Bool = false
    @Published var currentAnimation: String = "IDLE"
    @Published var position: CGPoint = CGPoint(x: 100, y: 100)
    @Published var isDragging: Bool = false
    @Published var lastInteraction: Date = Date()

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
            positionY: position.y
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
    
    func getRecentMessages(limit: Int = 10) -> [ChatMessage] {
        Array(messages.suffix(limit))
    }
    
    func getMessagesForAPI() -> [[String: String]] {
        messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    }
}