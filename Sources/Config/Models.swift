import Foundation
import CoreGraphics

// MARK: - Configuration Models

struct AppConfig: Codable {
    var pet: PetConfig
    var tts: TTSConfig
    var chat: ChatConfig
    var autoSpeech: AutoSpeechConfig
    var timeReport: TimeReportConfig
    var interaction: InteractionConfig
    var window: WindowConfig
    var menuBar: MenuBarConfig
    var notifications: NotificationsConfig
    var data: DataConfig
    /// 难度与物理反馈参数
    var gameplay: GameplayConfig
    /// 全局快捷键（首次点击宠物后注册），格式如 "option+s"
    var hotkeySettings: String? = nil
    var hotkeyChat: String? = nil

    private enum CodingKeys: String, CodingKey {
        case pet, tts, chat, autoSpeech, timeReport, interaction, window, menuBar, notifications, data, gameplay
        case hotkeySettings, hotkeyChat
    }

    init(
        pet: PetConfig,
        tts: TTSConfig,
        chat: ChatConfig,
        autoSpeech: AutoSpeechConfig,
        timeReport: TimeReportConfig,
        interaction: InteractionConfig,
        window: WindowConfig,
        menuBar: MenuBarConfig,
        notifications: NotificationsConfig,
        data: DataConfig,
        gameplay: GameplayConfig = .default,
        hotkeySettings: String? = nil,
        hotkeyChat: String? = nil
    ) {
        self.pet = pet
        self.tts = tts
        self.chat = chat
        self.autoSpeech = autoSpeech
        self.timeReport = timeReport
        self.interaction = interaction
        self.window = window
        self.menuBar = menuBar
        self.notifications = notifications
        self.data = data
        self.gameplay = gameplay
        self.hotkeySettings = hotkeySettings
        self.hotkeyChat = hotkeyChat
    }

    /// 旧 config.json 没有 gameplay 等新字段时逐项兜底，避免整份配置被重置。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pet = try c.decodeIfPresent(PetConfig.self, forKey: .pet) ?? .default
        tts = try c.decodeIfPresent(TTSConfig.self, forKey: .tts) ?? .default
        chat = try c.decodeIfPresent(ChatConfig.self, forKey: .chat) ?? .default
        autoSpeech = try c.decodeIfPresent(AutoSpeechConfig.self, forKey: .autoSpeech) ?? .default
        timeReport = try c.decodeIfPresent(TimeReportConfig.self, forKey: .timeReport) ?? .default
        interaction = try c.decodeIfPresent(InteractionConfig.self, forKey: .interaction) ?? .default
        window = try c.decodeIfPresent(WindowConfig.self, forKey: .window) ?? .default
        menuBar = try c.decodeIfPresent(MenuBarConfig.self, forKey: .menuBar) ?? .default
        notifications = try c.decodeIfPresent(NotificationsConfig.self, forKey: .notifications) ?? .default
        data = try c.decodeIfPresent(DataConfig.self, forKey: .data) ?? .default
        gameplay = try c.decodeIfPresent(GameplayConfig.self, forKey: .gameplay) ?? .default
        hotkeySettings = try c.decodeIfPresent(String.self, forKey: .hotkeySettings)
        hotkeyChat = try c.decodeIfPresent(String.self, forKey: .hotkeyChat)
    }
    
    static let `default` = AppConfig(
        pet: PetConfig.default,
        tts: TTSConfig.default,
        chat: ChatConfig.default,
        autoSpeech: AutoSpeechConfig.default,
        timeReport: TimeReportConfig.default,
        interaction: InteractionConfig.default,
        window: WindowConfig.default,
        menuBar: MenuBarConfig.default,
        notifications: NotificationsConfig.default,
        data: DataConfig.default,
        gameplay: GameplayConfig.default
    )
}

struct PetConfig: Codable {
    var name: String
    var model: PetModelConfig
    var position: PetPositionConfig
    var size: PetSizeConfig
    var behavior: PetBehaviorConfig
    
    static let `default` = PetConfig(
        name: "大肥鱼",
        model: PetModelConfig.default,
        position: PetPositionConfig.default,
        size: PetSizeConfig.default,
        behavior: PetBehaviorConfig.default
    )
}

struct PetModelConfig: Codable {
    var scale: Double
    var opacity: Double
    /// 全局统一缩放系数（相对 187 分辨率原始像素）。默认 0.75，所有动作共用，保证比例一致。
    var petScale: Double

