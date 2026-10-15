import Foundation

// 类型化的请求与事件。取值来源见 docs/BLE-PROTOCOL.md 第 4 节。

/// 上报给设备的 Mac 状态（pwMessageType = 10）。键名必须与固件一致，值必须是 JSON 布尔。
public struct MacState: Codable, Equatable, Sendable {
    public var isScreenLocked = false
    public var isDisplaySleep = false
    public var isSystemSleep = false
    public var isScreensaver = false
    /// 固件用它决定「现在允许键入吗」。
    ///
    /// 补丁固件（v3）把它当作**武装位**：只有它非 0、且应用在场（激活位 + 心跳新鲜）时才键入。
    /// 原厂固件用它表示「应用接管键入」，所以 JSON 键名沿用 `hasAccessibilityPermission`。
    public var allowsTyping = false
    public var hasExternalScreen = false
    public var isTouchIDAvailability = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case isScreenLocked, isDisplaySleep, isSystemSleep, isScreensaver
        case allowsTyping = "hasAccessibilityPermission"
        case hasExternalScreen, isTouchIDAvailability
    }
}

public enum DeviceRequest: Equatable, Sendable, CustomStringConvertible {
    case queryVersion
    case pair
    /// 置设备的「激活」标志（固件 +6）。补丁固件：激活且心跳新鲜时才键入。应用连上后发一次。
    case assistOn
    /// 清设备的「激活」标志，设备立即回到不键入状态。应用退出前发。
    case assistOff
    /// 运行期暂停：同样清「激活」标志，但消息留空，避免设备日志里出现 "Disconnecting"。
    /// 前台没有窗口需要密码时发它，比等心跳超时（2 秒）即时得多。
    case assistPause
    case reportMacState(MacState)
    case setDefaultPassword(String)
    case setPassword(id: Int, password: String)
    case queryFingerprints
    case startEnroll(id: Int, rejectDuplicate: Bool)
    case cancelEnroll
    case identify(targetId: Int?)
    case deleteFingerprint(id: Int)
    /// 指示灯（fp=23）。真机实测：`colorType` 0=熄灭、1=蓝、2=绿、3=青（固件默认）、4=红、5=紫；
    /// `count` 是闪烁次数。参数非法时固件按 colorType=3、count=1 处理。
    case setIndicator(colorType: Int, count: Int)

    public func packet() throws -> PacketData {
        switch self {
        case .queryVersion:
            return PacketData(messageType: Domain.versionRequest)
        case .pair:
            return PacketData(messageType: Domain.ble, ble: 3)
        case .assistOn:
            return PacketData(messageType: Domain.ble, ble: 1)
        case .assistOff:
            return PacketData(messageType: Domain.ble, ble: 2, message: "Disconnecting")
        case .assistPause:
            return PacketData(messageType: Domain.ble, ble: 2)
        case .reportMacState(let state):
            return PacketData(messageType: Domain.password, pw: 10, message: try Self.json(state))
        case .setDefaultPassword(let password):
            return PacketData(messageType: Domain.password, pw: 1, message: password)
        case .setPassword(let id, let password):
            return PacketData(messageType: Domain.password, pw: 4,
                              message: try Self.json(PasswordBody(id: id, pw: password)))
        case .queryFingerprints:
            return PacketData(messageType: Domain.fingerprint, fp: 2)
        case .startEnroll(let id, let reject):
            return PacketData(messageType: Domain.fingerprint, fp: 4,
                              message: try Self.json(EnrollBody(id: id, bln: reject ? 1 : 0)))
        case .cancelEnroll:
            return PacketData(messageType: Domain.fingerprint, fp: 10)
        case .identify(let target):
            return PacketData(messageType: Domain.fingerprint, fp: 14,
                              message: try target.map { try Self.json(IdentifyBody(targetId: $0)) } ?? "")
        case .deleteFingerprint(let id):
            return PacketData(messageType: Domain.fingerprint, fp: 17,
                              message: try Self.json(IDBody(id: id)))
        case .setIndicator(let colorType, let count):
            return PacketData(messageType: Domain.fingerprint, fp: 23,
                              message: try Self.json(IndicatorBody(colorType: colorType, count: count)))
        }
    }

