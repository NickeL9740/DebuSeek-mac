import SpriteKit
import SwiftUI
import Combine
import AppKit

// MARK: - Hit Zone

/// 像素级命中分区
enum HitZone {
    case face
    case head
    case body
    case tail
    /// 气泡：窗口级命中时优先于鱼身，点击只爆气泡，不触发鱼身互动
    case bubble
    case none
}

// MARK: - Pet Sprite Node

class PetSpriteNode: SKSpriteNode {
    var currentAnimation: String = "IDLE"
    var textures: [String: [SKTexture]] = [:]
    /// 全局统一缩放系数（宠物大小），所有动作共用一个比例
    private(set) var uniformScale: CGFloat = 1.0
    var isPlayingAnimation: Bool = false
    var onAnimationComplete: (() -> Void)?
    
    // Animation queue for sequential animations
    private var animationQueue: [(name: String, loop: Bool, completion: (() -> Void)?)] = []
    private var isProcessingQueue = false
    
    /// 全局统一缩放（由 PetScene.setScale 调用），xScale/yScale 始终等值
    func setUniformScale(_ scale: CGFloat) {
        uniformScale = scale
        setScale(scale)
    }


    /// 所有动作统一的固定节点尺寸（正方形）
    static let canvasSize = CGSize(width: 150, height: 150)

    /// 把任意原始尺寸的纹理等比 fit 进 150×150 的透明画布。
    /// 节点尺寸固定，但纹理不拉伸，既统一大小又不破坏比例。
    private func normalizedTexture(_ texture: SKTexture) -> SKTexture {
        let cgImage = texture.cgImage()
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return texture }

        let scale = min(Self.canvasSize.width / pixelSize.width, Self.canvasSize.height / pixelSize.height)
        let drawSize = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        let drawRect = NSRect(
            x: (Self.canvasSize.width - drawSize.width) / 2,
            y: (Self.canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let source = NSImage(cgImage: cgImage, size: pixelSize)
        let canvas = NSImage(size: Self.canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        // 立即在主线程光栅化，避免 SKTexture 懒加载时在其它线程执行绘制回调
        var proposedRect = NSRect(origin: .zero, size: Self.canvasSize)
        if let rasterized = canvas.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            let normalized = SKTexture(cgImage: rasterized)
            normalized.filteringMode = .linear
            return normalized
        }

        let normalized = SKTexture(image: canvas)
        normalized.filteringMode = .linear
        return normalized
    }

    func loadAnimations() {
        // AnimationLoader 是唯一资源入口：强制走 manifests/actions.json + 187 高清帧
        do {
            try AnimationLoader.shared.loadAll()
        } catch {
            NSLog("❌ AnimationLoader 加载失败: \(error.localizedDescription)")
            return
        }

        // 直接使用 Manifest 动作名（IDLE / BLINK / POKE_REACT ...），不再有旧名映射层
        textures.removeAll()
        for actionName in AnimationLoader.shared.getAllActionNames() {
            if let frames = AnimationLoader.shared.getTextures(for: actionName), !frames.isEmpty {
                textures[actionName] = frames.map { normalizedTexture($0) }
            }
        }

        // 节点尺寸固定 150×150（纹理已在画布内等比 fit）
        size = Self.canvasSize

        // 初始纹理：IDLE 是 idle_front 正面帧
        if let idleFrames = textures["IDLE"], let first = idleFrames.first {
            texture = first
        }

        NSLog("🎬 可用动画: \(textures.keys.sorted().joined(separator: ", "))")
        playAnimation("IDLE")
    }
    func playAnimation(_ name: String, loop: Bool = true, completion: (() -> Void)? = nil) {
        guard let frames = textures[name], !frames.isEmpty else {
            NSLog("⚠️ Animation '\(name)' not found, available: \(textures.keys.sorted().joined(separator: ", "))")
            completion?()
            return
        }

        let config = AnimationLoader.shared.getConfig(for: name)
        var frameDuration = config?.frameDuration ?? (1.0 / 30.0)

        // 走路动画统一为多帧循环节奏（4 帧 × 0.15s ≈ 0.6s 一个循环）
        if name == "WALKING" || name.hasPrefix("walk_") {
            frameDuration = 0.15
        }

        // 所有动作统一固定为 150×150 的正方形（纹理本身已等比 fit，不会变形）
        // 缩放/镜像统一由 PetScene.applyPetScale 在动画开始前设置，这里不再覆盖 xScale，
        // 否则向右走时刚设好的 -|petScale| 会被重置回正值。
        size = Self.canvasSize

        currentAnimation = name
        isPlayingAnimation = true

        removeAllActions()

        let animate = SKAction.animate(with: frames, timePerFrame: frameDuration)
        if loop {
            run(SKAction.repeatForever(animate), withKey: "currentAnimation")
            completion?()
        } else {
            run(SKAction.sequence([animate, SKAction.run { [weak self] in
                self?.isPlayingAnimation = false
                // 不自动回 IDLE：由调用方 completion 决定，避免两个循环动画互相覆盖
                completion?()
            }]), withKey: "currentAnimation")
        }
    }
    func playAnimationOnce(_ name: String, completion: (() -> Void)? = nil) {
        playAnimation(name, loop: false, completion: completion)
    }
    
    func stopAnimation() {
        removeAction(forKey: "currentAnimation")
        isPlayingAnimation = false
    }
    
    func resumeIdle() {
        playAnimation("IDLE")
    }
    
    // Play a sequence of animations (e.g., walk_start -> walk -> walk_stop -> idle)
    func playAnimationSequence(_ sequence: [(name: String, loop: Bool)], completion: (() -> Void)? = nil) {
        animationQueue = sequence.map { ($0.name, $0.loop, nil) }
        if !animationQueue.isEmpty {
            animationQueue[animationQueue.count - 1].completion = completion
            processAnimationQueue()
        } else {
            completion?()
        }
    }
    
    private func processAnimationQueue() {
        guard !animationQueue.isEmpty else {
            isProcessingQueue = false
            playAnimation("IDLE")
            return
        }
        
        isProcessingQueue = true
        let next = animationQueue.removeFirst()
        playAnimation(next.name, loop: next.loop) { [weak self] in
            next.completion?()
            self?.processAnimationQueue()
        }
    }
    
    // MARK: - Alpha Mask（像素级命中测试）
    
    /// 一张纹理的 alpha 掩码（187×187，1 字节/像素）
    final class AlphaMask {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        
        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }
        
        /// 归一化纹理坐标（u 向右、v 向下，均为 0...1）取 alpha
        func alpha(atU u: CGFloat, atV v: CGFloat) -> UInt8 {
            let x = min(max(Int(u * CGFloat(width)), 0), width - 1)
            let y = min(max(Int(v * CGFloat(height)), 0), height - 1)
            return bytes[y * width + x]
        }
    }
    
