import Foundation
import AVFoundation
import Combine
import CryptoKit

// MARK: - TTS Service Protocol

@MainActor
protocol TTSServiceProtocol: AnyObject {
    func speak(_ text: String, isDynamic: Bool) async throws
    func stop()
    var isSpeaking: Bool { get }
    /// 全局音量（0...1）
    var volume: Float { get set }
    /// 全局语速倍数（0.5...2.0）；GPT-SoVITS 走 speed_factor，系统语音换算 rate
    var speed: Double { get set }
}

// MARK: - TTS Service Manager

@MainActor
final class TTSServiceManager: ObservableObject {
    static let shared = TTSServiceManager()

    @Published var isSpeaking: Bool = false
    @Published var currentProvider: TTSProvider = .cloud

    /// 全局音量（0...1）；设置页直接绑定这个值。
    @Published var volume: Float = 0.3
    /// 全局语速倍数（0.5...2.0）；GPT-SoVITS 用 speed_factor，系统语音换算 rate。
    @Published var speed: Double = 1.0

    private var currentService: TTSServiceProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// 语音代次：每次新的 speak 都 +1，旧请求/旧回调全部按代次丢弃。
    private var generation = 0
    /// 云端/本地失败后临时回退的系统语音；新 speak 时也要能立刻停掉。
    private var fallbackService: SystemTTSService?

    private init() {
        updateProvider()

        // Observe config changes
        ConfigManager.shared.$config
            .sink { [weak self] _ in
                self?.updateProvider()
            }
            .store(in: &cancellables)
    }

    private func updateProvider() {
        // 切换服务前先停掉旧服务，保证其挂起的 continuation 被收尾（避免 CheckedContinuation 泄漏）
        generation += 1
        currentService?.stop()
        fallbackService?.stop()
        fallbackService = nil

        let provider = ConfigManager.shared.config.tts.provider
        currentProvider = provider

        let ttsConfig = ConfigManager.shared.config.tts
        let service: TTSServiceProtocol
        switch provider {
        case .cloud:
            if ttsConfig.cloud.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("🔊 TTS: 云端 API Key 为空 → 使用系统语音")
                service = SystemTTSService()
            } else {
                print("🔊 TTS: 使用云端语音（已配置 API Key）")
                service = CloudTTSService()
            }
        case .localGptSovits:
            if ttsConfig.localGptSovits.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("🔊 TTS: GPT-SoVITS 地址为空 → 使用系统语音")
                service = SystemTTSService()
            } else {
                service = LocalGptSovitsService()
            }
        case .system:
            service = SystemTTSService()
        }

        service.volume = volume
        service.speed = speed
        currentService = service
    }

    func speak(_ text: String, isDynamic: Bool = false) async {
        let spoken = TTSTextSanitizer.spokenText(from: text)

        guard ConfigManager.shared.config.tts.enabled else {
            print("🔇 TTS: 已禁用 → stop 当前语音")
            stop()
            return
        }
        guard let service = currentService else {
            print("⚠️ TTS: 没有可用的语音服务，跳过")
            stop()
            return
        }

        // 新的 speak 立刻打断上一句：停播 + 让旧请求的回调按代次失效。
        generation += 1
        let myGeneration = generation
        service.stop()
        fallbackService?.stop()
        fallbackService = nil
        isSpeaking = false

        // 过滤后只剩动作描写：不播语音，但已经停掉上一句。
        guard !spoken.isEmpty else { return }

        service.volume = volume
        service.speed = speed
        isSpeaking = true
        defer {
            if generation == myGeneration {
                isSpeaking = false
                print("🔊 TTS isSpeaking=false (gen \(myGeneration))")
            }
        }

        do {
            try await service.speak(spoken, isDynamic: isDynamic)
        } catch {
            guard generation == myGeneration else { return }
            print("❌ TTS Error: \(error.localizedDescription)")

            // 云端/本地服务不可用（含 API Key 为空）时回退系统语音；
            // 裸二进制（无 .app Bundle）下 AVSpeechSynthesizer 依然可用，不再跳过。
            guard ConfigManager.shared.config.tts.fallbackToSystem,
                  currentProvider != .system else {
                return
            }

            print("🔊 TTS: 回退 SystemTTSService")
            let system = SystemTTSService()
            fallbackService = system
            system.volume = volume
            system.speed = speed
            do {
                try await system.speak(spoken, isDynamic: isDynamic)
            } catch {
                print("❌ TTS Fallback Error: \(error.localizedDescription)")
            }
            if fallbackService === system {
                fallbackService = nil
            }
        }
    }

    func stop() {
        generation += 1
        currentService?.stop()
        fallbackService?.stop()
        fallbackService = nil
        isSpeaking = false
        print("🔊 TTS isSpeaking=false (stop)")
    }
}

