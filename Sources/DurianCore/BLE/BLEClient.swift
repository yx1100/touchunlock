import CoreBluetooth
import Foundation

public enum BLEState: Equatable, Sendable {
    case unauthorized, poweredOff, unsupported
    case idle        // 蓝牙就绪，未在连接
    case searching   // 正在扫描
    case connecting  // 已发现设备，正在建立连接或发现服务
    case ready       // 已订阅通知，可以发送请求
}

public enum BLEError: Error, Equatable {
    case notReady
    case payloadTooLarge(Int)
}

/// 一次写入的完成凭据。`didWriteValueFor` 与超时先到者触发，只触发一次。
/// CoreBluetooth 按顺序回报写入结果，所以队列可以按先进先出配对。
private final class WriteTicket {
    private var fired = false
    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    func fire() {
        guard !fired else { return }
        fired = true
        action()
    }
}

/// 连接榴莲指纹设备的自定义 GATT 服务（docs/BLE-PROTOCOL.md 第 1 节）。
/// 所有回调都在主队列，必须在主线程使用。
public final class BLEClient: NSObject {
    public static let serviceUUID = CBUUID(string: "4FAFC201-1FB5-459E-8FCC-C5C9C331914B")
    public static let rxUUID = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A8")  // 主机写入
    public static let txUUID = CBUUID(string: "BEB5483E-36E1-4688-B7F5-EA07361B26A9")  // 设备通知
    static let advertisedName = "Durian Touch"
    static let savedIDKey = "TouchUnlock.peripheralID"
    static let maxWrite = 512
    /// 一次扫描持续多久。无限扫描会让附近每个广播包都唤醒主队列。
    static let scanWindow: TimeInterval = 30
    /// 扫描空转一轮后歇多久再扫。
    static let scanPause: TimeInterval = 3
    /// 写入确认的最长等待时间，超时按失败处理，免得调用方永远等下去。
    static let writeTimeout: TimeInterval = 1
    /// 直连记住的设备最多等多久。CoreBluetooth 的 connect 永不超时，设备不接受连接时
    /// 会一直停在「正在连接」，所以到点就取消，改为扫描。
    static let connectTimeout: TimeInterval = 8

    public private(set) var state: BLEState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var deviceName: String?

    public var onStateChange: ((BLEState) -> Void)?
    public var onEvent: ((DeviceEvent) -> Void)?
    /// 日志行。永远不含密码；调用方也不应往里写。
    public var onLog: ((String) -> Void)?
    /// 仅供探测工具：收到的每个完整报文的原始 JSON。可能含密码，应用不要设置。
    public var onRawPacket: ((String) -> Void)? {
        didSet { reassembler.onRawPacket = onRawPacket }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var reassembler = ChunkReassembler()
    private var wantsConnection = false
    /// 还没被 `didWriteValueFor` 认领的写入凭据，与写入一一对应。
    private var writeTickets: [WriteTicket] = []
    /// 已协商的单次写入上限，订阅成功时更新。
    private var writeLimit = BLEClient.maxWrite
    private var warnedAboutWriteLimit = false
    private var scanTimeout: DispatchWorkItem?
    /// 刚被「忘记」的设备。它作为蓝牙键盘仍连在系统上，不跳过的话会被
    /// `retrieveConnectedPeripherals` 立刻找回来。扫描一轮仍没找到别的设备时清掉，
    /// 让只有这一块设备的用户还能连回去。
    private var forgottenID: UUID?
    private var connectTimeoutWork: DispatchWorkItem?
    /// 直连超时过一次后，下一轮先扫描而不是再直连同一台。
    private var preferScan = false

    public override init() { super.init() }

    // MARK: 控制

    /// 开始（并保持）连接；断线后自动重连。首次调用会触发系统蓝牙授权弹窗。
    public func start() {
        wantsConnection = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            connectOrScan()
        }
    }

