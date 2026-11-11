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

    /// 右键「查看状态」的悬浮窗；强引用防止瞬间释放/重复创建。
    private var statusWindow: NSWindow?
    
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
    /// 昏厥后强制睡到的精力目标（80~100）；0 表示普通睡眠。
    private var wakeTargetEnergy: Int = 0
    /// 精力归零通知的观察者（PetState.updateEnergy 发布）
    private var energyDepletedObserver: NSObjectProtocol?
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

    // MARK: - Needs / Gameplay

    /// 小数消耗累计，避免 0.7 倍率被 Int 截断后完全失效。
    private var energyDecayCarry: Double = 0
    private var hungerDecayCarry: Double = 0
    private var lastHappinessDecayTick: Int = 0
    /// 长期不交互的每小时结算基准。
    private var lastSocialDecayAt: Date = Date()
    /// 撞墙扣属性防刷（同一轮抛掷可能连续贴墙）。
    private var lastWallPenaltyAt: Date = .distantPast
    
    // MARK: - Speech
    
    private var speechGeneration: Int = 0

    // MARK: - Memory Summarization

    private var isSummarizing = false
    private let summarizationSystemPrompt = """
    你是一个对话记忆压缩器。请把下面的聊天记录压缩成一段简洁、客观、第三人称的中文长期记忆，供桌面宠物以后回忆。保留：用户称呼、身份、偏好、重要事实、约定、情绪与关系进展、未完成事项；删除寒暄、重复和无关细节。不要扮演宠物，不要使用“大肥鱼”人设，不要加标题、解释或 Markdown，只输出摘要正文，尽量不超过 300 字。
    """
    
    // MARK: - Misc
    
    private var cancellables = Set<AnyCancellable>()
    private var lastTimeReportHour: Int = -1
    private var lastTimeReportAt: Date = .distantPast
    private var lastIntervalReportTime: Date = .distantPast
    
    private override init() {
        super.init()
        NSLog("🐟 PetController init started")
        setupPet()
        setupEnergyDepletionObserver()
        setupHeartbeat()
        observeConfigChanges()

        // 启动 3 秒后自动弹出设置窗口，方便确认 UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.openSettingsWindow()
        }

        NSLog("🐟 PetController init completed")
    }
    
    /// 精力归零由 PetState 统一发通知；这里负责强睡到 80~100，避免各处 updateEnergy 重复写。
    private func setupEnergyDepletionObserver() {
        energyDepletedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PetEnergyDepleted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !PetState.shared.isSleeping else { return }
                self.wakeTargetEnergy = Int.random(in: 80...100)
                self.startActivity(.sleep)
                NSLog("😵 energy depleted → forced sleep triggered")
            }
        }
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

            // 特殊值 -1：极短飞行/轻放。只做视觉收尾，不给奖励也不扣心情/精力。
            if impact < 0 {
                self.windowController.clearWallHitFlag()
                self.windowController.lastReleaseVelocity = nil
                self.petScene.playAnimationOnce("LANDING") { [weak self] in
                    self?.petScene.playAnimation("IDLE")
                }
                NSLog("🪶 soft landing: no reward, no penalty")
                return
            }

            // 难度系统：整段抛掷没撞墙才给心情奖励；撞过墙则只扣不加。
            let gameplay = ConfigManager.shared.config.gameplay
            let releaseDY = self.windowController.lastReleaseVelocity?.dy ?? 0
            let heightBonus = max(0, Int(releaseDY / 100.0))
            if !self.windowController.hitWallDuringJump {
                let reward = gameplay.landingHappinessReward + heightBonus
                _ = self.tryGainHappiness(amount: reward, energyCost: 0, hungerCost: 0)
                NSLog("🛬 clean landing reward +\(reward) (height bonus \(heightBonus))")
            } else {
                NSLog("🛬 landing after wall hit: no reward")
            }
            self.windowController.clearWallHitFlag()
            self.windowController.lastReleaseVelocity = nil

            let animation = impact >= PetWindowController.Physics.heavyLandingSpeed ? "DIZZY" : "LANDING"
            let useAI = ConfigManager.shared.config.interaction.useAIForInteraction
            let line = useAI ? nil : (self.dialogueManager.speak(category: "interaction") ?? "呼…落地了。")
            self.playInteraction(
                animation,
                line: line,
                aiPrompt: useAI ? "（用户把你扔到了天上并落地）" : nil
            )
        }

        // 撞墙/撞天花板：按难度扣心情和大量精力；0.8 秒防抖避免贴墙连续触发。
        windowController.onWallBounce = { [weak self] in
            self?.handleWallBounce()
        }

        // 自主跳跃专用落地：只播 LANDING/DIZZY，绝不触发 onLanding 的 AI 互动回复。
        windowController.onSelfJumpLanding = { [weak self] impact in
            guard let self = self else { return }
            self.windowController.clearWallHitFlag()
            PetState.shared.currentActivity = .idle

            // 自主跳跃的落地成本/奖励：只对真正跳过（impact > 1）生效，
            // 避免接住/轻放也扣精力、加饥饿。
            if impact > 1 {
                let state = PetState.shared
                state.updateEnergy(-1)
                state.updateHunger(1)
                _ = self.tryGainHappiness(amount: 2, energyCost: 0, hungerCost: 0)
                NSLog("🦘 self jump landing: energy-1 hunger+1 happiness+2")
            }

            // 轻放（endDrag 慢速松手）不应播摔跤动画，给一个 HAPPY 收尾。
            if impact <= 1 {
                // 接住/轻放也算一次正向互动：加心情并弹 Toast。
                _ = self.tryGainHappiness(amount: 3, energyCost: 1, hungerCost: 0)
                self.petScene.showToast("接住啦！心情 +3")

                self.petScene.playAnimationOnce("HAPPY") { [weak self] in
                    self?.petScene.playAnimation("IDLE")
                }
                return
            }

            let animation = impact >= PetWindowController.Physics.heavyLandingSpeed ? "DIZZY" : "LANDING"
            self.petScene.playAnimationOnce(animation) { [weak self] in
                self?.petScene.playAnimation("IDLE")
            }
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
            let behavior = ConfigManager.shared.config.pet.behavior
            let lower = max(1, min(behavior.activityMinInterval, behavior.activityMaxInterval))
            let upper = max(lower, behavior.activityMaxInterval)
            nextActivityTick = tick + Int.random(in: lower...upper)
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
            let didSpeak = triggerAutoSpeech()
            if didSpeak {
                scheduleNextAutoSpeech()
            }
        }
        
        if tick % 60 == 0 {
            saveLastOnlineTimestamp()
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
        // 睡觉期间严禁扣除任何属性（包括精力/饥饿/心情/社交衰减）。
        guard !PetState.shared.isSleeping else { return }

        let state = PetState.shared
        guard windowController.state == .resting else { return }
        guard !state.isDragging else {
            state.saveState()
            return
        }

        let gameplay = ConfigManager.shared.config.gameplay

        // 消耗倍率可能小于 1，先累计小数再取整，避免每 30 秒固定扣 1 导致倍率失效。
        energyDecayCarry += 1.0 * gameplay.energyMultiplier
        hungerDecayCarry += 1.0 * gameplay.hungerMultiplier
        let energyLoss = Int(energyDecayCarry)
        let hungerGain = Int(hungerDecayCarry)
        energyDecayCarry -= Double(energyLoss)
        hungerDecayCarry -= Double(hungerGain)
        if energyLoss > 0 { state.updateEnergy(-energyLoss) }
        if hungerGain > 0 { state.updateHunger(hungerGain) }

        // 精力归零：立刻强制昏睡，而不是继续按 idle 行为耗着。
        if state.energy <= 0 && !state.isSleeping {
            NSLog("😵 energy depleted → forced sleep")
            // 先定好强睡目标，避免通知观察者因 isSleeping 已置位而跳过设置，
            // 导致醒来条件退化成普通睡眠。
            wakeTargetEnergy = Int.random(in: 80...100)
            startActivity(.sleep)
        }

        // 心情按每分钟 -1 衰减（与 30 秒的 decay 心跳解耦，避免扣太快）。
        if lastHappinessDecayTick == 0 { lastHappinessDecayTick = tick }
        if tick - lastHappinessDecayTick >= 60 {
            lastHappinessDecayTick = tick
            state.updateHappiness(-1)
        }

        // 拟真电池：精力 > 80 时，越满越容易突然睡着。
        if state.energy > 80,
           state.currentActivity == .idle,
           petScene.petNode.currentAnimation == "IDLE" {
            let ratio = Double(state.energy - 80) / 20.0
            let probability = pow(ratio, 2)
            if Double.random(in: 0..<1) < probability {
                NSLog("😴 forced sleep: energy=\(state.energy) p=\(String(format: "%.2f", probability))")
                startActivity(.sleep)
            }
        }

        applySocialDecay(to: state)
        state.saveState()
    }

    /// 长期不交互掉心情：每小时最多结算一次。
    /// - 超过 1 小时没互动：扣 1；
    /// - 未满 1 小时，但饥饿 > 70 或心情 < 30：也扣 1。
    private func applySocialDecay(to state: PetState) {
        let now = Date()
        guard now.timeIntervalSince(lastSocialDecayAt) >= 3600 else { return }
        lastSocialDecayAt = now

        let idle = now.timeIntervalSince(state.lastInteraction)
        guard idle > 3600 || state.hunger > 70 || state.happiness < 30 else { return }

        state.updateHappiness(-1)
        NSLog("💔 social decay: idle=\(Int(idle))s hunger=\(state.hunger) happiness=\(state.happiness)")
    }

    private func handleWallBounce() {
        let now = Date()
        guard now.timeIntervalSince(lastWallPenaltyAt) >= 0.8 else { return }
        lastWallPenaltyAt = now

        let gameplay = ConfigManager.shared.config.gameplay
        let happinessPenalty = max(1, Int((Double(gameplay.wallHappinessPenalty) * gameplay.happinessMultiplier).rounded()))
        let energyPenalty = max(1, Int((Double(gameplay.wallEnergyPenalty) * gameplay.energyMultiplier).rounded()))

        PetState.shared.updateHappiness(-happinessPenalty)
        PetState.shared.updateEnergy(-energyPenalty)
        NSLog("💥 wall penalty: happiness-\(happinessPenalty) energy-\(energyPenalty) difficulty=\(gameplay.difficulty.rawValue)")
    }
    
    // MARK: - Behavior Decision（加权随机）
    
    private func decideActivity() {
        // 睡眠期间任何后台行为决策都必须让路，否则会把 .sleep 覆盖成 idle/walk。
        guard !PetState.shared.isSleeping else { return }
        guard !isBusy else { return }
        guard petScene.petNode.currentAnimation == "IDLE" else { return }
        
        let state = PetState.shared
        let behavior = ConfigManager.shared.config.pet.behavior

        // 自主跳跃是独立 ActivityType；不占用走路分支，跳完由下一次决策重新选行为。
        if behavior.allowJump && Double.random(in: 0..<1) < behavior.jumpProbability {
            NSLog("🦘 decide activity → jump (p=\(behavior.jumpProbability))")
            startActivity(.jump)
            return
        }

        // 无聊值超过阈值 → 强制出门散步（不平移窗口就永远看不到 WALKING）
        if state.boredom > 40 && state.energy > 20 {
            NSLog("🚶 boredom=\(Int(state.boredom)) > 40 → startActivity(.walk)")
            startActivity(.walk)
            return
        }
        
        var candidates: [(PetActivity, Double)] = []
        
        if state.energy < 20 && !state.isSleeping {
            let low = max(0, 20 - state.energy)
            let drowsy = pow(Double(low) / 20.0, 2) * 100
            candidates.append((.sleep, Double(100 - state.energy) + drowsy))
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

        case .jump:
            if windowController.state == .resting {
                petScene.playAnimation("FALLING")
                windowController.launchSelfJump()
                activityEndTick = tick + 8
            } else {
                state.currentActivity = .idle
                petScene.playAnimation("IDLE")
            }

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
            if tick % 60 == 0 { state.updateHappiness(1) }
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
            // 昏厥：必须睡到 80~100 精力，期间不能被普通睡眠计时叫醒。
            if state.energy <= 0 {
                // 彻底锁死 activityEndTick 倒计时；只有 wakeTargetEnergy 达标才走 wakeUp()。
                activityEndTick = Int.max
            }
            if state.energy <= 0 && wakeTargetEnergy == 0 {
                wakeTargetEnergy = Int.random(in: 80...100)
                NSLog("😵 fainted sleep target=\(wakeTargetEnergy)")
            }

            // 落地/拖拽回调可能把睡眠动画覆盖成 IDLE；只要仍在睡，就补回 SLEEPING，
            // 避免出现 isSleeping=true 但立绘卡在 IDLE 的假醒状态。
            if petScene.petNode.currentAnimation == "IDLE" {
                petScene.playAnimation("SLEEPING")
            }

            // 拟真电池：每 60 个 tick（1 分钟）才恢复 1% 精力。
            if tick % 60 == 0 {
                state.updateEnergy(1)
            }

            if wakeTargetEnergy > 0 {
                if state.energy >= wakeTargetEnergy {
                    NSLog("😴 fainted sleep complete energy=\(state.energy)")
                    wakeTargetEnergy = 0
                    wakeUp()
                } else {
                    activityEndTick = max(activityEndTick, tick + 60)
                    if tick % 60 == 0 {
                        NSLog("😴 fainted sleep continue energy=\(state.energy)/\(wakeTargetEnergy)")
                    }
                }
            } else if state.energy < 20 {
                // 低电量：用 pow(energy/20, 2) 作为每分钟醒来的概率；
                // 没醒就强制延长 1 分钟，避免刚睡着就被低电量叫醒。
                if tick % 60 == 0 {
                    let ratio = Double(state.energy) / 20.0
                    let wakeProbability = pow(ratio, 2)
                    if Double.random(in: 0..<1) < wakeProbability {
                        NSLog("🔋 wake: low energy=\(state.energy) p=\(String(format: "%.2f", wakeProbability))")
                        wakeUp()
                    } else {
                        activityEndTick = max(activityEndTick, tick + 60)
                        NSLog("😴 sleep extended: energy=\(state.energy) p=\(String(format: "%.2f", wakeProbability))")
                    }
                }
            } else if tick >= activityEndTick {
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
    
    /// 设置页「重置宠物状态」唯一入口：重置状态、清掉强睡目标、强制回 IDLE。
    func resetPetState() {
        wakeTargetEnergy = 0
        stopWalkStep()
        PetState.shared.resetState()
        petScene.playAnimation("IDLE")
        NSLog("🔄 pet state reset")
    }

    private func wakeUp() {
        wakeTargetEnergy = 0
        guard PetState.shared.isSleeping else { return }
        PetState.shared.isSleeping = false
        PetState.shared.currentActivity = .idle
        petScene.playAnimationOnce("sleep_wake") { [weak self] in
            self?.petScene.playAnimation("IDLE")
        }
    }
    
    private func interruptActivity() {
        stopWalkStep()
        wakeTargetEnergy = 0
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
    
    @discardableResult
    private func triggerAutoSpeech() -> Bool {
        let config = ConfigManager.shared.config.autoSpeech
        let anim = petScene.petNode.currentAnimation
        let busy = isBusy

        let busyReason: String
        if PetState.shared.isDragging {
            busyReason = "dragging"
        } else if windowController.state != .resting {
            busyReason = "airborne"
        } else if PetState.shared.isSleeping {
            busyReason = "sleeping"
        } else if TTSServiceManager.shared.isSpeaking {
            busyReason = "tts-speaking"
        } else {
            busyReason = "unknown"
        }

        guard config.enabled else {
            nextSpeechAt = .distantFuture
            print("🔇 autoSpeech skip: enabled=false busy=\(busy) anim=\(anim) reason=disabled")
            return false
        }

        // 被忙碌状态挡住时不要直接放弃：5 秒后再试，避免错过整段 3~10 分钟窗口。
        guard !busy else {
            nextSpeechAt = Date().addingTimeInterval(5)
            print("🔇 autoSpeech skip: enabled=true busy=true anim=\(anim) reason=\(busyReason) → retry in 5s")
            return false
        }

        // 允许覆盖眨眼/瞥一眼/发呆这类低优先级微动作，避免自动说话总被微动作挡掉
        let canSpeak = anim == "IDLE" || anim == "BLINK" || anim == "GLANCE" || anim == "THINKING"
        guard canSpeak else {
            nextSpeechAt = Date().addingTimeInterval(5)
            print("🔇 autoSpeech skip: enabled=true busy=false anim=\(anim) reason=animation → retry in 5s")
            return false
        }

        guard let line = dialogueManager.speakForContext() else {
            nextSpeechAt = Date().addingTimeInterval(5)
            print("🔇 autoSpeech skip: enabled=true busy=false anim=\(anim) reason=no-dialogue → retry in 5s")
            return false
        }

        print("🔊 autoSpeech trigger: enabled=true busy=false anim=\(anim)")
        speak(line)
        return true
    }
    
    // MARK: - Offline Compensation

    private static let lastOnlineKey = "debuSeek.lastOnlineTimestamp"

    func saveLastOnlineTimestamp() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastOnlineKey)
    }

    /// 离线 Stopwatch：最多补偿 12 小时。
    /// 睡眠速率补精力（1/min），正常速率扣心情（1/hour），并增加饥饿值（2/hour）。
    func handleOfflineCompensation() {
        let now = Date()
        let nowTS = now.timeIntervalSince1970
        let lastTS = UserDefaults.standard.double(forKey: Self.lastOnlineKey)
        guard lastTS > 0 else {
            saveLastOnlineTimestamp()
            return
        }

        let offline = min(max(0, nowTS - lastTS), 12 * 3600)
        saveLastOnlineTimestamp()
        guard offline >= 60 else { return }

        let state = PetState.shared
        let minutes = Int(offline / 60)
        let hours = offline / 3600

        let energyGain = min(max(0, 100 - state.energy), minutes)
        let moodLoss = min(max(0, state.happiness), Int(hours))
        let hungerGain = min(max(0, 100 - state.hunger), Int(hours * 2))

        if energyGain > 0 { state.updateEnergy(energyGain) }
        if moodLoss > 0 { state.updateHappiness(-moodLoss) }
        if hungerGain > 0 { state.updateHunger(hungerGain) }
        state.saveState()

        NSLog("⏱️ offline compensation: \(Int(offline/60))min energy+\(energyGain) mood-\(moodLoss) hunger+\(hungerGain)")
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
        var isIntervalReport = false
        if config.announceOnHour && minute == 0 && hour != lastTimeReportHour {
            shouldReport = true
        } else if config.announceOnHalfHour && minute == 30 {
            shouldReport = true
        } else if config.intervalMinutes > 0 && minute % config.intervalMinutes == 0 {
            // 间隔报时单独用 Date 去重，避免同一分钟附近连续两分钟都报。
            let interval = TimeInterval(config.intervalMinutes * 60)
            if now.timeIntervalSince(lastIntervalReportTime) >= interval - 5 {
                shouldReport = true
                isIntervalReport = true
            }
        }
        
        guard shouldReport else { return }
        // 不要打断互动/拖拽/说话中的动画
        guard petScene.petNode.currentAnimation == "IDLE" else { return }
        
        lastTimeReportHour = hour
        lastTimeReportAt = now
        if isIntervalReport { lastIntervalReportTime = now }
        
        let formatter = DateFormatter()
        formatter.dateFormat = config.format
        let timeString = formatter.string(from: now)
        
        let phrase = config.phrases.randomElement() ?? "现在是{time}啦~"
        speak(phrase.replacingOccurrences(of: "{time}", with: timeString))
    }
    
    // MARK: - Interaction Handlers

    /// 心情前置消耗：先确认付得起精力/饥饿成本，再一次性扣费并加心情。
    /// 返回 false 表示精力不够或再吃就要撑爆了，调用方仍可继续播动画。
    @discardableResult
    private func tryGainHappiness(amount: Int, energyCost: Int, hungerCost: Int) -> Bool {
        let state = PetState.shared
        guard state.energy >= energyCost,
              state.hunger + hungerCost <= 100 else {
            NSLog("💔 gain happiness failed: energy=\(state.energy)/\(energyCost) hunger=\(state.hunger)/\(hungerCost)")
            return false
        }
        if energyCost > 0 { state.updateEnergy(-energyCost) }
        if hungerCost > 0 { state.updateHunger(hungerCost) }
        if amount != 0 { state.updateHappiness(amount) }
        return true
    }
    
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
                if tryGainHappiness(amount: 1, energyCost: 1, hungerCost: 1) {
                    petScene.showToast("心情 +1")
                }
                playInteraction(
                    "POKE_REACT",
                    line: interactionLine(zone: zone, type: .click, fallback: "嗯？"),
                    aiPrompt: interactionAIPrompt(zone: zone, type: .click)
                )
            }
            
        case .face, .head:
            state.affection = min(100, state.affection + 2)
            if tryGainHappiness(amount: 2, energyCost: 1, hungerCost: 1) {
                petScene.showToast("心情 +2")
            }
            playInteraction(
                "HAPPY",
                line: interactionLine(zone: zone, type: .click, fallback: "嘿嘿~"),
                aiPrompt: interactionAIPrompt(zone: zone, type: .click)
            )
            
        case .tail:
            state.affection = min(100, state.affection + 1)
            if tryGainHappiness(amount: 1, energyCost: 1, hungerCost: 1) {
                petScene.showToast("心情 +1")
            }
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
        if tryGainHappiness(amount: 5, energyCost: 2, hungerCost: 1) {
            petScene.showToast("心情 +5")
        }
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

    // MARK: - AI Interaction Throttle

    /// 上一次成功发出 AI 请求的时间（冷却计时起点）。
    private var lastAPIRequestTime: Date = .distantPast
    /// 同一时间只允许一个 AI 互动请求在途，避免高频点击堆叠请求。
    private var isAIRequestInFlight = false
    
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
        let config = ConfigManager.shared.config.interaction

        // 空中（抛掷/下落/反弹）时跳过请求，避免落地瞬间连续刷 API。
        if config.skipAIWhileAirborne, windowController?.state == .airborne {
            NSLog("⏭️ AI interaction skipped: airborne → local fallback")
            speak(fallbackLine)
            return
        }

        // 冷却期内不重复请求；用本地台词保证互动仍有反馈。
        if Date().timeIntervalSince(lastAPIRequestTime) < config.apiRequestCooldown {
            NSLog("⏭️ AI interaction skipped: cooldown \(config.apiRequestCooldown)s → local fallback")
            speak(fallbackLine)
            return
        }

        // 上一次请求还没返回时也不再发第二个，防止高频点击把请求堆起来。
        guard !isAIRequestInFlight else {
            NSLog("⏭️ AI interaction skipped: request already in flight → local fallback")
            speak(fallbackLine)
            return
        }

        isAIRequestInFlight = true
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.isAIRequestInFlight = false }
            do {
                let reply = try await ChatServiceManager.shared.sendMessage(prompt)
                // 请求成功发出（拿到回复）后开始计冷却。
                self.lastAPIRequestTime = Date()
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // 模型返回空文本时退回本地固定台词，不应写进 TTS 缓存
                    self.speak(fallbackLine)
                } else {
                    self.speak(trimmed, isDynamic: true)
                }
            } catch {
                NSLog("⚠️ AI interaction reply failed: \(error.localizedDescription) → fallback")
                self.speak(fallbackLine)
            }
        }
    }
    
    // MARK: - Public Actions
    
    /// 所有发声的唯一出口：气泡 + TALKING 循环 + TTS，结束/报错后回 IDLE
    func speak(_ text: String, isDynamic: Bool = false) {
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
                await TTSServiceManager.shared.speak(spokenText, isDynamic: isDynamic)
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
        if PetState.shared.isFainted {
            ChatHistoryManager.shared.addMessage(
                ChatMessage(role: .systemNote, content: "【系统】大肥鱼精力耗尽昏睡中，无法聊天")
            )
            showSpeech("太累了，说不出话…")
            return
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        ChatHistoryManager.shared.addMessage(ChatMessage(role: .user, content: message))
        
        Task {
            do {
                let response = try await ChatServiceManager.shared.sendMessage(message)
                ChatHistoryManager.shared.addMessage(ChatMessage(role: .assistant, content: response))
                presentChatReply(response, isDynamic: true)
                self.maybeAutoSummarizeHistory()
            } catch {
                presentChatReply("呜...网络好像出问题了 (＞﹏＜)", isDynamic: false)
            }
        }
    }
    
    /// 聊天回复统一出口：默认只显示气泡，不播 TALKING、不调用 TTS。
    /// 只有设置里显式打开 chat.readChatAloud，才走 speak()（气泡 + TALKING + 语音）。
    /// 点击/长按等宠物互动仍然走 playInteraction → speak，不受这个开关影响。
    private func presentChatReply(_ text: String, isDynamic: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if ConfigManager.shared.config.chat.readChatAloud {
            speak(trimmed, isDynamic: isDynamic)
        } else {
            showSpeech(trimmed)
        }
    }
    
    // MARK: - Memory Summarization

    /// 手动/自动压缩历史。请求走 ChatService 的摘要专用通道，不带大肥鱼人设、
    /// 不注入旧回忆录或 Token 提示；成功后不删历史，只追加一条仅 UI 可见的 systemNote。
    func summarizeAndClearHistory() {
        let chat = ConfigManager.shared.config.chat
        guard chat.enableMemorySummarization else {
            NSLog("🧠 memory summarize skipped: enableMemorySummarization=false")
            return
        }
        guard !isSummarizing else {
            NSLog("🧠 memory summarize skipped: already summarizing")
            return
        }
        guard !ChatServiceManager.shared.isProcessing else {
            NSLog("🧠 memory summarize skipped: chat request in flight")
            return
        }

        // 只压缩上次 systemNote 之后的新对话；没有新对话则不重复压缩。
        let pending = ChatHistoryManager.shared.messagesSinceLastSummary()
        guard !pending.isEmpty else {
            NSLog("🧠 memory summarize skipped: no unsummarized messages")
            return
        }

        let transcript = pending.map { message -> String in
            let role = message.role == .user ? "用户" : "宠物"
            return "\(role)：\(message.content)"
        }.joined(separator: "\n")

        let existingMemory = chat.memorySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = ""
        if !existingMemory.isEmpty {
            content += "【已有回忆录】\n\(existingMemory)\n\n"
        }
        content += "【新的聊天记录】\n\(transcript)"

        // 用户自定义摘要 Prompt：支持 {transcript} 占位符；留空则用内置提示词。
        let customPrompt = chat.customSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarySystemPrompt: String
        let summaryTranscript: String
        if customPrompt.isEmpty {
            summarySystemPrompt = summarizationSystemPrompt
            summaryTranscript = content
        } else if customPrompt.contains("{transcript}") {
            summarySystemPrompt = "你是对话记忆压缩器。请严格按用户提供的模板输出摘要，不要添加解释或 Markdown。"
            summaryTranscript = customPrompt.replacingOccurrences(of: "{transcript}", with: content)
        } else {
            summarySystemPrompt = customPrompt
            summaryTranscript = content
        }

        isSummarizing = true
        NSLog("🧠 memory summarize start: \(pending.count) messages, customPrompt=\(!customPrompt.isEmpty)")

        Task { [weak self] in
            guard let self = self else { return }
            defer { self.isSummarizing = false }

            do {
                let summary = try await ChatServiceManager.shared.sendSummarizationRequest(
                    systemPrompt: summarySystemPrompt,
                    transcript: summaryTranscript
                )
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    NSLog("⚠️ memory summarize returned empty; history kept")
                    return
                }

                ConfigManager.shared.updateChatConfig { $0.memorySummary = trimmed }

                let timeFormatter = DateFormatter()
                timeFormatter.locale = Locale(identifier: "en_US_POSIX")
                timeFormatter.dateFormat = "HH:mm"
                let note = "【上下文已压缩】 \(timeFormatter.string(from: Date()))"
                ChatHistoryManager.shared.addMessage(ChatMessage(role: .systemNote, content: note))

                NSLog("🧠 memory summarize done: \(trimmed.count) chars, appended systemNote")
            } catch {
                NSLog("⚠️ memory summarize failed: \(error); history kept")
            }
        }
    }

    /// 聊天回复落库后检查是否达到自动压缩阈值；静默后台执行，不阻塞气泡。
    private func maybeAutoSummarizeHistory() {
        let chat = ConfigManager.shared.config.chat
        guard chat.enableMemorySummarization, chat.enableAutoSummarize else { return }
        guard !isSummarizing else { return }

        let threshold = max(2, chat.autoSummarizeRounds * 2)
        guard ChatHistoryManager.shared.messagesSinceLastSummary().count >= threshold else { return }
        summarizeAndClearHistory()
    }

    func feedPetWithItem(_ item: FeedItemConfig) {
        let price = max(0, item.price)
        guard UsageManager.shared.availableCurrency >= price else {
            speak("钱不够买\(item.name)呀～")
            return
        }
        guard UsageManager.shared.spend(price) else {
            speak("钱不够买\(item.name)呀～")
            return
        }

        PetState.shared.updateLastInteraction()
        PetState.shared.updateHappiness(item.happiness)
        PetState.shared.updateHunger(-item.satiety)
        if item.energy != 0 {
            PetState.shared.updateEnergy(item.energy)
        }
        interruptActivity()
        let energyText = item.energy == 0 ? "" : "  精力 \(item.energy > 0 ? "+" : "")\(item.energy)"
        petScene.showToast("饱腹度 +\(item.satiety)\(energyText)")
        playInteraction("EATING", line: item.lines.randomElement() ?? "好吃！")
        NSLog("🍤 feed \(item.name) price=\(price) remaining=\(UsageManager.shared.availableCurrency)")
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

    // MARK: - Right-click Menu Actions

    /// 睡觉 / 唤醒（菜单标题会随 isSleeping 动态变化）。
    @objc private func toggleSleep() {
        if PetState.shared.isSleeping {
            wakeUp()
            return
        }
        guard windowController.state == .resting else { return }
        interruptActivity()
        startActivity(.sleep)
    }

    /// 独立投喂菜单（子菜单和「投喂...」入口共用同一份构建逻辑）。
    @objc private func showFeedMenu() {
        makeFeedMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func makeFeedMenu() -> NSMenu {
        let menu = NSMenu()
        let items = ConfigManager.shared.config.interaction.feed.items
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "暂无食物", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for food in items {
            let priceText = food.price > 0 ? " · \(food.price)" : ""
            let item = NSMenuItem(
                title: "\(food.emoji) \(food.name)\(priceText)",
                action: #selector(feedPet(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = food
            menu.addItem(item)
        }
        return menu
    }

    /// 查看状态：NSWindow + NSHostingController 承载 StatusView。
    @objc private func showStatusPanel() {
        if let existing = statusWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "大肥鱼状态"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = StatusView(onClose: { [weak self] in
            self?.statusWindow?.orderOut(nil)
        })
        .environmentObject(PetState.shared)
        window.contentViewController = NSHostingController(rootView: root)
        window.center()

        statusWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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

        // 快捷键从配置解析，而不是写死 ⌘, / ⌘C。
        let settings = Self.menuShortcut(
            from: ConfigManager.shared.config.hotkeySettings ?? "option+s",
            fallbackKey: "s"
        )
        let chat = Self.menuShortcut(
            from: ConfigManager.shared.config.hotkeyChat ?? "option+c",
            fallbackKey: "c"
        )

        menu.addItem(menuItem(
            "设置 (Settings)...",
            action: #selector(openSettingsWindow),
            key: settings.key,
            modifiers: settings.modifiers
        ))
        menu.addItem(menuItem(
            "聊天 (Chat)...",
            action: #selector(showChat),
            key: chat.key,
            modifiers: chat.modifiers
        ))
        menu.addItem(NSMenuItem.separator())

        let sleepTitle = PetState.shared.isSleeping ? "唤醒" : "睡觉"
        menu.addItem(menuItem(sleepTitle, action: #selector(toggleSleep)))

        // 投喂子菜单：点击「投喂...」直接展开，不必再点一次。
        let feedRoot = NSMenuItem(title: "投喂...", action: nil, keyEquivalent: "")
        feedRoot.submenu = makeFeedMenu()
        menu.addItem(feedRoot)

        menu.addItem(menuItem("查看状态", action: #selector(showStatusPanel)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("退出 (Quit)", action: #selector(quitApp), key: "q"))

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 菜单项统一显式指定 target（accessory app 的 nil target 可能找不到响应者）
    private func menuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// 把 "option+s" / "cmd+," 解析成 NSMenuItem 可用的单字符 + 修饰键。
    private static func menuShortcut(
        from descriptor: String,
        fallbackKey: String
    ) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        let parts = descriptor
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let last = parts.last, last.count == 1 else {
            return (fallbackKey, [.option])
        }

        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "option", "alt": flags.insert(.option)
            case "command", "cmd": flags.insert(.command)
            case "control", "ctrl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        // 没写修饰键时，菜单默认按 ⌘ 处理，避免裸字母抢系统输入。
        if flags.isEmpty { flags = [.command] }
        return (String(last), flags)
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
