import AppKit
import CoreVideo
import QuartzCore
import SpriteKit

// MARK: - 物理状态机

/// 窗口的三种运动状态：静止 → 拖拽 → 空中 → 静止。
///
/// 物理完全由纯数学积分实现（直接计算 `window.frame.origin`），
/// 不使用 SpriteKit 物理引擎（SKPhysicsBody），也不使用 Timer 逐帧驱动。
enum PetMotionState: String, CustomStringConvertible {
    case resting
    case dragging
    case airborne

    var description: String { rawValue }
}

// MARK: - 自定义窗口

/// 透明无边框窗口。
///
/// 拖拽在这里统一接管（mouseDown/mouseDragged/mouseUp → PetWindowController），
/// 不用 `performDrag`、也不开 `isMovableByWindowBackground`，避免系统拖拽与自研物理双写 frame。
/// 事件仍通过 `super` 继续派发给视图，保证点击/双击/长按手势识别器正常工作。
final class PetWindow: NSWindow {
    /// 由 PetWindowController 在窗口搭建时挂上（weak，避免循环引用）
    weak var dragController: PetWindowController?

    /// 起拖阈值（pt）：小于此位移视为点击，不进入窗口拖拽
    private static let dragThreshold: CGFloat = 3

    private var mouseDownScreenPoint: CGPoint?
    private var mouseDownTimestamp: TimeInterval = 0
    private var isDraggingWindow = false
    /// 按下点是否命中鱼身像素（透明像素不启动窗口拖拽，也不派发点击）
    private var pressHitZone: HitZone = .none

    /// 窗口级长按计时（SKView 的 NSPressGestureRecognizer 在非 key 窗口不可靠，改由窗口统一判定）
    private var longPressWorkItem: DispatchWorkItem?
    private var isLeftMouseDown = false
    private var longPressFired = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 彻底解除系统对窗口的屏幕边界限制。
    /// 窗口上半部分是给气泡预留的透明区域；不解除的话，窗口顶部会先撞到菜单栏，
    /// 宠物实际能到达的最高点会被 320 的窗口高度压低。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    /// 关键：NSWindow 的内容区鼠标事件走 sendEvent，不会进 NSWindow.mouseDown。
    /// 所以在 sendEvent 里截获拖拽（AppKit 头文件也明确建议这种窗口级拖拽实现方式），
    /// 再调用 super 保留视图手势（点击/双击/长按）。
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let point = convertPoint(toScreen: event.locationInWindow)
            mouseDownScreenPoint = point
            mouseDownTimestamp = event.timestamp
            isDraggingWindow = false
            isLeftMouseDown = true
            longPressFired = false
            pressHitZone = hitZone(atScreenPoint: point)
            scheduleLongPress()
            NSLog("🖱 leftMouseDown @ \(point) zone=\(pressHitZone)")

        case .leftMouseDragged:
            handleLeftMouseDragged(event)

        case .leftMouseUp:
            handleLeftMouseUp(event)

        case .rightMouseDown:
            let point = convertPoint(toScreen: event.locationInWindow)
            let zone = hitZone(atScreenPoint: point)
            if zone != .none {
                dragController?.petScene.performRightClick(zone: zone)
            }