    /// 按纹理对象指针缓存 alpha 掩码；动画换帧后 key 自动跟随
    private static let maskCache = NSCache<NSString, AlphaMask>()
    
    /// 惰性生成并缓存当前纹理的 alpha 通道
    func alphaMask(for texture: SKTexture) -> AlphaMask? {
        let key = "\(Unmanaged.passUnretained(texture).toOpaque())" as NSString
        if let cached = Self.maskCache.object(forKey: key) {
            return cached
        }
        
        let cgImage = texture.cgImage()
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        
        // RGBA8 上下文绘制后取 A 通道（比 alphaOnly 上下文更稳）
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            alpha[index] = rgba[index * 4 + 3]
        }
        
        let mask = AlphaMask(width: width, height: height, bytes: alpha)
        Self.maskCache.setObject(mask, forKey: key)
        return mask
    }
}

// MARK: - Pet Scene

class PetScene: SKScene {
    var petNode: PetSpriteNode!
    var speechBubble: SpeechBubbleNode?
    /// 防止旧气泡的隐藏定时器误关新气泡
    private var speechBubbleGeneration: Int = 0
    /// 轻提示（投喂反馈等），同一时间只保留一个
    private var toastNode: SKNode?
    private var toastWorkItem: DispatchWorkItem?
    /// 气泡独立存活计时：只由它负责隐藏气泡，TALKING/TTS 结束不碰气泡
    private var speechHideWorkItem: DispatchWorkItem?

    /// 宠物中心距窗口底边的距离（与旧 210 窗口中心一致，视觉位置不变）
    private let petCenterFromBottom: CGFloat = 105