    // 命中区域：归一化坐标（0~1），原点在纹理左上角，y 向下。
    // 与 PetScene.hitTest 里的 (u, v) 完全一致，可直接用于可视化框选。
    var faceRect: CGRect
    var headRect: CGRect
    var bodyRect: CGRect
    var tailRect: CGRect

    static let defaultFaceRect = CGRect(x: 0.38, y: 0.22, width: 0.28, height: 0.24)
    static let defaultHeadRect = CGRect(x: 0.28, y: 0.04, width: 0.44, height: 0.48)
    static let defaultBodyRect = CGRect(x: 0.25, y: 0.50, width: 0.50, height: 0.44)
    static let defaultTailRect = CGRect(x: 0.64, y: 0.64, width: 0.26, height: 0.28)

    static let `default` = PetModelConfig(
        scale: 1.0,
        opacity: 1.0,
        petScale: 0.75,
        faceRect: defaultFaceRect,
        headRect: defaultHeadRect,
        bodyRect: defaultBodyRect,
        tailRect: defaultTailRect
    )

    init(
        scale: Double,
        opacity: Double,
        petScale: Double = 0.75,
        faceRect: CGRect = PetModelConfig.defaultFaceRect,
        headRect: CGRect = PetModelConfig.defaultHeadRect,
        bodyRect: CGRect = PetModelConfig.defaultBodyRect,
        tailRect: CGRect = PetModelConfig.defaultTailRect
    ) {
        self.scale = scale
        self.opacity = opacity
        self.petScale = petScale
        self.faceRect = faceRect
        self.headRect = headRect
        self.bodyRect = bodyRect
        self.tailRect = tailRect
    }

    enum CodingKeys: String, CodingKey {
        case scale
        case opacity
        case petScale
        case faceRect
        case headRect
        case bodyRect
        case tailRect
    }

    /// CGRect 在 macOS 的 CoreGraphics 里不自动符合 Codable，用这个 DTO 落 JSON。
    private struct RectDTO: Codable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.size.width
            height = rect.size.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        // 旧 config.json 没有 petScale：回落到默认 0.75，不重置用户配置
        petScale = try container.decodeIfPresent(Double.self, forKey: .petScale) ?? 0.75

        // 旧 config.json 没有命中框：使用默认值，保证升级后仍可点击
        faceRect = try container.decodeIfPresent(RectDTO.self, forKey: .faceRect)?.rect ?? Self.defaultFaceRect
        headRect = try container.decodeIfPresent(RectDTO.self, forKey: .headRect)?.rect ?? Self.defaultHeadRect
        bodyRect = try container.decodeIfPresent(RectDTO.self, forKey: .bodyRect)?.rect ?? Self.defaultBodyRect
        tailRect = try container.decodeIfPresent(RectDTO.self, forKey: .tailRect)?.rect ?? Self.defaultTailRect
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scale, forKey: .scale)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(petScale, forKey: .petScale)
        try container.encode(RectDTO(faceRect), forKey: .faceRect)
        try container.encode(RectDTO(headRect), forKey: .headRect)
        try container.encode(RectDTO(bodyRect), forKey: .bodyRect)
        try container.encode(RectDTO(tailRect), forKey: .tailRect)
    }
}

struct PetPositionConfig: Codable {
    var x: Double
    var y: Double
    var rememberPosition: Bool
    
    static let `default` = PetPositionConfig(
        x: 100,
        y: 100,
        rememberPosition: true
    )
}

struct PetSizeConfig: Codable {
    var width: Double
    var height: Double
    
    static let `default` = PetSizeConfig(width: 200, height: 200)
}

struct PetBehaviorConfig: Codable {
    var idleThreshold: Int
    var autoMove: Bool
    var moveInterval: Int
    var moveDistance: Double

    /// 行为决策的随机间隔范围（秒）。心跳每 tick 到期后重新随机，不再固定 10 秒。
    var activityMinInterval: Int
    var activityMaxInterval: Int

    /// 是否允许自主跳跃。
    var allowJump: Bool
    /// 每次行为决策时触发跳跃的概率（0~1）。
    var jumpProbability: Double

    private enum CodingKeys: String, CodingKey {
        case idleThreshold, autoMove, moveInterval, moveDistance
        case activityMinInterval, activityMaxInterval
        case allowJump, jumpProbability
    }

