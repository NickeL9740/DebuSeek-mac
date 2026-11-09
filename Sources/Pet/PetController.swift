import Foundation
import SwiftUI
import Combine
import AppKit
import Carbon
import QuartzCore

// MARK: - Pet Controller

@MainActor
class PetController: NSObject, ObservableObject {
    static let shared = PetController()
    
    @Published var isVisible: Bool = true
    @Published var showSettingsWindow: Bool = false
    @Published var showChatInput: Bool = false
    @Published var chatInputText: String = ""
    
    // MARK: - Core
    
    private var petScene: PetScene!
    private var windowController: PetWindowController!
    // 全局快捷键（首次点击宠物后才注册）
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?
    private var hotKeysRegistered = false
    
    private var dialogueManager: DialogueManager!
    private let awareness = AwarenessManager()
    
    // MARK: - Heartbeat（全项目唯一 Timer，1.0s）
    
    private var heartbeatTimer: Timer?
    private var tick: Int = 0
    private var nextActivityTick: Int = 6
    private var nextMicroTick: Int = 4
    private var nextAwarenessTick: Int = 2
    private var nextSpeechAt: Date = .distantFuture
    
    // MARK: - Activity
    
    private var activityEndTick: Int = 0
    private var walkDirection: CGFloat = 1

    // 走路平滑位移：0.1s 局部 Timer，每次 1pt，10 次走完 10pt
    private var walkStepTimer: Timer?
    private var walkStepRemaining: Int = 0
    private var walkStepDelta: CGFloat = 0
    private var walkStepTargetX: CGFloat = 0
    private var walkStepHitEdge = false
    
    // MARK: - Interaction bookkeeping
    
    private var angryUntilTick: Int = 0
    private var lastPokeTick: Int = 0
    
    // MARK: - Speech
    
    private var speechGeneration: Int = 0
    
    // MARK: - Misc
    
    private var cancellables = Set<AnyCancellable>()
    private var lastTimeReportHour: Int = -1
    private var lastTimeReportAt: Date = .distantPast
    
    private override init() {
        super.init()
        NSLog("🐟 PetController init started")
        setupPet()
        setupHeartbeat()
        observeConfigChanges()

        // 启动 3 秒后自动弹出设置窗口，方便确认 UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.openSettingsWindow()
        }

