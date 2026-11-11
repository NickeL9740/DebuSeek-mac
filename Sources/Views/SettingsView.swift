import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    @EnvironmentObject var petState: PetState
    @EnvironmentObject var petController: PetController
    
    @State private var selectedTab: SettingsTab = .general
    @State private var showModelPicker = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gear") }
                .tag(SettingsTab.general)
            
            PetAppearanceView()
                .tabItem { Label("外观", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            
            TTSView()
                .tabItem { Label("语音", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.tts)
            
            ChatSettingsView()
                .tabItem { Label("聊天", systemImage: "message") }
                .tag(SettingsTab.chat)
            
            BehaviorSettingsView()
                .tabItem { Label("行为", systemImage: "brain") }
                .tag(SettingsTab.behavior)
            
            InteractionSettingsView()
                .tabItem { Label("互动", systemImage: "hand.tap") }
                .tag(SettingsTab.interaction)
            
            AdvancedSettingsView()
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)

            DebugSettingsView()
                .tabItem { Label("调试", systemImage: "ladybug") }
                .tag(SettingsTab.debug)
        }
        .frame(minWidth: 550, minHeight: 600)
        .padding()
    }
}

enum SettingsTab: String, CaseIterable {
    case general = "general"
    case appearance = "appearance"
    case tts = "tts"
    case chat = "chat"
    case behavior = "behavior"
    case interaction = "interaction"
    case advanced = "advanced"
    case debug = "debug"
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    
    var body: some View {
        Form {
            Section("快捷键（首次点击宠物后生效）") {
                TextField("设置：option+s", text: Binding(
                    get: { configManager.config.hotkeySettings ?? "option+s" },
                    set: { configManager.updateHotkeySettings($0) }
                ))
                TextField("聊天：option+c", text: Binding(
                    get: { configManager.config.hotkeyChat ?? "option+c" },
                    set: { configManager.updateHotkeyChat($0) }
                ))
                Text("修改后重新注册：再次点击宠物或重启程序。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("基本设置") {
                TextField("宠物名称", text: Binding(
                    get: { configManager.config.pet.name },
                    set: { newValue in configManager.updatePetConfig { $0.name = newValue } }
                ))
                
                Toggle("启动时自动显示", isOn: Binding(
                    get: { true }, // Would need to add to config
                    set: { _ in }
                ))
                
                Toggle("开机自启动", isOn: Binding(
                    get: { isLoginItemEnabled() },
                    set: { setLoginItem(enabled: $0) }
                ))
            }
            
            Section("窗口设置") {
                Picker("窗口层级", selection: Binding(
                    get: { configManager.config.window.level },
                    set: { newValue in configManager.updateWindowConfig { $0.level = newValue } }
                )) {
                    ForEach(WindowConfig.WindowLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                
                Toggle("始终置顶", isOn: Binding(
                    get: { configManager.config.window.alwaysOnTop },
                    set: { newValue in configManager.updateWindowConfig { $0.alwaysOnTop = newValue } }
                ))
                
                Toggle("空闲时点击穿透", isOn: Binding(
                    get: { configManager.config.window.clickThroughWhenIdle },
                    set: { newValue in configManager.updateWindowConfig { $0.clickThroughWhenIdle = newValue } }
                ))
                
                if configManager.config.window.clickThroughWhenIdle {
                    Stepper("空闲超时: \(configManager.config.window.idleTimeout)秒", value: Binding(
                        get: { configManager.config.window.idleTimeout },
                        set: { newValue in configManager.updateWindowConfig { $0.idleTimeout = newValue } }
                    ), in: 1...60)
                }
            }
            
            Section("数据管理") {
                Button("导出配置") { exportConfig() }
                Button("导入配置") { importConfig() }
                Button("导出聊天记录（JSON）") { exportChatJSON() }
                Button("导出聊天记录（TXT）") { exportChatTXT() }
                Button("重置为默认") { configManager.resetToDefault() }
                    .foregroundColor(.red)
                Button("清空聊天记录") { ChatHistoryManager.shared.clearHistory() }
                    .foregroundColor(.orange)
            }
        }
        .formStyle(.grouped)
    }
    
    private func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("❌ Failed to update login item: \(error)")
        }
    }
    
    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DesktopPet_Config.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? configManager.exportConfig(to: url)
            }
        }
    }
    
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? configManager.importConfig(from: url)
            }
        }
    }

    private func exportChatJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DebuSeek_Chat_\(fileTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ChatHistoryManager.shared.exportHistoryJSON(to: url)
            } catch {
                NSLog("❌ Failed to export chat JSON: \(error)")
            }
        }
    }

    private func exportChatTXT() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DebuSeek_Chat_\(fileTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ChatHistoryManager.shared.exportHistoryTXT(to: url)
            } catch {
                NSLog("❌ Failed to export chat TXT: \(error)")
            }
        }
    }

    private func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter.string(from: Date())
    }
}

// MARK: - Pet Appearance Settings

struct PetAppearanceView: View {
    @EnvironmentObject var configManager: ConfigManager
    