// MARK: - Cloud TTS Service

@MainActor
final class CloudTTSService: TTSServiceProtocol {
    var isSpeaking: Bool = false
    var volume: Float = 0.3
    var speed: Double = 1.0

    private let audioPlayer = AVPlayer()
    /// 当前播放会话；打断/停止时确保其 continuation 被收尾，避免泄漏
    private var activeGate: TTSCallbackGate?
    /// 请求/播放代次：被新请求或 stop 打断后，旧回调直接丢弃
    private var generation = 0

    func speak(_ text: String, isDynamic: Bool = false) async throws {
        generation += 1
        let myGeneration = generation
        cancelPlayback()

        guard !text.isEmpty else { throw TTSError.invalidConfiguration }

        let config = ConfigManager.shared.config.tts.cloud

        guard !config.apiKey.isEmpty, !config.apiUrl.isEmpty else {
            throw TTSError.invalidConfiguration
        }
        guard let url = URL(string: config.apiUrl) else {
            throw TTSError.invalidConfiguration
        }

        isSpeaking = true
        defer {
            if myGeneration == generation {
                isSpeaking = false
            }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "text": text,
            "voice": config.voice,
            "speed": max(0.5, min(2.0, config.speed * speed)),
            "pitch": config.pitch,
            "volume": Double(volume)
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("❌ TTS: 请求体序列化失败 \(error.localizedDescription)")
            throw TTSError.invalidConfiguration
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        // 请求期间被新的 speak/stop 打断 → 丢弃旧响应，不播
        guard myGeneration == generation else { return }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TTSError.apiError
        }
        guard !data.isEmpty else {
            throw TTSError.playbackError
        }

        // Save audio data to temp file and play
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts_\(UUID().uuidString).mp3")

        do {
            try data.write(to: tempURL)
            try await playAudio(url: tempURL, generation: myGeneration)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func cancelPlayback() {
        audioPlayer.pause()
        activeGate?.finish()
        activeGate = nil
    }

    private func playAudio(url: URL, generation: Int) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TTSError.playbackError
        }
        guard generation == self.generation else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard generation == self.generation else {
                continuation.resume()
                return
            }

            let item = AVPlayerItem(url: url)
            let gate = TTSCallbackGate(continuation)
            activeGate = gate

            audioPlayer.replaceCurrentItem(with: item)
            audioPlayer.volume = volume
            audioPlayer.play()

            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                gate.finish()
            }
            gate.add(observer: endObserver)

            let failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                gate.finish(TTSError.playbackError)
            }
            gate.add(observer: failObserver)
        }
    }

    func stop() {
        generation += 1
        cancelPlayback()
        isSpeaking = false
    }
}

// MARK: - Local GPT-SoVITS Service

@MainActor
final class LocalGptSovitsService: TTSServiceProtocol {
    var isSpeaking: Bool = false
    var volume: Float = 0.3
    var speed: Double = 1.0

    // MARK: - 本地语音缓存

