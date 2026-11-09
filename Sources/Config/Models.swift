import Foundation

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
    /// 全局快捷键（首次点击宠物后注册），格式如 "option+s"
    var hotkeySettings: String? = nil
    var hotkeyChat: String? = nil
    
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
        data: DataConfig.default
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
    
    static let `default` = PetBehaviorConfig(
        idleThreshold: 30,
        autoMove: true,
        moveInterval: 120,
        moveDistance: 50
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

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, deepseek, localLlm, readChatAloud
    }

    init(
        enabled: Bool,
        provider: ChatProvider,
        deepseek: DeepSeekConfig,
        localLlm: LocalLLMConfig,
        readChatAloud: Bool = false
    ) {
        self.enabled = enabled
        self.provider = provider
        self.deepseek = deepseek
        self.localLlm = localLlm
        self.readChatAloud = readChatAloud
    }

    /// 兼容旧 config.json：没有 readChatAloud 字段时默认 false，避免整份配置解码失败被重置。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        provider = try container.decodeIfPresent(ChatProvider.self, forKey: .provider) ?? .deepseek
        deepseek = try container.decodeIfPresent(DeepSeekConfig.self, forKey: .deepseek) ?? .default
        localLlm = try container.decodeIfPresent(LocalLLMConfig.self, forKey: .localLlm) ?? .default
        readChatAloud = try container.decodeIfPresent(Bool.self, forKey: .readChatAloud) ?? false
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

    static let `default` = InteractionConfig(
        click: ClickInteractionConfig.default,
        doubleClick: DoubleClickInteractionConfig.default,
        rightClick: RightClickInteractionConfig.default,
        drag: DragInteractionConfig.default,
        longPress: LongPressInteractionConfig.default,
        feed: FeedInteractionConfig.default,
        useAIForInteraction: false
    )

    init(
        click: ClickInteractionConfig,
        doubleClick: DoubleClickInteractionConfig,
        rightClick: RightClickInteractionConfig,
        drag: DragInteractionConfig,
        longPress: LongPressInteractionConfig,
        feed: FeedInteractionConfig,
        useAIForInteraction: Bool = false
    ) {
        self.click = click
        self.doubleClick = doubleClick
        self.rightClick = rightClick
        self.drag = drag
        self.longPress = longPress
        self.feed = feed
        self.useAIForInteraction = useAIForInteraction
    }

    enum CodingKeys: String, CodingKey {
        case click
        case doubleClick
        case rightClick
        case drag
        case longPress
        case feed
        case useAIForInteraction
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

struct ClickReactionConfig: Codable {
    var animation: String
    var probability: Double
    var speak: Bool
    var lines: [String]
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
        items: [
            FeedItemConfig(name: "小虾米", emoji: "🍤", happiness: 10, animation: "EATING", lines: ["好吃！", "谢谢~", "还要！"]),
            FeedItemConfig(name: "海藻", emoji: "🌿", happiness: 5, animation: "EATING", lines: ["健康~", "咕嘟~"]),
            FeedItemConfig(name: "泡泡糖", emoji: "🫧", happiness: 15, animation: "HAPPY", lines: ["甜甜的！", "吹泡泡~"])
        ]
    )
}

struct FeedItemConfig: Codable {
    var name: String
    var emoji: String
    var happiness: Int
    var animation: String
    var lines: [String]
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