    var body: some View {
        Form {
            Section("模型设置") {
                Text("动画由 manifests/actions.json 清单驱动（187×187 高清帧），无需手动配置。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Slider(value: Binding(
                    get: { configManager.config.pet.model.petScale },
                    set: { newValue in configManager.updatePetConfig { $0.model.petScale = newValue } }
                ), in: 0.4...1.2, step: 0.05) {
                    Text("缩放: \(String(format: "%.2f", configManager.config.pet.model.petScale))x")
                }
                
                Slider(value: Binding(
                    get: { configManager.config.pet.model.opacity },
                    set: { newValue in configManager.updatePetConfig { $0.model.opacity = newValue } }
                ), in: 0.1...1.0, step: 0.1) {
                    Text("透明度: \(Int(configManager.config.pet.model.opacity * 100))%")
                }
            }
            
            Section("大小与位置") {
                Stepper("宽度: \(Int(configManager.config.pet.size.width))", value: Binding(
                    get: { configManager.config.pet.size.width },
                    set: { newValue in configManager.updatePetConfig { $0.size.width = newValue } }
                ), in: 100...500, step: 10)
                
                Stepper("高度: \(Int(configManager.config.pet.size.height))", value: Binding(
                    get: { configManager.config.pet.size.height },
                    set: { newValue in configManager.updatePetConfig { $0.size.height = newValue } }
                ), in: 100...500, step: 10)
                
                Toggle("记住位置", isOn: Binding(
                    get: { configManager.config.pet.position.rememberPosition },
                    set: { newValue in configManager.updatePetConfig { $0.position.rememberPosition = newValue } }
                ))
            }
            
            Section("命中区域校准") {
                HitZoneCalibrationView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hit Zone Calibration（可视化框选）

private enum CalibrationZone: String, CaseIterable {
    case face
    case head
    case body
    case tail
    
    var title: String {
        switch self {
        case .face: return "脸"
        case .head: return "头"
        case .body: return "身体"
        case .tail: return "尾巴"
        }
    }
    
    var color: Color {
        switch self {
        case .face: return .pink
        case .head: return .blue
        case .body: return .green
        case .tail: return .orange
        }
    }
    
    var defaultRect: CGRect {
        switch self {
        case .face: return PetModelConfig.defaultFaceRect
        case .head: return PetModelConfig.defaultHeadRect
        case .body: return PetModelConfig.defaultBodyRect
        case .tail: return PetModelConfig.defaultTailRect
        }
    }
}

struct HitZoneCalibrationView: View {
    @EnvironmentObject var configManager: ConfigManager
    @EnvironmentObject var petController: PetController
    
    /// 归一化坐标（0~1，左上角原点，y 向下），与 PetScene.hitTest 的 (u, v) 一致
    @State private var rects: [CalibrationZone: CGRect] = [:]
    @State private var moveStart: [CalibrationZone: CGRect] = [:]
    @State private var resizeStart: [CalibrationZone: CGRect] = [:]
    
    private let canvasHeight: CGFloat = 320
    private let minBoxSize: CGFloat = 0.05
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拖动方框移动，拖右下角圆点缩放；坐标会自动保存到当前模型配置。")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let image = petController.idlePreviewImage {
                GeometryReader { geo in
                    let layout = imageLayout(image: image, in: geo.size)
                    
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: layout.size.width, height: layout.size.height)
                            .position(x: layout.origin.x + layout.size.width / 2,
                                      y: layout.origin.y + layout.size.height / 2)
                        
                        ForEach(CalibrationZone.allCases, id: \.self) { zone in
                            zoneBox(zone: zone, layout: layout)
                        }
                    }
                }
                .frame(height: canvasHeight)
            } else {
                Text("模型帧未加载，先启动宠物窗口再回来校准。")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .onAppear(perform: syncFromConfig)
    }
    
    private struct ImageLayout {
        var origin: CGPoint
        var size: CGSize
    }
    
    private func imageLayout(image: NSImage, in available: CGSize) -> ImageLayout {
        let imageSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : CGSize(width: 1, height: 1)
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return ImageLayout(
            origin: CGPoint(x: (available.width - drawSize.width) / 2,
                            y: (available.height - drawSize.height) / 2),
            size: drawSize
        )
    }
    
    @ViewBuilder
    private func zoneBox(zone: CalibrationZone, layout: ImageLayout) -> some View {
        let rect = rects[zone] ?? zone.defaultRect
        let boxWidth = max(2, rect.width * layout.size.width)
        let boxHeight = max(2, rect.height * layout.size.height)
        let centerX = layout.origin.x + (rect.minX + rect.width / 2) * layout.size.width
        let centerY = layout.origin.y + (rect.minY + rect.height / 2) * layout.size.height
        
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(zone.color.opacity(0.16))
                .contentShape(Rectangle())
                .gesture(moveGesture(zone: zone, layout: layout))
            
            Rectangle()
                .stroke(zone.color, lineWidth: 1.5)
                .allowsHitTesting(false)
            
            Text(zone.title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(zone.color.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .offset(x: 3, y: 3)
                .allowsHitTesting(false)
            
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(zone.color, lineWidth: 2))
                .frame(width: 14, height: 14)
                .position(x: boxWidth - 7, y: boxHeight - 7)
                .gesture(resizeGesture(zone: zone, layout: layout))
        }
        .frame(width: boxWidth, height: boxHeight)
        .position(x: centerX, y: centerY)
    }
    
    private func moveGesture(zone: CalibrationZone, layout: ImageLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moveStart[zone] == nil {
                    moveStart[zone] = rects[zone] ?? zone.defaultRect
                }
                guard let start = moveStart[zone] else { return }
                var rect = start
                rect.origin.x = clamp(
                    start.origin.x + value.translation.width / layout.size.width,
                    lower: 0,
                    upper: 1 - start.width
                )
                rect.origin.y = clamp(
                    start.origin.y + value.translation.height / layout.size.height,
                    lower: 0,
                    upper: 1 - start.height
                )
                rects[zone] = rect
            }
            .onEnded { _ in
                moveStart[zone] = nil
                saveToConfig()
            }
    }
    
    private func resizeGesture(zone: CalibrationZone, layout: ImageLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeStart[zone] == nil {
                    resizeStart[zone] = rects[zone] ?? zone.defaultRect
                }
                guard let start = resizeStart[zone] else { return }
                var rect = start
                rect.size.width = clamp(
                    start.width + value.translation.width / layout.size.width,
                    lower: minBoxSize,
                    upper: 1 - start.minX
                )
                rect.size.height = clamp(
                    start.height + value.translation.height / layout.size.height,
                    lower: minBoxSize,
                    upper: 1 - start.minY
                )
                rects[zone] = rect
            }
            .onEnded { _ in
                resizeStart[zone] = nil
                saveToConfig()
            }
    }
    
    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
    
    private func syncFromConfig() {
        let model = configManager.config.pet.model
        rects = [
            .face: model.faceRect,
            .head: model.headRect,
            .body: model.bodyRect,
            .tail: model.tailRect
        ]
    }
    
    private func saveToConfig() {
        guard rects.count == CalibrationZone.allCases.count else { return }
        configManager.updatePetConfig { pet in
            if let rect = rects[.face] { pet.model.faceRect = rect }
            if let rect = rects[.head] { pet.model.headRect = rect }
            if let rect = rects[.body] { pet.model.bodyRect = rect }
            if let rect = rects[.tail] { pet.model.tailRect = rect }
        }
    }
}

// MARK: - TTS Settings

struct TTSView: View {
    @EnvironmentObject var configManager: ConfigManager

    /// 音量/语速直接绑定 TTSServiceManager；进入页面时同步一次当前值
    @State private var ttsVolume: Double = 0.3
    @State private var ttsSpeed: Double = 1.0
    @State private var cacheCleanMessage: String = ""
    