    /// ~/Library/Application Support/DebuSeek/Cache/
    static var cacheDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DebuSeek/Cache", isDirectory: true)
    }

    /// 删除缓存目录中的所有 .wav，返回清理数量。
    @discardableResult
    static func clearCache() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var removed = 0
        for file in files where file.pathExtension.lowercased() == "wav" {
            if (try? fm.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }

    private static func cacheFileURL(
        text: String,
        config: LocalGptSovitsConfig,
        speed: Double
    ) -> URL {
        let material = [
            text,
            config.referWavPath,
            config.promptText,
            config.promptLanguage,
            config.textLanguage,
            String(config.topK),
            String(format: "%.4f", config.topP),
            String(format: "%.4f", config.temperature),
            String(format: "%.4f", speed)
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).wav")
    }

    private let audioPlayer = AVPlayer()
    private var activeGate: TTSCallbackGate?
    /// 请求/播放代次：被新请求或 stop 打断后，旧回调直接丢弃
    private var generation = 0

    func speak(_ text: String, isDynamic: Bool = false) async throws {
        generation += 1
        let myGeneration = generation
        cancelPlayback()

        guard !text.isEmpty else { throw TTSError.invalidConfiguration }

        let config = ConfigManager.shared.config.tts.localGptSovits

        let apiBase = config.apiUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // 沙盒/本地网络对 localhost 解析不稳定，统一改成 127.0.0.1
            .replacingOccurrences(of: "localhost", with: "127.0.0.1", options: .caseInsensitive)
        guard !apiBase.isEmpty else {
            throw TTSError.invalidConfiguration
        }

        // 兼容两种填法：base 地址（http://127.0.0.1:9880）或完整地址（.../tts）
        let baseWithoutSlash = apiBase.hasSuffix("/") ? String(apiBase.dropLast()) : apiBase
        let endpoint = baseWithoutSlash.hasSuffix("/tts") ? baseWithoutSlash : "\(baseWithoutSlash)/tts"
        guard let url = URL(string: endpoint) else {
            throw TTSError.invalidConfiguration
        }

        // GPT-SoVITS 必须带参考音频和参考文本，否则接口大概率 400
        let refAudioPath = config.referWavPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = config.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refAudioPath.isEmpty, !promptText.isEmpty else {
            print("🔊 TTS: GPT-SoVITS 参考音频或参考文本为空 → 回退系统语音")
            throw TTSError.invalidConfiguration
        }

        // 缓存命中：直接播本地 wav，跳过网络请求和本地推理。
        let cacheURL = Self.cacheFileURL(text: text, config: config, speed: speed)
        if !isDynamic,
           let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > 44 {
            print("🔊 TTS[GPT-SoVITS]: 命中缓存 \(cacheURL.lastPathComponent) → 跳过 API")
            isSpeaking = true
            defer {
                if myGeneration == generation {
                    isSpeaking = false
                }
            }
            try await playAudio(url: cacheURL, generation: myGeneration)
            return
        }

        print("🔊 TTS[GPT-SoVITS]: POST \(url.absoluteString) ref=\(refAudioPath)")

        isSpeaking = true
        defer {
            if myGeneration == generation {
                isSpeaking = false
            }
        }

        var request = URLRequest(url: url)
        // 本地 CPU 推理可能很慢，给足时间；失败仍由 TTSServiceManager 回退系统语音
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "text_lang": config.textLanguage,
            "ref_audio_path": refAudioPath,
            "prompt_text": promptText,
            "prompt_lang": config.promptLanguage,
            "top_k": config.topK,
            "top_p": config.topP,
            "temperature": config.temperature,
            "speed_factor": max(0.5, min(2.0, speed)),
            "text_split_method": "cut0",
            "batch_size": 1,
            "media_type": "wav",
            "streaming_mode": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("❌ TTS: 请求体序列化失败 \(error.localizedDescription)")
            throw TTSError.invalidConfiguration
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        // 请求期间被新的 speak/stop 打断 → 丢弃旧响应，不播
        guard myGeneration == generation else { return }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TTSError.apiError
        }
        guard !data.isEmpty else {
            throw TTSError.playbackError
        }

        // 动态 AI 内容不进缓存，避免无限增长；固定台词命中率才高。
        if !isDynamic {
            do {
                try FileManager.default.createDirectory(
                    at: Self.cacheDirectory,
                    withIntermediateDirectories: true
                )
                try data.write(to: cacheURL, options: .atomic)
                print("🔊 TTS cache saved: \(cacheURL.lastPathComponent)")
            } catch {
                print("⚠️ TTS cache write failed: \(error.localizedDescription)")
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt_sovits_\(UUID().uuidString).wav")

        do {
            try data.write(to: tempURL)
            try await playAudio(url: tempURL, generation: myGeneration)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func cancelPlayback() {
        audioPlayer.pause()
        activeGate?.finish()
        activeGate = nil
    }

    private func playAudio(url: URL, generation: Int) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TTSError.playbackError
        }
        guard generation == self.generation else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard generation == self.generation else {
                continuation.resume()
                return
            }

            let item = AVPlayerItem(url: url)
            let gate = TTSCallbackGate(continuation)
            activeGate = gate

            audioPlayer.replaceCurrentItem(with: item)
            audioPlayer.volume = volume
            audioPlayer.play()

            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                gate.finish()
            }
            gate.add(observer: endObserver)

            let failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                gate.finish(TTSError.playbackError)
            }
            gate.add(observer: failObserver)
        }
    }

    func stop() {
        generation += 1
        cancelPlayback()
        isSpeaking = false
    }
}

