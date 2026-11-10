import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 判断「当前是不是有窗口在等密码」，用来决定设备该不该武装。
///
/// 两个信号取或：
/// 1. 系统处于 **Secure Event Input**——绝大多数密码输入框、终端里的密码提示都会开启它；
/// 2. 辅助功能 API 报告焦点元素是安全文本输入框（`AXSecureTextField`）。
///
/// 第 2 条需要「辅助功能」授权；未授权时只用第 1 条，仍能覆盖大多数需要密码的场景。
/// 轮询而不是 AXObserver：焦点变化的通知在跨进程场景下丢事件的情况更多，
/// 0.35 秒一次的单次 AX 查询开销可以忽略。
@MainActor
final class FocusMonitor {
    /// 焦点所在处需要密码。变化时回调。
    private(set) var passwordInputFocused = false {
        didSet { if passwordInputFocused != oldValue { onChange?(passwordInputFocused) } }
    }

    /// 系统授权弹窗正在屏幕上（见 `authDialogBundleIDs`）。这类弹窗收不住设备一口气
    /// 发完的整串按键，所以这时由应用自己逐字代打密码（见 `AppModel.typeIntoAuthDialog`）。
    private(set) var authDialogVisible = false {
        didSet { if authDialogVisible != oldValue { onChange?(passwordInputFocused) } }
    }

    /// 两个原始信号，分开留一份只为了日志和排查（判定逻辑见 `passwordFieldIsTarget`）。
    private(set) var secureInputActive = false
    private(set) var secureFieldFocused = false

    /// 是否已获得「辅助功能」授权。未授权时只靠 Secure Event Input 判断。
    private(set) var hasAccessibilityPermission = AXIsProcessTrusted() {
        didSet {
            if hasAccessibilityPermission != oldValue { onPermissionChange?(hasAccessibilityPermission) }
        }
    }

    /// 位于前台时不响应的应用（bundle id）。
    var ignoredBundleIDs: Set<String> = []

    var onChange: ((Bool) -> Void)?
    var onPermissionChange: ((Bool) -> Void)?

    private var timer: Timer?