    public func stop() {
        wantsConnection = false
        stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        rx = nil; tx = nil
        finishPendingWrites()
        if state != .unauthorized && state != .poweredOff && state != .unsupported { state = .idle }
    }

    /// 忘记记住的设备并重新扫描（换了一块设备时用）。
    public func forgetDevice() {
        forgottenID = peripheral?.identifier
            ?? UserDefaults.standard.string(forKey: Self.savedIDKey).flatMap(UUID.init(uuidString:))
        UserDefaults.standard.removeObject(forKey: Self.savedIDKey)
        let wasRunning = wantsConnection
        stop()
        if wasRunning { start() }
    }

    /// `quiet` 用于心跳这类高频报文：不写日志，免得把日志冲掉。
    /// `completion` 在写入被设备确认、链路断开或超时后回调一次，用来在断开前等写入落地。
    public func send(_ request: DeviceRequest, quiet: Bool = false,
                     completion: (() -> Void)? = nil) throws {
        if !quiet { onLog?("send \(request)") }
        try write(try request.packet(), completion: completion)
    }

    /// 发送任意报文。探测工具用它试未确认的取值。日志只记类型字段，不记 message。
    public func send(packet: PacketData, completion: (() -> Void)? = nil) throws {
        onLog?("send raw messageType=\(packet.messageType) ble=\(packet.bleMessageType) pw=\(packet.pwMessageType) fp=\(packet.fpMessageType) debug=\(packet.debugMessageType) messageBytes=\(packet.message.utf8.count)")
        try write(packet, completion: completion)
    }

    private func write(_ packet: PacketData, completion: (() -> Void)? = nil) throws {
        guard state == .ready, let p = peripheral, let rx else { throw BLEError.notReady }
        let data = try packet.encoded()
        guard data.count <= Self.maxWrite else { throw BLEError.payloadTooLarge(data.count) }
        if data.count > writeLimit, !warnedAboutWriteLimit {
            warnedAboutWriteLimit = true
            // 超过协商长度的报文要靠 CoreBluetooth 拆成多次 prepare/execute 写入。
            onLog?("packet \(data.count) bytes exceeds the negotiated write length \(writeLimit), relying on a long write")
        }
        // 每条写入都挂一张凭据：即使调用方不关心结果，也要占住队列位次，
        // 否则后面写入的凭据会被这条写入的结果提前认领。超时只触发凭据、不出队，
        // 位次一直留到这条写入真正回报（或链路断开）为止。
        let ticket = WriteTicket(completion ?? {})
        writeTickets.append(ticket)
        if writeTickets.count > 16 { writeTickets.removeFirst().fire() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeTimeout) { [weak self] in
            self?.expire(ticket)
        }
        p.writeValue(data, for: rx, type: .withResponse)
    }

    /// 超时只让调用方继续，凭据留在队列里：这条写入的 `didWriteValueFor` 迟早还会到，
    /// 若先摘掉，迟到的回报就会认领下一条写入的凭据，让它的 completion 提前触发。
    private func expire(_ ticket: WriteTicket) {
        ticket.fire()
    }

    /// 链路没了：所有等待中的调用方立即继续，不阻塞退出流程。
    private func finishPendingWrites() {
        let pending = writeTickets
        writeTickets.removeAll()
        pending.forEach { $0.fire() }
    }

    // MARK: 连接流程

