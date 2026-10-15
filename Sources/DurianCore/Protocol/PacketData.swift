import Foundation

/// 内层报文，对应固件的 PacketData（见 docs/BLE-PROTOCOL.md 第 2 节）。
/// 前 7 个字段是整数，`message` 是字符串，常装嵌套 JSON 文本。
public struct PacketData: Codable, Equatable, Sendable {
    public var fpStatus = 0
    public var command = 0
    public var messageType: Int
    public var bleMessageType = 0
    public var pwMessageType = 0
    public var fpMessageType = 0
    public var debugMessageType = 0
    public var message = ""

    public init(messageType: Int, ble: Int = 0, pw: Int = 0, fp: Int = 0, debug: Int = 0, message: String = "") {
        self.messageType = messageType
        self.bleMessageType = ble
        self.pwMessageType = pw
        self.fpMessageType = fp
        self.debugMessageType = debug
        self.message = message
    }

    /// 缺失的字段按 0 / 空串处理，设备固件对字段齐全与否没有保证。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fpStatus = try c.decodeIfPresent(Int.self, forKey: .fpStatus) ?? 0
        command = try c.decodeIfPresent(Int.self, forKey: .command) ?? 0
        messageType = try c.decode(Int.self, forKey: .messageType)
        bleMessageType = try c.decodeIfPresent(Int.self, forKey: .bleMessageType) ?? 0
        pwMessageType = try c.decodeIfPresent(Int.self, forKey: .pwMessageType) ?? 0
        fpMessageType = try c.decodeIfPresent(Int.self, forKey: .fpMessageType) ?? 0
        debugMessageType = try c.decodeIfPresent(Int.self, forKey: .debugMessageType) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    // 编解码器复用实例。BLE 回调固定在主队列（CBCentralManager 用 .main 创建），
    // 应用侧与探测工具也都是单线程调用，所以共享同一个实例是安全的；
    // 原先每次编解码都新建一个，心跳期间每秒要建两次。
    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func decode(_ data: Data) throws -> PacketData {
        try decoder.decode(PacketData.self, from: data)
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }
}

/// messageType 取值（docs/BLE-PROTOCOL.md 第 3 节）。
public enum Domain {
    public static let ble = 2
    public static let password = 3
    public static let fingerprint = 5
    public static let versionRequest = 6
    public static let versionResponse = 7
    public static let debug = 8
}