    /// 日志里不出现密码。
    public var description: String {
        switch self {
        case .queryVersion: return "queryVersion"
        case .pair: return "pair"
        case .reportMacState(let s): return "reportMacState(\(s))"
        case .setDefaultPassword: return "setDefaultPassword(<redacted>)"
        case .setPassword(let id, _): return "setPassword(id: \(id), <redacted>)"
        case .queryFingerprints: return "queryFingerprints"
        case .startEnroll(let id, let reject): return "startEnroll(id: \(id), rejectDuplicate: \(reject))"
        case .cancelEnroll: return "cancelEnroll"
        case .identify(let target): return "identify(targetId: \(target.map(String.init) ?? "any"))"
        case .deleteFingerprint(let id): return "deleteFingerprint(id: \(id))"
        case .assistOn: return "assistOn"
        case .assistOff: return "assistOff"
        case .assistPause: return "assistPause"
        case .setIndicator(let colorType, let count): return "setIndicator(colorType: \(colorType), count: \(count))"
        }
    }

    private struct PasswordBody: Encodable { var id: Int; var pw: String }
    private struct EnrollBody: Encodable { var id: Int; var bln: Int }
    private struct IdentifyBody: Encodable { var targetId: Int }
    private struct IDBody: Encodable { var id: Int }
    private struct IndicatorBody: Encodable { var colorType: Int; var count: Int }

    /// 复用编码器：与 PacketData 同样的理由，避免每条消息都新建一个 JSONEncoder。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public struct FingerprintInfo: Equatable, Sendable {
    public var maxFingerprint: Int?
    public var registeredIdsCount: Int?
    public var enrollTotalSteps: Int?
    public var registeredIds: [Int]

    public init(maxFingerprint: Int? = nil, registeredIdsCount: Int? = nil,
                enrollTotalSteps: Int? = nil, registeredIds: [Int]) {
        self.maxFingerprint = maxFingerprint
        self.registeredIdsCount = registeredIdsCount
        self.enrollTotalSteps = enrollTotalSteps
        self.registeredIds = registeredIds
    }

    /// 设备的指纹 ID 从 0 开始（固件 1.0.4 实测 maxFingerprint=100，已录入 [0, 1]），
    /// 有效范围是 0..<maxFingerprint。没有空位时返回 nil。
    public static let assumedCapacity = 10  // 设备没告知容量时的保守值

    public var nextFreeID: Int? {
        let used = Set(registeredIds)
        return (0..<(maxFingerprint ?? Self.assumedCapacity)).first { !used.contains($0) }
    }
}

public enum EnrollFailure: Equatable, Sendable {
    case generic, timeout, cancelled, alreadyExists, duplicateID
}

public enum DeviceEvent: Equatable, Sendable {
    case version(String)
    case pairing(success: Bool)
    case defaultPasswordSet(success: Bool)
    case passwordSet(success: Bool)
    /// 设备已经输入密码（指纹解锁完成后主动推送）。
    case passwordTyped
    /// 托管模式下设备识别到指纹后把密码交给应用（pw=11，message 为 {"matchId":N,"pw":"…"}）。
    /// 这里只保留 matchId，密码原文既不解码也不保存。
    case passwordHandedOver(matchId: Int)
    case fingerprintInfo(FingerprintInfo)
    case fingerprintInfoFailed
    case enrollStarted
    case enrollProgress(id: Int, step: Int, totalSteps: Int)
    case enrollSucceeded
    case enrollFailed(id: Int?, failure: EnrollFailure, reason: String?)
    case identified(matchId: Int)
    case identifyFailed
    case identifyTimeout
    case deleted(id: Int?, success: Bool)
    /// 无法识别的报文。密码域和 fp=25 的 message 已被抹掉。
    case unknown(PacketData)

