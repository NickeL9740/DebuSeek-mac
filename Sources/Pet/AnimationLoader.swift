import Foundation
import SpriteKit

// MARK: - Actions.json Format Models (actions.json 数据模型)

struct ActionsManifest: Codable {
    let formatVersion: Int
    let characterId: String
    let assets: [String: AssetDefinition]
    let actions: [String: ActionDefinition]
    let fallbacks: [String: String]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case characterId = "character_id"
        case assets
        case actions
        case fallbacks
    }
}

struct AssetDefinition: Codable {
    let sourceMasters: [String]
    let frames: [String: [String]] // 分辨率 -> 帧相对路径
    let frameCount: Int
    let quality: String
    let artFamily: String
    let generatedAtRuntime: Bool

    enum CodingKeys: String, CodingKey {
        case sourceMasters = "source_masters"
        case frames
        case frameCount = "frame_count"
        case quality
        case artFamily = "art_family"
        case generatedAtRuntime = "generated_at_runtime"
    }
}

struct ActionDefinition: Codable {
    let id: String
    let asset: String
    let loop: Bool
    let durationMs: Int?
    let priority: Int
    let interruptible: Bool
    let returnState: String
    let anchor: Anchor?
    let proceduralMotion: ProceduralMotion?
    let quality: String
    let requiresRealFrames: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case asset
        case loop
        case durationMs = "duration_ms"
        case priority
        case interruptible
        case returnState = "return_state"
        case anchor
        case proceduralMotion = "procedural_motion"
        case quality
        case requiresRealFrames = "requires_real_frames"
    }
}

struct Anchor: Codable {
    let type: String
    let x: Double
    let y: Double
}

struct ProceduralMotion: Codable {
    let type: String
}

// MARK: - Resource Resolver（唯一资源定位入口，杜绝硬编码绝对路径）

enum ResourceResolver {

    /// 定位 fish_pet 资源根目录（包含 manifests/、assets/、dialogue/）。
    /// 依序探测：Bundle 资源目录 → 从源码路径推导的项目根目录。
    static func findFishPetRoot() -> String? {
        let candidates = candidateRoots().map { "\($0)/Models/fish_pet" }
        for root in candidates where FileManager.default.fileExists(atPath: root) {
            return root
        }
        return nil
    }

    /// 候选基目录：Bundle.main.resourcePath（可执行文件所在目录）
    /// 以及 #filePath 推导出的项目根目录（覆盖 swiftc 直编与 SPM 两种布局）。
    static func candidateRoots() -> [String] {
        var roots: [String] = []
        if let resourcePath = Bundle.main.resourcePath {
            roots.append(resourcePath)                 // 可执行文件同级
            roots.append("\(resourcePath)/Resources")  // SPM .copy("../Resources") 布局
        }
        // #filePath = <project>/Sources/Pet/AnimationLoader.swift
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AnimationLoader.swift
            .deletingLastPathComponent() // Pet
            .deletingLastPathComponent() // Sources -> 项目根
            .path
        roots.append(projectRoot)
        roots.append("\(projectRoot)/Resources")
        return roots
    }

