import AppKit
import CoreGraphics
import DurianCore
import LocalAuthentication

/// 收集要上报给设备的 7 项 Mac 状态（docs/BLE-PROTOCOL.md 第 4 节），状态变化时回调。
@MainActor
final class MacStateMonitor {
    private(set) var state = MacState()
    var onChange: ((MacState) -> Void)?

    private var locked = false
    private var displaySleep = false
    private var systemSleep = false
    private var screensaver = false
    /// 武装位：应用是否允许设备现在键入。应用连上设备期间恒为 true。
    private var allowsTyping = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// 复用同一个 LAContext。状态每次变化都会重算，而新建一个 LAContext 会白白加载
    /// LocalAuthentication 并分配一批对象；这个查询的答案是稳定的，不需要新上下文。
    private let biometrics = LAContext()

    /// 设置武装位。变化时立即重算并上报，不用等下一个心跳。
    func setAllowsTyping(_ on: Bool) {
        guard on != allowsTyping else { return }
        allowsTyping = on
        recompute()
    }

    func start() {
        locked = Self.sessionIsLocked()
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { $0.displaySleep = true }
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { $0.displaySleep = false }
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.systemSleep = true }
        add(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.systemSleep = false }
        add(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { _ in }

        let distributed = DistributedNotificationCenter.default()
        add(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        add(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        add(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaver = true }
        add(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screensaver = false }

        recompute()
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (MacStateMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.recompute()
            }
        }
        observers.append((center, token))
    }

    private func recompute() {
        var s = MacState()
        s.isScreenLocked = locked
        s.isDisplaySleep = displaySleep
        s.isSystemSleep = systemSleep
        s.isScreensaver = screensaver
        // 武装位：应用连上设备期间恒为 true。
        s.allowsTyping = allowsTyping
        s.hasExternalScreen = Self.hasExternalDisplay()
        s.isTouchIDAvailability = biometrics.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        guard s != state else { return }
        state = s
        onChange?(s)
    }

    private static func sessionIsLocked() -> Bool {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        return dict?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
    }
}