    /// 宠物实际绘制区域的顶部距窗口底边的距离。
    /// 物理天花板必须用这个值，不能用窗口 frame 高度：窗口上方是给气泡预留的透明区域，
    /// 高度会随气泡变化，拿窗口顶部当碰撞面会把宠物的抛掷高度越压越低。
    var petVisualTopFromBottom: CGFloat {
        guard let petNode = petNode else { return petCenterFromBottom }
        return petNode.frame.maxY
    }

    /// 走路朝向：WALKING 原始帧朝左，向右走时由 PetScene 做水平镜像
    private(set) var walkFacingRight: Bool = false
    /// 镜像时只翻转 xScale，yScale 与 size 永远锁死，避免包围盒缩水
    func setWalkFacing(right: Bool) {
        walkFacingRight = right
    }

    // 气泡需要更高窗口时向 PetController 申请；返回实际可用的窗口高度
    var onSpeechHeightRequest: ((CGFloat) -> CGFloat)?
    // 气泡消失后把窗口收回基础高度（底边不动，宠物不会跳）
    var onSpeechHeightReset: (() -> Void)?

    // Interaction callbacks（拖拽已由 PetWindowController 统一接管，不再走场景手势）
    var onClick: ((HitZone) -> Void)?
    var onDoubleClick: ((HitZone) -> Void)?
    var onRightClick: ((HitZone) -> Void)?
    var onLongPress: ((HitZone) -> Void)?
    
    private var longPressTimer: Timer?
    private var lastClickTime: Date = Date.distantPast
    private var clickCount: Int = 0

    /// 拖拽结束后的短暂点击抑制时间点（CFAbsoluteTime）
    private var clicksSuppressedUntil: CFAbsoluteTime = 0

    /// 拖拽结束时调用：窗口跟随光标移动会让点击识别器误判成点击
    func suppressClicks(for duration: TimeInterval = 0.3) {
        clicksSuppressedUntil = CFAbsoluteTimeGetCurrent() + duration
    }

