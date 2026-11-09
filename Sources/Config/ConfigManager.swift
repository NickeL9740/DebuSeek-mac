import Foundation
import Combine

// MARK: - Configuration Manager

@MainActor
class ConfigManager: ObservableObject {
    static let shared = ConfigManager()
    
    @Published var config: AppConfig = .default
    
    private let configURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        // 获取标准的 Application Support 目录
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // 拼接专属文件夹
        let configDir = appSupportDir.appendingPathComponent("DebuSeek").path
        // 确保目录存在
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        
        configURL = URL(fileURLWithPath: configDir).appendingPathComponent("config.json")
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadConfig()
    }
    
    func loadConfig() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                config = try decoder.decode(AppConfig.self, from: data)
                print("✅ Config loaded from \(configURL.path)")
                if migrateLegacyAnimationNames() {
                    saveConfig()
                }
            } catch {
                print("❌ Failed to load config: \(error)")
                config = .default
                saveConfig()
            }
        } else {
            print("📝 No config found, creating default")
            config = .default
            saveConfig()
        }
    }
    
    func saveConfig() {
        do {
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            print("💾 Config saved to \(configURL.path)")
        } catch {
            print("❌ Failed to save config: \(error)")
        }
    }
    
    /// 旧 config.json 里的小写动画名（happy/think/pet…）迁移为 Manifest 动作名（HAPPY/THINKING/HEAD_PAT…）
    @discardableResult
    private func migrateLegacyAnimationNames() -> Bool {
        let mapping: [String: String] = [
            "idle": "IDLE",
            "blink": "BLINK",
            "glance": "GLANCE",
            "think": "THINKING",
            "thinking": "THINKING",
            "walk": "WALKING",
            "happy": "HAPPY",
            "pet": "HEAD_PAT",
            "head_pat": "HEAD_PAT",
            "speak": "TALKING",
            "talking": "TALKING",
            "angry": "ANGRY",
            "poke": "POKE_REACT",
            "poke_react": "POKE_REACT",
            "tail": "TAIL_REACT",
            "tail_react": "TAIL_REACT",
            "eat": "EATING",
            "eating": "EATING",
            "sweep": "SWEEPING",
            "sweeping": "SWEEPING",
            "sleep": "SLEEPING",
            "sleeping": "SLEEPING",
            "drag": "DRAGGING",
            "dragging": "DRAGGING",
            "fall": "FALLING",
            "falling": "FALLING",
            "land": "LANDING",
            "landing": "LANDING",
            "dizzy": "DIZZY"
        ]

        var changed = false
        func migrate(_ name: inout String) {
            guard let mapped = mapping[name.lowercased()], mapped != name else { return }
            name = mapped
            changed = true
        }

        for index in config.interaction.click.reactions.indices {
            migrate(&config.interaction.click.reactions[index].animation)
        }
        migrate(&config.interaction.doubleClick.animation)
        migrate(&config.interaction.drag.animation)
        migrate(&config.interaction.longPress.animation)
        for index in config.interaction.feed.items.indices {
            migrate(&config.interaction.feed.items[index].animation)
        }
        return changed
    }
    
    func resetToDefault() {
        config = .default
        saveConfig()
    }
    
    func updatePetConfig(_ block: (inout PetConfig) -> Void) {
        block(&config.pet)
        saveConfig()
    }
    
    func updateTTSConfig(_ block: (inout TTSConfig) -> Void) {
        block(&config.tts)
        saveConfig()
    }
    
    func updateChatConfig(_ block: (inout ChatConfig) -> Void) {
        block(&config.chat)
        saveConfig()
    }
    
    func updateAutoSpeechConfig(_ block: (inout AutoSpeechConfig) -> Void) {
        block(&config.autoSpeech)
        saveConfig()
    }
    
    func updateTimeReportConfig(_ block: (inout TimeReportConfig) -> Void) {
        block(&config.timeReport)
        saveConfig()
    }
    
    func updateInteractionConfig(_ block: (inout InteractionConfig) -> Void) {
        block(&config.interaction)
        saveConfig()
    }
    
    func updateHotkeySettings(_ value: String) {
        config.hotkeySettings = value
        saveConfig()
    }
    
    func updateHotkeyChat(_ value: String) {
        config.hotkeyChat = value
        saveConfig()
    }
    
    func updateWindowConfig(_ block: (inout WindowConfig) -> Void) {
        block(&config.window)
        saveConfig()
    }
    
    func exportConfig(to url: URL) throws {
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
    
    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        config = try decoder.decode(AppConfig.self, from: data)
        saveConfig()
    }
}