    init(
        idleThreshold: Int = 30,
        autoMove: Bool = true,
        moveInterval: Int = 120,
        moveDistance: Double = 50,
        activityMinInterval: Int = 5,
        activityMaxInterval: Int = 10,
        allowJump: Bool = true,
        jumpProbability: Double = 0.1
    ) {
        self.idleThreshold = idleThreshold
        self.autoMove = autoMove
        self.moveInterval = moveInterval
        self.moveDistance = moveDistance
        self.activityMinInterval = activityMinInterval
        self.activityMaxInterval = activityMaxInterval
        self.allowJump = allowJump
        self.jumpProbability = jumpProbability
    }

    /// 兼容旧 pet config：缺失新字段时回退到 5~10 秒 / 允许跳跃 / 10%。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idleThreshold = try container.decodeIfPresent(Int.self, forKey: .idleThreshold) ?? 30
        autoMove = try container.decodeIfPresent(Bool.self, forKey: .autoMove) ?? true
        moveInterval = try container.decodeIfPresent(Int.self, forKey: .moveInterval) ?? 120
        moveDistance = try container.decodeIfPresent(Double.self, forKey: .moveDistance) ?? 50
        activityMinInterval = try container.decodeIfPresent(Int.self, forKey: .activityMinInterval) ?? 5
        activityMaxInterval = try container.decodeIfPresent(Int.self, forKey: .activityMaxInterval) ?? 10
        allowJump = try container.decodeIfPresent(Bool.self, forKey: .allowJump) ?? true
        jumpProbability = try container.decodeIfPresent(Double.self, forKey: .jumpProbability) ?? 0.1
    }

    static let `default` = PetBehaviorConfig(
        idleThreshold: 30,
        autoMove: true,
        moveInterval: 120,
        moveDistance: 50,
        activityMinInterval: 5,
        activityMaxInterval: 10,
        allowJump: true,
        jumpProbability: 0.1
    )
}

// MARK: - TTS Configuration

struct TTSConfig: Codable {
    var enabled: Bool
    var provider: TTSProvider
    var cloud: CloudTTSConfig
    var localGptSovits: LocalGptSovitsConfig
    var fallbackToSystem: Bool
    
    static let `default` = TTSConfig(
        enabled: true,
        provider: .cloud,
        cloud: CloudTTSConfig.default,
        localGptSovits: LocalGptSovitsConfig.default,
        fallbackToSystem: true
    )
}

enum TTSProvider: String, Codable {
    case cloud = "cloud"
    case localGptSovits = "local_gpt_sovits"
    case system = "system"
}

struct CloudTTSConfig: Codable {
    var apiUrl: String
    var apiKey: String
    var voice: String
    var speed: Double
    var pitch: Double
    var volume: Double
    
    static let `default` = CloudTTSConfig(
        apiUrl: "https://api.example.com/tts",
        apiKey: "",
        voice: "zh-CN-XiaoxiaoNeural",
        speed: 1.0,
        pitch: 1.0,
        volume: 0.8
    )
}

struct LocalGptSovitsConfig: Codable {
    var apiUrl: String
    var referWavPath: String
    var promptText: String
    var promptLanguage: String
    var textLanguage: String
    var topK: Int
    var topP: Double
    var temperature: Double
    
    static let `default` = LocalGptSovitsConfig(
        apiUrl: "http://localhost:9880",
        referWavPath: "",
        promptText: "",
        promptLanguage: "zh",
        textLanguage: "zh",
        topK: 5,
        topP: 0.8,
        temperature: 0.8
    )
}

// MARK: - Chat Configuration

struct ChatConfig: Codable {
    var enabled: Bool
    var provider: ChatProvider
    var deepseek: DeepSeekConfig
    var localLlm: LocalLLMConfig
    /// 聊天回复是否朗读。默认 false：聊天只显示气泡，不播 TALKING、不调用 TTS。
    var readChatAloud: Bool = false

    // MARK: - Rolling Memory

    /// 历史对话压缩后的长期回忆录；会作为 system 的一部分注入聊天请求。
    var memorySummary: String = ""
    /// 用户自定义的摘要提示词；支持 {transcript} 占位符，留空则用内置提示词。
    var customSummaryPrompt: String = ""
    /// 长期记忆总开关：关闭后既不注入回忆录，也不允许压缩。
    var enableMemorySummarization: Bool = false
    /// 历史达到 autoSummarizeRounds * 2 条时，是否自动后台压缩。
    var enableAutoSummarize: Bool = false
    /// 自动压缩的轮数阈值（一轮 = 一条 user + 一条 assistant）。
    var autoSummarizeRounds: Int = 10