    var isClickSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < clicksSuppressedUntil
    }
    
    override init(size: CGSize) {
        super.init(size: size)
        setupScene()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupScene()
    }
    
    private func setupScene() {
        backgroundColor = .clear
        // 锚点放到窗口底边：窗口为了气泡向上增高时，宠物不会被顶起来
        anchorPoint = CGPoint(x: 0.5, y: 0)
        
        petNode = PetSpriteNode()
        // 距窗口底边固定 105pt，与旧 210×210 窗口中的视觉位置完全一致
        petNode.position = CGPoint(x: 0, y: petCenterFromBottom)
        petNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        petNode.size = PetSpriteNode.canvasSize
        petNode.zPosition = 10
        addChild(petNode)
    }
    
    override func didMove(to view: SKView) {
        // 点击/双击/长按全部由 PetWindow 窗口级事件派发，不再使用 SKView 手势识别器
    }
    
    func loadModel() {
        petNode.loadAnimations()
    }
    
    override func setScale(_ scale: CGFloat) {
        // SKScene 自身的 scale 无效（还会刷警告），统一只缩放 petNode
        petNode.setUniformScale(scale)
        // 缩放变化后重新套用当前朝向，避免走路镜像被重置
        applyPetScale(for: petNode.currentAnimation)
    }
    
    func setAlpha(_ alpha: CGFloat) {
        petNode.alpha = alpha
    }
    
    // MARK: - Pixel Hit Testing
    
    /// 场景坐标 → 纹理像素 → alpha 判定 → 分区
    ///
    /// 换算说明：先转成 petNode 的本地坐标（自动处理 scene/petNode 的缩放与位置），
    /// 再按 anchorPoint(0.5, 0.5) 归一化；纹理 v 轴向下，需翻转 y。
    func hitTest(scenePoint: CGPoint) -> HitZone {
        // 气泡优先：点气泡只爆气泡，不触发鱼身点击，也保证窗口不会把它当透明区穿透
        if let bubble = speechBubble,
           bubble.calculateAccumulatedFrame().contains(scenePoint) {
            return .bubble
        }

        guard let texture = petNode.texture,
              let mask = petNode.alphaMask(for: texture) else { return .none }
        
        let local = petNode.convert(scenePoint, from: self)
        let width = petNode.size.width
        let height = petNode.size.height
        guard width > 0, height > 0 else { return .none }
        
        let u = local.x / width + 0.5
        let v = 1.0 - (local.y / height + 0.5)
        
        // 注：petNode.convert 已包含 xScale（含负值）的变换，
        // 镜像时 local.x 已自动翻转，这里不能再手动 1-u，否则会二次翻转。
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return .none }
        guard mask.alpha(atU: u, atV: v) >= 16 else { return .none }
        
        // 分区：全部来自 ConfigManager 的归一化框（左上角原点，y 向下），
        // 顺序保持“越具体越先命中”：脸 → 尾巴 → 头 → 身体。
        let model = ConfigManager.shared.config.pet.model
        let point = CGPoint(x: u, y: v)
        if model.faceRect.contains(point) { return .face }
        if model.tailRect.contains(point) { return .tail }
        if model.headRect.contains(point) { return .head }
        if model.bodyRect.contains(point) { return .body }
        return .none
    }
    
    func playAnimation(_ name: String, loop: Bool = true, completion: (() -> Void)? = nil) {
        applyPetScale(for: name)
        petNode.playAnimation(name, loop: loop, completion: completion)
    }
    
    func playAnimationOnce(_ name: String, completion: (() -> Void)? = nil) {
        applyPetScale(for: name)
        petNode.playAnimationOnce(name, completion: completion)
    }
    
    /// 每次播放动画前强制锁定包围盒与缩放：
    /// - 所有动画：size 恒为 150×150，yScale = |petScale|
    /// - WALKING：原始帧朝左，向右走时 xScale = -|petScale|（水平镜像）
    /// - 切回 IDLE 等非走路动画：xScale 立即恢复 +|petScale|
    private func applyPetScale(for animationName: String) {
        let scale = abs(CGFloat(ConfigManager.shared.config.pet.model.petScale))

        // 翻转前先锁死节点尺寸，绝不允许镜像导致包围盒缩水
        petNode.size = CGSize(width: 150, height: 150)
        petNode.yScale = scale

        let mirroredWalk = animationName == "WALKING" && walkFacingRight
        petNode.xScale = mirroredWalk ? -scale : scale
    }
    
    // MARK: - Speech Bubble
    
    func showSpeech(_ text: String) {
        // 新气泡取消旧计时；气泡存活时间只由这里决定，TTS/TALKING 结束不负责隐藏
        speechHideWorkItem?.cancel()
        speechHideWorkItem = nil

        speechBubble?.removeFromParent()
        speechBubble = nil
        speechBubbleGeneration += 1
        let generation = speechBubbleGeneration

        let maxWidth: CGFloat = 220
        let gap: CGFloat = 8       // 尾巴尖与鱼头顶的间距
        let margin: CGFloat = 4
        let petTop = petNode.frame.maxY

        // 先按宽松上限量一次，算出气泡需要多高；窗口只会向上长，底边和宠物都不动
        var bubble = SpeechBubbleNode(text: text, maxWidth: maxWidth, maxTotalHeight: 600)
        let desiredHeight = petTop + gap + margin + bubble.bubbleSize.height
        let availableHeight = onSpeechHeightRequest?(desiredHeight) ?? desiredHeight

        // 屏幕顶部空间不足时按实际可用高度缩字号，绝不让气泡往下压住脸
        let maxBubbleHeight = availableHeight - petTop - gap - margin
        if bubble.bubbleSize.height > maxBubbleHeight {
            bubble = SpeechBubbleNode(
                text: text,
                maxWidth: maxWidth,
                maxTotalHeight: max(60, maxBubbleHeight)
            )
        }

        let halfW = bubble.bubbleSize.width / 2
        let halfH = bubble.bubbleSize.height / 2
        let sceneHalfW = size.width / 2

        var x = petNode.position.x
        x = min(max(x, -sceneHalfW + halfW + margin), sceneHalfW - halfW - margin)

        // 尾巴尖（节点底部）永远固定在鱼头顶上方
        let y = petTop + gap + halfH

        bubble.position = CGPoint(x: x, y: y)
        bubble.zPosition = 1000
        addChild(bubble)
        speechBubble = bubble

        // 气泡一出现就确保窗口可交互，避免光标恰好停在气泡上时点击穿到下层 App
        view?.window?.ignoresMouseEvents = false

        bubble.animateIn()

        // 独立存活计时：3~10 秒，只由气泡自己负责消失
        let lifetime = min(10.0, max(3.0, Double(text.count) * 0.25))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, generation == self.speechBubbleGeneration else { return }
            self.hideSpeech()
        }
        speechHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: workItem)
    }
    
    func hideSpeech() {
        speechHideWorkItem?.cancel()
        speechHideWorkItem = nil

        guard let bubble = speechBubble else {
            onSpeechHeightReset?()
            return
        }
        speechBubble = nil

        bubble.animateOut { [weak self, weak bubble] in
            bubble?.removeFromParent()
            // 若淡出期间已出现新气泡，不要回收窗口高度
            if self?.speechBubble == nil {
                self?.onSpeechHeightReset?()
            }
        }
    }

    /// 宠物头顶的轻量 Toast（投喂反馈等），1.5 秒后自动淡出销毁。
    func showToast(_ text: String, duration: TimeInterval = 1.5) {
        toastWorkItem?.cancel()
        toastWorkItem = nil
        toastNode?.removeFromParent()
        toastNode = nil

        let label = SKLabelNode(fontNamed: "Helvetica-Bold")
        label.text = text
        label.fontSize = 12
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center

        let width = max(92, label.frame.width + 24)
        let height = max(26, label.frame.height + 14)
        let shape = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: height / 2)
        shape.fillColor = NSColor.black.withAlphaComponent(0.72)
        shape.strokeColor = NSColor.white.withAlphaComponent(0.18)
        shape.lineWidth = 1
        shape.zPosition = 999
        shape.position = CGPoint(x: petNode.position.x, y: petNode.frame.maxY + 40)
        shape.alpha = 0
        shape.addChild(label)
        addChild(shape)
        toastNode = shape
        shape.run(.fadeIn(withDuration: 0.12))

        let item = DispatchWorkItem { [weak self, weak shape] in
            guard let shape = shape else { return }
            shape.run(.sequence([
                .fadeOut(withDuration: 0.25),
                .removeFromParent()
            ]))
            if let self = self, self.toastNode === shape {
                self.toastNode = nil
            }
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    /// 点击气泡：0.2 秒放大到 1.2 + 淡出，随后移除；不触发鱼身互动。
    func popSpeechBubble() {
        guard let bubble = speechBubble else { return }

        speechHideWorkItem?.cancel()
        speechHideWorkItem = nil
        speechBubbleGeneration += 1
        let generation = speechBubbleGeneration
        speechBubble = nil

        // 气泡消失后 0.35s 内抑制鱼身点击，防止双击气泡的第二下落到鱼身上触发互动
        suppressClicks(for: 0.35)

        bubble.removeAllActions()
        bubble.animatePop { [weak self, weak bubble] in
            bubble?.removeFromParent()
            guard let self = self, generation == self.speechBubbleGeneration else { return }
            // 0.2 秒内若又弹了新气泡，不能把窗口高度收回
            if self.speechBubble == nil {
                self.onSpeechHeightReset?()
            }
        }
    }
    
    // MARK: - Window-level Click Dispatch（由 PetWindow 调用）
    
    /// 单击：窗口级事件已做过像素命中，这里再防一次拖拽/长按后的误触发
    func performClick(zone: HitZone) {
        if zone == .bubble {
            popSpeechBubble()
            return
        }
        guard !isClickSuppressed, zone != .none else { return }
        onClick?(zone)
    }
    
    /// 双击
    func performDoubleClick(zone: HitZone) {
        if zone == .bubble {
            popSpeechBubble()
            return
        }
        guard !isClickSuppressed, zone != .none else { return }
        onDoubleClick?(zone)
    }

    /// 长按（由 PetWindow 的鼠标按住计时派发）
    func performLongPress(zone: HitZone) {
        // 长按气泡不触发鱼身互动
        guard zone != .bubble else { return }
        guard !isClickSuppressed, zone != .none else { return }
        onLongPress?(zone)
    }
    
    /// 右键（由 PetWindow 派发，弹出原生 NSMenu）
    func performRightClick(zone: HitZone) {
        guard zone != .bubble else { return }
        guard zone != .none else { return }
        onRightClick?(zone)
    }
    
    @objc private func handleLongPress(_ gesture: NSPressGestureRecognizer) {
        guard !isClickSuppressed else { return }
        let location = gesture.location(in: gesture.view)
        let sceneLocation = convertPoint(fromView: location)
        
        guard gesture.state == .began else { return }
        let zone = hitTest(scenePoint: sceneLocation)
        guard zone != .none else { return }
        // 长按识别后，松开时点击识别器可能再触发一次 HAPPY，这里抑制掉
        suppressClicks(for: 0.6)
        onLongPress?(zone)
    }
}

