import Foundation

public enum ChunkError: Error, Equatable {
    case malformed
    case lengthMismatch(expected: Int, actual: Int)
}

/// 设备→主机的分片信封（docs/BLE-PROTOCOL.md 第 1 节）。
/// `isLastChunk` 不参与判断：片数凑齐即完整。
private struct ChunkEnvelope: Decodable {
    var sessionId: Int
    var totalLength: Int
    var chunkIndex: Int
    var totalChunks: Int
    var packetDataStr: String
}

/// 把 TX 特征上的通知重组为完整的 `PacketData`。
public struct ChunkReassembler {
    private struct Session {
        var total: Int
        var length: Int
        var parts: [Int: String] = [:]
    }

    /// 同时保留的未完成会话上限，防止丢片后内存无限增长。
    public static let maxSessions = 8

    private var sessions: [Int: Session] = [:]
    private var order: [Int] = []

    public init() {}

    /// 每凑齐一整包就回调一次原始 JSON 文本，探测工具用它核对字段。
    /// 内容可能含密码（pw=2 回显、fp=25），只给调用方主动开启的调试用途，应用本身不设置。
    public var onRawPacket: ((String) -> Void)?

    /// 复用解码器：设备每条通知都走这里，没必要每次新建。
    private static let decoder = JSONDecoder()

    /// 喂入一条通知。凑齐一整包时返回解码后的 `PacketData`，否则返回 nil。
    public mutating func feed(_ notification: Data) throws -> PacketData? {
        let env = try Self.decoder.decode(ChunkEnvelope.self, from: notification)
        guard env.totalChunks > 0, (0..<env.totalChunks).contains(env.chunkIndex) else {
            throw ChunkError.malformed
        }

        let id = env.sessionId
        var session = sessions[id] ?? Session(total: env.totalChunks, length: env.totalLength)
        if sessions[id] == nil {
            order.append(id)
            if order.count > Self.maxSessions { sessions[order.removeFirst()] = nil }
        }
        session.parts[env.chunkIndex] = env.packetDataStr

        guard session.parts.count == session.total else {
            sessions[id] = session
            return nil
        }
        sessions[id] = nil
        order.removeAll { $0 == id }

        let bytes = Data((0..<session.total).compactMap { session.parts[$0] }.joined().utf8)
        guard bytes.count == session.length else {
            throw ChunkError.lengthMismatch(expected: session.length, actual: bytes.count)
        }
        onRawPacket?(String(decoding: bytes, as: UTF8.self))
        return try PacketData.decode(bytes)
    }
}