    // MARK: - Token Awareness

    /// 是否在本次请求最后一条 user 消息末尾临时追加极简 Token 提示。
    /// 该提示只存在于请求数组中，绝不写入 ChatHistoryManager。
    var injectTokenUsage: Bool = false
    /// 用户希望宠物怎么称呼自己；空字符串表示不注入。
    var userNickname: String = ""

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, deepseek, localLlm, readChatAloud
        case memorySummary, customSummaryPrompt, enableMemorySummarization, enableAutoSummarize, autoSummarizeRounds
        case injectTokenUsage, userNickname
    }

    init(
        enabled: Bool,
        provider: ChatProvider,
        deepseek: DeepSeekConfig,
        localLlm: LocalLLMConfig,
        readChatAloud: Bool = false,
        memorySummary: String = "",
        customSummaryPrompt: String = "",
        enableMemorySummarization: Bool = false,
        enableAutoSummarize: Bool = false,
        autoSummarizeRounds: Int = 10,
        injectTokenUsage: Bool = false,
        userNickname: String = ""
    ) {
        self.enabled = enabled
        self.provider = provider
        self.deepseek = deepseek
        self.localLlm = localLlm
        self.readChatAloud = readChatAloud
        self.memorySummary = memorySummary
        self.customSummaryPrompt = customSummaryPrompt
        self.enableMemorySummarization = enableMemorySummarization
        self.enableAutoSummarize = enableAutoSummarize
        self.autoSummarizeRounds = autoSummarizeRounds
        self.injectTokenUsage = injectTokenUsage
        self.userNickname = userNickname
    }

    /// 兼容旧 config.json：所有新增字段缺失时都走默认值，避免整份配置解码失败被重置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        provider = try container.decodeIfPresent(ChatProvider.self, forKey: .provider) ?? .deepseek
        deepseek = try container.decodeIfPresent(DeepSeekConfig.self, forKey: .deepseek) ?? .default
        localLlm = try container.decodeIfPresent(LocalLLMConfig.self, forKey: .localLlm) ?? .default
        readChatAloud = try container.decodeIfPresent(Bool.self, forKey: .readChatAloud) ?? false
        memorySummary = try container.decodeIfPresent(String.self, forKey: .memorySummary) ?? ""
        customSummaryPrompt = try container.decodeIfPresent(String.self, forKey: .customSummaryPrompt) ?? ""
        enableMemorySummarization = try container.decodeIfPresent(Bool.self, forKey: .enableMemorySummarization) ?? false
        enableAutoSummarize = try container.decodeIfPresent(Bool.self, forKey: .enableAutoSummarize) ?? false
        autoSummarizeRounds = try container.decodeIfPresent(Int.self, forKey: .autoSummarizeRounds) ?? 10
        injectTokenUsage = try container.decodeIfPresent(Bool.self, forKey: .injectTokenUsage) ?? false
        userNickname = try container.decodeIfPresent(String.self, forKey: .userNickname) ?? ""
    }

    /// 当前 provider 实际生效的系统提示词（请求层统一从这里读取）
    var systemPrompt: String {
        switch provider {
        case .deepseek:
            return deepseek.systemPrompt
        case .localLlm:
            return localLlm.systemPrompt
        }
    }
    
    static let `default` = ChatConfig(
        enabled: true,
        provider: .deepseek,
        deepseek: DeepSeekConfig.default,
        localLlm: LocalLLMConfig.default
    )
}

enum ChatProvider: String, Codable {
    case deepseek = "deepseek"
    case localLlm = "local_llm"
}

struct DeepSeekConfig: Codable {
    var apiUrl: String
    var apiKey: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var systemPrompt: String
    
    static let `default` = DeepSeekConfig(
        apiUrl: "https://api.deepseek.com/v1/chat/completions",
        apiKey: "",
        model: "deepseek-chat",
        temperature: 0.7,
        maxTokens: 500,
        systemPrompt: "你是大肥鱼，一个可爱的桌面宠物。你性格活泼可爱，偶尔会卖萌，说话简短自然，像好朋友一样聊天。不要太正式，多用语气词。"
    )
}

struct LocalLLMConfig: Codable {
    var apiUrl: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var systemPrompt: String
    
