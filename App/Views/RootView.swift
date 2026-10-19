import DurianCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, fingerprints, password, settings, log

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Overview"
        case .fingerprints: return "Fingerprints"
        case .password: return "Password"
        case .settings: return "Settings"
        case .log: return "Log"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .fingerprints: return "touchid"
        case .password: return "key.fill"
        case .settings: return "gearshape.fill"
        case .log: return "text.alignleft"
        }
    }

    var color: Color {
        switch self {
        case .overview: return .blue
        case .fingerprints: return .pink
        case .password: return .orange
        case .settings: return .gray
        case .log: return .indigo
        }
    }

    /// 图标墨迹的尺寸修正，数值由「渲染成图片再量墨迹包围盒」实测反推：
    /// 同一字号下墨迹高度 `key.fill` 58%、`touchid` 51%、`gearshape` 49%、
    /// `square.grid.2x2` 43%、`text.alignleft` 41%，统一到 45% 左右才不会看着大小不一。
    var iconScale: CGFloat {
        switch self {
        case .overview: return 1.06
        case .fingerprints: return 0.90
        case .password: return 0.80
        case .settings: return 0.94
        case .log: return 1.04
        }
    }

    /// 墨迹重心相对布局盒的偏移，按色块尺寸归一（实测约 0.25~0.38 点 / 88 点色块）。
    var iconNudge: CGSize {
        switch self {
        case .overview: return CGSize(width: 0, height: 0.0043)
        case .fingerprints: return CGSize(width: -0.0043, height: 0.0043)
        case .password: return CGSize(width: -0.0028, height: 0.0043)
        case .settings: return CGSize(width: -0.0028, height: 0.0028)
        case .log: return CGSize(width: -0.0043, height: 0)
        }
    }
}

/// 不可见的工具栏占位项。macOS 26 上还要去掉它的玻璃底，否则右上角会露出一道细线。
private struct TitlePlaceholder: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 1, height: 1) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 1, height: 1) }
        }
    }
}

struct RootView: View {
    let model: AppModel
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        IconBadge(systemName: item.symbol, color: item.color,
                                  scale: item.iconScale, nudge: item.iconNudge)
                    }
                    .badge(item == .fingerprints ? model.fingerprintCount : 0)
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus(model: model) }
        } detail: {
            let current = page ?? .overview
            Group {
                switch current {
                case .overview: OverviewPage(model: model, go: { page = $0 })
                case .fingerprints: FingerprintsPage(model: model, go: { page = $0 })
                case .password: PasswordPage(model: model)
                case .settings: SettingsPage(model: model)
                case .log: LogPage(model: model)
                }
            }
            .navigationTitle(current.title)
            // 去掉边栏按钮后工具栏会变空，标题随之缩成小号窗口标题；放一个不可见的占位项保持原来的大标题。
            .toolbar { TitlePlaceholder() }
        }
        .overlay(alignment: .bottom) {
            // 测试面板优先：它不自动消失，必须由用户点叉结束。
            if let test = model.fingerprintTest {
                FingerprintTestPanel(state: test, name: { model.displayName(for: $0) }) {
                    model.endFingerprintTest()
                }
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let toast = model.toast {
                ToastView(toast: toast) { model.dismissToast() }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.fingerprintTest)
        .animation(.spring(duration: 0.35), value: model.toast)
        .sheet(isPresented: Binding(
            get: { model.enroll != .idle },
            set: { if !$0 { model.closeEnroll() } }
        )) {
            EnrollSheet(model: model)
        }
    }
}

/// 侧边栏底部的连接状态，任何页面都看得到。
private struct SidebarStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.bleState.tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.bleState.title)
                    .font(.callout)
                if model.isReady, let version = model.firmwareVersion {
                    Text("Firmware \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
