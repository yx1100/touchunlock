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

    /// 两个原始信号，分开留一份只为了日志和排查（判定逻辑见 `passwordFieldIsTarget`）。
    private(set) var secureInputActive = false
    private(set) var secureFieldFocused = false

    /// 是否已获得「辅助功能」授权。未授权时只靠 Secure Event Input 判断。
    private(set) var hasAccessibilityPermission = AXIsProcessTrusted() {
        didSet {
            if hasAccessibilityPermission != oldValue { onPermissionChange?(hasAccessibilityPermission) }
        }
    }

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
        passwordInputFocused = Self.passwordFieldIsTarget(secureInput: secureInputActive,
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
    private static func passwordFieldIsTarget(secureInput: Bool, secureField: Bool, front: String?) -> Bool {
        guard let front else { return secureField }
        // 我们自己窗口里的安全输入框不需要设备代打。
        if front == Bundle.main.bundleIdentifier { return false }
        if secureField { return true }
        if secureInput, front != "com.apple.finder" { return true }
        return false
    }

    private static var secureEventInputActive: Bool { IsSecureEventInputEnabled() }

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

    private static func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