    static let `default` = LocalLLMConfig(
        apiUrl: "http://localhost:11434/v1/chat/completions",
        model: "qwen2.5:7b",
        temperature: 0.7,
        maxTokens: 500,
        systemPrompt: "你是大肥鱼，一个可爱的桌面宠物。你性格活泼可爱，偶尔会卖萌，说话简短自然，像好朋友一样聊天。"
    )
}

// MARK: - Auto Speech Configuration

struct AutoSpeechConfig: Codable {
    var enabled: Bool
    var intervalMin: Int
    var intervalMax: Int
    var categories: [String: SpeechCategoryConfig]
    
    static let `default` = AutoSpeechConfig(
        enabled: true,
        intervalMin: 180,
        intervalMax: 600,
        categories: [
            "greeting": SpeechCategoryConfig(enabled: true, weight: 20, lines: [
                "嘿！你好呀~", "哇，又见面了！", "今天过得怎么样？", "我在这儿等你很久啦~"
            ]),
            "encouragement": SpeechCategoryConfig(enabled: true, weight: 25, lines: [
                "加油哦！你一定行的！", "别太累了，休息一下吧~", "相信自己，你很棒的！", "小鱼为你加油！🐟"
            ]),
            "curiosity": SpeechCategoryConfig(enabled: true, weight: 15, lines: [
                "你在忙什么呢？", "那个图标是干嘛的？", "我也想学会用电脑~", "屏幕上那个会动吗？"
            ]),
            "random_thoughts": SpeechCategoryConfig(enabled: true, weight: 20, lines: [
                "肚子饿了...想吃小虾米~", "好想游泳呀~🏊", "泡泡...泡泡...🫧", "今天水温刚刚好~"
            ]),
            "custom": SpeechCategoryConfig(enabled: true, weight: 20, lines: [])
        ]
    )
}

struct SpeechCategoryConfig: Codable {
    var enabled: Bool
    var weight: Int
    var lines: [String]
}

// MARK: - Time Report Configuration

struct TimeReportConfig: Codable {
    var enabled: Bool
    var intervalMinutes: Int
    var announceOnHour: Bool
    var announceOnHalfHour: Bool
    var format: String
    var phrases: [String]
    
    static let `default` = TimeReportConfig(
        enabled: true,
        intervalMinutes: 60,
        announceOnHour: true,
        announceOnHalfHour: false,
        format: "HH点mm分",
        phrases: [
            "现在是{time}啦~",
            "嘀嗒嘀嗒，{time}了哦~",
            "时间过得真快，已经{time}啦！",
            "报时：{time}～"
        ]
    )
}

// MARK: - Interaction Configuration

struct InteractionConfig: Codable {
    var click: ClickInteractionConfig
    var doubleClick: DoubleClickInteractionConfig
    var rightClick: RightClickInteractionConfig
    var drag: DragInteractionConfig
    var longPress: LongPressInteractionConfig
    var feed: FeedInteractionConfig
    /// 物理互动是否直接请求大模型（关闭时走 DialogueManager 预设台词）
    var useAIForInteraction: Bool
    /// 两次 AI 互动请求之间的最小间隔（秒）
    var apiRequestCooldown: Double
    /// 宠物在空中时跳过 AI 请求，避免抛掷/落地瞬间刷请求
    var skipAIWhileAirborne: Bool

    static let `default` = InteractionConfig(
        click: ClickInteractionConfig.default,
        doubleClick: DoubleClickInteractionConfig.default,
        rightClick: RightClickInteractionConfig.default,
        drag: DragInteractionConfig.default,
        longPress: LongPressInteractionConfig.default,
        feed: FeedInteractionConfig.default,
        useAIForInteraction: false,
        apiRequestCooldown: 1.0,
        skipAIWhileAirborne: true
    )

    init(
        click: ClickInteractionConfig,
        doubleClick: DoubleClickInteractionConfig,
        rightClick: RightClickInteractionConfig,
        drag: DragInteractionConfig,
        longPress: LongPressInteractionConfig,
        feed: FeedInteractionConfig,
        useAIForInteraction: Bool = false,
        apiRequestCooldown: Double = 1.0,
        skipAIWhileAirborne: Bool = true
    ) {
        self.click = click
        self.doubleClick = doubleClick
        self.rightClick = rightClick
        self.drag = drag
        self.longPress = longPress
        self.feed = feed
        self.useAIForInteraction = useAIForInteraction
        self.apiRequestCooldown = apiRequestCooldown
        self.skipAIWhileAirborne = skipAIWhileAirborne
    }

