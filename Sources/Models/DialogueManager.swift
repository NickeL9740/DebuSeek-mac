import Foundation
import AppKit

// MARK: - Awareness Manager（心跳驱动，无自己的 Timer）

/// 极简前台感知：由 PetController 心跳每 2 tick 调一次 `sample()`。
@MainActor
final class AwarenessManager {
    private(set) var frontmostApp: String = ""
    private(set) var appCategory: String = "other"

    func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        frontmostApp = app.localizedName ?? app.bundleIdentifier ?? ""
        appCategory = Self.category(for: frontmostApp)
    }

    static func category(for appName: String) -> String {
        let codingApps = ["Xcode", "VS Code", "Visual Studio Code", "Sublime Text", "Vim", "Neovim", "IntelliJ", "PyCharm", "Cursor", "Terminal", "iTerm"]
        let documentApps = ["Pages", "Word", "TextEdit", "Notes", "Obsidian", "Notion", "Preview"]
        let videoApps = ["QuickTime Player", "VLC", "IINA", "Safari", "Chrome", "Firefox"]

        if codingApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { return "coding" }
        if documentApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { return "document" }
        if videoApps.contains(where: { appName.localizedCaseInsensitiveContains($0) }) { return "video" }
        return "other"
    }
}

// MARK: - Dialogue Interaction Type

enum DialogueInteractionType {
    case click
    case longPress
    case doubleClick
    case dragStart
    case dragEnd
}

// MARK: - Dialogue Manager（12 个分类 JSON + 上下文/交互取词）

@MainActor
final class DialogueManager {
    /// 一条台词：文本 + 语气 + 权重（数组内越靠前权重越高）
    struct Line {
        let text: String
        let tone: String
        let weight: Double
    }

    /// 12 个分类，与 Resources/Models/fish_pet/dialogue/*.json 一一对应
    static let categories = [
        "idle", "routine", "relationship", "interaction",
        "state", "coding", "document", "video",
        "daily", "github", "late_night", "inner_voice"
    ]

    private(set) var linesByCategory: [String: [Line]] = [:]
    private var lastSpokenAt: [String: Date] = [:]
    // 测试期 12s；文档原定 30s，验收后可调回
    private let cooldown: TimeInterval = 12

    private let petState: PetState
    private let awareness: AwarenessManager

    init(petState: PetState, awareness: AwarenessManager) {
        self.petState = petState
        self.awareness = awareness
        loadDialogues()
    }

    // MARK: - Loading

    private func loadDialogues() {
        guard let root = ResourceResolver.findDialogueRoot() else {
            NSLog("⚠️ DialogueManager: 未找到 dialogue 目录")
            return
        }

        var total = 0
        for category in Self.categories {
            let path = "\(root)/\(category).json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let rootDict = object as? [String: Any] else {
                continue
            }

            // 兼容两种结构：
            // 1) 扁平：{"lines": {"standard": [...]}}
            // 2) 分组：{"idle": {"standard": [...]}, "return": {...}}
            // 统一递归摊平成 Line，tone 取最内层字典的 key。
            var lines: [Line] = []
            collectLines(from: rootDict, tone: nil, into: &lines)

            guard !lines.isEmpty else { continue }
            linesByCategory[category] = lines
            total += lines.count
        }

        NSLog("💬 DialogueManager: 已加载 \(linesByCategory.count)/\(Self.categories.count) 个分类，共 \(total) 条台词")
    }

    private func collectLines(from object: Any, tone: String?, into lines: inout [Line]) {
        if let texts = object as? [String] {
            for (index, text) in texts.enumerated() {
                let weight = Double(texts.count - index)
                lines.append(Line(text: text, tone: tone ?? "standard", weight: weight))
            }
            return
        }

        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                collectLines(from: value, tone: key, into: &lines)
            }
        }
    }

    // MARK: - Speaking

    /// 分类冷却 + 加权随机。冷却中返回 nil。`forced` 跳过冷却。
    @discardableResult
    func speak(category: String, forced: Bool = false) -> String? {
        guard let lines = linesByCategory[category], !lines.isEmpty else { return nil }

        if !forced, let last = lastSpokenAt[category],
           Date().timeIntervalSince(last) < cooldown {
            return nil
        }

        let totalWeight = lines.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        var random = Double.random(in: 0..<totalWeight)
        var selected: Line?
        for line in lines {
            random -= line.weight
            if random <= 0 {
                selected = line
                break
            }
        }
        guard let line = selected ?? lines.last else { return nil }

        lastSpokenAt[category] = Date()
        return line.text
    }

    /// 上下文取词：angry → state；sleep/eat → routine；
    /// 前台 App 分类（coding/document/video）→ 对应分类；深夜/白天 → late_night/idle。
    func speakForContext() -> String? {
        let category: String

        if petState.isAngry {
            category = "state"
        } else if petState.isSleeping || petState.currentActivity == .eat {
            category = "routine"
        } else if awareness.appCategory != "other" {
            category = awareness.appCategory
        } else {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 22 || hour < 5 {
                category = "late_night"
            } else if Bool.random() {
                category = "idle"
            } else {
                category = "daily"
            }
        }

        if let line = speak(category: category) { return line }
        // 主分类冷却中时，换几个兜底分类，避免自动说话被冷却“吞掉”
        for fallback in ["idle", "daily", "inner_voice"] {
            if let line = speak(category: fallback) { return line }
        }
        return nil
    }

    /// 交互取词：点击 → interaction；长按 → relationship；双击 → routine；拖拽 → state。
    func speakOnInteraction(zone: HitZone, type: DialogueInteractionType) -> String? {
        switch type {
        case .click:
            return speak(category: "interaction")
        case .longPress:
            return speak(category: "relationship")
        case .doubleClick:
            return speak(category: "routine")
        case .dragStart, .dragEnd:
            return speak(category: "state")
        }
    }
}
