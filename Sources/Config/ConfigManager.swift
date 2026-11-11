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

    func updateGameplayConfig(_ block: (inout GameplayConfig) -> Void) {
        block(&config.gameplay)
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

// MARK: - Token Usage

/// 轻量 Token 统计：`usage.total_tokens` 累加后持久化。
/// `todayTokens` 按自然日重置；`totalTokens` 永久累计。
@MainActor
final class UsageManager: ObservableObject {
    static let shared = UsageManager()

    @Published private(set) var todayTokens: Int = 0
    @Published private(set) var totalTokens: Int = 0
    /// 今日 prompt cache miss Token（Token 货币的主要来源）
    @Published private(set) var todayCacheMiss: Int = 0
    /// 今日 completion Token
    @Published private(set) var todayOutput: Int = 0
    /// 全局货币池：不随自然日重置，喂食从这里扣费。
    @Published private(set) var totalCurrency: Int = 0

    /// 可用货币直接读全局货币池。
    var availableCurrency: Int { max(0, totalCurrency) }

    private let defaults = UserDefaults.standard
    private let todayKey = "debuSeek.usage.todayTokens"
    private let totalKey = "debuSeek.usage.totalTokens"
    private let cacheMissKey = "debuSeek.usage.todayCacheMiss"
    private let outputKey = "debuSeek.usage.todayOutput"
    private let totalCurrencyKey = "debuSeek.usage.totalCurrency"
    private let dayKey = "debuSeek.usage.day"

    private init() {
        todayTokens = defaults.integer(forKey: todayKey)
        totalTokens = defaults.integer(forKey: totalKey)
        todayCacheMiss = defaults.integer(forKey: cacheMissKey)
        todayOutput = defaults.integer(forKey: outputKey)

        // 新字段：老版本没有 totalCurrency，就把当天剩余货币迁移进来。
        if defaults.object(forKey: totalCurrencyKey) == nil {
            totalCurrency = max(0, todayCacheMiss + todayOutput)
            defaults.set(totalCurrency, forKey: totalCurrencyKey)
        } else {
            totalCurrency = max(0, defaults.integer(forKey: totalCurrencyKey))
        }

        let today = Self.dayString()
        if defaults.string(forKey: dayKey) != today {
            resetToday()
            defaults.set(today, forKey: dayKey)
        }
    }

    func add(_ usage: ChatUsage) {
        guard usage.totalTokens > 0 || usage.cacheMissTokens > 0 || usage.outputTokens > 0 else { return }
        rolloverIfNeeded()

        todayTokens += max(0, usage.totalTokens)
        totalTokens += max(0, usage.totalTokens)
        let earned = max(0, usage.cacheMissTokens) + max(0, usage.outputTokens)
        todayCacheMiss += max(0, usage.cacheMissTokens)
        todayOutput += max(0, usage.outputTokens)
        totalCurrency += earned
        persist()
    }

    /// 扣货币；余额不足返回 false，不修改余额。
    @discardableResult
    func spend(_ amount: Int) -> Bool {
        guard amount > 0 else { return true }
        rolloverIfNeeded()
        guard totalCurrency >= amount else { return false }

        totalCurrency = max(0, totalCurrency - amount)
        persist()
        return true
    }

    func resetAll() {
        todayTokens = 0
        totalTokens = 0
        todayCacheMiss = 0
        todayOutput = 0
        totalCurrency = 0
        defaults.set(0, forKey: todayKey)
        defaults.set(0, forKey: totalKey)
        defaults.set(0, forKey: cacheMissKey)
        defaults.set(0, forKey: outputKey)
        defaults.set(0, forKey: totalCurrencyKey)
        defaults.set(Self.dayString(), forKey: dayKey)
    }

    private func resetToday() {
        todayTokens = 0
        todayCacheMiss = 0
        todayOutput = 0
        defaults.set(0, forKey: todayKey)
        defaults.set(0, forKey: cacheMissKey)
        defaults.set(0, forKey: outputKey)
    }

    private func persist() {
        defaults.set(todayTokens, forKey: todayKey)
        defaults.set(totalTokens, forKey: totalKey)
        defaults.set(todayCacheMiss, forKey: cacheMissKey)
        defaults.set(todayOutput, forKey: outputKey)
        defaults.set(totalCurrency, forKey: totalCurrencyKey)
    }

    private func rolloverIfNeeded() {
        let today = Self.dayString()
        guard defaults.string(forKey: dayKey) != today else { return }
        resetToday()
        defaults.set(today, forKey: dayKey)
    }

    private static func dayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