    enum CodingKeys: String, CodingKey {
        case click
        case doubleClick
        case rightClick
        case drag
        case longPress
        case feed
        case useAIForInteraction
        case apiRequestCooldown
        case skipAIWhileAirborne
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        click = try container.decodeIfPresent(ClickInteractionConfig.self, forKey: .click) ?? .default
        doubleClick = try container.decodeIfPresent(DoubleClickInteractionConfig.self, forKey: .doubleClick) ?? .default
        rightClick = try container.decodeIfPresent(RightClickInteractionConfig.self, forKey: .rightClick) ?? .default
        drag = try container.decodeIfPresent(DragInteractionConfig.self, forKey: .drag) ?? .default
        longPress = try container.decodeIfPresent(LongPressInteractionConfig.self, forKey: .longPress) ?? .default
        feed = try container.decodeIfPresent(FeedInteractionConfig.self, forKey: .feed) ?? .default
        useAIForInteraction = try container.decodeIfPresent(Bool.self, forKey: .useAIForInteraction) ?? false
        apiRequestCooldown = try container.decodeIfPresent(Double.self, forKey: .apiRequestCooldown) ?? 1.0
        skipAIWhileAirborne = try container.decodeIfPresent(Bool.self, forKey: .skipAIWhileAirborne) ?? true
    }
}

struct ClickInteractionConfig: Codable {
    var enabled: Bool
    var reactions: [ClickReactionConfig]
    
    static let `default` = ClickInteractionConfig(
        enabled: true,
        reactions: [
            ClickReactionConfig(animation: "HAPPY", probability: 0.4, speak: true, lines: ["嘿嘿~", "痒痒~", "别戳我啦！"]),
            ClickReactionConfig(animation: "THINKING", probability: 0.3, speak: true, lines: ["嗯？", "怎么了？", "在看什么？"]),
            ClickReactionConfig(animation: "HEAD_PAT", probability: 0.3, speak: false, lines: [])
        ]
    )
}

struct ClickReactionConfig: Codable, Identifiable {
    /// 稳定身份：用于 SwiftUI ForEach，避免用数组下标导致删除/编辑错位。
    /// 不参与 Codable，旧配置文件解码时自动生成新的 UUID。
    let id: UUID
    var animation: String
    var probability: Double
    var speak: Bool
    var lines: [String]

    private enum CodingKeys: String, CodingKey {
        case animation, probability, speak, lines
    }

    init(id: UUID = UUID(), animation: String, probability: Double, speak: Bool, lines: [String]) {
        self.id = id
        self.animation = animation
        self.probability = probability
        self.speak = speak
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        animation = try container.decodeIfPresent(String.self, forKey: .animation) ?? ""
        probability = try container.decodeIfPresent(Double.self, forKey: .probability) ?? 0
        speak = try container.decodeIfPresent(Bool.self, forKey: .speak) ?? true
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
}

struct DoubleClickInteractionConfig: Codable {
    var enabled: Bool
    var animation: String
    var speak: Bool
    var lines: [String]
    
    static let `default` = DoubleClickInteractionConfig(
        enabled: true,
        animation: "EATING",
        speak: true,
        lines: ["哇！", "开心！", "耶～"]
    )
}

struct RightClickInteractionConfig: Codable {
    var enabled: Bool
    var showMenu: Bool
    
    static let `default` = RightClickInteractionConfig(enabled: true, showMenu: true)
}

struct DragInteractionConfig: Codable {
    var enabled: Bool
    var followMouse: Bool
    var animation: String
    var speakOnRelease: Bool
    var releaseLines: [String]
    
    static let `default` = DragInteractionConfig(
        enabled: true,
        followMouse: true,
        animation: "DRAGGING",
        speakOnRelease: true,
        releaseLines: ["放下我！", "飞翔的感觉！", "哇哦～"]
    )
}

struct LongPressInteractionConfig: Codable {
    var enabled: Bool
    var duration: Double
    var animation: String
    var speak: Bool
    var lines: [String]
    
    static let `default` = LongPressInteractionConfig(
        enabled: true,
        duration: 1.0,
        animation: "HEAD_PAT",
        speak: true,
        lines: ["舒服~", "继续摸~", "好舒服呀~"]
    )
}

struct FeedInteractionConfig: Codable {
    var enabled: Bool
    var items: [FeedItemConfig]
    
    static let `default` = FeedInteractionConfig(
        enabled: true,
        items: defaultItems(for: .normal)
    )

