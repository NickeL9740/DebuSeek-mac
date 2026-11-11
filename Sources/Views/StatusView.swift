import SwiftUI

// MARK: - 宠物状态面板

/// 右键菜单「查看状态」弹出的悬浮窗内容。
/// 数据全部来自 PetState.shared（0...100），通过 @EnvironmentObject 实时刷新。
struct StatusView: View {
    @EnvironmentObject private var state: PetState

    /// 由 PetController 注入：关闭悬浮窗（不销毁，方便再次打开）。
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            statusRow(
                title: "饱腹度",
                icon: "leaf.fill",
                value: 100 - state.hunger,
                color: .green
            )
            statusRow(
                title: "心情",
                icon: "heart.fill",
                value: state.happiness,
                color: .pink
            )
            statusRow(
                title: "精力",
                icon: "bolt.fill",
                value: state.energy,
                color: .green
            )

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Circle()
                    .fill(state.mood.color)
                    .frame(width: 8, height: 8)
                Text(state.isSleeping ? "正在睡觉" : "当前心情 \(state.mood.emoji)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("饥饿 \(state.hunger)  ·  心情 \(state.happiness)  ·  精力 \(state.energy)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 340, height: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "fish.fill")
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("大肥鱼状态")
                    .font(.headline)
                Text(state.isSleeping ? "嘘…她在睡觉" : "实时状态 · 每 1 秒刷新")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("关闭状态面板")
            }
        }
    }

    private func statusRow(title: String, icon: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                Spacer()
                Text("\(value) / 100")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ProgressView(value: Double(value), total: 100)
                .progressViewStyle(.linear)
                .tint(color)
        }
    }
}