    static func findManifestPath() -> String? {
        guard let root = findFishPetRoot() else { return nil }
        let path = "\(root)/manifests/actions.json"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func findDialogueRoot() -> String? {
        guard let root = findFishPetRoot() else { return nil }
        let path = "\(root)/dialogue"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

// MARK: - Action Animation Config

public struct ActionAnimationConfig {
    public let actionName: String
    public let assetName: String
    public let frames: [SKTexture]
    public let frameDuration: TimeInterval
    public let loop: Bool
    public let priority: Int
    public let interruptible: Bool
    public let returnState: String
}

// MARK: - Animation Loader（唯一的动画资源入口）

public class AnimationLoader {
    public static let shared = AnimationLoader()

    public enum LoadError: LocalizedError {
        case manifestNotFound
        case manifestParseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .manifestNotFound:
                return "未找到 actions.json（Resources/Models/fish_pet/manifests/actions.json）"
            case .manifestParseFailed(let detail):
                return "actions.json 解析失败：\(detail)"
            }
        }
    }

    private var manifest: ActionsManifest?
    private var textures: [String: [SKTexture]] = [:]
    private var actionConfigs: [String: ActionAnimationConfig] = [:]
    private var assetRoot: String = ""

    // 强制使用 187 分辨率高清帧
    private let preferredResolution = "187"

    private init() {}

    // MARK: - 加载入口（manifest + 全部纹理，一次调用完成）

    public func loadAll() throws {
        guard let manifestPath = ResourceResolver.findManifestPath() else {
            throw LoadError.manifestNotFound
        }

        let url = URL(fileURLWithPath: manifestPath)
        do {
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(ActionsManifest.self, from: data)
        } catch {
            throw LoadError.manifestParseFailed(error.localizedDescription)
        }

        // 资源根 = manifest 上一级目录（fish_pet 根）
        assetRoot = url.deletingLastPathComponent().deletingLastPathComponent().path
        NSLog("📦 AnimationLoader: manifest 已加载 \(manifestPath)")
        NSLog("📦 AnimationLoader: 资源根目录 \(assetRoot)")

        loadAllTextures()
    }

    private func loadAllTextures() {
        guard let manifest = manifest else {
            NSLog("⚠️ AnimationLoader: 未加载 manifest")
            return
        }

        textures.removeAll()
        actionConfigs.removeAll()

        // 以 actions 为准加载每个动作
        for (actionName, actionDef) in manifest.actions {
            loadAsset(named: actionDef.asset, forAction: actionName, actionDef: actionDef)
        }

        // 加载未被 actions 引用的纯资产状态（walk_start_left、sleep_enter 等过渡帧）
        let referencedAssets = Set(manifest.actions.values.map { $0.asset })
        for assetName in manifest.assets.keys where !referencedAssets.contains(assetName) {
            loadAsset(named: assetName, forAction: assetName, actionDef: nil)
        }

        NSLog("🎬 AnimationLoader: 共加载 \(textures.count) 个动画状态")
    }

    private func loadAsset(named assetName: String, forAction actionName: String, actionDef: ActionDefinition?) {
        guard let assetDef = manifest?.assets[assetName] else {
            NSLog("⚠️ AnimationLoader: 资产 '\(assetName)' 不存在")
            return
        }
        guard let framePaths = assetDef.frames[preferredResolution], !framePaths.isEmpty else {
            NSLog("⚠️ AnimationLoader: 资产 '\(assetName)' 无 \(preferredResolution) 分辨率帧")
            return
        }

        var frames: [SKTexture] = []
        for framePath in framePaths {
            let fullPath = "\(assetRoot)/\(framePath)"
            if FileManager.default.fileExists(atPath: fullPath) {
                let texture = SKTexture(imageNamed: fullPath)
                texture.filteringMode = .linear
                frames.append(texture)
            } else {
                NSLog("⚠️ AnimationLoader: 帧文件缺失 \(fullPath)")
            }
        }

        guard !frames.isEmpty else { return }

        textures[actionName] = frames

        let frameDuration: TimeInterval
        if let durationMs = actionDef?.durationMs, durationMs > 0 {
            frameDuration = TimeInterval(durationMs) / Double(frames.count) / 1000.0
        } else {
            frameDuration = 1.0 / 30.0
        }

        actionConfigs[actionName] = ActionAnimationConfig(
            actionName: actionName,
            assetName: assetName,
            frames: frames,
            frameDuration: frameDuration,
            loop: actionDef?.loop ?? true,
            priority: actionDef?.priority ?? 10,
            interruptible: actionDef?.interruptible ?? true,
            returnState: actionDef?.returnState ?? "IDLE"
        )
    }

    // MARK: - 查询接口

    public func getTextures(for actionName: String) -> [SKTexture]? {
        textures[actionName]
    }

    public func getConfig(for actionName: String) -> ActionAnimationConfig? {
        actionConfigs[actionName]
    }

    public func getAllActionNames() -> [String] {
        Array(textures.keys).sorted()
    }

}