    /// 按难度返回预设食物与价格；旧配置里的 price 仍然按 0 兼容。
    static func defaultItems(for difficulty: GameplayDifficulty) -> [FeedItemConfig] {
        let shrimp: Int
        let seaweed: Int
        let candy: Int
        switch difficulty {
        case .easy:
            shrimp = 50; seaweed = 20; candy = 80
        case .normal:
            shrimp = 100; seaweed = 40; candy = 150
        case .realistic:
            shrimp = 200; seaweed = 80; candy = 300
        }
        return [
            FeedItemConfig(name: "小虾米", emoji: "🍤", happiness: 10, satiety: 12, energy: 5, price: shrimp, animation: "EATING", lines: ["好吃！", "谢谢~", "还要！"]),
            FeedItemConfig(name: "海藻", emoji: "🌿", happiness: 5, satiety: 6, energy: 2, price: seaweed, animation: "EATING", lines: ["健康~", "咕嘟~"]),
            FeedItemConfig(name: "泡泡糖", emoji: "🫧", happiness: 15, satiety: 8, energy: 10, price: candy, animation: "HAPPY", lines: ["甜甜的！", "吹泡泡~"])
        ]
    }
}

struct FeedItemConfig: Codable, Identifiable {
    /// 稳定身份：ForEach 删除/编辑不再依赖数组下标。
    let id: UUID
    var name: String
    var emoji: String
    var happiness: Int
    /// 饱腹度加成：喂食时 hunger 减少这么多
    var satiety: Int
    /// 精力加成：可以为负
    var energy: Int
    /// 价格（Token 货币）；0 表示免费
    var price: Int
    var animation: String
    var lines: [String]

    private enum CodingKeys: String, CodingKey {
        case name, emoji, happiness, satiety, energy, price, animation, lines
    }

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        happiness: Int,
        satiety: Int = 0,
        energy: Int = 0,
        price: Int = 0,
        animation: String,
        lines: [String]
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.happiness = happiness
        self.satiety = satiety
        self.energy = energy
        self.price = price
        self.animation = animation
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        happiness = try container.decodeIfPresent(Int.self, forKey: .happiness) ?? 0
        satiety = try container.decodeIfPresent(Int.self, forKey: .satiety) ?? 0
        energy = try container.decodeIfPresent(Int.self, forKey: .energy) ?? 0
        price = try container.decodeIfPresent(Int.self, forKey: .price) ?? 0
        animation = try container.decodeIfPresent(String.self, forKey: .animation) ?? ""
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
}

// MARK: - Gameplay Configuration

enum GameplayDifficulty: String, Codable, CaseIterable, Identifiable {
    case easy
    case normal
    case realistic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: return "轻松"
        case .normal: return "普通"
        case .realistic: return "拟真"
        }
    }
}

/// 难度、消耗倍率与物理反馈。所有新字段都有默认值，旧配置可直接解码。
struct GameplayConfig: Codable {
    var difficulty: GameplayDifficulty
    /// 精力消耗倍率
    var energyMultiplier: Double
    /// 饥饿增长倍率
    var hungerMultiplier: Double
    /// 心情变化倍率
    var happinessMultiplier: Double
    /// 撞墙扣心情
    var wallHappinessPenalty: Int
    /// 撞墙扣精力
    var wallEnergyPenalty: Int
    /// 无碰撞落地奖励心情
    var landingHappinessReward: Int
    /// 地板安全区高度：窗口底边低于该值时，松手不抛掷、落地不扣血
    var floorSafeHeight: CGFloat

    static let `default` = GameplayConfig(
        difficulty: .normal,
        energyMultiplier: 1.0,
        hungerMultiplier: 1.0,
        happinessMultiplier: 1.0,
        wallHappinessPenalty: 12,
        wallEnergyPenalty: 30,
        landingHappinessReward: 2,
        floorSafeHeight: 200
    )

    init(
        difficulty: GameplayDifficulty = .normal,
        energyMultiplier: Double = 1.0,
        hungerMultiplier: Double = 1.0,
        happinessMultiplier: Double = 1.0,
        wallHappinessPenalty: Int = 12,
        wallEnergyPenalty: Int = 30,
        landingHappinessReward: Int = 2,
        floorSafeHeight: CGFloat = 200
    ) {
        self.difficulty = difficulty
        self.energyMultiplier = energyMultiplier
        self.hungerMultiplier = hungerMultiplier
        self.happinessMultiplier = happinessMultiplier
        self.wallHappinessPenalty = wallHappinessPenalty
        self.wallEnergyPenalty = wallEnergyPenalty
        self.landingHappinessReward = landingHappinessReward
        self.floorSafeHeight = floorSafeHeight
    }