    var body: some View {
        Form {
            Section("播放参数") {
                Slider(value: $ttsVolume, in: 0...1.0, step: 0.05) {
                    Text("音量: \(Int(ttsVolume * 100))%")
                }
                .onChange(of: ttsVolume) { newValue in
                    TTSServiceManager.shared.volume = Float(newValue)
                }

                Slider(value: $ttsSpeed, in: 0.5...2.0, step: 0.1) {
                    Text("语速: \(String(format: "%.1f", ttsSpeed))x")
                }
                .onChange(of: ttsSpeed) { newValue in
                    TTSServiceManager.shared.speed = newValue
                }

                Text("音量作用于所有 TTS；语速会传给 GPT-SoVITS 的 speed_factor，系统语音则换算成 AVSpeechUtterance.rate。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("通用") {
                Toggle("启用语音", isOn: Binding(
                    get: { configManager.config.tts.enabled },
                    set: { newValue in configManager.updateTTSConfig { $0.enabled = newValue } }
                ))
                
                Picker("TTS 提供商", selection: Binding(
                    get: { configManager.config.tts.provider },
                    set: { newValue in configManager.updateTTSConfig { $0.provider = newValue } }
                )) {
                    Text("云端 API").tag(TTSProvider.cloud)
                    Text("GPT-SoVITS 本地").tag(TTSProvider.localGptSovits)
                    Text("系统语音").tag(TTSProvider.system)
                }
                
                Toggle("失败时回退到系统语音", isOn: Binding(
                    get: { configManager.config.tts.fallbackToSystem },
                    set: { newValue in configManager.updateTTSConfig { $0.fallbackToSystem = newValue } }
                ))
            }
            
            if configManager.config.tts.provider == .cloud {
                Section("云端 API 设置") {
                    TextField("API 地址", text: Binding(
                        get: { configManager.config.tts.cloud.apiUrl },
                        set: { newValue in configManager.updateTTSConfig { $0.cloud.apiUrl = newValue } }
                    ))
                    
                    SecureField("API Key", text: Binding(
                        get: { configManager.config.tts.cloud.apiKey },
                        set: { newValue in configManager.updateTTSConfig { $0.cloud.apiKey = newValue } }
                    ))
                    
                    TextField("声音", text: Binding(
                        get: { configManager.config.tts.cloud.voice },
                        set: { newValue in configManager.updateTTSConfig { $0.cloud.voice = newValue } }
                    ))
                    
                    Slider(value: Binding(
                        get: { configManager.config.tts.cloud.pitch },
                        set: { newValue in configManager.updateTTSConfig { $0.cloud.pitch = newValue } }
                    ), in: 0.5...2.0, step: 0.1) {
                        Text("音调: \(String(format: "%.1f", configManager.config.tts.cloud.pitch))x")
                    }
                    
                }
            }
            
            if configManager.config.tts.provider == .localGptSovits {
                Section("GPT-SoVITS v2 设置") {
                    TextField("API 地址", text: Binding(
                        get: { configManager.config.tts.localGptSovits.apiUrl },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.apiUrl = newValue } }
                    ))
                    
                    TextField("参考音频路径", text: Binding(
                        get: { configManager.config.tts.localGptSovits.referWavPath },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.referWavPath = newValue } }
                    ))
                    
                    TextField("参考文本", text: Binding(
                        get: { configManager.config.tts.localGptSovits.promptText },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.promptText = newValue } }
                    ))
                    
                    Picker("参考语言", selection: Binding(
                        get: { configManager.config.tts.localGptSovits.promptLanguage },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.promptLanguage = newValue } }
                    )) {
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                        Text("日文").tag("ja")
                    }
                    
                    Picker("生成语言", selection: Binding(
                        get: { configManager.config.tts.localGptSovits.textLanguage },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.textLanguage = newValue } }
                    )) {
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                        Text("日文").tag("ja")
                    }
                    
                    Stepper("Top K: \(configManager.config.tts.localGptSovits.topK)", value: Binding(
                        get: { configManager.config.tts.localGptSovits.topK },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.topK = newValue } }
                    ), in: 1...20)
                    
                    Slider(value: Binding(
                        get: { configManager.config.tts.localGptSovits.topP },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.topP = newValue } }
                    ), in: 0.1...1.0, step: 0.05) {
                        Text("Top P: \(String(format: "%.2f", configManager.config.tts.localGptSovits.topP))")
                    }
                    
                    Slider(value: Binding(
                        get: { configManager.config.tts.localGptSovits.temperature },
                        set: { newValue in configManager.updateTTSConfig { $0.localGptSovits.temperature = newValue } }
                    ), in: 0.1...1.5, step: 0.05) {
                        Text("Temperature: \(String(format: "%.2f", configManager.config.tts.localGptSovits.temperature))")
                    }
                }
            }

            Section("本地语音缓存") {
                Button("清理本地语音缓存") {
                    let removed = LocalGptSovitsService.clearCache()
                    cacheCleanMessage = removed > 0
                        ? "已清理 \(removed) 个缓存文件"
                        : "缓存已经是空的"
                }

                if !cacheCleanMessage.isEmpty {
                    Text(cacheCleanMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("缓存目录：~/Library/Application Support/DebuSeek/Cache/。\n仅对 GPT-SoVITS 本地语音生效，相同的文本/参考音频/参数会直接复用。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("测试") {
                Button("测试语音") {
                    PetController.shared.speak("你好呀！我是大肥鱼~")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ttsVolume = Double(TTSServiceManager.shared.volume)
            ttsSpeed = TTSServiceManager.shared.speed
        }
    }
}

// MARK: - Chat Settings

struct ChatSettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    @ObservedObject private var usage = UsageManager.shared
    @ObservedObject private var chatService = ChatServiceManager.shared
    
    var body: some View {
        Form {
            Section("通用") {
                Toggle("启用聊天", isOn: Binding(
                    get: { configManager.config.chat.enabled },
                    set: { newValue in configManager.updateChatConfig { $0.enabled = newValue } }
                ))
                
                Picker("聊天提供商", selection: Binding(
                    get: { configManager.config.chat.provider },
                    set: { newValue in configManager.updateChatConfig { $0.provider = newValue } }
                )) {
                    Text("OpenAI 兼容 API").tag(ChatProvider.deepseek)
                    Text("本地 LLM (Ollama)").tag(ChatProvider.localLlm)
                }

                TextField("用户昵称", text: Binding(
                    get: { configManager.config.chat.userNickname },
                    set: { newValue in configManager.updateChatConfig { $0.userNickname = newValue } }
                ), prompt: Text("例如：老板 / 小 nick（留空则不注入）"))
                Text("会追加到 system prompt 末尾，让宠物用这个称呼叫你。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("长期记忆") {
                Toggle("启用长期记忆", isOn: Binding(
                    get: { configManager.config.chat.enableMemorySummarization },
                    set: { newValue in configManager.updateChatConfig { $0.enableMemorySummarization = newValue } }
                ))

                Toggle("自动压缩历史", isOn: Binding(
                    get: { configManager.config.chat.enableAutoSummarize },
                    set: { newValue in configManager.updateChatConfig { $0.enableAutoSummarize = newValue } }
                ))
                .disabled(!configManager.config.chat.enableMemorySummarization)

                Stepper("每 \(configManager.config.chat.autoSummarizeRounds) 轮压缩", value: Binding(
                    get: { configManager.config.chat.autoSummarizeRounds },
                    set: { newValue in configManager.updateChatConfig { $0.autoSummarizeRounds = max(1, newValue) } }
                ), in: 1...50)
                .disabled(!configManager.config.chat.enableMemorySummarization || !configManager.config.chat.enableAutoSummarize)

                Button("立即压缩历史") {
                    PetController.shared.summarizeAndClearHistory()
                }
                .disabled(!configManager.config.chat.enabled || !configManager.config.chat.enableMemorySummarization || chatService.isProcessing)

                Text("回忆录（可编辑，压缩后会更新；也可手动修正模型记错的内容）")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: Binding(
                    get: { configManager.config.chat.memorySummary },
                    set: { newValue in configManager.updateChatConfig { $0.memorySummary = newValue } }
                ))
                .frame(height: 110)
                .border(Color.gray.opacity(0.3))

                Text("摘要 Prompt（可选，支持 {transcript} 占位符；留空使用内置提示词）")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: Binding(
                    get: { configManager.config.chat.customSummaryPrompt },
                    set: { newValue in configManager.updateChatConfig { $0.customSummaryPrompt = newValue } }
                ))
                .frame(height: 80)
                .border(Color.gray.opacity(0.3))

                Text("回忆录 \(configManager.config.chat.memorySummary.count) 字；达到 \(max(2, configManager.config.chat.autoSummarizeRounds * 2)) 条历史后后台静默压缩。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Token 感知") {
                Toggle("注入 Token 消耗提示", isOn: Binding(
                    get: { configManager.config.chat.injectTokenUsage },
                    set: { newValue in configManager.updateChatConfig { $0.injectTokenUsage = newValue } }
                ))

                Text("今日已消耗 Token: \(usage.todayTokens) / 累计: \(usage.totalTokens)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("可用货币: \(usage.availableCurrency)（今日来源 cache miss \(usage.todayCacheMiss) + output \(usage.todayOutput)）")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("只在发送请求时临时拼在最后一条 user 消息末尾，不写入聊天记录，也不在 UI 渲染。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if configManager.config.chat.provider == .deepseek {
                Section("OpenAI 兼容 API") {
                    Text("支持 OpenAI / Gemini / NVIDIA / Vercel 代理等所有 OpenAI 格式服务")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextField("API 地址", text: Binding(
                        get: { configManager.config.chat.deepseek.apiUrl },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.apiUrl = newValue } }
                    ), prompt: Text("https://api.openai.com/v1/chat/completions"))
                    Text("填完整请求地址（以 /chat/completions 结尾），代码会直接 POST 到这里")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    SecureField("API Key", text: Binding(
                        get: { configManager.config.chat.deepseek.apiKey },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.apiKey = newValue } }
                    ), prompt: Text("sk-..."))
                    
                    TextField("模型名称", text: Binding(
                        get: { configManager.config.chat.deepseek.model },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.model = newValue } }
                    ), prompt: Text("gpt-4o / gemini-1.5-pro / nvidia/llama-3.1-70b-instruct"))
                    Text("模型名可手填，例如 gpt-4o、gemini-1.5-pro、nvidia/llama-3.1-70b-instruct")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(value: Binding(
                        get: { configManager.config.chat.deepseek.temperature },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.temperature = newValue } }
                    ), in: 0...2.0, step: 0.1) {
                        Text("Temperature: \(String(format: "%.1f", configManager.config.chat.deepseek.temperature))")
                    }
                    
                    Stepper("Max Tokens: \(configManager.config.chat.deepseek.maxTokens)", value: Binding(
                        get: { configManager.config.chat.deepseek.maxTokens },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.maxTokens = newValue } }
                    ), in: 100...4000, step: 100)
                    
                    TextEditor(text: Binding(
                        get: { configManager.config.chat.deepseek.systemPrompt },
                        set: { newValue in configManager.updateChatConfig { $0.deepseek.systemPrompt = newValue } }
                    ))
                    .frame(height: 100)
                    .border(Color.gray.opacity(0.3))
                    .overlay(alignment: .topLeading) {
                        Text("系统提示词").foregroundColor(.secondary).padding(4)
                    }
                }
            }
            
            if configManager.config.chat.provider == .localLlm {
                Section("本地 LLM 设置") {
                    TextField("API 地址", text: Binding(
                        get: { configManager.config.chat.localLlm.apiUrl },
                        set: { newValue in configManager.updateChatConfig { $0.localLlm.apiUrl = newValue } }
                    ))
                    
                    TextField("模型名称", text: Binding(
                        get: { configManager.config.chat.localLlm.model },
                        set: { newValue in configManager.updateChatConfig { $0.localLlm.model = newValue } }
                    ))
                    
                    Slider(value: Binding(
                        get: { configManager.config.chat.localLlm.temperature },
                        set: { newValue in configManager.updateChatConfig { $0.localLlm.temperature = newValue } }
                    ), in: 0...2.0, step: 0.1) {
                        Text("Temperature: \(String(format: "%.1f", configManager.config.chat.localLlm.temperature))")
                    }
                    
                    Stepper("Max Tokens: \(configManager.config.chat.localLlm.maxTokens)", value: Binding(
                        get: { configManager.config.chat.localLlm.maxTokens },
                        set: { newValue in configManager.updateChatConfig { $0.localLlm.maxTokens = newValue } }
                    ), in: 100...4000, step: 100)
                    
                    TextEditor(text: Binding(
                        get: { configManager.config.chat.localLlm.systemPrompt },
                        set: { newValue in configManager.updateChatConfig { $0.localLlm.systemPrompt = newValue } }
                    ))
                    .frame(height: 100)
                    .border(Color.gray.opacity(0.3))
                }
            }
            
            Section("测试") {
                Button("测试聊天") {
                    Task {
                        try? await PetController.shared.sendChatMessage("你好！")
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Section("语音") {
                Toggle("朗读聊天回复", isOn: Binding(
                    get: { configManager.config.chat.readChatAloud },
                    set: { newValue in configManager.updateChatConfig { $0.readChatAloud = newValue } }
                ))
                Text("默认关闭：聊天回复只显示气泡，不播放 TALKING 动画，也不调用 TTS。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Behavior Settings

private struct IntNumberStepperRow: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 32, alignment: .leading)
        }
    }
}

private struct DoubleNumberStepperRow: View {
    let title: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 32, alignment: .leading)
        }
    }
}