    public init(_ p: PacketData) {
        switch (p.messageType, p.bleMessageType, p.pwMessageType, p.fpMessageType) {
        case (Domain.versionResponse, _, _, _):
            let v = Self.decode(VersionBody.self, p.message)?.firmwareVersion ?? p.message
            self = .version(v)

        case (Domain.ble, 4, _, _): self = .pairing(success: true)
        case (Domain.ble, 5, _, _): self = .pairing(success: false)

        case (Domain.password, _, 2, _): self = .defaultPasswordSet(success: true)
        case (Domain.password, _, 3, _): self = .defaultPasswordSet(success: false)
        case (Domain.password, _, 5, _): self = .passwordSet(success: true)
        case (Domain.password, _, 6, _): self = .passwordSet(success: false)
        case (Domain.password, _, 9, _): self = .passwordTyped
        case (Domain.password, _, 11, _):
            self = .passwordHandedOver(matchId: Self.decode(HandOverBody.self, p.message)?.matchId ?? -1)

        case (Domain.fingerprint, _, _, 1):
            self = .fingerprintInfo(Self.info(p.message))
        case (Domain.fingerprint, _, _, 3): self = .fingerprintInfoFailed
        case (Domain.fingerprint, _, _, 5): self = .enrollStarted
        case (Domain.fingerprint, _, _, 6):
            if let b = Self.decode(ProgressBody.self, p.message) {
                self = .enrollProgress(id: b.id, step: b.step, totalSteps: b.totalSteps)
            } else {
                self = .unknown(p)
            }
        case (Domain.fingerprint, _, _, 7): self = .enrollSucceeded
        case (Domain.fingerprint, _, _, let fp) where (8...12).contains(fp):
            let body = Self.decode(FailureBody.self, p.message)
            let kind: EnrollFailure = [8: .generic, 9: .timeout, 10: .cancelled,
                                       11: .alreadyExists, 12: .duplicateID][fp] ?? .generic
            self = .enrollFailed(id: body?.id, failure: kind, reason: body?.reason)
        case (Domain.fingerprint, _, _, 15):
            if let b = Self.decode(MatchBody.self, p.message) { self = .identified(matchId: b.matchId) }
            else { self = .unknown(p) }
        case (Domain.fingerprint, _, _, 16): self = .identifyFailed
        case (Domain.fingerprint, _, _, 27): self = .identifyTimeout
        case (Domain.fingerprint, _, _, 18): self = .deleted(id: Self.decode(IDBody.self, p.message)?.id, success: true)
        case (Domain.fingerprint, _, _, 19): self = .deleted(id: Self.decode(IDBody.self, p.message)?.id, success: false)

        default:
            var scrubbed = p
            if p.messageType == Domain.password || p.fpMessageType == 25 { scrubbed.message = "<redacted>" }
            self = .unknown(scrubbed)
        }
    }

    private struct VersionBody: Decodable { var firmwareVersion: String }
    private struct ProgressBody: Decodable { var id: Int; var step: Int; var totalSteps: Int }
    private struct FailureBody: Decodable { var id: Int?; var reason: String? }
    private struct MatchBody: Decodable { var matchId: Int }
    private struct IDBody: Decodable { var id: Int }
    /// 故意不声明 pw 字段：解码时丢弃密码。
    private struct HandOverBody: Decodable { var matchId: Int }

    private struct InfoBody: Decodable {
        var maxFingerprint: Int?
        var registeredIdsCount: Int?
        var enrollTotalSteps: Int?
        var registeredIds: [Int]?
    }

    private static let decoder = JSONDecoder()

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? decoder.decode(T.self, from: Data(text.utf8))
    }

    /// 字段类型尚待真机验证，所以全部可缺省。
    private static func info(_ text: String) -> FingerprintInfo {
        let b = decode(InfoBody.self, text)
        return FingerprintInfo(maxFingerprint: b?.maxFingerprint,
                               registeredIdsCount: b?.registeredIdsCount,
                               enrollTotalSteps: b?.enrollTotalSteps,
                               registeredIds: b?.registeredIds ?? [])
    }
}