    private enum CodingKeys: String, CodingKey {
        case difficulty, energyMultiplier, hungerMultiplier, happinessMultiplier
        case wallHappinessPenalty, wallEnergyPenalty, landingHappinessReward
        case floorSafeHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let diff = try c.decodeIfPresent(GameplayDifficulty.self, forKey: .difficulty) ?? .normal
        let preset = GameplayConfig.recommended(for: diff)
        difficulty = diff
        energyMultiplier = try c.decodeIfPresent(Double.self, forKey: .energyMultiplier) ?? preset.energyMultiplier
        hungerMultiplier = try c.decodeIfPresent(Double.self, forKey: .hungerMultiplier) ?? preset.hungerMultiplier
        happinessMultiplier = try c.decodeIfPresent(Double.self, forKey: .happinessMultiplier) ?? preset.happinessMultiplier
        wallHappinessPenalty = try c.decodeIfPresent(Int.self, forKey: .wallHappinessPenalty) ?? preset.wallHappinessPenalty
        wallEnergyPenalty = try c.decodeIfPresent(Int.self, forKey: .wallEnergyPenalty) ?? preset.wallEnergyPenalty
        landingHappinessReward = try c.decodeIfPresent(Int.self, forKey: .landingHappinessReward) ?? preset.landingHappinessReward
        floorSafeHeight = try c.decodeIfPresent(CGFloat.self, forKey: .floorSafeHeight) ?? preset.floorSafeHeight
    }

    static func recommended(for difficulty: GameplayDifficulty) -> GameplayConfig {
        switch difficulty {
        case .easy:
            return GameplayConfig(
                difficulty: .easy,
                energyMultiplier: 0.7,
                hungerMultiplier: 0.8,
                happinessMultiplier: 0.7,
                wallHappinessPenalty: 8,
                wallEnergyPenalty: 20,
                landingHappinessReward: 3,
                floorSafeHeight: 200
            )
        case .normal:
            return GameplayConfig(
                difficulty: .normal,
                energyMultiplier: 1.0,
                hungerMultiplier: 1.0,
                happinessMultiplier: 1.0,
                wallHappinessPenalty: 12,
                wallEnergyPenalty: 30,
                landingHappinessReward: 2,
                floorSafeHeight: 200
            )
        case .realistic:
            return GameplayConfig(
                difficulty: .realistic,
                energyMultiplier: 1.5,
                hungerMultiplier: 1.3,
                happinessMultiplier: 1.4,
                wallHappinessPenalty: 20,
                wallEnergyPenalty: 45,
                landingHappinessReward: 1,
                floorSafeHeight: 200
            )
        }
    }
}

// MARK: - Window Configuration

struct WindowConfig: Codable {
    enum WindowLevel: String, Codable, CaseIterable {
        case normal = "normal"
        case floating = "floating"
        case statusBar = "statusbar"
        case popUpMenu = "popupmenu"
        case screenSaver = "screensaver"
    }
    
    var level: WindowLevel
    var ignoresMouseEvents: Bool
    var backgroundColor: String
    var alwaysOnTop: Bool
    var clickThroughWhenIdle: Bool
    var idleTimeout: Int
    
    static let `default` = WindowConfig(
        level: .floating,
        ignoresMouseEvents: false,
        backgroundColor: "clear",
        alwaysOnTop: true,
        clickThroughWhenIdle: false,
        idleTimeout: 5
    )
}

// MARK: - Menu Bar Configuration

struct MenuBarConfig: Codable {
    var enabled: Bool
    var showStatus: Bool
    var icon: String
    
    static let `default` = MenuBarConfig(enabled: true, showStatus: true, icon: "fish")
}

// MARK: - Notifications Configuration

struct NotificationsConfig: Codable {
    var enabled: Bool
    var showSpeech: Bool
    var showTimeReport: Bool
    
    static let `default` = NotificationsConfig(enabled: true, showSpeech: true, showTimeReport: true)
}

// MARK: - Data Configuration

struct DataConfig: Codable {
    var saveChatHistory: Bool
    var maxHistory: Int
    var savePosition: Bool
    var saveHappiness: Bool
    
    static let `default` = DataConfig(
        saveChatHistory: true,
        maxHistory: 100,
        savePosition: true,
        saveHappiness: true
    )
}