// MARK: - System TTS Service (macOS built-in)

@MainActor
final class SystemTTSService: TTSServiceProtocol {
    var isSpeaking: Bool = false
    var volume: Float = 0.3
    var speed: Double = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Error>?
    /// AVSpeechSynthesizer.delegate 是 weak，必须自己强引用住回调对象
    private var speechDelegate: SpeechSynthesizerDelegate?
    /// 语音代次：旧 utterance 的 didFinish/didCancel/看门狗按代次丢弃
    private var generation = 0

    func speak(_ text: String, isDynamic: Bool = false) async throws {
        guard !text.isEmpty else { throw TTSError.invalidConfiguration }
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            throw TTSError.invalidConfiguration
        }

        generation += 1
        let myGeneration = generation

        // 先收尾上一句，避免旧的 continuation 悬挂
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishSpeaking()

        isSpeaking = true
        defer {
            if myGeneration == generation {
                isSpeaking = false
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard myGeneration == generation else {
                continuation.resume()
                return
            }
            self.continuation = continuation

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            // 0.5 是系统默认中速；按全局语速缩放并限制在合法范围
            utterance.rate = Float(max(0.1, min(1.0, 0.5 * self.speed)))
            utterance.pitchMultiplier = 1.0
            utterance.volume = max(0, min(1, self.volume))

            let delegate = SpeechSynthesizerDelegate { [weak self] in
                // 回调只做 continuation 收尾，不碰任何 UI
                Task { @MainActor in
                    self?.finishSpeaking(generation: myGeneration)
                }
            }
            self.speechDelegate = delegate
            self.synthesizer.delegate = delegate

            self.synthesizer.speak(utterance)

            // 看门狗：AVSpeechSynthesizer 回调若丢失，8s 后强制收尾，
            // 防止 continuation 悬挂、isSpeaking 永久为 true 拖死心跳里的自动说话。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.finishSpeaking(generation: myGeneration)
            }
        }
    }

    /// 单次收尾：保证 continuation 只 resume 一次；传入代次时旧回调直接丢弃。
    private func finishSpeaking(generation: Int? = nil) {
        if let generation = generation, generation != self.generation { return }
        guard let continuation = continuation else { return }
        self.continuation = nil
        synthesizer.delegate = nil
        speechDelegate = nil
        continuation.resume()
    }

    func stop() {
        generation += 1
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishSpeaking()
        isSpeaking = false
    }
}

// MARK: - Speech Synthesizer Delegate

final class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
}

// MARK: - Playback Continuation Gate

/// 保证一次播放的 continuation 只 resume 一次，并清理 NotificationCenter 观察者。
/// 只在主队列（NotificationCenter queue: .main）访问，因此标注 @unchecked Sendable。
private final class TTSCallbackGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var observers: [NSObjectProtocol] = []

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func add(observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func finish(_ error: Error? = nil) {
        guard let continuation = continuation else { return }
        self.continuation = nil

        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

// MARK: - TTS Text Sanitizer

/// TTS 朗读净化：去掉中文括号（）/英文括号() 以及括号里的动作描写。
/// 气泡仍然显示完整原文，只有送进语音服务的文本会被过滤。
enum TTSTextSanitizer {
    private static let actionRegex = try? NSRegularExpression(
        pattern: "[（(][^）)]*[）)]",
        options: []
    )

    static func spokenText(from text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var cleaned = actionRegex?.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        ) ?? text

        // 段落不要换行：全部换成句号，防止 Python 后端按换行强切
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "。")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "。")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "。")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉开头连续的标点/空白，避免 TTS 第一句是“，呀——”这种断句
        while let scalar = cleaned.unicodeScalars.first,
              CharacterSet.punctuationCharacters.contains(scalar) ||
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            cleaned.removeFirst()
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TTS Errors

enum TTSError: LocalizedError {
    case invalidConfiguration
    case apiError
    case playbackError
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "TTS configuration is invalid"
        case .apiError: return "TTS API request failed"
        case .playbackError: return "Audio playback failed"
        case .networkError: return "Network error"
        }
    }
}