// MARK: - Speech Bubble Node

class SpeechBubbleNode: SKNode {
    private var background: SKShapeNode!
    private var label: SKLabelNode!
    private let padding: CGFloat = 10
    private var maxWidth: CGFloat = 220
    /// 气泡整体尺寸（含下方小尾巴），供 PetScene 做窗口/头顶定位
    private(set) var bubbleSize: CGSize = .zero
    
    init(text: String, maxWidth: CGFloat = 220, maxTotalHeight: CGFloat = .greatestFiniteMagnitude) {
        self.maxWidth = maxWidth
        super.init()
        setupBubble(text: text, maxTotalHeight: maxTotalHeight)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupBubble(text: String, maxTotalHeight: CGFloat) {
        // 长台词：限制文本宽度并自动多行；超过可用高度时逐级缩小字号
        let textWidth = maxWidth - padding * 2
        var fontSize: CGFloat = 12
        var textSize = calculateTextSize(text: text, maxWidth: textWidth, fontSize: fontSize)
        while (textSize.height + padding * 2 + 8) > maxTotalHeight && fontSize > 9 {
            fontSize -= 1
            textSize = calculateTextSize(text: text, maxWidth: textWidth, fontSize: fontSize)
        }
        
        label = SKLabelNode(text: text)
        label.fontName = "PingFang SC"
        label.fontSize = fontSize
        label.fontColor = .black
        label.numberOfLines = 0
        label.preferredMaxLayoutWidth = textWidth
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        
        let bubbleWidth = min(maxWidth, textSize.width + padding * 2)
        let bubbleHeight = textSize.height + padding * 2
        bubbleSize = CGSize(width: bubbleWidth, height: bubbleHeight + 8) // +8 = 下方小尾巴
        
        let rect = CGRect(x: -bubbleWidth/2, y: -bubbleHeight/2, width: bubbleWidth, height: bubbleHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        
        background = SKShapeNode(path: path)
        background.fillColor = .white
        background.strokeColor = .systemGray
        background.lineWidth = 1
        background.alpha = 0.95
        
        // Add tail
        let tailPath = CGMutablePath()
        tailPath.move(to: CGPoint(x: -8, y: -bubbleHeight/2))
        tailPath.addLine(to: CGPoint(x: 0, y: -bubbleHeight/2 - 8))
        tailPath.addLine(to: CGPoint(x: 8, y: -bubbleHeight/2))
        tailPath.closeSubpath()
        
        let tail = SKShapeNode(path: tailPath)
        tail.fillColor = .white
        tail.strokeColor = .systemGray
        tail.lineWidth = 1
        background.addChild(tail)
        
        addChild(background)
        background.addChild(label)
        
        label.position = .zero
    }
    
    private func calculateTextSize(text: String, maxWidth: CGFloat, fontSize: CGFloat) -> CGSize {
        let font = NSFont(name: "PingFang SC", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let constraintRect = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let boundingBox = text.boundingRect(with: constraintRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: ceil(boundingBox.width), height: ceil(boundingBox.height))
    }
    
    func animateIn() {
        setScale(0.1)
        alpha = 0
        let scaleAction = SKAction.scale(to: 1.0, duration: 0.2)
        scaleAction.timingMode = .easeOut
        let fadeAction = SKAction.fadeIn(withDuration: 0.15)
        run(SKAction.group([scaleAction, fadeAction]))
    }
    
    func animateOut(completion: @escaping () -> Void) {
        let scaleAction = SKAction.scale(to: 0.1, duration: 0.15)
        scaleAction.timingMode = .easeIn
        let fadeAction = SKAction.fadeOut(withDuration: 0.15)
        let group = SKAction.group([scaleAction, fadeAction])
        run(SKAction.sequence([group, SKAction.run(completion)]))
    }

    /// 点击爆掉：放大到 1.2 倍并淡出，持续 0.2 秒。
    func animatePop(completion: @escaping () -> Void) {
        let scaleAction = SKAction.scale(to: 1.2, duration: 0.2)
        scaleAction.timingMode = .easeOut
        let fadeAction = SKAction.fadeOut(withDuration: 0.2)
        let group = SKAction.group([scaleAction, fadeAction])
        run(SKAction.sequence([group, SKAction.run(completion)]))
    }
}
