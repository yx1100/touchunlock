import AppKit
import DurianCore
import Observation
import ServiceManagement

enum EnrollState: Equatable {
    case idle
    case starting(id: Int)
    case progress(id: Int, step: Int, total: Int)
    case binding(id: Int)
    case done(id: Int)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .progress, .binding: return true
        case .idle, .done, .failed: return false
        }
    }
}

/// 短暂的状态提示，几秒后自动消失。
struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, warning, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// 手动测试指纹的进度。面板要一直挂到用户点叉，所以状态留在模型里，
/// 而不是用会自动消失的 toast。
enum FingerprintTest: Equatable {
    /// 已发出识别请求，等手指。
    case waiting
    /// 识别成功，附指纹编号（界面上让对应那一行闪一下）。
    case matched(Int)
    /// 有手指按下，但没录入过。
    case unmatched
    /// 传感器没等到手指。
    case timedOut

    var kind: Toast.Kind {
        switch self {
        case .waiting: return .info
        case .matched: return .success
        case .unmatched, .timedOut: return .warning
        }
    }

    var symbol: String {
        switch self {
        case .waiting: return "hand.point.up.left.fill"
        case .matched: return "checkmark.circle.fill"
        case .unmatched: return "questionmark.circle.fill"
        case .timedOut: return "clock.badge.questionmark"
        }
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var bleState: BLEState = .idle
    private(set) var deviceName: String?
    private(set) var firmwareVersion: String?
    private(set) var fingerprints: FingerprintInfo?
    private(set) var enroll: EnrollState = .idle
    private(set) var toast: Toast?
    /// 手动测试的进度；非 nil 时底部显示测试面板，面板不自动消失。
    private(set) var fingerprintTest: FingerprintTest?
    /// 刚识别到的那一枚，用来让它所在的那一行闪一下。
    private(set) var flashingFingerprint: Int?
    @ObservationIgnored private var flashTimer: Timer?
    @ObservationIgnored private var testDismissTimer: Timer?
    private(set) var hasStoredPassword = PasswordStore.exists()
    private(set) var macState = MacState()
    /// 系统是否已为设备创建蓝牙键盘；false 时设备键入的密码无人接收。
    private(set) var keyboardLinked = KeyboardLink.isPresent()
    private(set) var logLines: [String] = []
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// 是否在程序坞显示图标。默认显示；关闭后只留菜单栏图标。
    private(set) var showDockIcon = UserDefaults.standard.object(forKey: "TouchUnlock.showDockIcon") as? Bool ?? true

    /// 位于前台时设备不键入的应用（bundle id）。
    private(set) var ignoredApps = UserDefaults.standard.stringArray(forKey: "TouchUnlock.ignoredApps") ?? []

    @ObservationIgnored private let client = BLEClient()
    @ObservationIgnored private let monitor = MacStateMonitor()
    /// 前台是否有窗口在等密码。决定未锁屏时设备该不该键入。
    @ObservationIgnored private let focus = FocusMonitor()
    /// 屏幕顶部的提示面板。
    @ObservationIgnored let hud = HUD()
    /// 设置默认密码期间暂存，设备确认成功后才写入钥匙串，用完即清。
    @ObservationIgnored private var pendingPassword: String?
    @ObservationIgnored private var rebindQueue: [Int] = []
    /// 在等的密码写入。设备的 pw=5/6 回包**不带 id**，所以必须自己记住在等哪一条。
    @ObservationIgnored private var pendingBind: PendingBind?
    /// 密码重绑链的状态。指纹页会按它禁用「添加指纹」并给出页脚提示，
    /// 所以这两个不加 `@ObservationIgnored`，改动要能触发视图更新。
    private var rebinding = false
    /// 还差一份指纹列表才能开始重绑（改密码时列表尚未取到）。
    private var rebindAfterInfoRefresh = false
    /// 这一轮重绑下发的密码是「系统密码」还是「各指纹自己的密码」。
    /// 设备当前是否处于武装状态（激活位已置）。避免重复下发 ble=1 / ble=2。
    @ObservationIgnored private var deviceArmed = false
    /// 心跳期间持有的活动凭证。没有它，只驻菜单栏的应用会被系统节流（App Nap），
    /// 0.7 秒的定时器可能被拉长到超过固件 2 秒的超时，设备就会时断时续地停止键入。
    @ObservationIgnored private var heartbeatActivity: NSObjectProtocol?
    /// 最近一次武装的时刻。设备键入要花几百毫秒，期间焦点可能已经变了，
    /// 所以判断「这次键入是不是我们让它做的」不能只看当下的 deviceArmed。
    @ObservationIgnored private var lastArmedAt: Date?
    /// 指示灯是否正在慢闪。
    @ObservationIgnored private var indicatorPulsing = false
    @ObservationIgnored private var indicatorTimer: Timer?
    /// 设备上的密码是否已切到「锁屏档案」（所有指纹都绑系统密码）。
    @ObservationIgnored private var started = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// 心跳计时器：定期向设备发消息。固件据此判断应用是否仍在运行。
    @ObservationIgnored private var heartbeat: Timer?
    /// 密码写入的单步超时：设备不回包时放掉状态，而不是把界面卡死。
    @ObservationIgnored private var writeTimeout: Timer?

    /// 一次只允许一条密码写入在飞。
    private enum PendingBind: Equatable {
        case enroll(id: Int)   // 录入成功后绑定密码
        case rebind            // 系统密码变了，逐个更新已录入指纹
        case manual(id: Int)   // 界面上给某枚指纹单独设密码

        var label: String {
            switch self {
            case .enroll(let id): return "enroll(\(id))"
            case .rebind: return "rebind"
            case .manual(let id): return "manual(\(id))"
            }
        }
    }

    var isReady: Bool { bleState == .ready }
    var fingerprintCount: Int { fingerprints?.registeredIds.count ?? 0 }
    /// 正在把新密码逐个写到已录入的指纹上。此时不能开始新的录入，否则两条
    /// 密码写入链同时在飞，设备的回包不带 id，结果会认错。
    var isRebinding: Bool { rebinding || rebindAfterInfoRefresh }
    /// 是否显示屏幕顶部的提示面板。
    var showHUD = UserDefaults.standard.object(forKey: "TouchUnlock.showHUD") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showHUD, forKey: "TouchUnlock.showHUD")
            hud.isEnabled = showHUD
        }
    }
    /// 有窗口在等密码时让识别器的指示灯慢闪。
    var showIndicator = UserDefaults.standard.object(forKey: "TouchUnlock.showIndicator") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showIndicator, forKey: "TouchUnlock.showIndicator")
            refreshIndicator()
        }
    }

    /// 辅助功能授权状态。焦点监视每次轮询都会刷新，这里镜像一份给界面用。
    private(set) var hasAccessibilityPermission = FocusMonitor.accessibilityPermissionGranted

    /// 菜单栏图标：正常时是指纹，需要用户处理时换成警告。
    var menuBarSymbol: String {
        switch bleState {
        case .ready: return keyboardLinked ? "touchid" : "exclamationmark.triangle"
        case .searching, .connecting: return "dot.radiowaves.left.and.right"
        case .unauthorized, .poweredOff, .unsupported: return "exclamationmark.triangle"
        case .idle: return "touchid"
        }
    }

    // MARK: 启动

    func start() {
        guard !started else { return }
        started = true

        client.onLog = { [weak self] in self?.log("ble: \($0)") }
        client.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.bleStateChanged(state) }
        }
        client.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        monitor.onChange = { [weak self] state in
            MainActor.assumeIsolated { self?.macStateChanged(state) }
        }
        focus.onChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshArmedState() }
        }
        focus.onPermissionChange = { [weak self] granted in
            MainActor.assumeIsolated { self?.hasAccessibilityPermission = granted }
        }

        focus.ignoredBundleIDs = Set(ignoredApps)
        applyDockPolicy()
        hud.isEnabled = showHUD
        monitor.start()
        focus.start()
        client.start()

        // 配对状态没有通知，轮询注册表。
        let linkTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyboardLink() }
        }
        // 用 .common 模式：菜单打开、拖窗口、滚动时主 run loop 会切到 eventTracking，
        // 只挂在 .default 上的计时器在这些时候不会触发。
        RunLoop.main.add(linkTimer, forMode: .common)
    }

    private func refreshKeyboardLink() {
        // 键盘链路只影响「已连接」时的状态图标和警告；没连设备时不必去查 IORegistry。
        guard isReady else { return }
        let linked = KeyboardLink.isPresent()
        guard linked != keyboardLinked else { return }
        keyboardLinked = linked
        log("keyboard link: \(linked ? "present" : "missing")")
    }

    // MARK: 提示

    private func post(_ kind: Toast.Kind, _ text: String) {
        toastTask?.cancel()
        toast = Toast(kind: kind, text: text)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    // MARK: 设备连接

    func reconnect() { client.stop(); client.start() }

    func disconnect() {
        leaveAssistMode { [weak self] in self?.client.stop() }
    }

    func forgetDevice() {
        firmwareVersion = nil
        fingerprints = nil
        leaveAssistMode { [weak self] in self?.client.forgetDevice() }
    }

    /// 离开前发 assistOff，清掉设备的「激活」标志，设备立即回到不键入状态。
    /// 返回 true 表示写入已发出。`completion` 在设备确认、链路断开或超时（1 秒）后回调一次，
    /// 调用方据此等到写入落地再断开，而不是猜一个固定延时。
    @discardableResult
    func leaveAssistMode(completion: (() -> Void)? = nil) -> Bool {
        guard isReady else {
            completion?()
            return false
        }
        stopHeartbeat()
        stopIndicator()
        sendIndicator(colorType: Self.indicatorOff, count: 1)   // 退出前把灯熄掉
        do {
            try client.send(.assistOff, completion: completion)
            return true
        } catch {
            log("send failed: \(error)")
            completion?()
            return false
        }
    }

    func refreshDevice() {
        send(.queryVersion)
        send(.queryFingerprints)
    }

    func pairDevice() { send(.pair) }

    private func bleStateChanged(_ state: BLEState) {
        bleState = state
        deviceName = client.deviceName
        if state == .ready {
            // 设备可能残留上一次会话的激活位，连上后显式下发一次当前该有的状态。
            deviceArmed = !currentArmedState
            refreshArmedState()
            sendMacReport()
            startHeartbeatIfArmed()
            refreshDevice()
        } else {
            stopHeartbeat()
            stopIndicator()          // 断了就停闪灯；设备那边 2 秒后也会自己回到不键入
            endFingerprintTest()     // 测试没结果了，面板收起来
            if enroll.isBusy {
                enroll = .failed(String(localized: "The connection to the device was lost."))
            }
            resetPasswordOperations()
        }
    }

    /// 断线后丢弃没走完的密码操作：设备回包不带 id，重连后一条无关的回包
    /// 会被当成上一轮的结果，链子会卡在半路。
    private func resetPasswordOperations() {
        pendingPassword = nil
        pendingBind = nil
        abandonRebind("connection lost during a password update")
    }

    /// 放弃剩余的重绑。已录入的指纹里有一部分可能还是旧密码，必须告诉用户。
    private func abandonRebind(_ reason: String) {
        let wasUpdating = isRebinding
        rebindQueue.removeAll()
        rebinding = false
        rebindAfterInfoRefresh = false
        pendingBind = nil
        cancelWriteTimeout()
        guard wasUpdating else { return }
        log(reason)
        post(.warning, String(localized: "Some fingerprints were not updated. Save the password again."))
    }

    /// 向设备发一次 Mac 状态；也兼作心跳，刷新固件的「最近收到消息」时间戳。
    /// 心跳（`quiet`）不进日志：0.7 秒一条会把日志里的有用信息冲掉。
    private func sendMacReport(quiet: Bool = false) {
        guard isReady else { return }
        send(.reportMacState(macState), quiet: quiet)
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendMacReport(quiet: true) }
        }
        // .common 模式：菜单打开、拖窗口、滚动时心跳照发，否则固件的 2 秒超时会让
        // 设备停止键入，用户按压指纹没有反应。
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        if heartbeatActivity == nil {
            heartbeatActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Heartbeat to the fingerprint device")
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let activity = heartbeatActivity { ProcessInfo.processInfo.endActivity(activity) }
        heartbeatActivity = nil
    }

    /// 连上时按当前武装状态决定要不要起心跳（`refreshArmedState` 已在前面跑过，
    /// 多数情况下这里什么都不用做，只是个兜底）。
    private func startHeartbeatIfArmed() {
        guard isReady, currentArmedState, heartbeat == nil else { return }
        startHeartbeat()
    }

    private func send(_ request: DeviceRequest, quiet: Bool = false, completion: (() -> Void)? = nil) {
        do {
            try client.send(request, quiet: quiet, completion: completion)
        } catch {
            log("send failed: \(error)")
            if !quiet { post(.warning, String(localized: "The device is not connected.")) }
            completion?()
        }
    }

    // MARK: Mac 状态

    private func macStateChanged(_ state: MacState) {
        macState = state
        // 锁屏、屏保状态变化后重新上报，并重算武装位。
        refreshArmedState()
        sendMacReport()
        // 锁屏期间设备必须输入系统密码（需求 3），解锁后恢复各自单独设置的密码。
    }

    /// 武装位 = 设备现在该不该键入。
    ///
    /// - 锁屏或屏保：恒为 true。设备用系统密码解锁锁屏，
    ///   这类场景 app 看不到也不需要看到前台窗口。
    /// - 未锁屏：只看前台有没有正在等密码的输入框。没有就不武装，
    ///   设备即使识别成功也不会往任何窗口里键入。
    /// 应用没有运行时设备从不键入：退出发 `assistOff`，崩溃则心跳超时。
    private func refreshArmedState() {
        let armed = currentArmedState
        monitor.setAllowsTyping(armed)
        setDeviceArmed(armed)
        refreshIndicator()
    }
    private var currentArmedState: Bool {
        monitor.state.isScreenLocked || monitor.state.isScreensaver || focus.passwordInputFocused
    }

    /// 让设备开始或停止键入。
    ///
    /// `ble=1` 置激活位、`ble=2` 清它，两条都是一次写入即时生效——比只靠心跳超时
    /// （2 秒）干净得多，也不需要改固件。心跳照常一直发：固件要求激活位与心跳新鲜
    /// 同时成立才键入，心跳停了 2 秒后即使激活位还在也不会键入（应用崩溃时的兜底）。
    private func setDeviceArmed(_ armed: Bool) {
        guard armed != deviceArmed else { return }
        deviceArmed = armed
        if armed { lastArmedAt = .now }
        // 把触发原因一起记下来：误判时只看「armed/disarmed」根本查不出是哪个信号。
        log("device \(armed ? "armed: it may type" : "disarmed: it stays silent")"
            + " [locked: \(monitor.state.isScreenLocked), screensaver: \(monitor.state.isScreensaver),"
            + " secureInput: \(focus.secureInputActive), secureField: \(focus.secureFieldFocused)]")
        send(armed ? .assistOn : .assistPause, quiet: true)
        // 心跳只为了让固件知道「应用还在」；不武装时没有需要键入的东西，
        // 停掉它可以把每秒两条的蓝牙流量降到零。武装瞬间的 ble=1 与状态上报
        // 本身就会刷新固件的时间戳，所以不必提前预热。
        if armed { startHeartbeat() } else { stopHeartbeat() }
    }

    /// 指示灯：未锁屏、且前台有窗口在等密码时闪，表示「现在按指纹就会输入」。
    ///
    /// 锁屏时不闪：那时候没人盯着识别器，整夜闪灯既费电又扰人；锁屏能不能解锁
    /// 本来就由系统密码兜底。实测色值见 `DeviceRequest.setIndicator`。
    ///
    /// 触发方式很关键：真机实测发现**在灯效还没播完时反复下发指令**会把效果引擎推进
    /// 循环状态（压测结束后灯一直闪，直到下一条「熄灭」才停）。所以只在状态切换时
    /// 下发一条长闪序列，解除时显式熄灭，不在播放期间补发。
    private func refreshIndicator() {
        let shouldPulse = isReady && showIndicator && focus.passwordInputFocused && !monitor.state.isScreenLocked
        guard shouldPulse != indicatorPulsing else { return }
        indicatorPulsing = shouldPulse
        log("indicator \(shouldPulse ? "pulsing: a window is waiting for a password" : "off")")
        if shouldPulse {
            sendIndicator(colorType: Self.indicatorReady, count: Self.indicatorBlinks)
            let timer = Timer(timeInterval: Self.indicatorRefresh, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendIndicator(colorType: Self.indicatorReady, count: Self.indicatorBlinks) }
            }
            RunLoop.main.add(timer, forMode: .common)
            indicatorTimer = timer
        } else {
            indicatorTimer?.invalidate()
            indicatorTimer = nil
            sendIndicator(colorType: Self.indicatorOff, count: 1)      // 熄灭
        }
    }

    private func stopIndicator() {
        indicatorPulsing = false
        indicatorTimer?.invalidate()
        indicatorTimer = nil
    }

    private func sendIndicator(colorType: Int, count: Int) {
        guard isReady else { return }
        send(.setIndicator(colorType: colorType, count: count), quiet: true)
    }

    /// 真机实测的色值：0 熄灭、1 蓝、2 绿、3 青、4 红、5 紫；count 是闪烁次数。
    private static let indicatorOff = 0
    private static let indicatorReady = 3
    private static let indicatorSuccess = 2
    /// 一条指令里包含的闪烁次数。实测一次闪烁约 0.3 秒，120 次约 36 秒。
    private static let indicatorBlinks = 120
    /// 武装期间重新下发的间隔，比上一次闪完（约 36 秒）再晚一点。
    private static let indicatorRefresh: TimeInterval = 45

    // MARK: 常驻识别

    // 这里曾经有一条「常驻识别请求」（每约 13 秒发一次 fp=14，用来拿识别结果做提示）。
    // 真机实测证明它有害，已删除，原因记录在此以免以后有人再加回来：
    //
    //   +0.00s  发送 identify
    //   +2.09s  发送 queryVersion
    //   +8.73s  设备才回 identifyTimeout
    //   +9.28s  设备才回 version —— 版本查询被识别请求堵了 7.2 秒
    //
    // 也就是说设备的 BLE 消息是**串行处理**的，一条识别请求会让它在约 9 秒内不处理
    // 任何其他消息：app 发出的设密码请求会一直排队（界面看起来毫无反应）、心跳被排队
    // 导致固件判定「应用不在」而拒绝键入，连续请求还会把设备彻底卡死（要复位才能恢复）。
    //
    // 代价：设备不主动上报识别结果，所以未武装时按指纹、以及「这根手指没录入」这两类
    // 反馈拿不到。功能上的验证改用指纹页的「测试」按钮（用户主动发一次请求），
    // 「有没有窗口在等密码」则由指示灯表达。

    // MARK: 密码

    /// 把默认密码发给设备；设备确认后写入钥匙串，并重新绑定到已有的指纹。
    func setPassword(_ password: String) {
        guard PasswordPolicy.isValid(password) else {
            post(.warning, String(localized: "Use 1 to \(PasswordPolicy.maxLength) printable ASCII characters."))
            return
        }
        guard isReady else {
            post(.warning, String(localized: "The device is not connected."))
            return
        }
        pendingPassword = password
        // 设备忙的时候（例如正卡在一次识别或录入里）这条写入会排队，可能几十秒都没有回包。
        // 没有超时的话界面一直毫无反应，用户只会以为「点了没反应」。
        scheduleWriteTimeout { [weak self] in self?.defaultPasswordTimedOut() }
        send(.setDefaultPassword(password))
    }

    private func defaultPasswordTimedOut() {
        guard pendingPassword != nil else { return }
        pendingPassword = nil
        log("no reply for the default password write")
        post(.warning, String(localized: "The device did not confirm the password."))
    }

    func removeStoredPassword() {
        PasswordStore.delete()
        hasStoredPassword = false
        post(.info, String(localized: "Removed the copy on this Mac. The device keeps its own copy."))
    }

    /// 删除指纹前的本机确认；没有存密码副本时不做确认。
    private func confirmsPassword(_ input: String) -> Bool {
        guard let stored = PasswordStore.load() else { return true }
        return stored == input
    }

    // MARK: 每枚指纹自己的密码

    /// 指纹名字。只保存在这台 Mac 上：设备的指纹列表只有编号，没有名字字段，
    /// 所以改名不会同步到设备，换一台电脑也不会带过去。
    private(set) var fingerprintNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: "TouchUnlock.fingerprintNames") as? [String: String] ?? [:]

    /// 界面上显示的名字：改过就用改过的，否则用编号。
    func displayName(for id: Int) -> String {
        fingerprintNames[String(id)] ?? String(localized: "Fingerprint \(id)")
    }

    /// 改名。传空字符串即恢复默认的「指纹 N」。
    func rename(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            fingerprintNames[String(id)] = nil
        } else {
            fingerprintNames[String(id)] = String(trimmed.prefix(40))
        }
        UserDefaults.standard.set(fingerprintNames, forKey: "TouchUnlock.fingerprintNames")
    }

    // MARK: 指纹触发的快捷键

    /// 每枚指纹绑定的快捷键。同样只保存在这台 Mac 上。
    private(set) var fingerprintShortcuts: [String: Shortcut] =
        UserDefaults.standard.data(forKey: "TouchUnlock.fingerprintShortcuts")
            .flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]

    func shortcut(for id: Int) -> Shortcut? { fingerprintShortcuts[String(id)] }

    /// 绑定快捷键。传 nil 即清除。
    func setShortcut(_ shortcut: Shortcut?, for id: Int) {
        fingerprintShortcuts[String(id)] = shortcut
        if let data = try? JSONEncoder().encode(fingerprintShortcuts) {
            UserDefaults.standard.set(data, forKey: "TouchUnlock.fingerprintShortcuts")
        }
    }

    /// 设备识别到指纹、但没有键入密码时上报编号；这里发出该指纹绑定的快捷键。
    private func fireShortcut(for id: Int) {
        guard let shortcut = shortcut(for: id) else { return }
        guard hasAccessibilityPermission else {
            post(.warning, String(localized: "Shortcut not sent: allow Device Control and Data Access first."))
            return
        }
        log("shortcut for fingerprint \(id): \(shortcut.display)")
        shortcut.post()
    }

    /// 这枚指纹单独绑定的密码；nil 表示它跟随系统密码。
    func customPassword(for id: Int) -> String? {
        PasswordStore.load(account: PasswordStore.fingerprintAccount(id))
    }

    /// 这枚指纹是否单独设过密码（界面上用来显示「跟随系统密码 / 单独设置」）。
    func hasCustomPassword(_ id: Int) -> Bool {
        PasswordStore.exists(account: PasswordStore.fingerprintAccount(id))
    }

    /// 给某枚指纹单独设置密码：先存本机钥匙串，再下发给设备（pw=4）。
    /// 锁屏时设备用系统密码，这个设置只在未锁屏、且前台有密码输入框时生效。
    func setCustomPassword(_ password: String, for id: Int) {
        guard PasswordPolicy.isValid(password) else {
            post(.warning, String(localized: "Use 1 to \(PasswordPolicy.maxLength) printable ASCII characters."))
            return
        }
        guard isReady else {
            post(.warning, String(localized: "The device is not connected."))
            return
        }
        guard beginPasswordWrite(.manual(id: id)) else { return }
        do {
            try PasswordStore.save(password, account: PasswordStore.fingerprintAccount(id))
        } catch {
            pendingBind = nil
            cancelWriteTimeout()
            log("keychain save failed: \(error)")
            post(.error, String(localized: "Could not save the password to the keychain."))
            return
        }
        send(.setPassword(id: id, password: password))
    }

    /// 让这枚指纹改回「跟随系统密码」：删掉单独设置的副本，再把系统密码绑给它。
    func useSystemPassword(for id: Int) {
        PasswordStore.delete(account: PasswordStore.fingerprintAccount(id))
        guard let system = PasswordStore.load() else {
            post(.warning, String(localized: "Set the unlock password first."))
            return
        }
        guard isReady else {
            post(.warning, String(localized: "The device is not connected."))
            return
        }
        guard beginPasswordWrite(.manual(id: id)) else { return }
        send(.setPassword(id: id, password: system))
    }

    // MARK: 指纹

    func startEnroll() {
        guard isReady, !enroll.isBusy else { return }
        guard !isRebinding else {
            post(.info, String(localized: "Still updating the enrolled fingerprints. Try again in a moment."))
            return
        }
        guard hasStoredPassword else {
            post(.warning, String(localized: "Set the unlock password first."))
            return
        }
        guard let id = (fingerprints ?? FingerprintInfo(registeredIds: [])).nextFreeID else {
            post(.warning, String(localized: "There is no free fingerprint slot."))
            return
        }
        enroll = .starting(id: id)
        send(.startEnroll(id: id, rejectDuplicate: true))
    }

    func cancelEnroll() { send(.cancelEnroll) }

    /// 关闭录入弹窗。录入进行中不能关，要先取消。
    func closeEnroll() {
        if !enroll.isBusy { enroll = .idle }
    }

    /// 删除指纹。已保存密码副本时必须先输入解锁密码确认。
    func deleteFingerprint(_ id: Int, confirming input: String) {
        guard confirmsPassword(input) else {
            post(.error, String(localized: "The password is incorrect."))
            return
        }
        send(.deleteFingerprint(id: id))
    }

    /// 开始一次手动测试：发一条「识别任意指纹」的请求，面板挂在那里等结果。
    ///
    /// 设备不主动上报识别结果，只有收到请求时才回一次，所以测试必须由用户主动发起；
    /// 而一条识别请求会让设备约 9 秒不处理其他消息，因此不做常驻轮询。
    func startFingerprintTest() {
        guard isReady else {
            post(.warning, String(localized: "The device is not connected."))
            return
        }
        testDismissTimer?.invalidate()
        testDismissTimer = nil
        flashingFingerprint = nil
        fingerprintTest = .waiting
        send(.identify(targetId: nil))
    }

    /// 结束测试：用户点了面板上的叉、结果展示够了、或者设备断开了。
    /// 设备那边已经排队的识别请求会自己超时，这里只是不再理会它的结果。
    func endFingerprintTest() {
        testDismissTimer?.invalidate()
        testDismissTimer = nil
        fingerprintTest = nil
        stopFlashing()
    }

    /// 结果出来后让面板自己再留一会儿就收起来。
    /// 等手指的那一档**不能**自动消失——用户可能正抬手往传感器按。
    private func scheduleTestAutoDismiss() {
        testDismissTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFingerprintTest() }
        }
        RunLoop.main.add(timer, forMode: .common)
        testDismissTimer = timer
    }

    /// 让某一枚指纹那一行闪一下。测试结束后面板还留着，但闪烁要自己停下来。
    private func flashFingerprint(_ id: Int) {
        flashingFingerprint = id
        flashTimer?.invalidate()
        let timer = Timer(timeInterval: 2.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopFlashing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashingFingerprint = nil
    }
    // MARK: 设置项

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            post(.error, String(localized: "Could not change the login item: \(error.localizedDescription)"))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func addIgnoredApp(at url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !ignoredApps.contains(id) else { return }
        setIgnoredApps(ignoredApps + [id])
    }

    func removeIgnoredApp(_ id: String) {
        setIgnoredApps(ignoredApps.filter { $0 != id })
    }

    private func setIgnoredApps(_ ids: [String]) {
        ignoredApps = ids
        UserDefaults.standard.set(ids, forKey: "TouchUnlock.ignoredApps")
        focus.ignoredBundleIDs = Set(ids)
    }

    func setShowDockIcon(_ on: Bool) {
        showDockIcon = on
        UserDefaults.standard.set(on, forKey: "TouchUnlock.showDockIcon")
        applyDockPolicy()
        // 切换策略会让应用失去前台，把窗口拉回来，免得设置页突然消失。
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    func openBluetoothSettings() {
        open("x-apple.systempreferences:com.apple.BluetoothSettings")
    }

    func openBluetoothPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    /// 拉起辅助功能授权弹窗。未授权时只靠 Secure Event Input 判断前台是不是在等密码，
    /// 覆盖不到「终端里 sudo 提示」之外的普通密码框场景。
    func requestAccessibilityPermission() {
        FocusMonitor.requestAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: 设备事件

    private func handle(_ event: DeviceEvent) {
        log("event: \(event)")
        switch event {
        case .version(let v): firmwareVersion = v
        case .pairing(let ok):
            if ok { post(.success, String(localized: "Paired with this Mac.")) }
            else { post(.warning, String(localized: "Pairing failed. Put the device into pairing mode first.")) }
        case .fingerprintInfo(let info):
            fingerprints = info
            // 改密码时没拿到列表，现在补上：开始逐个重绑。
            if rebindAfterInfoRefresh {
                rebindAfterInfoRefresh = false
                beginRebind(info.registeredIds)
            }
        case .fingerprintInfoFailed: post(.error, String(localized: "Could not read the fingerprint list."))

        case .defaultPasswordSet(let ok): defaultPasswordResult(ok)
        case .passwordSet(let ok): passwordBindResult(ok)
        // 设备键入完成后主动推送。应用连上设备期间设备都处于武装状态。
        case .passwordTyped:
            // 设备只在武装状态下才该键入。没武装过却收到这条，说明状态没对上（或设备
            // 自说自话），这时绝不能弹「密码已输入」——字符落在哪里根本没人知道。
            // 键入本身要花几百毫秒，期间焦点可能已经变了，所以给一个几秒的宽限。
            let weAskedForIt = deviceArmed || (lastArmedAt.map { Date.now.timeIntervalSince($0) < 5 } ?? false)
            if weAskedForIt {
                if showHUD { hud.show(String(localized: "Fingerprint recognized. Password typed."), kind: .success) }
                sendIndicator(colorType: Self.indicatorSuccess, count: 3)
            } else {
                log("device reported typing while it was never armed; ignored")
            }
        // 托管模式下设备把密码交给应用（原厂固件的行为）。密码在解码时就已丢弃，这里什么都不做。
        case .passwordHandedOver(let id): fireShortcut(for: id)

        case .enrollStarted: break
        case .enrollProgress(let id, let step, let total): enroll = .progress(id: id, step: step, total: total)
        case .enrollSucceeded: enrollSucceeded()
        case .enrollFailed(_, let failure, let reason): enrollFailed(failure, reason: reason)

        case .identified(let id):
            // 只有手动测试会发识别请求，所以这里的反馈只服务于测试面板。
            if fingerprintTest != nil {
                fingerprintTest = .matched(id)
                flashFingerprint(id)
                scheduleTestAutoDismiss()
            }
        case .identifyFailed:
            if fingerprintTest != nil {
                fingerprintTest = .unmatched
                scheduleTestAutoDismiss()
            }
        case .identifyTimeout:
            if fingerprintTest != nil {
                fingerprintTest = .timedOut
                scheduleTestAutoDismiss()
            }

        case .deleted(let id, let ok):
            if ok {
                // 名字跟着指纹一起清掉，免得编号被复用后张冠李戴。
                if let id { rename(id, to: ""); setShortcut(nil, for: id) }
                post(.success, String(localized: "Fingerprint deleted."))
            } else {
                post(.error, String(localized: "Could not delete the fingerprint."))
            }
            send(.queryFingerprints)

        case .unknown: break
        }
    }

    private func defaultPasswordResult(_ ok: Bool) {
        // 没有待处理的设密码请求时收到 pw=2/3，不是用户操作（例如设备拒了心跳里的 pw=10）。
        guard let password = pendingPassword else {
            if !ok { log("device rejected a pw request we did not send (ignored)") }
            return
        }
        pendingPassword = nil
        cancelWriteTimeout()

        guard ok else {
            post(.error, String(localized: "The device rejected the password."))
            return
        }
        do {
            try PasswordStore.save(password)
            hasStoredPassword = true
            post(.success, String(localized: "Password saved."))
        } catch {
            log("keychain save failed: \(error)")
            post(.warning, String(localized: "The device accepted the password, but saving it to the keychain failed."))
        }
        // 已有指纹各自绑着旧密码，一起更新。列表还没取到就先查一次，
        // 否则这些指纹会继续绑着旧密码，指纹解锁会静默失败。
        if let ids = fingerprints?.registeredIds {
            beginRebind(ids)
        } else {
            rebindAfterInfoRefresh = true
            send(.queryFingerprints)
        }
    }

    /// 改了系统密码之后，把每枚指纹重新绑成它此刻该用的密码
    /// （单独设过用单独那枚，否则跟随系统密码）。
    private func beginRebind(_ ids: [Int]) {
        rebindQueue = ids
        rebinding = !rebindQueue.isEmpty
        rebindNext()
    }

    private func rebindNext() {
        guard pendingBind == nil else { return }   // 有一条在飞，等它回来再继续
        guard !rebindQueue.isEmpty else {
            rebinding = false
            return
        }
        let id = rebindQueue.removeFirst()
        let password = effectivePassword(for: id)
        guard let password else {
            rebinding = false
            rebindQueue.removeAll()
            return
        }
        guard beginPasswordWrite(.rebind, notify: false) else { return }
        send(.setPassword(id: id, password: password))
    }

    /// 某枚指纹此刻应该绑在设备上的密码：单独设置过就用它，否则用系统密码。
    private func effectivePassword(for id: Int) -> String? {
        PasswordStore.load(account: PasswordStore.fingerprintAccount(id)) ?? PasswordStore.load()
    }

    /// 认领一次密码写入。一次只允许一条在飞：设备的 pw=5/6 回包**不带 id**，
    /// 两条同时在飞就没法判断回包属于谁。
    private func beginPasswordWrite(_ kind: PendingBind, notify: Bool = true) -> Bool {
        guard pendingBind == nil else {
            if notify {
                post(.info, String(localized: "Still updating the enrolled fingerprints. Try again in a moment."))
            }
            return false
        }
        pendingBind = kind
        scheduleWriteTimeout()
        return true
    }

    /// 每次写入都重置超时。设备没了响应时靠它放掉状态，否则界面会一直灰着，
    /// 只能靠断开连接恢复。
    private func scheduleWriteTimeout(_ action: (() -> Void)? = nil) {
        cancelWriteTimeout()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if let action { action() } else { self?.passwordWriteTimedOut() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        writeTimeout = timer
    }

    private func cancelWriteTimeout() {
        writeTimeout?.invalidate()
        writeTimeout = nil
    }

    private func passwordWriteTimedOut() {
        guard let pending = pendingBind else { return }
        pendingBind = nil
        cancelWriteTimeout()
        log("password write timed out: \(pending.label)")
        switch pending {
        case .rebind:
            abandonRebind("no reply for a password update")
        case .enroll:
            enroll = .failed(String(localized: "The device did not confirm the password."))
        case .manual:
            post(.warning, String(localized: "The device did not confirm the password."))
        }
    }

    private func passwordBindResult(_ ok: Bool) {
        guard let pending = pendingBind else {
            // 没有在等结果的密码操作：多半是设备拒绝了心跳里的 pw=10，不是用户操作。
            if !ok { log("device rejected a password update we did not request (ignored)") }
            return
        }
        pendingBind = nil
        cancelWriteTimeout()
        switch pending {
        case .enroll(let id):
            enroll = ok ? .done(id: id) : .failed(String(localized: "The fingerprint was enrolled, but binding the password failed."))
            send(.queryFingerprints)
        case .manual(let id):
            if ok { post(.success, String(localized: "Password saved for fingerprint \(id).")) }
            else { post(.error, String(localized: "The device rejected the password.")) }
        case .rebind:
            if !ok { log("device rejected a password update for an enrolled fingerprint") }
            if rebindQueue.isEmpty {
                rebinding = false
                send(.queryFingerprints)
            }
        }
        // 重绑链可能刚才在等这条回包（例如用户同时给某枚指纹单独设了密码）。
        if rebinding { rebindNext() }
    }

    private func enrollSucceeded() {
        let id: Int
        switch enroll {
        case .starting(let i), .progress(let i, _, _): id = i
        default: return
        }
        guard let password = PasswordStore.load() else {
            enroll = .failed(String(localized: "Set the unlock password first."))
            return
        }
        guard beginPasswordWrite(.enroll(id: id), notify: false) else {
            enroll = .failed(String(localized: "The device did not confirm the password."))
            return
        }
        enroll = .binding(id: id)
        send(.setPassword(id: id, password: password))
    }

    private func enrollFailed(_ failure: EnrollFailure, reason: String?) {
        switch failure {
        case .cancelled:
            enroll = .idle
            post(.info, String(localized: "Enrollment cancelled."))
        case .timeout: enroll = .failed(String(localized: "No finger was detected in time."))
        case .alreadyExists: enroll = .failed(String(localized: "This finger is already enrolled."))
        case .duplicateID: enroll = .failed(String(localized: "That fingerprint slot is already in use."))
        case .generic: enroll = .failed(reason ?? String(localized: "Enrollment did not finish."))
        }
    }

    // MARK: 日志

    /// 只记状态和事件，不记密码：DeviceRequest / DeviceEvent 的描述已做脱敏。
    func log(_ line: String) {
        let stamp = Date.now.formatted(.dateTime.hour().minute().second())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    func clearLog() { logLines.removeAll() }
}