        NSLog("🐟 PetController init completed")
    }
    
    private func setupPet() {
        let config = ConfigManager.shared.config
        
        petScene = PetScene(size: CGSize(width: config.pet.size.width, height: config.pet.size.height))
        // 场景铺满窗口；PetScene 的锚点在底边，窗口为气泡向上增高时宠物不动
        petScene.scaleMode = .resizeFill
        
        // 交互回调带像素级 zone（face/head/body/tail）
        petScene.onClick = { [weak self] zone in self?.handleClick(zone: zone) }
        petScene.onDoubleClick = { [weak self] zone in self?.handleDoubleClick(zone: zone) }
        petScene.onRightClick = { [weak self] _ in self?.handleRightClick() }
        petScene.onLongPress = { [weak self] zone in self?.handleLongPress(zone: zone) }
        
        // 加载动画：AnimationLoader 是唯一资源入口（manifest 动作名 IDLE/HAPPY/...）
        petScene.loadModel()
        petScene.setScale(CGFloat(config.pet.model.petScale))  // 全局统一缩放（petScale，默认 0.75）
        petScene.setAlpha(CGFloat(config.pet.model.opacity))
        
        // 对话：ResourceResolver 定位 dialogue/*.json（12 分类）
        dialogueManager = DialogueManager(petState: PetState.shared, awareness: awareness)
        
        // Create window
        windowController = PetWindowController(petScene: petScene, config: config.window)

        // 气泡过高时向上增高窗口；消失后收回。底边固定，宠物位置不受影响。
        petScene.onSpeechHeightRequest = { [weak self] desiredHeight in
            self?.windowController.requestSpeechHeight(desiredHeight) ?? desiredHeight
        }
        petScene.onSpeechHeightReset = { [weak self] in
            self?.windowController.resetSpeechHeight()
        }
        
        // 拖拽回调：物理 → 动画；绝不在这里触发 TTS
        windowController.onDragStart = { [weak self] in
            self?.stopWalkStep()
            PetState.shared.updateLastInteraction()
            PetState.shared.setDragging(true)
            self?.interruptActivity()
            self?.petScene.playAnimation("DRAGGING")
        }
        windowController.onDragEnd = { [weak self] velocity in
            PetState.shared.setDragging(false)
            PetState.shared.setPosition(self?.windowController?.getPosition() ?? .zero)
            self?.handleDragEnd(velocity: velocity)
        }
        windowController.onLanding = { [weak self] impact in
            guard let self = self else { return }
            let animation = impact >= PetWindowController.Physics.heavyLandingSpeed ? "DIZZY" : "LANDING"
            let useAI = ConfigManager.shared.config.interaction.useAIForInteraction
            let line = useAI ? nil : (self.dialogueManager.speak(category: "interaction") ?? "呼…落地了。")
            self.playInteraction(
                animation,
                line: line,
                aiPrompt: useAI ? "（用户把你扔到了天上并落地）" : nil
            )
        }
        
        // Set initial position - bottom center of visible screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth = windowController.getSize().width
            let pos = CGPoint(
                x: screenFrame.midX - windowWidth / 2,
                y: screenFrame.minY + 50
            )
            NSLog("🐟 Using screen bottom center position: \(pos)")
            windowController.setPosition(pos)
        } else {
            let pos = CGPoint(x: 100, y: 100)
            NSLog("🐟 Using fallback position: \(pos)")
            windowController.setPosition(pos)
        }
        
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Heartbeat
    
    private func setupHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        heartbeatTimer?.tolerance = 0.1
        scheduleNextAutoSpeech()
    }
    
    /// 1 秒心跳：驱动一切周期逻辑（状态衰减 / 行为决策 / 微动作 / 感知 / 自动说话 / 报时）
    private func heartbeat() {
        tick += 1
        
        // 无聊值随时间稳定增长（每秒 +1），互动会把它打下去
        let state = PetState.shared
        if !state.isSleeping && !state.isDragging {
            state.boredom = min(100, state.boredom + 1)
        }
        
        if tick % 30 == 0 { decayNeeds() }
        
        if tick >= nextActivityTick {
            decideActivity()
            nextActivityTick = tick + Int.random(in: 5...10)
        }
        
        if tick >= nextMicroTick {
            playMicroActionIfPossible()
            nextMicroTick = tick + Int.random(in: 3...8)
        }
        
        if tick >= nextAwarenessTick {
            awareness.sample()
            nextAwarenessTick = tick + 2
        }
        
        if Date() >= nextSpeechAt {
            triggerAutoSpeech()
            scheduleNextAutoSpeech()
        }
        
        checkTimeReport()
        updateActivity()
        
        if angryUntilTick > 0 && tick >= angryUntilTick {
            PetState.shared.isAngry = false
            angryUntilTick = 0
        }
        
        if lastPokeTick > 0 && tick - lastPokeTick > 5 {
            PetState.shared.consecutivePokes = 0
            lastPokeTick = 0
        }
    }
    
    // MARK: - Needs Decay
    
    private func decayNeeds() {
        let state = PetState.shared
        guard windowController.state == .resting else { return }
        guard !state.isDragging, !state.isSleeping else {
            state.saveState()
            return
        }
        
        state.updateEnergy(-1)
        state.updateHunger(1)
        
        if state.hunger > 70 || state.happiness < 30 {
            state.updateHappiness(-1)
        } else {
            state.updateHappiness(1)
        }
        state.saveState()
    }
    
    // MARK: - Behavior Decision（加权随机）
    
    private func decideActivity() {
        guard !isBusy else { return }
        guard petScene.petNode.currentAnimation == "IDLE" else { return }
        
        let state = PetState.shared
        
        // 无聊值超过阈值 → 强制出门散步（不平移窗口就永远看不到 WALKING）
        if state.boredom > 40 && state.energy > 20 {
            NSLog("🚶 boredom=\(Int(state.boredom)) > 40 → startActivity(.walk)")
            startActivity(.walk)
            return
        }
        
        var candidates: [(PetActivity, Double)] = []
        
        if state.energy < 20 && !state.isSleeping {
            candidates.append((.sleep, Double(100 - state.energy)))
        }
        if state.boredom > 70 {
            candidates.append((.eat, state.boredom))
        }
        if state.boredom > 40 && state.energy > 30 {
            candidates.append((.walk, state.boredom * 0.5))
            candidates.append((.explore, state.boredom * 0.3))
        }
        candidates.append((.idle, max(5, 50 - state.boredom * 0.5)))
        
        let total = candidates.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return }
        
        var random = Double.random(in: 0..<total)
        for (activity, weight) in candidates {
            random -= weight
            if random <= 0 {
                startActivity(activity)
                return
            }
        }
        if let last = candidates.last {
            startActivity(last.0)
        }
    }
    
    private func startActivity(_ activity: PetActivity) {
        let state = PetState.shared
        let normalized: PetActivity = (activity == .explore) ? .walk : activity
        state.currentActivity = normalized
        
        switch normalized {
        case .idle:
            if petScene.petNode.currentAnimation != "IDLE" {
                petScene.playAnimation("IDLE")
            }
            
        case .walk:
            walkDirection = Bool.random() ? 1 : -1
            let isMovingRight = walkDirection > 0
            NSLog("🚶 walk start direction=\(isMovingRight ? "right" : "left")")

            // 强制循环播放 WALKING 多帧动画；向右只做水平镜像，
            // applyPetScale 会先锁死 size=150×150，再设置 xScale=-|petScale|。
            petScene.setWalkFacing(right: isMovingRight)
            petScene.playAnimation("WALKING")
            activityEndTick = tick + Int.random(in: 5...9)
            
        case .sleep:
            state.isSleeping = true
            petScene.playAnimationOnce("sleep_enter") { [weak self] in
                guard let self = self else { return }
                guard PetState.shared.isSleeping else { return }
                self.petScene.playAnimation("SLEEPING")
            }
            activityEndTick = tick + 60
            
        case .eat:
            petScene.playAnimationOnce("EATING") { [weak self] in
                guard let self = self else { return }
                let current = PetState.shared
                current.boredom = max(0, current.boredom - 20)
                current.energy = min(100, current.energy + 10)
                current.currentActivity = .idle
                self.petScene.playAnimation("IDLE")
                current.saveState()
            }
            activityEndTick = tick + 5
            
        case .sweep:
            petScene.playAnimationOnce("SWEEPING") { [weak self] in
                self?.petScene.playAnimation("IDLE")
            }
            activityEndTick = tick + 5
            
        case .explore:
            break
        }
    }
    
    private func updateActivity() {
        let state = PetState.shared
        
        switch state.currentActivity {
        case .walk:
            if tick >= activityEndTick {
                // 说话期间不切 walk_stop，避免打断 TALKING；说完后再收脚
                if !TTSServiceManager.shared.isSpeaking {
                    stopWalking()
                }
            } else if !TTSServiceManager.shared.isSpeaking {
                // 说话时暂停脚步，避免 TALKING 动画下窗口还在平移
                stepWalk()
            }
        case .sleep:
            state.energy = min(100, state.energy + 1)
            if state.energy >= 60 || tick >= activityEndTick {
                wakeUp()
            }
        default:
            break
        }
    }
    
    private func stepWalk() {
        guard windowController.state == .resting else { return }
        guard walkStepTimer == nil else { return }
        
        let size = windowController.getSize()
        let origin = windowController.getPosition()
        let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height))
        }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        
        var x = origin.x + walkDirection * 10
        var hitEdge = false
        if x < visibleFrame.minX {
            x = visibleFrame.minX
            hitEdge = true
        }
        if x + size.width > visibleFrame.maxX {
            x = visibleFrame.maxX - size.width
            hitEdge = true
        }
        
        // 每次心跳走 10pt：拆成 10 次 ×1pt，0.1 秒一步，视觉上平滑连续
        let delta = x - origin.x
        guard abs(delta) >= 0.5 else {
            if hitEdge {
                walkDirection = -walkDirection
                NSLog("🚶 hit screen edge → turn around & stop")
                stopWalking()
            }
            return
        }
        
        stopWalkStep()
        walkStepTargetX = x
        walkStepHitEdge = hitEdge
        walkStepRemaining = 10
        walkStepDelta = delta / 10
        
        // 0.1s 级别（0.09s ×10 次 = 0.9s 走完 10pt，确保下一次心跳前完成，不会一卡一卡）
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceWalkStep()
            }
        }
        walkStepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func advanceWalkStep() {
        guard walkStepRemaining > 0, let window = windowController.window else {
            stopWalkStep()
            return
        }
        
        let origin = windowController.getPosition()
        walkStepRemaining -= 1
        
        var nextX = origin.x + walkStepDelta
        if walkStepRemaining == 0 {
            nextX = walkStepTargetX
        }
        
        let newOrigin = CGPoint(x: nextX.rounded(), y: origin.y.rounded())
        window.setFrameOrigin(newOrigin)
        PetState.shared.setPosition(newOrigin)
        
        if walkStepRemaining == 0 {
            let hitEdge = walkStepHitEdge
            stopWalkStep()
            if hitEdge {
                walkDirection = -walkDirection
                NSLog("🚶 hit screen edge → turn around & stop")
                stopWalking()
            }
        }
    }
    
    private func stopWalkStep() {
        walkStepTimer?.invalidate()
        walkStepTimer = nil
        walkStepRemaining = 0
    }
    
    private func stopWalking() {
        guard PetState.shared.currentActivity == .walk else { return }
        stopWalkStep()
        PetState.shared.currentActivity = .idle
        // 散步消耗无聊值，避免刚停下就立刻重新出发
        PetState.shared.boredom = max(0, PetState.shared.boredom - 25)
        // 走路循环结束立即回 IDLE；applyPetScale 会强制 xScale = +|petScale|，解除镜像
        petScene.playAnimation("IDLE")
        NSLog("🚶 walk stop → IDLE")
    }
    
    private func wakeUp() {
        guard PetState.shared.isSleeping else { return }
        PetState.shared.isSleeping = false
        PetState.shared.currentActivity = .idle
        petScene.playAnimationOnce("sleep_wake") { [weak self] in
            self?.petScene.playAnimation("IDLE")
        }
    }
    
    private func interruptActivity() {
        stopWalkStep()
        let state = PetState.shared
        state.isSleeping = false
        state.currentActivity = .idle
    }
    
    // MARK: - Micro Actions（BLINK / GLANCE）
    
    private func playMicroActionIfPossible() {
        guard !isBusy else { return }
        guard petScene.petNode.currentAnimation == "IDLE" else { return }
        guard !TTSServiceManager.shared.isSpeaking else { return }
        
        let animation = Bool.random() ? "BLINK" : "GLANCE"
        petScene.playAnimationOnce(animation) { [weak self] in
            self?.petScene.playAnimation("IDLE")
        }
    }
    
    /// 拖拽/空中飞行/睡觉/TTS 播报期间，行为树不抢动画
    private var isBusy: Bool {
        let state = PetState.shared
        if state.isDragging { return true }
        if windowController.state != .resting { return true }
        if state.isSleeping { return true }
        if TTSServiceManager.shared.isSpeaking { return true }
        return false
    }
    
    // MARK: - Auto Speech
    
    private func scheduleNextAutoSpeech() {
        let config = ConfigManager.shared.config.autoSpeech
        guard config.enabled else {
            nextSpeechAt = .distantFuture
            return
        }
        // 恢复正常节奏：3~10 分钟一句（用配置的 intervalMin/intervalMax）
        let lower = max(60, config.intervalMin)
        let upper = max(lower, config.intervalMax)
        let interval = TimeInterval.random(in: TimeInterval(lower)...TimeInterval(upper))
        nextSpeechAt = Date().addingTimeInterval(interval)
    }
    
    private func triggerAutoSpeech() {
        guard ConfigManager.shared.config.autoSpeech.enabled else { return }
        guard !isBusy else { return }
        // 允许覆盖眨眼/瞥一眼/发呆这类低优先级微动作，避免自动说话总被微动作挡掉
        let current = petScene.petNode.currentAnimation
        let canSpeak = current == "IDLE" || current == "BLINK" || current == "GLANCE" || current == "THINKING"
        guard canSpeak else { return }
        guard let line = dialogueManager.speakForContext() else { return }
        speak(line)
    }
    
    // MARK: - Time Report
    
    private func checkTimeReport() {
        let config = ConfigManager.shared.config.timeReport
        guard config.enabled else { return }
        guard !PetState.shared.isSleeping else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastTimeReportAt) >= 55 else { return }
        
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        
        var shouldReport = false
        if config.announceOnHour && minute == 0 && hour != lastTimeReportHour {
            shouldReport = true
        } else if config.announceOnHalfHour && minute == 30 {
            shouldReport = true
        } else if config.intervalMinutes > 0 && minute % config.intervalMinutes == 0 {
            shouldReport = true
        }
        
        guard shouldReport else { return }
        // 不要打断互动/拖拽/说话中的动画
        guard petScene.petNode.currentAnimation == "IDLE" else { return }
        
        lastTimeReportHour = hour
        lastTimeReportAt = now
        
        let formatter = DateFormatter()
        formatter.dateFormat = config.format
        let timeString = formatter.string(from: now)
        
        let phrase = config.phrases.randomElement() ?? "现在是{time}啦~"
        speak(phrase.replacingOccurrences(of: "{time}", with: timeString))
    }
    
    // MARK: - Interaction Handlers
    
    private func handleClick(zone: HitZone) {
        registerGlobalHotKeysIfNeeded()
        let state = PetState.shared
        state.updateLastInteraction()
        state.boredom = max(0, state.boredom - 8)
        interruptActivity()
        
        switch zone {
        case .body:
            state.consecutivePokes += 1
            lastPokeTick = tick
            
            if state.consecutivePokes >= 3 {
                state.consecutivePokes = 0
                state.affection = max(0, state.affection - 10)
                state.isAngry = true
                angryUntilTick = tick + 15
                let line = useAIForInteraction
                    ? nil
                    : (dialogueManager.speak(category: "state", forced: true) ?? "哼！")
                playInteraction(
                    "ANGRY",
                    line: line,
                    aiPrompt: useAIForInteraction ? "（用户连续戳了你的身体，你有点生气了）" : nil
                )
            } else {
                playInteraction(
                    "POKE_REACT",
                    line: interactionLine(zone: zone, type: .click, fallback: "嗯？"),
                    aiPrompt: interactionAIPrompt(zone: zone, type: .click)
                )
            }
            
        case .face, .head:
            state.affection = min(100, state.affection + 2)
            playInteraction(
                "HAPPY",
                line: interactionLine(zone: zone, type: .click, fallback: "嘿嘿~"),
                aiPrompt: interactionAIPrompt(zone: zone, type: .click)
            )
            
        case .tail:
            state.affection = min(100, state.affection + 1)
            playInteraction(
                "TAIL_REACT",
                line: interactionLine(zone: zone, type: .click, fallback: "尾巴不能乱摸啦！"),
                aiPrompt: interactionAIPrompt(zone: zone, type: .click)
            )
            
        case .none:
            break

        case .bubble:
            // 气泡点击由 PetScene 直接爆气泡，不会走到这里；仅为穷举完整
            break
        }
    }
    
    private func handleDoubleClick(zone: HitZone) {
        let state = PetState.shared
        state.updateLastInteraction()
        state.boredom = max(0, state.boredom - 10)
        state.affection = min(100, state.affection + 3)
        state.updateHunger(-10)
        interruptActivity()
        
        playInteraction(
            "EATING",
            line: interactionLine(zone: zone, type: .doubleClick, fallback: "好吃！"),
            aiPrompt: interactionAIPrompt(zone: zone, type: .doubleClick)
        )
    }
    
    private func handleRightClick() {
        PetState.shared.updateLastInteraction()
        registerGlobalHotKeysIfNeeded()
        showPetContextMenu()
    }
    
    private func handleLongPress(zone: HitZone) {
        // 拖拽/空中状态已在 PetWindow 窗口级长按判定中过滤，这里不再重复拦截
        let state = PetState.shared
        state.updateLastInteraction()
        state.boredom = max(0, state.boredom - 8)
        state.affection = min(100, state.affection + (zone == .body ? 3 : 5))
        interruptActivity()
        
        playInteraction(
            "HEAD_PAT",
            line: interactionLine(zone: zone, type: .longPress, fallback: "好舒服~"),
            aiPrompt: interactionAIPrompt(zone: zone, type: .longPress)
        )
    }
    
    private func handleDragEnd(velocity: CGVector) {
        let speed = (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
        if speed > 500 {
            petScene.playAnimation("FALLING")
        } else {
            petScene.playAnimation("IDLE")
        }
    }
    
    // MARK: - AI Interaction
    
    /// 物理互动是否走大模型（设置里的“物理互动触发 AI 实时回复”）。
    private var useAIForInteraction: Bool {
        ConfigManager.shared.config.interaction.useAIForInteraction
    }
    
    /// 关闭 AI 时才查本地预设；AI 开启时返回 nil，避免提前消耗 DialogueManager 的冷却。
    private func interactionLine(zone: HitZone, type: DialogueInteractionType, fallback: String) -> String? {
        guard !useAIForInteraction else { return nil }
        return dialogueManager.speakOnInteraction(zone: zone, type: type) ?? fallback
    }
    
    /// 把像素命中区翻译成给大模型的“事件描述”，只用一句，不污染聊天历史。
    private func interactionAIPrompt(zone: HitZone, type: DialogueInteractionType) -> String? {
        guard useAIForInteraction else { return nil }
        switch type {
        case .click:
            switch zone {
            case .face: return "（用户戳了戳你的脸）"
            case .head: return "（用户摸了摸你的头部）"
            case .body: return "（用户戳了戳你的身体）"
            case .tail: return "（用户摸了摸你的尾巴）"
            case .bubble: return nil
            case .none: return "（用户碰了碰你）"
            }
        case .longPress:
            return "（用户摸了摸你的头部）"
        case .doubleClick:
            return "（用户双击了你）"
        case .dragStart, .dragEnd:
            return "（用户碰了碰你）"
        }
    }
    
    /// 先播一次性互动动画，结束后再说话（TALKING 覆盖 IDLE，保证 TALKING 与 TTS 同步）。
    /// `aiPrompt` 非空且设置开启时，改为请求大模型；失败则用 line/兜底台词，保证不会无声。
    private func playInteraction(_ animation: String, line: String?, aiPrompt: String? = nil) {
        petScene.playAnimationOnce(animation) { [weak self] in
            guard let self = self else { return }
            if let prompt = aiPrompt, self.useAIForInteraction {
                self.requestAIInteractionReply(prompt: prompt, fallbackLine: line ?? "嗯？")
            } else if let line = line, !line.isEmpty {
                self.speak(line)
            } else if self.petScene.petNode.currentAnimation != "TALKING" {
                self.petScene.playAnimation("IDLE")
            }
        }
    }
    
    /// 互动触发的 AI 回复：气泡 + TALKING + TTS；失败安静回退到本地台词。
    private func requestAIInteractionReply(prompt: String, fallbackLine: String) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let reply = try await ChatServiceManager.shared.sendMessage(prompt)
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                self.speak(trimmed.isEmpty ? fallbackLine : trimmed)
            } catch {
                NSLog("⚠️ AI interaction reply failed: \(error.localizedDescription) → fallback")
                self.speak(fallbackLine)
            }
        }
    }
    
    // MARK: - Public Actions
    
    /// 所有发声的唯一出口：气泡 + TALKING 循环 + TTS，结束/报错后回 IDLE
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        NSLog("🔊 speak: \(trimmed)")

        // 气泡保留完整括号动作描写；送进 TTS 的只有纯对话。
        let spokenText = TTSTextSanitizer.spokenText(from: trimmed)

        showSpeech(trimmed)
        
        speechGeneration += 1
        let generation = speechGeneration

        // 每次新的 speak 立刻打断上一句语音（只停声音，不动气泡/立绘）。
        TTSServiceManager.shared.stop()
        
        petScene.playAnimation("TALKING", loop: true)
        
        let hasVoice = ConfigManager.shared.config.tts.enabled && !spokenText.isEmpty
        if hasVoice {
            Task { [weak self] in
                await TTSServiceManager.shared.speak(spokenText)
                self?.finishSpeaking(generation: generation)
            }
        }
        
        // 看门狗：TTS 服务异常挂起或这句话没有可读文本时，也不让 TALKING 卡死
        let timeout = hasVoice ? min(12.0, 2.0 + Double(trimmed.count) * 0.25) : 2.0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finishSpeaking(generation: generation)
        }
    }
    
    private func finishSpeaking(generation: Int) {
        guard generation == speechGeneration else { return }
        guard petScene.petNode.currentAnimation == "TALKING" else { return }
        // 走路途中说话，说完继续走；否则回 IDLE
        if PetState.shared.currentActivity == .walk {
            petScene.playAnimation("WALKING")
        } else {
            petScene.playAnimation("IDLE")
        }
    }
    
    func showSpeech(_ text: String) {
        // 裸二进制（无 .app Bundle）不能调用 UserNotifications，气泡即唯一提示
        petScene.showSpeech(text)
    }
    
    /// 设置页命中区校准用：当前 IDLE 第一帧（已经是 150×150 的归一化画布，
    /// 与 PetScene.hitTest 的 (u, v) 坐标系完全一致）。
    var idlePreviewImage: NSImage? {
        guard let scene = petScene,
              let node = scene.petNode,
              let texture = node.textures["IDLE"]?.first else { return nil }
        let cgImage = texture.cgImage()
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    func sendChatMessage(_ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        ChatHistoryManager.shared.addMessage(ChatMessage(role: .user, content: message))
        
        Task {
            do {
                let response = try await ChatServiceManager.shared.sendMessage(message)
                ChatHistoryManager.shared.addMessage(ChatMessage(role: .assistant, content: response))
                presentChatReply(response)
            } catch {
                presentChatReply("呜...网络好像出问题了 (＞﹏＜)")
            }
        }
    }
    
    /// 聊天回复统一出口：默认只显示气泡，不播 TALKING、不调用 TTS。
    /// 只有设置里显式打开 chat.readChatAloud，才走 speak()（气泡 + TALKING + 语音）。
    /// 点击/长按等宠物互动仍然走 playInteraction → speak，不受这个开关影响。
    private func presentChatReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if ConfigManager.shared.config.chat.readChatAloud {
            speak(trimmed)
        } else {
            showSpeech(trimmed)
        }
    }
    
    func feedPetWithItem(_ item: FeedItemConfig) {
        PetState.shared.updateHappiness(item.happiness)
        PetState.shared.updateHunger(-item.happiness)
        interruptActivity()
        playInteraction("EATING", line: item.lines.randomElement() ?? "好吃！")
    }
    
    @objc func toggleVisibility() {
        isVisible.toggle()
        
        if isVisible {
            windowController.window?.ignoresMouseEvents = false
            windowController.window?.makeKeyAndOrderFront(nil)
        } else {
            windowController.window?.orderOut(nil)
        }
        
    }
    
    @objc func showChat() {
        showChatInput = true
        AppDelegate.shared.showChatWindow()
    }
    
    @objc func feedPet(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FeedItemConfig {
            feedPetWithItem(item)
        }
    }
    
    @objc func toggleTTS() {
        ConfigManager.shared.updateTTSConfig { $0.enabled.toggle() }
    }
    
    @objc func toggleAutoSpeech() {
        ConfigManager.shared.updateAutoSpeechConfig { $0.enabled.toggle() }
        scheduleNextAutoSpeech()
    }
    
    @objc func toggleTimeReport() {
        ConfigManager.shared.updateTimeReportConfig { $0.enabled.toggle() }
    }
    
    @objc func openSettingsWindow() {
        showSettingsWindow = true
        AppDelegate.shared.showSettingsWindow()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
    
    func getWindowPosition() -> CGPoint {
        windowController.getPosition()
    }
    
    func setWindowPosition(_ point: CGPoint) {
        windowController.setPosition(point)
    }
    
    // MARK: - Right-click Menu（替代 NSStatusItem）

    private func showPetContextMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("设置 (Settings)...", action: #selector(openSettingsWindow), key: ","))
        menu.addItem(menuItem("聊天 (Chat)...", action: #selector(showChat), key: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("退出 (Quit)", action: #selector(quitApp), key: "q"))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 菜单项统一显式指定 target（accessory app 的 nil target 可能找不到响应者）
    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Global Hotkeys（首次点击宠物后注册）

    private func registerGlobalHotKeysIfNeeded() {
        guard !hotKeysRegistered else { return }
        hotKeysRegistered = true

        installHotKeyHandler()

        let config = ConfigManager.shared.config
        let settingsKey = config.hotkeySettings ?? "option+s"
        let chatKey = config.hotkeyChat ?? "option+c"
        registerHotKey(settingsKey, id: 1)
        registerHotKey(chatKey, id: 2)
        print("⌨️ global hotkeys registered (settings=\(settingsKey), chat=\(chatKey))")
    }

    private func installHotKeyHandler() {
        guard hotKeyHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            petHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        print("⌨️ hotkey handler install status=\(status)")
    }

    private func registerHotKey(_ descriptor: String, id: UInt32) {
        guard let parsed = Self.parseHotKey(descriptor) else {
            print("⚠️ 无法解析快捷键：\(descriptor)（示例：option+s）")
            return
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x44504B54), id: id)
        let status = RegisterEventHotKey(
            UInt32(parsed.keyCode),
            UInt32(parsed.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
            print("⌨️ hotkey registered: \(descriptor) id=\(id)")
        } else {
            print("⚠️ hotkey register failed: \(descriptor) status=\(status)")
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeysRegistered = false
    }

    func handleHotKey(id: UInt32) {
        switch id {
        case 1:
            openSettingsWindow()
        case 2:
            showChat()
        default:
            break
        }
    }

    private static func parseHotKey(_ descriptor: String) -> (keyCode: Int, modifiers: Int)? {
        let parts = descriptor
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, let key = parts.last else { return nil }

        var modifiers = 0
        for part in parts.dropLast() {
            switch part {
            case "option", "alt": modifiers |= optionKey
            case "command", "cmd": modifiers |= cmdKey
            case "control", "ctrl": modifiers |= controlKey
            case "shift": modifiers |= shiftKey
            default: return nil
            }
        }

        guard let keyCode = keyCodeMap[key] else { return nil }
        return (keyCode, modifiers)
    }

    private static let keyCodeMap: [String: Int] = [
        "a": Int(kVK_ANSI_A), "b": Int(kVK_ANSI_B), "c": Int(kVK_ANSI_C),
        "d": Int(kVK_ANSI_D), "e": Int(kVK_ANSI_E), "f": Int(kVK_ANSI_F),
        "g": Int(kVK_ANSI_G), "h": Int(kVK_ANSI_H), "i": Int(kVK_ANSI_I),
        "j": Int(kVK_ANSI_J), "k": Int(kVK_ANSI_K), "l": Int(kVK_ANSI_L),
        "m": Int(kVK_ANSI_M), "n": Int(kVK_ANSI_N), "o": Int(kVK_ANSI_O),
        "p": Int(kVK_ANSI_P), "q": Int(kVK_ANSI_Q), "r": Int(kVK_ANSI_R),
        "s": Int(kVK_ANSI_S), "t": Int(kVK_ANSI_T), "u": Int(kVK_ANSI_U),
        "v": Int(kVK_ANSI_V), "w": Int(kVK_ANSI_W), "x": Int(kVK_ANSI_X),
        "y": Int(kVK_ANSI_Y), "z": Int(kVK_ANSI_Z),
        "0": Int(kVK_ANSI_0), "1": Int(kVK_ANSI_1), "2": Int(kVK_ANSI_2),
        "3": Int(kVK_ANSI_3), "4": Int(kVK_ANSI_4), "5": Int(kVK_ANSI_5),
        "6": Int(kVK_ANSI_6), "7": Int(kVK_ANSI_7), "8": Int(kVK_ANSI_8),
        "9": Int(kVK_ANSI_9),
        ",": Int(kVK_ANSI_Comma), ".": Int(kVK_ANSI_Period), "/": Int(kVK_ANSI_Slash)
    ]

    // MARK: - Config Observation
    
    private func observeConfigChanges() {
        ConfigManager.shared.$config
            .dropFirst()
            .sink { [weak self] newConfig in
                self?.applyConfigChanges(newConfig)
            }
            .store(in: &cancellables)
    }
    
    private func applyConfigChanges(_ config: AppConfig) {
        windowController.window?.level = windowLevel(from: config.window.level)
        windowController.window?.ignoresMouseEvents = config.window.ignoresMouseEvents
        
        scheduleNextAutoSpeech()

        // 快捷键已启用时，配置变更后重新注册
        if hotKeysRegistered {
            unregisterHotKeys()
            registerGlobalHotKeysIfNeeded()
        }

        // 动画资源已常驻内存，配置变更只调整缩放/透明度，
        // 避免在设置里每输入一个字符就重新加载并归一化全部纹理（会卡顿）。
        petScene.setScale(CGFloat(config.pet.model.petScale))
        petScene.setAlpha(CGFloat(config.pet.model.opacity))
    }
    
    private func windowLevel(from config: WindowConfig.WindowLevel) -> NSWindow.Level {
        switch config {
        case .normal: return .normal
        case .floating: return .floating
        case .statusBar: return .statusBar
        case .popUpMenu: return .popUpMenu
        case .screenSaver: return .screenSaver
        }
    }
}

// MARK: - Carbon Hotkey Callback

private func petHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else { return noErr }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let controller = Unmanaged<PetController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        controller.handleHotKey(id: hotKeyID.id)
    }
    return noErr
}

// MARK: - Extensions

extension NSMenuItem {
    func withRepresentedObject(_ object: Any) -> NSMenuItem {
        self.representedObject = object
        return self
    }
}