        default:
            break
        }

        super.sendEvent(event)
    }

    private func handleLeftMouseDragged(_ event: NSEvent) {
        let currentPoint = convertPoint(toScreen: event.locationInWindow)

        // 兜底：应用处于非激活态时，系统可能吃掉第一次 mouseDown（点击只用于激活 App）。
        // 此时用首个 dragged 事件的位置作为基准，保证拖拽仍能起来。
        if mouseDownScreenPoint == nil {
            mouseDownScreenPoint = currentPoint
        }
        guard let downPoint = mouseDownScreenPoint, let controller = dragController else { return }
        // 只有按在鱼身像素上才允许拖拽窗口
        guard pressHitZone != .none else { return }

        if !isDraggingWindow {
            let dx = currentPoint.x - downPoint.x
            let dy = currentPoint.y - downPoint.y
            guard (dx * dx + dy * dy).squareRoot() > Self.dragThreshold else { return }
            isDraggingWindow = true
            cancelLongPress()
            isLeftMouseDown = false
            controller.startDrag(at: downPoint)
            NSLog("🖱 Mouse Dragged → drag start @ \(downPoint)")
        }

        controller.dragTo(currentPoint)
    }

    private func handleLeftMouseUp(_ event: NSEvent) {
        let wasDragging = isDraggingWindow
        let didLongPress = longPressFired
        mouseDownScreenPoint = nil
        isDraggingWindow = false
        isLeftMouseDown = false
        longPressFired = false
        cancelLongPress()

        if didLongPress {
            // 长按已经触发过 HEAD_PAT，松开时不再当作点击
            return
        }

        if wasDragging {
            // 拖拽结束后抑制这一拍点击
            dragController?.petScene.suppressClicks()
            let velocity = dragController?.endDrag() ?? .zero
            NSLog("🖱 Mouse Up → drag end v=(\(Int(velocity.dx)), \(Int(velocity.dy)))")
            return
        }

        // 单击 / 双击：窗口级派发。
        // SKView 上的 NSClickGestureRecognizer 在 borderless / 非 key 窗口场景下不可靠，
        // 而窗口级 sendEvent 一定能收到事件，所以点击判定放在这里。
        guard let controller = dragController else { return }
        guard pressHitZone != .none else { return }
        guard !controller.petScene.isClickSuppressed else { return }

        let pressDuration = event.timestamp - mouseDownTimestamp
        let longPressDuration = ConfigManager.shared.config.interaction.longPress.duration
        guard pressDuration > 0, pressDuration < longPressDuration else { return }

        let zone = hitZone(atScreenPoint: convertPoint(toScreen: event.locationInWindow))
        guard zone != .none else { return }

        if event.clickCount >= 2 {
            controller.petScene.performDoubleClick(zone: zone)
        } else {
            controller.petScene.performClick(zone: zone)
        }
        NSLog("🖱 click zone=\(zone) count=\(event.clickCount)")
    }

    /// 窗口切换到穿透/隐藏时，清掉可能残留的拖拽跟踪状态
    func cancelMouseTracking() {
        mouseDownScreenPoint = nil
        isDraggingWindow = false
        pressHitZone = .none
        isLeftMouseDown = false
        longPressFired = false
        cancelLongPress()
    }

    // MARK: - 窗口级长按

    private func scheduleLongPress() {
        longPressWorkItem?.cancel()
        guard pressHitZone != .none, dragController != nil else { return }

        let duration = ConfigManager.shared.config.interaction.longPress.duration
        let item = DispatchWorkItem { [weak self] in
            self?.fireLongPress()
        }
        longPressWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func fireLongPress() {
        guard isLeftMouseDown, !isDraggingWindow, pressHitZone != .none else { return }
        guard let controller = dragController, controller.state == .resting else { return }

        longPressFired = true
        controller.petScene.suppressClicks(for: 0.6)
        controller.petScene.performLongPress(zone: pressHitZone)
        NSLog("🖱 long press zone=\(pressHitZone)")
    }

    /// 屏幕坐标处的像素命中分区（复用 PetScene 的 alpha 掩码判定）
    private func hitZone(atScreenPoint screenPoint: CGPoint) -> HitZone {
        guard let controller = dragController,
              let window = controller.window,
              let contentView = window.contentView else { return .none }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        let scenePoint = controller.petScene.convertPoint(fromView: viewPoint)
        return controller.petScene.hitTest(scenePoint: scenePoint)
    }
}

// MARK: - Pet Window Controller

/// 唯一窗口控制器：窗口搭建 + 纯数学物理引擎（拖拽/抛掷/重力/反弹）。
///
/// 帧驱动只用 `CVDisplayLink`，且仅在「空中飞行」期间运行；落地静止立刻 `stopDisplayLink()`，
/// 静止时零帧开销。拖拽期间由 `PetWindow` 的鼠标事件直接写 `frame.origin`，不启动 displayLink。
final class PetWindowController: NSWindowController {