struct BehaviorSettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    
    var body: some View {
        Form {
            Section("自动说话") {
                Toggle("启用自动说话", isOn: Binding(
                    get: { configManager.config.autoSpeech.enabled },
                    set: { newValue in configManager.updateAutoSpeechConfig { $0.enabled = newValue } }
                ))
                
                Stepper("最小间隔: \(configManager.config.autoSpeech.intervalMin)秒", value: Binding(
                    get: { configManager.config.autoSpeech.intervalMin },
                    set: { newValue in configManager.updateAutoSpeechConfig { $0.intervalMin = newValue } }
                ), in: 30...3600, step: 30)
                
                Stepper("最大间隔: \(configManager.config.autoSpeech.intervalMax)秒", value: Binding(
                    get: { configManager.config.autoSpeech.intervalMax },
                    set: { newValue in configManager.updateAutoSpeechConfig { $0.intervalMax = newValue } }
                ), in: 60...7200, step: 60)
                
                ForEach(Array(configManager.config.autoSpeech.categories.keys.sorted()), id: \.self) { key in
                    if let category = configManager.config.autoSpeech.categories[key] {
                        SpeechCategoryRow(key: key, category: category) { newCat in
                            configManager.updateAutoSpeechConfig { $0.categories[key] = newCat }
                        }
                    }
                }
            }
            
            Section("报时") {
                Toggle("启用报时", isOn: Binding(
                    get: { configManager.config.timeReport.enabled },
                    set: { newValue in configManager.updateTimeReportConfig { $0.enabled = newValue } }
                ))
                
                Stepper("间隔: \(configManager.config.timeReport.intervalMinutes)分钟", value: Binding(
                    get: { configManager.config.timeReport.intervalMinutes },
                    set: { newValue in configManager.updateTimeReportConfig { $0.intervalMinutes = newValue } }
                ), in: 15...180, step: 15)
                
                Toggle("整点报时", isOn: Binding(
                    get: { configManager.config.timeReport.announceOnHour },
                    set: { newValue in configManager.updateTimeReportConfig { $0.announceOnHour = newValue } }
                ))
                
                Toggle("半点报时", isOn: Binding(
                    get: { configManager.config.timeReport.announceOnHalfHour },
                    set: { newValue in configManager.updateTimeReportConfig { $0.announceOnHalfHour = newValue } }
                ))
                
                TextField("时间格式", text: Binding(
                    get: { configManager.config.timeReport.format },
                    set: { newValue in configManager.updateTimeReportConfig { $0.format = newValue } }
                ))
                
                ForEach(configManager.config.timeReport.phrases.indices, id: \.self) { idx in
                    HStack {
                        TextField("报时话术 \(idx + 1)", text: Binding(
                            get: { configManager.config.timeReport.phrases[idx] },
                            set: { newValue in configManager.updateTimeReportConfig { $0.phrases[idx] = newValue } }
                        ))
                        Button(action: {
                            configManager.updateTimeReportConfig { $0.phrases.remove(at: idx) }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Button("添加报时话术") {
                    configManager.updateTimeReportConfig { $0.phrases.append("现在是{time}啦~") }
                }
            }
            
            Section("行为参数") {
                IntNumberStepperRow(title: "空闲阈值", unit: "秒", value: Binding(
                    get: { configManager.config.pet.behavior.idleThreshold },
                    set: { newValue in configManager.updatePetConfig { $0.behavior.idleThreshold = newValue } }
                ), range: 10...300, step: 10)

                Toggle("自动移动", isOn: Binding(
                    get: { configManager.config.pet.behavior.autoMove },
                    set: { newValue in configManager.updatePetConfig { $0.behavior.autoMove = newValue } }
                ))

                IntNumberStepperRow(title: "移动间隔", unit: "秒", value: Binding(
                    get: { configManager.config.pet.behavior.moveInterval },
                    set: { newValue in configManager.updatePetConfig { $0.behavior.moveInterval = newValue } }
                ), range: 30...600, step: 30)

                DoubleNumberStepperRow(title: "移动距离", unit: "像素", value: Binding(
                    get: { configManager.config.pet.behavior.moveDistance },
                    set: { newValue in configManager.updatePetConfig { $0.behavior.moveDistance = newValue } }
                ), range: 10...200, step: 10)

                IntNumberStepperRow(title: "行动最小间隔", unit: "秒", value: Binding(
                    get: { configManager.config.pet.behavior.activityMinInterval },
                    set: { newValue in
                        configManager.updatePetConfig {
                            $0.behavior.activityMinInterval = newValue
                            if $0.behavior.activityMaxInterval < newValue {
                                $0.behavior.activityMaxInterval = newValue
                            }
                        }
                    }
                ), range: 1...60, step: 1)

                IntNumberStepperRow(title: "行动最大间隔", unit: "秒", value: Binding(
                    get: { configManager.config.pet.behavior.activityMaxInterval },
                    set: { newValue in
                        configManager.updatePetConfig {
                            $0.behavior.activityMaxInterval = newValue
                            if $0.behavior.activityMinInterval > newValue {
                                $0.behavior.activityMinInterval = newValue
                            }
                        }
                    }
                ), range: 1...60, step: 1)

                Divider()

                Toggle("允许跳跃", isOn: Binding(
                    get: { configManager.config.pet.behavior.allowJump },
                    set: { newValue in configManager.updatePetConfig { $0.behavior.allowJump = newValue } }
                ))

                HStack {
                    Text("跳跃概率: \(Int(configManager.config.pet.behavior.jumpProbability * 100))%")
                    Slider(value: Binding(
                        get: { configManager.config.pet.behavior.jumpProbability },
                        set: { newValue in configManager.updatePetConfig { $0.behavior.jumpProbability = min(max(newValue, 0), 1) } }
                    ), in: 0...1, step: 0.01)
                }
                .disabled(!configManager.config.pet.behavior.allowJump)

                Text("跳跃是独立行为：每次行为决策按概率触发，跳完不会强制接走路。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("难度与物理反馈") {
                Picker("难度", selection: Binding(
                    get: { configManager.config.gameplay.difficulty },
                    set: { newValue in
                        // 切换难度时载入推荐参数；下面的滑条仍可继续微调。
                        configManager.updateGameplayConfig { $0 = GameplayConfig.recommended(for: newValue) }
                    }
                )) {
                    ForEach(GameplayDifficulty.allCases) { difficulty in
                        Text(difficulty.title).tag(difficulty)
                    }
                }

                Slider(value: Binding(
                    get: { configManager.config.gameplay.energyMultiplier },
                    set: { newValue in configManager.updateGameplayConfig { $0.energyMultiplier = min(max(newValue, 0.5), 2.0) } }
                ), in: 0.5...2.0, step: 0.1) {
                    Text("精力消耗倍率: \(String(format: "%.1f", configManager.config.gameplay.energyMultiplier))×")
                }

                Slider(value: Binding(
                    get: { configManager.config.gameplay.hungerMultiplier },
                    set: { newValue in configManager.updateGameplayConfig { $0.hungerMultiplier = min(max(newValue, 0.5), 2.0) } }
                ), in: 0.5...2.0, step: 0.1) {
                    Text("饥饿增长倍率: \(String(format: "%.1f", configManager.config.gameplay.hungerMultiplier))×")
                }

                Slider(value: Binding(
                    get: { configManager.config.gameplay.happinessMultiplier },
                    set: { newValue in configManager.updateGameplayConfig { $0.happinessMultiplier = min(max(newValue, 0.5), 2.0) } }
                ), in: 0.5...2.0, step: 0.1) {
                    Text("心情变化倍率: \(String(format: "%.1f", configManager.config.gameplay.happinessMultiplier))×")
                }

                Slider(value: Binding(
                    get: { Double(configManager.config.gameplay.wallHappinessPenalty) },
                    set: { newValue in configManager.updateGameplayConfig { $0.wallHappinessPenalty = Int(newValue) } }
                ), in: 0...50, step: 1) {
                    Text("撞墙扣心情: \(configManager.config.gameplay.wallHappinessPenalty)")
                }

                Slider(value: Binding(
                    get: { Double(configManager.config.gameplay.wallEnergyPenalty) },
                    set: { newValue in configManager.updateGameplayConfig { $0.wallEnergyPenalty = Int(newValue) } }
                ), in: 0...100, step: 1) {
                    Text("撞墙扣精力: \(configManager.config.gameplay.wallEnergyPenalty)")
                }

                Slider(value: Binding(
                    get: { Double(configManager.config.gameplay.landingHappinessReward) },
                    set: { newValue in configManager.updateGameplayConfig { $0.landingHappinessReward = Int(newValue) } }
                ), in: 0...10, step: 1) {
                    Text("无碰撞落地奖励: +\(configManager.config.gameplay.landingHappinessReward) 心情")
                }

                Text("撞墙扣的属性会再乘以对应难度倍率；抛掷全程没撞墙，落地才加心情。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SpeechCategoryRow: View {
    let key: String
    let category: SpeechCategoryConfig
    let onChange: (SpeechCategoryConfig) -> Void
    
    @State private var enabled: Bool
    @State private var weight: Int
    @State private var linesText: String
    
    init(key: String, category: SpeechCategoryConfig, onChange: @escaping (SpeechCategoryConfig) -> Void) {
        self.key = key
        self.category = category
        self.onChange = onChange
        self._enabled = State(initialValue: category.enabled)
        self._weight = State(initialValue: category.weight)
        self._linesText = State(initialValue: category.lines.joined(separator: "\n"))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(key.capitalized, isOn: $enabled)
                    .onChange(of: enabled) { update() }
                Spacer()
                Stepper("权重: \(weight)", value: $weight, in: 1...100)
                    .onChange(of: weight) { update() }
            }
            
            TextEditor(text: $linesText)
                .frame(height: 80)
                .border(Color.gray.opacity(0.3))
                .onChange(of: linesText) { update() }
            
            Text("每行一条台词，共 \(linesText.split(separator: "\n").count) 条")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func update() {
        let lines = linesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        onChange(SpeechCategoryConfig(enabled: enabled, weight: weight, lines: lines))
    }
}

// MARK: - Interaction Settings

struct InteractionSettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    
    var body: some View {
        Form {
            Section("AI 互动") {
                Toggle("物理互动触发 AI 实时回复", isOn: Binding(
                    get: { configManager.config.interaction.useAIForInteraction },
                    set: { newValue in configManager.updateInteractionConfig { $0.useAIForInteraction = newValue } }
                ))
                
                Toggle("空中时跳过 AI 请求", isOn: Binding(
                    get: { configManager.config.interaction.skipAIWhileAirborne },
                    set: { newValue in configManager.updateInteractionConfig { $0.skipAIWhileAirborne = newValue } }
                ))
                
                Slider(value: Binding(
                    get: { configManager.config.interaction.apiRequestCooldown },
                    set: { newValue in configManager.updateInteractionConfig { $0.apiRequestCooldown = newValue } }
                ), in: 0.2...5.0, step: 0.1) {
                    Text("API 冷却: \(String(format: "%.1f", configManager.config.interaction.apiRequestCooldown)) 秒")
                }
                
                Text("开启后，单击、长按、抛掷落地会直接把事件描述发给聊天模型（不走预设台词）；关闭则使用下面的本地反应配置。冷却期内或宠物在空中时不会发起请求，直接用本地台词。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("点击") {
                Toggle("启用", isOn: Binding(
                    get: { configManager.config.interaction.click.enabled },
                    set: { newValue in configManager.updateInteractionConfig { $0.click.enabled = newValue } }
                ))
                
                ForEach(Array(configManager.config.interaction.click.reactions.enumerated()), id: \.element.id) { idx, reaction in
                    ClickReactionRow(
                        index: idx,
                        reaction: reaction,
                        onDelete: {
                            configManager.updateInteractionConfig { config in
                                guard idx < config.click.reactions.count else { return }
                                config.click.reactions.remove(at: idx)
                            }
                        },
                        onChange: { newReaction in
                            configManager.updateInteractionConfig { config in
                                guard let current = config.click.reactions.firstIndex(where: { $0.id == reaction.id }) else { return }
                                config.click.reactions[current] = newReaction
                            }
                        }
                    )
                }
                
                Button("添加反应") {
                    configManager.updateInteractionConfig {
                        $0.click.reactions.append(ClickReactionConfig(
                            animation: "HAPPY", probability: 0.3, speak: true, lines: ["新反应"]
                        ))
                    }
                }
            }
            
            Section("双击") {
                Toggle("启用", isOn: Binding(
                    get: { configManager.config.interaction.doubleClick.enabled },
                    set: { newValue in configManager.updateInteractionConfig { $0.doubleClick.enabled = newValue } }
                ))
                
                TextField("动画", text: Binding(
                    get: { configManager.config.interaction.doubleClick.animation },
                    set: { newValue in configManager.updateInteractionConfig { $0.doubleClick.animation = newValue } }
                ))
                
                Toggle("说话", isOn: Binding(
                    get: { configManager.config.interaction.doubleClick.speak },
                    set: { newValue in configManager.updateInteractionConfig { $0.doubleClick.speak = newValue } }
                ))
                
                ForEach(configManager.config.interaction.doubleClick.lines.indices, id: \.self) { idx in
                    TextField("台词 \(idx + 1)", text: Binding(
                        get: { configManager.config.interaction.doubleClick.lines[idx] },
                        set: { newValue in configManager.updateInteractionConfig { $0.doubleClick.lines[idx] = newValue } }
                    ))
                }
                
                Button("添加台词") {
                    configManager.updateInteractionConfig { $0.doubleClick.lines.append("新台词") }
                }
            }
            
            Section("长按") {
                Toggle("启用", isOn: Binding(
                    get: { configManager.config.interaction.longPress.enabled },
                    set: { newValue in configManager.updateInteractionConfig { $0.longPress.enabled = newValue } }
                ))
                
                Slider(value: Binding(
                    get: { configManager.config.interaction.longPress.duration },
                    set: { newValue in configManager.updateInteractionConfig { $0.longPress.duration = newValue } }
                ), in: 0.5...3.0, step: 0.1) {
                    Text("触发时长: \(String(format: "%.1f", configManager.config.interaction.longPress.duration))秒")
                }
                
                TextField("动画", text: Binding(
                    get: { configManager.config.interaction.longPress.animation },
                    set: { newValue in configManager.updateInteractionConfig { $0.longPress.animation = newValue } }
                ))
                
                Toggle("说话", isOn: Binding(
                    get: { configManager.config.interaction.longPress.speak },
                    set: { newValue in configManager.updateInteractionConfig { $0.longPress.speak = newValue } }
                ))
                
                ForEach(configManager.config.interaction.longPress.lines.indices, id: \.self) { idx in
                    TextField("台词 \(idx + 1)", text: Binding(
                        get: { configManager.config.interaction.longPress.lines[idx] },
                        set: { newValue in configManager.updateInteractionConfig { $0.longPress.lines[idx] = newValue } }
                    ))
                }
                
                Button("添加台词") {
                    configManager.updateInteractionConfig { $0.longPress.lines.append("新台词") }
                }
            }
            
            Section("拖拽") {
                Toggle("启用", isOn: Binding(
                    get: { configManager.config.interaction.drag.enabled },
                    set: { newValue in configManager.updateInteractionConfig { $0.drag.enabled = newValue } }
                ))
                
                Toggle("跟随鼠标", isOn: Binding(
                    get: { configManager.config.interaction.drag.followMouse },
                    set: { newValue in configManager.updateInteractionConfig { $0.drag.followMouse = newValue } }
                ))
                
                TextField("拖拽时动画", text: Binding(
                    get: { configManager.config.interaction.drag.animation },
                    set: { newValue in configManager.updateInteractionConfig { $0.drag.animation = newValue } }
                ))
                
                Toggle("放开时说话", isOn: Binding(
                    get: { configManager.config.interaction.drag.speakOnRelease },
                    set: { newValue in configManager.updateInteractionConfig { $0.drag.speakOnRelease = newValue } }
                ))
                
                ForEach(configManager.config.interaction.drag.releaseLines.indices, id: \.self) { idx in
                    TextField("放开台词 \(idx + 1)", text: Binding(
                        get: { configManager.config.interaction.drag.releaseLines[idx] },
                        set: { newValue in configManager.updateInteractionConfig { $0.drag.releaseLines[idx] = newValue } }
                    ))
                }
            }
            
            Section("喂食") {
                Toggle("启用喂食", isOn: Binding(
                    get: { configManager.config.interaction.feed.enabled },
                    set: { newValue in configManager.updateInteractionConfig { $0.feed.enabled = newValue } }
                ))
                
                ForEach(Array(configManager.config.interaction.feed.items.enumerated()), id: \.element.id) { idx, item in
                    FeedItemRow(
                        index: idx,
                        item: item,
                        onDelete: {
                            configManager.updateInteractionConfig { config in
                                guard idx < config.feed.items.count else { return }
                                config.feed.items.remove(at: idx)
                            }
                        },
                        onChange: { newItem in
                            configManager.updateInteractionConfig { config in
                                guard let current = config.feed.items.firstIndex(where: { $0.id == item.id }) else { return }
                                config.feed.items[current] = newItem
                            }
                        }
                    )
                }
                
                Button("添加食物") {
                    configManager.updateInteractionConfig {
                        $0.feed.items.append(FeedItemConfig(
                            name: "新食物", emoji: "🍎", happiness: 5, satiety: 5, energy: 2,
                            animation: "EATING", lines: ["好吃"]
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClickReactionRow: View {
    let index: Int
    let reaction: ClickReactionConfig
    let onDelete: () -> Void
    let onChange: (ClickReactionConfig) -> Void

    @State private var animation: String
    @State private var probability: Double
    @State private var speak: Bool
    @State private var linesText: String
    @State private var saveWorkItem: DispatchWorkItem?

    init(index: Int, reaction: ClickReactionConfig, onDelete: @escaping () -> Void, onChange: @escaping (ClickReactionConfig) -> Void) {
        self.index = index
        self.reaction = reaction
        self.onDelete = onDelete
        self.onChange = onChange
        self._animation = State(initialValue: reaction.animation)
        self._probability = State(initialValue: reaction.probability)
        self._speak = State(initialValue: reaction.speak)
        self._linesText = State(initialValue: reaction.lines.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("反应 \(index + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                TextField("动画", text: $animation)
                    .frame(width: 100)
                    .onChange(of: animation) { _ in scheduleUpdate() }
                Slider(value: $probability, in: 0...1, step: 0.05) {
                    Text("概率: \(Int(probability * 100))%")
                }
                .frame(width: 150)
                .onChange(of: probability) { _ in scheduleUpdate() }
                Toggle("说话", isOn: $speak)
                    .onChange(of: speak) { _ in scheduleUpdate() }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: $linesText)
                .frame(height: 50)
                .border(Color.gray.opacity(0.3))
                .onChange(of: linesText) { _ in scheduleUpdate() }
        }
        .padding(.vertical, 4)
        .onDisappear {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            update()
        }
    }

    /// 防抖 300ms：连续输入只更新一次配置，避免每个按键都重绘整个设置页。
    private func scheduleUpdate() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { update() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func update() {
        let lines = linesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        onChange(ClickReactionConfig(
            id: reaction.id,
            animation: animation,
            probability: probability,
            speak: speak,
            lines: lines
        ))
    }
}

struct FeedItemRow: View {
    let index: Int
    let item: FeedItemConfig
    let onDelete: () -> Void
    let onChange: (FeedItemConfig) -> Void

    @State private var name: String
    @State private var emoji: String
    @State private var happiness: Int
    @State private var satiety: Int
    @State private var energy: Int
    @State private var price: Int
    @State private var animation: String
    @State private var linesText: String
    @State private var saveWorkItem: DispatchWorkItem?

    init(index: Int, item: FeedItemConfig, onDelete: @escaping () -> Void, onChange: @escaping (FeedItemConfig) -> Void) {
        self.index = index
        self.item = item
        self.onDelete = onDelete
        self.onChange = onChange
        self._name = State(initialValue: item.name)
        self._emoji = State(initialValue: item.emoji)
        self._happiness = State(initialValue: item.happiness)
        self._satiety = State(initialValue: item.satiety)
        self._energy = State(initialValue: item.energy)
        self._price = State(initialValue: item.price)
        self._animation = State(initialValue: item.animation)
        self._linesText = State(initialValue: item.lines.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("名称", text: $name)
                    .frame(width: 100)
                    .onChange(of: name) { _ in scheduleUpdate() }
                TextField("表情", text: $emoji)
                    .frame(width: 40)
                    .onChange(of: emoji) { _ in scheduleUpdate() }
                TextField("动画", text: $animation)
                    .frame(width: 80)
                    .onChange(of: animation) { _ in scheduleUpdate() }
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                IntNumberStepperRow(
                    title: "开心度",
                    unit: "",
                    value: $happiness,
                    range: 1...50,
                    step: 1
                )
                .frame(maxWidth: 220)
                .onChange(of: happiness) { _ in scheduleUpdate() }

                IntNumberStepperRow(
                    title: "价格",
                    unit: "",
                    value: $price,
                    range: 0...1000,
                    step: 10
                )
                .frame(maxWidth: 220)
                .onChange(of: price) { _ in scheduleUpdate() }
            }

            HStack(spacing: 16) {
                IntNumberStepperRow(
                    title: "饱腹度",
                    unit: "",
                    value: $satiety,
                    range: -50...50,
                    step: 1
                )
                .frame(maxWidth: 220)
                .onChange(of: satiety) { _ in scheduleUpdate() }

                IntNumberStepperRow(
                    title: "精力",
                    unit: "",
                    value: $energy,
                    range: -20...20,
                    step: 1
                )
                .frame(maxWidth: 220)
                .onChange(of: energy) { _ in scheduleUpdate() }
            }

            TextEditor(text: $linesText)
                .frame(height: 50)
                .border(Color.gray.opacity(0.3))
                .onChange(of: linesText) { _ in scheduleUpdate() }
        }
        .padding(.vertical, 4)
        .onDisappear {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            update()
        }
    }

    private func scheduleUpdate() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { update() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func update() {
        let lines = linesText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        onChange(FeedItemConfig(
            id: item.id,
            name: name,
            emoji: emoji,
            happiness: happiness,
            satiety: satiety,
            energy: energy,
            price: price,
            animation: animation,
            lines: lines
        ))
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @EnvironmentObject var configManager: ConfigManager
    
    var body: some View {
        Form {
            Section("通知") {
                Toggle("启用通知", isOn: Binding(
                    get: { configManager.config.notifications.enabled },
                    set: { newValue in configManager.updateNotificationsConfig { $0.enabled = newValue } }
                ))
                
                Toggle("显示说话通知", isOn: Binding(
                    get: { configManager.config.notifications.showSpeech },
                    set: { newValue in configManager.updateNotificationsConfig { $0.showSpeech = newValue } }
                ))
                
                Toggle("显示报时通知", isOn: Binding(
                    get: { configManager.config.notifications.showTimeReport },
                    set: { newValue in configManager.updateNotificationsConfig { $0.showTimeReport = newValue } }
                ))
            }
            
            Section("数据存储") {
                Toggle("保存聊天记录", isOn: Binding(
                    get: { configManager.config.data.saveChatHistory },
                    set: { newValue in configManager.updateDataConfig { $0.saveChatHistory = newValue } }
                ))
                
                Stepper("最大记录数: \(configManager.config.data.maxHistory)", value: Binding(
                    get: { configManager.config.data.maxHistory },
                    set: { newValue in configManager.updateDataConfig { $0.maxHistory = newValue } }
                ), in: 10...1000, step: 10)
                
                Toggle("保存位置", isOn: Binding(
                    get: { configManager.config.data.savePosition },
                    set: { newValue in configManager.updateDataConfig { $0.savePosition = newValue } }
                ))
                
                Toggle("保存心情", isOn: Binding(
                    get: { configManager.config.data.saveHappiness },
                    set: { newValue in configManager.updateDataConfig { $0.saveHappiness = newValue } }
                ))
            }
            
            Section("调试") {
                Button("重置宠物状态") { PetController.shared.resetPetState() }
                    .foregroundColor(.orange)
                Button("打开配置文件夹") { openConfigFolder() }
                Button("打开模型文件夹") { openModelFolder() }
            }
            
            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("0.2.1").foregroundColor(.secondary)
                }
                HStack {
                    Text("作者")
                    Spacer()
                    Text("NickeL9740（nickel9740@gmail.com）").foregroundColor(.secondary)
                }
                Link("GitHub 仓库", destination: URL(string: "https://github.com/NickeL9740/DebuSeek-mac")!)
                Link("DeepSeek api官网", destination: URL(string: "https://platform.deepseek.com")!)
            }
        }
        .formStyle(.grouped)
    }
    
    // 打开配置文件夹
    private func openConfigFolder() {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupportDir.appendingPathComponent("DebuSeek").path
        
        // 确保文件夹存在，如果不存在则自动创建
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        
        NSWorkspace.shared.open(URL(fileURLWithPath: configDir))
    }

    // 打开模型文件夹
    private func openModelFolder() {
        var targetPath = ""
        
        // 1. 优先查找 App Bundle 里的 Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundleModelPath = resourcePath + "/Models"
            if FileManager.default.fileExists(atPath: bundleModelPath) {
                targetPath = bundleModelPath
            }
        }
        
        // 2. 如果 App 里没有，兜底查找当前运行目录下的 Resources/Models
        if targetPath.isEmpty {
            let currentPath = FileManager.default.currentDirectoryPath + "/Resources/Models"
            if FileManager.default.fileExists(atPath: currentPath) {
                targetPath = currentPath
            }
        }
        
        // 3. 如果找到了，就用系统默认文件管理器打开
        if !targetPath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
        } else {
            print("⚠️ 找不到模型文件夹")
        }
    }
}

// MARK: - ConfigManager Extensions for Settings

extension ConfigManager {
    func updateMenuBarConfig(_ block: (inout MenuBarConfig) -> Void) {
        block(&config.menuBar)
        saveConfig()
    }
    
    func updateNotificationsConfig(_ block: (inout NotificationsConfig) -> Void) {
        block(&config.notifications)
        saveConfig()
    }
    
    func updateDataConfig(_ block: (inout DataConfig) -> Void) {
        block(&config.data)
        saveConfig()
    }
}

// MARK: - Debug Settings

struct DebugSettingsView: View {
    @ObservedObject private var logger = ChatDebugLogger.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近 20 次聊天请求")
                    .font(.headline)
                Spacer()
                Button("导出为 .txt") {
                    exportLogs()
                }
                .disabled(logger.logs.isEmpty)
                Button("清空") {
                    logger.clear()
                }
                .disabled(logger.logs.isEmpty)
            }

            Toggle("启用调试抓包", isOn: $logger.isEnabled)
                .toggleStyle(.switch)

            if logger.logs.isEmpty {
                Spacer()
                Text("还没有聊天请求。发一条消息后，这里会显示完整的 Request / Response JSON。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(logger.logs) { entry in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Request JSON")
                                .font(.caption.bold())
                            Text(entry.requestJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)

                            Text("Response JSON")
                                .font(.caption.bold())
                            Text(entry.responseJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text(entry.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                            Text(entry.provider)
                                .font(.caption.bold())
                            Spacer()
                            Text("prompt \(entry.promptTokens) / completion \(entry.completionTokens) / miss \(entry.cacheMissTokens)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
    }

    private func exportLogs() {
        guard !logger.logs.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = logger.logs.map { entry -> String in
            """
            [\(formatter.string(from: entry.timestamp))] \(entry.provider)
            prompt=\(entry.promptTokens) completion=\(entry.completionTokens) cacheMiss=\(entry.cacheMissTokens)

            Request:
            \(entry.requestJSON)

            Response:
            \(entry.responseJSON)
            """
        }.joined(separator: "\n\n----------------------------------------\n\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "DebuSeek-ChatDebug-\(stamp).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("🐞 debug export failed: \(error)")
            }
        }
    }
}
