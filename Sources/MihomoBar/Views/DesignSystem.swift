import SwiftUI

// MARK: - 卡片容器

/// 内容分组卡片。macOS 常规应用的视觉基本单元。
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(title: String? = nil,
         systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = nil
        self.content = content()
    }

    init<A: View>(title: String?,
                  systemImage: String? = nil,
                  @ViewBuilder accessory: () -> A,
                  @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Spacer(minLength: 8)
                    if let accessory { accessory }
                }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 9)
                Divider().padding(.horizontal, 14)
            }
            content
                .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - 状态指示

struct StatusDot: View {
    enum Level { case ok, warn, off, error }
    let level: Level

    var color: Color {
        switch level {
        case .ok:    return .green
        case .warn:  return .orange
        case .off:   return Color(nsColor: .tertiaryLabelColor)
        case .error: return .red
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).scaleEffect(1.6))
    }
}

/// 一行「标签 — 值」，右侧可带控件
struct InfoRow<Trailing: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var trailing: Trailing

    init(_ label: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.hint = hint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13))
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// `InfoRow` 右侧的默认值文本。
/// 单独抽成类型而不是在 extension 里用 `Text` —— 加了修饰符后类型就变成 `some View`，
/// 不再能匹配 `Trailing == Text` 的泛型约束。
struct InfoValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

extension InfoRow where Trailing == InfoValue {
    init(_ label: String, value: String, hint: String? = nil) {
        self.init(label, hint: hint) { InfoValue(text: value) }
    }
}

// MARK: - 指标块

/// 概览页的指标方块（流量速率等）
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - 页面骨架

struct PaneScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 空状态占位
struct EmptyHint: View {
    let systemImage: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - 延迟配色

enum DelayStyle {
    static func color(_ ms: Int?) -> Color {
        guard let ms else { return Color(nsColor: .tertiaryLabelColor) }
        if ms <= 0 { return .red }
        if ms < 150 { return .green }
        if ms < 400 { return .orange }
        return .red
    }

    static func text(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms <= 0 ? "超时" : "\(ms) ms"
    }
}