    // MARK: - 窗口画布
    //
    // 240 宽：容纳 220 宽气泡 + 左右安全边距；
    // 320 高：宠物仍固定在距底边 105pt，上方留出气泡空间，内容更高时再向上动态增高。
    static let baseSize = CGSize(width: 240, height: 320)

    // MARK: - 物理参数（纯数学，无 SpriteKit 物理体）

    enum Physics {
        /// 重力加速度：980 pt/s²，方向向下（AppKit 屏幕坐标 -y）
        static let gravity: CGFloat = 980
        /// 地面反弹恢复系数
        static let floorRestitution: CGFloat = 0.45
        /// 左右边缘反弹恢复系数
        static let wallRestitution: CGFloat = 0.65
        /// 低于此速度且贴地 → 静止
        static let settleSpeed: CGFloat = 60
        /// 低于此速度松手 → 不抛掷，直接静止
        static let throwSpeedMin: CGFloat = 30
        /// 落地冲击速度 ≥ 此值视为重落地（回调方播 DIZZY，否则 LANDING）
        static let heavyLandingSpeed: CGFloat = 120
        /// 静止时窗口底边离可见屏幕底部的距离（留出 dock 间隙）
        static let restHeight: CGFloat = 40
        /// 单帧最大积分步长，防跳帧穿墙
        static let maxTimeStep: CFTimeInterval = 1.0 / 30.0
        /// 撞墙/撞顶的防抖阈值：法向速度过小不重复触发 onWallBounce
        static let wallBounceMinSpeed: CGFloat = 1
        /// 速度采样队列长度（只保留最近 5 个采样）
        static let maxSamples = 5
        /// 首尾采样时间跨度低于此值（1ms）→ 速度按 0 处理
        static let minSampleSpan: CFTimeInterval = 0.001
    }

    // MARK: - 回调协议（留给后续阶段接线）

    /// 拖拽开始。后续接线：播放 DRAGGING；若睡着先唤醒。
    var onDragStart: (() -> Void)?
    /// 拖拽结束，携带松手速度（pt/s，AppKit 坐标）。后续接线：速度分档 FALLING / AIRBORNE。
    var onDragEnd: ((CGVector) -> Void)?
    /// 落地，携带冲击速度（pt/s）。后续接线：>= 120 播 DIZZY，否则 LANDING。
    var onLanding: ((CGFloat) -> Void)?
    /// 撞到左右屏幕边缘或顶部天花板。后续接线：播 POKE_REACT 一次。
    var onWallBounce: (() -> Void)?

    // MARK: - 状态

    private(set) var state: PetMotionState = .resting
    private(set) var velocity: CGVector = .zero

    /// 保留给像素命中测试（第二阶段）使用
    private(set) var petScene: PetScene

    /// CVDisplayLink 帧驱动（仅空中飞行期间非 nil）
    private var displayLink: CVDisplayLink?
    private var lastTickTime: CFTimeInterval = 0

    /// 拖拽抓取点相对窗口原点的偏移
    private var grabOffset: CGPoint = .zero

    /// 最近若干次拖拽采样：(时间戳, 窗口原点)
    private var samples: [(time: CFTimeInterval, origin: CGPoint)] = []

    /// 像素级穿透监听（本地：窗口可交互期间；全局：窗口穿透期间）
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    // MARK: - Init