    private func connectOrScan() {
        guard wantsConnection, let central, central.state == .poweredOn, peripheral == nil else { return }
        if preferScan {
            preferScan = false
            onLog?("scanning instead of reconnecting directly")
            startScan()
            return
        }

        if let p = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            .first(where: { $0.identifier != forgottenID }) {
            onLog?("found already-connected peripheral")
            connect(p); return
        }
        if let text = UserDefaults.standard.string(forKey: Self.savedIDKey),
           let id = UUID(uuidString: text),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            onLog?("reconnecting to remembered peripheral")
            connect(p); return
        }
        onLog?("scanning")
        startScan()
    }

    /// 扫一段就停。设备不在时无限扫描会让主队列被附近所有广播包吵醒。
    private func startScan() {
        state = .searching
        // 不确定设备是否在广播包里带自定义服务 UUID，所以扫全部再按服务或名称过滤。
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanTimedOut() }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanWindow, execute: work)
    }

    private func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
    }

    private func scanTimedOut() {
        scanTimeout = nil
        guard wantsConnection, state == .searching else { return }
        onLog?("no device found in \(Int(Self.scanWindow))s, scanning again later")
        forgottenID = nil
        central?.stopScan()
        state = .idle
        reconnectLater(after: Self.scanPause)
    }

    private func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        deviceName = p.name
        state = .connecting
        central?.connect(p, options: nil)
        connectTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, p === self.peripheral, self.state == .connecting else { return }
            self.onLog?("connect timed out after \(Int(Self.connectTimeout))s, cancelling")
            self.central?.cancelPeripheralConnection(p)
            self.peripheral = nil; self.rx = nil; self.tx = nil
            self.state = .idle
            self.preferScan = true
            self.reconnectLater(after: 1)
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    private func resetReassembler() {
        reassembler = ChunkReassembler()
        reassembler.onRawPacket = onRawPacket
    }

    private func reconnectLater(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.connectOrScan()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .poweredOff || state == .unauthorized || state == .unsupported { state = .idle }
            connectOrScan()
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default:
            // poweredOff / resetting / unknown：连接已失效，等恢复后重来。
            peripheral = nil; rx = nil; tx = nil
            finishPendingWrites()
            state = .poweredOff
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        guard services.contains(Self.serviceUUID) || name == Self.advertisedName,
              p.identifier != forgottenID else { return }
        onLog?("discovered \(name ?? "device")")
        connect(p)
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        forgottenID = nil
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedIDKey)
        deviceName = p.name ?? deviceName
        onLog?("connected, discovering services")
        p.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        onLog?("connect failed: \(error?.localizedDescription ?? "unknown")")
        peripheral = nil
        state = .idle
        if wantsConnection { reconnectLater(after: 2) }
    }

    /// 只处理当前这台外设的断开。`stop()` 之后才到的旧连接断开回报若照单全收，
    /// 会把已经换上的新连接清掉、提前放掉它的写入凭据。
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else {
            onLog?("ignored a disconnect from a connection that was already closed")
            return
        }
        onLog?("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        peripheral = nil; rx = nil; tx = nil
        resetReassembler()
        finishPendingWrites()
        state = .idle
        if wantsConnection { reconnectLater(after: 1) }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEClient: CBPeripheralDelegate {
    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            onLog?("service not found: \(error?.localizedDescription ?? "no error")")
            central?.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
        tx = service.characteristics?.first { $0.uuid == Self.txUUID }
        guard rx != nil, let tx else {
            onLog?("characteristics missing: \(error?.localizedDescription ?? "no error")")
            central?.cancelPeripheralConnection(p)
            return
        }
        p.setNotifyValue(true, for: tx)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { onLog?("subscribe failed: \(error.localizedDescription)"); return }
        guard c.uuid == Self.txUUID, c.isNotifying else { return }
        resetReassembler()
        writeLimit = p.maximumWriteValueLength(for: .withResponse)
        warnedAboutWriteLimit = false
        connectTimeoutWork?.cancel()
        onLog?("ready (write limit \(writeLimit))")
        state = .ready
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.txUUID, let data = c.value else { return }
        do {
            if let packet = try reassembler.feed(data) { onEvent?(DeviceEvent(packet)) }
        } catch {
            // 带上前 24 字节的十六进制：不然「解不开的通知」完全没法排查。
            let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            onLog?("bad notification (\(data.count) bytes) [\(hex)]: \(error)")
        }
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { onLog?("write failed: \(error.localizedDescription)") }
        // 写入结果按顺序回报，队首就是这次写入的凭据。
        if !writeTickets.isEmpty { writeTickets.removeFirst().fire() }
    }
}