    /// 拉起一次系统授权弹窗。用户拒绝过之后只能去系统设置里改。
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var accessibilityPermissionGranted: Bool { AXIsProcessTrusted() }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common 模式：菜单打开、拖窗口时也要继续判断，否则武装状态会停在旧值。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        secureInputActive = Self.secureEventInputActive
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // 当前台不是我们自己、也不是 Finder 时，Secure Event Input 一旦为真结论就已经确定，
        // 不必再发 AX 查询——密码输入场景下可以省掉每 0.35 秒一次的 AX 调用与分配。
        secureFieldFocused = Self.secureInputDecides(secureInput: secureInputActive, front: front)
            ? false
            : Self.focusedElementIsSecureField()
        authDialogVisible = Self.authDialogWindowVisible
        passwordInputFocused = authDialogVisible
            || passwordFieldIsTarget(secureInput: secureInputActive,
                                     secureField: secureFieldFocused,
                                     front: front)
    }

    /// Secure Event Input 是否足以单独定论：它只在「前台不是 TouchUnlock 自己、
    /// 也不是 Finder」时才作数。终端里的 sudo 提示是前台应用自己开的，照常认。
    private static func secureInputDecides(secureInput: Bool, front: String?) -> Bool {
        guard let front else { return secureInput }
        return secureInput && front != Bundle.main.bundleIdentifier && front != "com.apple.finder"
    }

    /// 前台是不是真的在等密码。
    ///
    /// 两个信号取或，但都要先过一道「前台应用」的过滤：
    /// - `AXSecureTextField` 是精确信号，只在真正的安全输入框上成立；
    /// - Secure Event Input 是**全局**标志，任何进程都能开、也可能长时间不关。实测在桌面上
    ///   什么都没有时它也会为真，于是设备以为有人在等密码而照实输入（字符落进空气里），
    ///   弹窗还报「密码已输入」。所以只在「前台不是 TouchUnlock 自己、也不是 Finder」时才认它：
    ///   终端里的 sudo 提示仍然是前台应用自己开的 Secure Event Input，照常能认出来。
    private func passwordFieldIsTarget(secureInput: Bool, secureField: Bool, front: String?) -> Bool {
        // 没有 bundle id 的前台进程（如 osascript 弹出的密码框）也认 Secure Event Input。
        guard let front else { return secureField || secureInput }
        if ignoredBundleIDs.contains(front) { return false }
        // 我们自己窗口里的安全输入框不需要设备代打。
        if front == Bundle.main.bundleIdentifier { return false }
        if secureField { return true }
        if secureInput, front != "com.apple.finder" { return true }
        return false
    }

    private static var secureEventInputActive: Bool { IsSecureEventInputEnabled() }

    /// 显示系统授权弹窗的进程：
    /// - SecurityAgent：需要管理员密码的授权（安装软件、改系统级设置等）；
    /// - LocalAuthenticationRemoteService：本地认证弹窗，系统设置里改隐私与安全项、
    ///   通行密钥要电脑密码时都走它（实测系统设置的密码弹窗就是它）。
    static let authDialogBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthenticationRemoteService",
    ]
    private static let authDialogOwnerNames: Set<String> = [
        "SecurityAgent",
        "LocalAuthenticationRemoteService",
    ]

    /// 屏幕上有没有授权弹窗的窗口。这类弹窗不一定成为前台应用，SecurityAgent 的输入框
    /// 辅助功能也看不到，所以直接看窗口归属。读窗口所属进程不需要「屏幕录制」授权。
    /// 进程名可能被本地化，所以同时按进程号对照 bundle id；透明窗口不算。
    private static var authDialogWindowVisible: Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let dialogPIDs = Set(authDialogBundleIDs.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        })
        return windows.contains { window in
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 { return false }
            if let name = window[kCGWindowOwnerName as String] as? String, authDialogOwnerNames.contains(name) {
                return true
            }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return dialogPIDs.contains(pid)
        }
    }

    /// 轮询每 0.35 秒跑一次，AX 元素和属性名都缓存成常量：
    /// 原先每次都要新建一个 system-wide 元素、并把若干个 Swift 字符串桥接成 CFString。
    private static let systemWide = AXUIElementCreateSystemWide()
    private static let focusedElementAttribute = kAXFocusedUIElementAttribute as CFString
    private static let subroleAttribute = kAXSubroleAttribute as CFString
    private static let roleAttribute = kAXRoleAttribute as CFString

    private static func focusedElementIsSecureField() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, focusedElementAttribute, &focused) == .success,
              let element = focused else { return false }
        let ax = element as! AXUIElement
        if let subrole = copyString(ax, subroleAttribute), subrole == kAXSecureTextFieldSubrole {
            return true
        }
        // 少数实现只给 role，不给 subrole。
        return copyString(ax, roleAttribute) == kAXSecureTextFieldSubrole
    }

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSecureTextFieldSubrole,
    ]

    /// 键盘焦点是否落在授权弹窗**以外**的文字输入框里。
    ///
    /// 授权弹窗代打密码前用它把关：SecurityAgent 的输入框对辅助功能不可见，
    /// 所以没法正面确认「焦点在弹窗里」，只能反过来排除「焦点在别处的输入框里」。
    /// 查不到焦点元素（多半正是焦点在 SecurityAgent 弹窗里）时返回 false。
    static func textInputFocusedOutsideAuthDialog() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, focusedElementAttribute, &focused) == .success,
              let element = focused else { return false }
        let ax = element as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(ax, &pid) == .success,
           let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           authDialogBundleIDs.contains(owner) {
            return false
        }
        let role = copyString(ax, roleAttribute) ?? ""
        let subrole = copyString(ax, subroleAttribute) ?? ""
        return textInputRoles.contains(role) || textInputRoles.contains(subrole)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
