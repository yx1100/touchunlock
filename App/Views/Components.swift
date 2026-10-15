import DurianCore
import SwiftUI

/// 系统设置风格的小图标：纯色圆角方块加白色符号。
///
/// 各符号不能都用同一个字号：实测（88 点色块、同一个字号、渲染成图片量墨迹包围盒）
/// 同一字号下墨迹高度相差很大——`key.fill` 占 58%，`square.grid.2x2` 只有 43%，
/// 并排放在侧边栏里就显得有的偏大、有的像没居中。所以每个符号带一个修正系数，
/// 把墨迹高度统一到色块的四成半左右，再按实测重心补一点点偏移。
struct IconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 22
    /// 墨迹尺寸修正系数，1 表示基准字号（色块尺寸的 48%）。
    var scale: CGFloat = 1
    /// 墨迹重心相对布局盒的偏移，按色块尺寸归一。
    var nudge: CGSize = .zero

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.48 * scale, weight: .medium))
            .foregroundStyle(.white)
            .offset(x: nudge.width * size, y: nudge.height * size)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(color.gradient)
            }
            .overlay {
                // 顶亮底暗的一道极细描边，让色块有一点厚度，而不是一块死色。
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// 页面顶部的大状态图标：浅色圆底加彩色符号。
struct StatusGlyph: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 52
    var pulsing = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: pulsing)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 版本号

extension Bundle {
    /// 设置页显示的版本号：市场版本，若构建号与它不同则一并带上。
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}

// MARK: - 轻提示

extension Toast.Kind {
    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: toast.kind.symbol)
                .foregroundStyle(toast.kind.color)
            Text(toast.text)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 手动测试指纹的面板

/// 底部常驻的测试面板。外观与 toast 一致，但**不会自动消失**：
/// 只有右边的叉能关掉它，而关掉即代表结束测试（设备那边排队的请求自己超时即可）。
struct FingerprintTestPanel: View {
    let state: FingerprintTest
    let name: (Int) -> String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if state == .waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.kind.color)
                }
            }
            .frame(width: 16, height: 16)

            Text(title)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop Testing")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .waiting: return String(localized: "Place the finger on the sensor.")
        case .matched(let id): return String(localized: "Recognized: \(name(id))")
        case .unmatched: return String(localized: "This finger is not enrolled.")
        case .timedOut: return String(localized: "No finger was detected.")
        }
    }
}

// MARK: - 连接状态

extension BLEState {
    var title: String {
        switch self {
        case .unauthorized: return String(localized: "Bluetooth access denied")
        case .poweredOff: return String(localized: "Bluetooth is off")
        case .unsupported: return String(localized: "Bluetooth is not supported")
        case .idle: return String(localized: "Not connected")
        case .searching: return String(localized: "Searching for the device…")
        case .connecting: return String(localized: "Connecting…")
        case .ready: return String(localized: "Connected")
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "touchid"
        case .searching, .connecting: return "dot.radiowaves.left.and.right"
        case .idle: return "bolt.horizontal.circle"
        case .unauthorized, .poweredOff, .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .searching, .connecting: return .orange
        case .idle: return .secondary
        case .unauthorized, .poweredOff, .unsupported: return .red
        }
    }

    var isWorking: Bool { self == .searching || self == .connecting }
}