    init(petScene: PetScene, config: WindowConfig) {
        self.petScene = petScene

        let window = PetWindow(
            contentRect: NSRect(origin: .zero, size: Self.baseSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        let contentRect = window.contentView?.bounds ?? NSRect(origin: .zero, size: Self.baseSize)
        let skView = SKView(frame: contentRect)
        skView.allowsTransparency = true
        skView.ignoresSiblingOrder = true
        window.contentView = skView
        skView.presentScene(petScene)

        setupWindow(config: config)
        setupMouseMonitors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil

        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    // MARK: - Window Setup

    private func setupWindow(config: WindowConfig) {
        guard let window = window else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = config.ignoresMouseEvents
        window.level = windowLevel(from: config.level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // 与自研拖拽冲突的系统行为，一律关闭
        window.isMovableByWindowBackground = false

        window.styleMask = [.borderless]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil

        // 鼠标事件入口：窗口 → 控制器（拖拽）
        (window as? PetWindow)?.dragController = self
        // 需要持续收到 mouseMoved 才能做像素级穿透判定
        window.acceptsMouseMovedEvents = true

        if config.alwaysOnTop {
            window.level = .floating
        }
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

    // MARK: - 兼容旧接口（PetController 调用保持不变）

    func setPosition(_ point: CGPoint) {
        // 取整，杜绝亚像素抖动
        window?.setFrameOrigin(CGPoint(x: point.x.rounded(), y: point.y.rounded()))
    }

    func getPosition() -> CGPoint {
        window?.frame.origin ?? .zero
    }

    func setSize(_ size: CGSize) {
        window?.setContentSize(size)
    }

    func getSize() -> CGSize {
        window?.frame.size ?? Self.baseSize
    }

    // MARK: - 气泡增高（只动窗口高度，不碰物理/穿透的 origin 与宽度）

    /// 请求窗口达到指定高度（底边固定，只向上长）。
    /// 返回实际可用高度：屏幕顶部空间不足时会被截断，由气泡缩字号适配。
    @discardableResult
    func requestSpeechHeight(_ desiredHeight: CGFloat) -> CGFloat {
        guard let window = window else { return max(Self.baseSize.height, desiredHeight) }

        let frame = window.frame
        let screenTop = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? frame.maxY
        let maxHeight = max(Self.baseSize.height, screenTop - frame.minY)
        let target = min(max(Self.baseSize.height, ceil(desiredHeight)), maxHeight)

        guard abs(target - frame.height) > 0.5 else { return frame.height }

        var newFrame = frame
        newFrame.size.height = target
        // setFrame 的 origin 是左下角：保持 minY 不变，窗口向上增高
        window.setFrame(newFrame, display: true)
        return target
    }

    /// 气泡消失后收回基础高度；底边不动，宠物在屏幕上的位置完全不变。
    func resetSpeechHeight() {
        guard let window = window else { return }
        var frame = window.frame
        guard abs(frame.height - Self.baseSize.height) > 0.5 else { return }
        frame.size.height = Self.baseSize.height
        window.setFrame(frame, display: true)
    }

    func show() {
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - 动态点击穿透（像素级）

    /// 本地监听：窗口可交互时收到事件（含 mouseMoved / 按下瞬间）
    /// 全局监听：窗口穿透后自身收不到事件，靠“其它 App 的事件”恢复交互
    private func setupMouseMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            // 按下瞬间强制校正一次：防止光标停在透明区没移动就点击
            let isPress = event.type == .leftMouseDown || event.type == .rightMouseDown
            self.updatePassThrough(forceAtPress: isPress)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updatePassThrough(forceAtPress: false)
        }
    }

    /// 按光标下方的像素 alpha 决定整窗是否穿透。
    ///
    /// 严格的防死锁规则：
    /// - 拖拽/飞行中（state != .resting）绝不切换；
    /// - 鼠标按键按下期间绝不切换（按下瞬间的 mouseDown 校正除外）；
    /// - 只有窗口可见时才处理。
    private func updatePassThrough(forceAtPress: Bool = false) {
        // NSEvent 监听回调都在主线程；这里的窗口操作必须是主线程
        guard Thread.isMainThread else { return }
        guard let window = window, window.isVisible else { return }

        // 拖拽 / 空中飞行中锁定，避免切换瞬间产生假 mouseUp 打断拖拽
        guard state == .resting else { return }

        // 按键期间不切换（拖拽面板由 state 守卫，这里防的是普通点击/按住）
        if !forceAtPress && NSEvent.pressedMouseButtons != 0 { return }

        let mouseLocation = NSEvent.mouseLocation

        // 光标离开窗口范围 → 恢复默认交互状态
        guard window.frame.contains(mouseLocation) else {
            setIgnoresMouseEvents(false)
            return
        }

        let windowPoint = window.convertPoint(fromScreen: mouseLocation)
        let viewPoint: CGPoint
        if let contentView = window.contentView {
            viewPoint = contentView.convert(windowPoint, from: nil)
        } else {
            viewPoint = windowPoint
        }

        let scenePoint = petScene.convertPoint(fromView: viewPoint)
        let zone = petScene.hitTest(scenePoint: scenePoint)

        // 透明像素 → 穿透；鱼身像素 → 恢复交互
        setIgnoresMouseEvents(zone == .none)
    }

    private func setIgnoresMouseEvents(_ ignores: Bool) {
        guard let window = window, window.ignoresMouseEvents != ignores else { return }
        window.ignoresMouseEvents = ignores
        if ignores {
            // 切到穿透时清掉残留的鼠标跟踪状态（隐藏窗口同理避免拖拽卡死）
            (window as? PetWindow)?.cancelMouseTracking()
        }
    }

    // MARK: - 拖拽（窗口级，不由 petNode 移动）

    /// 开始拖拽。`screenPoint` 为 AppKit 屏幕坐标（原点左下，`NSEvent.mouseLocation` 同系）。
    func startDrag(at screenPoint: CGPoint) {
        guard let window = window else { return }

        // 从空中接管：先停帧驱动，避免与拖拽同时写 frame
        stopDisplayLink()

        state = .dragging
        velocity = .zero
        samples.removeAll(keepingCapacity: true)

        grabOffset = CGPoint(
            x: screenPoint.x - window.frame.origin.x,
            y: screenPoint.y - window.frame.origin.y
        )

        onDragStart?()
    }

    /// 拖拽中。`screenPoint` 为 AppKit 屏幕坐标。
    func dragTo(_ screenPoint: CGPoint) {
        guard state == .dragging, let window = window else { return }

        let origin = CGPoint(
            x: screenPoint.x - grabOffset.x,
            y: screenPoint.y - grabOffset.y
        )
        // 取整，杜绝亚像素抖动
        let pixelOrigin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        window.setFrameOrigin(pixelOrigin)
        recordSample(origin: pixelOrigin, at: CACurrentMediaTime())
    }

    /// 结束拖拽并决定是否抛掷。
    ///
    /// - Parameter velocity: 外部显式提供的松手速度；传 nil 时用采样队列做最小二乘拟合。
    /// - Returns: 采用的松手速度。
    @discardableResult
    func endDrag(velocity: CGVector? = nil) -> CGVector {
        guard state == .dragging else { return .zero }

        let releaseVelocity = velocity ?? estimateVelocity()
        self.velocity = releaseVelocity

        let speed = (releaseVelocity.dx * releaseVelocity.dx + releaseVelocity.dy * releaseVelocity.dy).squareRoot()
        if speed > Physics.throwSpeedMin {
            // 抛掷：进入空中状态，启动 CVDisplayLink 积分循环
            state = .airborne
            lastTickTime = CACurrentMediaTime()
            startDisplayLink()
        } else {
            // 慢速松手：不抛，直接静止（显示链路本来就没启动）
            state = .resting
            self.velocity = .zero
        }

        samples.removeAll(keepingCapacity: true)
        onDragEnd?(releaseVelocity)

        return releaseVelocity
    }

    // MARK: - 速度估计（最小二乘线性拟合）

    private func recordSample(origin: CGPoint, at time: CFTimeInterval) {
        samples.append((time, origin))
        if samples.count > Physics.maxSamples {
            samples.removeFirst(samples.count - Physics.maxSamples)
        }
    }

    /// 对最近 5 个采样做最小二乘线性拟合，返回 pt/s。
    private func estimateVelocity() -> CGVector {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last,
              last.time - first.time >= Physics.minSampleSpan else {
            return .zero
        }

        let n = CGFloat(samples.count)
        let t0 = samples[samples.count - 1].time
        var sumT: CGFloat = 0
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0

        for sample in samples {
            let t = CGFloat(sample.time - t0)
            sumT += t
            sumX += sample.origin.x
            sumY += sample.origin.y
        }

        let meanT = sumT / n
        let meanX = sumX / n
        let meanY = sumY / n

        var covarianceT: CGFloat = 0
        var covarianceX: CGFloat = 0
        var covarianceY: CGFloat = 0

        for sample in samples {
            let dt = CGFloat(sample.time - t0) - meanT
            covarianceT += dt * dt
            covarianceX += dt * (sample.origin.x - meanX)
            covarianceY += dt * (sample.origin.y - meanY)
        }

        guard covarianceT > 1e-9 else { return .zero }

        return CGVector(
            dx: covarianceX / covarianceT,
            dy: covarianceY / covarianceT
        )
    }

    // MARK: - CVDisplayLink 启停（极致低功耗：只在空中飞行期间运行）

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let newLink = link else {
            return
        }

        // 回调派发到主队列：NSWindow 操作必须在主线程
        CVDisplayLinkSetOutputHandler(newLink) { [weak self] _, _, _, _, _ in
            DispatchQueue.main.async {
                self?.step()
            }
            return kCVReturnSuccess
        }

        guard CVDisplayLinkStart(newLink) == kCVReturnSuccess else { return }
        displayLink = newLink
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - 物理积分（CVDisplayLink 主线程回调）

    private func step() {
        guard state == .airborne, let window = window else {
            stopDisplayLink()
            return
        }

        let now = CACurrentMediaTime()
        let dt = min(now - lastTickTime, Physics.maxTimeStep)
        lastTickTime = now
        guard dt > 0 else { return }

        let size = window.frame.size
        let deltaTime = CGFloat(dt)
        var x = window.frame.origin.x + velocity.dx * deltaTime
        var y = window.frame.origin.y + velocity.dy * deltaTime

        // 重力积分
        velocity.dy -= Physics.gravity * deltaTime

        // 地板取窗口当前所在屏幕的 visibleFrame（多屏 / 全屏空间安全）
        let screenFrame = targetVisibleFrame(for: NSRect(x: x, y: y, width: size.width, height: size.height))
        // 地板线取整，与 window origin 取整保持整数一致，避免「贴地-抬起」逐帧微抖
        let floorY = (screenFrame.minY + Physics.restHeight).rounded()

        // 左右墙
        if x < screenFrame.minX {
            x = screenFrame.minX
            let impact = abs(velocity.dx)
            velocity.dx = -velocity.dx * Physics.wallRestitution
            if impact > Physics.wallBounceMinSpeed { onWallBounce?() }
        }
        if x + size.width > screenFrame.maxX {
            x = screenFrame.maxX - size.width
            let impact = abs(velocity.dx)
            velocity.dx = -velocity.dx * Physics.wallRestitution
            if impact > Physics.wallBounceMinSpeed { onWallBounce?() }
        }

        // 天花板：直接用 y（窗口底边）+ 宠物在窗口内的真实头顶，绝不用窗口高度 320。
        // PetWindow.constrainFrameRect 已解除系统边界限制，窗口透明部分可以飞出菜单栏甚至屏幕外。
        let screenTop = screenFrame.maxY
        let petTopFromBottom = max(1, petScene.petVisualTopFromBottom)
        let petTopInScreen = y + petTopFromBottom

        if petTopInScreen > screenTop {
            // 把窗口拉回来，刚好让宠物头顶贴在屏幕顶
            y = (screenTop - petTopFromBottom).rounded(.down)
            if velocity.dy > 0 {
                velocity.dy = -velocity.dy * Physics.wallRestitution
                print("💥 Hit ceiling!")
                onWallBounce?()
            }
        }

        // 地板反弹 + 静止判定
        if y <= floorY {
            y = floorY
            let impact = abs(velocity.dy)

            velocity.dy = -velocity.dy * Physics.floorRestitution

            if impact > Physics.settleSpeed {
                onLanding?(impact)
            }

            if abs(velocity.dy) < Physics.settleSpeed {
                velocity.dy = 0
                settle()
            }
        }

        // 取整，杜绝亚像素抖动
        window.setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
    }

    /// 落地静止：切回 resting 并立即停止帧驱动（零帧开销）。
    private func settle() {
        state = .resting
        velocity = .zero
        stopDisplayLink()
    }

    /// 取窗口当前所在屏幕的 visibleFrame，而不是 NSScreen.main。
    private func targetVisibleFrame(for frame: NSRect) -> NSRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return screen.visibleFrame
        }
        if let screen = window?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? frame
    }
}
