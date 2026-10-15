import AppKit
import SwiftUI

/// 提示的语气，决定图标与颜色。
enum HUDKind {
    case success, info, warning, error

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// 屏幕顶部居中的小提示：macOS 26 起用 Liquid Glass，旧系统退回毛玻璃。
///
/// 不抢焦点、不拦鼠标、不参与窗口循环，1.8 秒后自动淡出。用于「按压识别器之后
/// 立刻要知道结果」的反馈；需要用户处理的问题仍然用应用窗口里的 toast。
@MainActor
final class HUD {
    /// 设置里可关。
    var isEnabled = true

    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDContent>?
    private var hideTask: Task<Void, Never>?

    private let visibleDuration = Duration.milliseconds(1800)

    func show(_ text: String, kind: HUDKind) {
        guard isEnabled else { return }
        let panel = panel ?? makePanel()
        let hosting = hosting ?? makeHosting()
        hosting.rootView = HUDContent(text: text, kind: kind)
        panel.contentView = hosting

        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        let duration = visibleDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // 点不到，也就不可能抢走输入焦点
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func makeHosting() -> NSHostingView<HUDContent> {
        let hosting = NSHostingView(rootView: HUDContent(text: "", kind: .info))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        self.hosting = hosting
        return hosting
    }

    /// 放在鼠标所在那块屏幕的顶部居中；那块屏通常就是用户正在看的那块。
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.maxY - size.height - 12))
    }
}

private struct HUDContent: View {
    let text: String
    let kind: HUDKind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .modifier(HUDBackground())
        .accessibilityElement(children: .combine)
    }
}

/// macOS 26 起用 Liquid Glass；更早的系统退回系统毛玻璃，保证同一份代码都能编译运行。
private struct HUDBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}
