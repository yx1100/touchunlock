import Foundation
import Testing
@testable import DurianCore

// 报文样例按真机回包构造，字段名和整数/字符串类型与 docs/BLE-PROTOCOL.md 一致。

private func json(_ s: String) -> Data { Data(s.utf8) }

/// 把一整包 JSON 按设备的方式切成信封通知。
private func chunks(of packet: String, session: Int, size: Int) -> [Data] {
    let bytes = Array(packet.utf8)
    let pieces = stride(from: 0, to: bytes.count, by: size).map { String(decoding: bytes[$0..<min($0 + size, bytes.count)], as: UTF8.self) }
    return pieces.enumerated().map { i, piece in
        let env: [String: Any] = [
            "sessionId": session, "totalLength": bytes.count, "chunkIndex": i,
            "totalChunks": pieces.count, "isLastChunk": i == pieces.count - 1 ? 1 : 0,
            "packetDataStr": piece,
        ]
        return try! JSONSerialization.data(withJSONObject: env)
    }
}

@Suite struct PacketDataTests {
    @Test func roundTripKeepsEveryField() throws {
        let p = PacketData(messageType: 5, ble: 1, pw: 2, fp: 3, debug: 4, message: "x")
        let decoded = try PacketData.decode(p.encoded())
        #expect(decoded == p)
    }

    @Test func encodedContainsAllEightKeys() throws {
        let text = String(decoding: try PacketData(messageType: 6).encoded(), as: UTF8.self)
        for key in ["fpStatus", "command", "messageType", "bleMessageType",
                    "pwMessageType", "fpMessageType", "debugMessageType", "message"] {
            #expect(text.contains("\"\(key)\""), "缺少 \(key)")
        }
    }

    @Test func decodeToleratesMissingFields() throws {
        let p = try PacketData.decode(json(#"{"messageType":6}"#))
        #expect(p == PacketData(messageType: 6))
    }

    @Test func decodeRejectsMissingMessageType() {
        #expect(throws: (any Error).self) { try PacketData.decode(json(#"{"message":"x"}"#)) }
    }
}

@Suite struct ChunkReassemblerTests {
    private let packet = #"{"fpStatus":0,"command":0,"messageType":7,"bleMessageType":0,"pwMessageType":0,"fpMessageType":0,"debugMessageType":0,"message":"{\"firmwareVersion\":\"1.0.3\"}"}"#

    @Test func singleChunkCompletesImmediately() throws {
        var r = ChunkReassembler()
        let out = try r.feed(chunks(of: packet, session: 1, size: 4096)[0])
        #expect(out?.messageType == 7)
    }

    @Test func multipleChunksInOrder() throws {
        var r = ChunkReassembler()
        let all = chunks(of: packet, session: 42, size: 40)
        #expect(all.count > 2)
        for c in all.dropLast() { #expect(try r.feed(c) == nil) }
        let out = try r.feed(all.last!)
        #expect(out?.message == #"{"firmwareVersion":"1.0.3"}"#)
    }

    @Test func chunksOutOfOrder() throws {
        var r = ChunkReassembler()
        var out: PacketData?
        for c in chunks(of: packet, session: 7, size: 40).reversed() { out = try r.feed(c) ?? out }
        #expect(out?.messageType == 7)
    }

    @Test func interleavedSessionsStaySeparate() throws {
        var r = ChunkReassembler()
        let a = chunks(of: packet, session: 1, size: 50)
        let b = chunks(of: packet.replacingOccurrences(of: "1.0.3", with: "9.9.9"), session: 2, size: 50)
        var results: [PacketData] = []
        for (x, y) in zip(a, b) {
            if let p = try r.feed(x) { results.append(p) }
            if let p = try r.feed(y) { results.append(p) }
        }
        #expect(results.map(\.message).contains { $0.contains("1.0.3") })
        #expect(results.map(\.message).contains { $0.contains("9.9.9") })
    }

    @Test func lengthMismatchThrows() throws {
        var r = ChunkReassembler()
        let env = #"{"sessionId":1,"totalLength":999,"chunkIndex":0,"totalChunks":1,"isLastChunk":1,"packetDataStr":"{\"messageType\":6}"}"#
        #expect(throws: ChunkError.lengthMismatch(expected: 999, actual: 17)) { try r.feed(json(env)) }
    }

    @Test func outOfRangeIndexIsMalformed() {
        var r = ChunkReassembler()
        let env = #"{"sessionId":1,"totalLength":1,"chunkIndex":3,"totalChunks":2,"isLastChunk":0,"packetDataStr":"x"}"#
        #expect(throws: ChunkError.malformed) { try r.feed(json(env)) }
    }

    @Test func abandonedSessionsAreEvicted() throws {
        var r = ChunkReassembler()
        // 每个会话只喂第一片，超过上限后最早的会话被丢弃，再喂它的最后一片不应凑齐。
        let first = chunks(of: packet, session: 0, size: 40)
        _ = try r.feed(first[0])
        for s in 1...ChunkReassembler.maxSessions {
            _ = try r.feed(chunks(of: packet, session: s, size: 40)[0])
        }
        var out: PacketData?
        for c in first.dropFirst() { out = try r.feed(c) ?? out }
        #expect(out == nil)
    }
}

@Suite struct RequestTests {
    @Test func queryVersionIsMessageType6() throws {
        #expect(try DeviceRequest.queryVersion.packet() == PacketData(messageType: 6))
    }

    @Test func macStateUsesRealJSONBooleans() throws {
        var s = MacState()
        s.isScreenLocked = true
        let p = try DeviceRequest.reportMacState(s).packet()
        #expect(p.messageType == 3 && p.pwMessageType == 10)
        #expect(p.message.contains(#""isScreenLocked":true"#))
        #expect(p.message.contains(#""isDisplaySleep":false"#))
        for key in ["isScreenLocked", "isDisplaySleep", "isSystemSleep", "isScreensaver",
                    "hasAccessibilityPermission", "hasExternalScreen", "isTouchIDAvailability"] {
            #expect(p.message.contains("\"\(key)\""))
        }
    }

    /// 武装位在协议里仍然叫 hasAccessibilityPermission（固件的字段名），改的只是应用侧的含义：
    /// 补丁固件 v3 用它决定「现在允许键入吗」。键名一旦写错，设备就永远不会键入。
    @Test func allowsTypingKeepsTheFirmwareKeyName() throws {
        var s = MacState()
        s.allowsTyping = true
        let text = try DeviceRequest.reportMacState(s).packet().message
        #expect(text.contains(#""hasAccessibilityPermission":true"#))
        #expect(!text.contains(#""allowsTyping""#))

        s.allowsTyping = false
        #expect(try DeviceRequest.reportMacState(s).packet().message
            .contains(#""hasAccessibilityPermission":false"#))
    }

    @Test func setDefaultPasswordSendsRawString() throws {
        let p = try DeviceRequest.setDefaultPassword("p@ss/word").packet()
        #expect(p.pwMessageType == 1 && p.message == "p@ss/word")
    }

    @Test func setPasswordSendsIdAndPw() throws {
        let p = try DeviceRequest.setPassword(id: 3, password: "a\"b").packet()
        #expect(p.pwMessageType == 4)
        #expect(p.message == #"{"id":3,"pw":"a\"b"}"#)
    }

    @Test func enrollEncodesDuplicateFlag() throws {
        #expect(try DeviceRequest.startEnroll(id: 2, rejectDuplicate: true).packet().message == #"{"bln":1,"id":2}"#)
        #expect(try DeviceRequest.startEnroll(id: 2, rejectDuplicate: false).packet().message == #"{"bln":0,"id":2}"#)
    }

    @Test func identifyWithoutTargetHasEmptyMessage() throws {
        #expect(try DeviceRequest.identify(targetId: nil).packet().message == "")
        #expect(try DeviceRequest.identify(targetId: 5).packet().message == #"{"targetId":5}"#)
    }

    @Test func deleteAndCancelUseFirmwareValues() throws {
        let d = try DeviceRequest.deleteFingerprint(id: 4).packet()
        #expect(d.fpMessageType == 17 && d.message == #"{"id":4}"#)
        #expect(try DeviceRequest.cancelEnroll.packet().fpMessageType == 10)
    }

    /// 回归：`default` 分支曾用 String(reflecting:) 回调自己，无限递归崩溃。
    /// 原版连上设备后第一条消息是 messageType=2 ble=1，退出时发 ble=2（附 "Disconnecting"）。
    /// 与真机行为一致，见 docs/BLE-PROTOCOL.md 第 6 节。
    @Test func assistRequestsMatchTheOriginalApp() throws {
        #expect(try DeviceRequest.assistOn.packet() == PacketData(messageType: 2, ble: 1))
        #expect(try DeviceRequest.assistOff.packet() == PacketData(messageType: 2, ble: 2, message: "Disconnecting"))
    }

    /// 运行期暂停也发 ble=2（清激活位），但不带 "Disconnecting"：
    /// 前台没有窗口需要密码时会频繁切换，不该在设备日志里留下断开字样。
    @Test func assistPauseClearsTheFlagQuietly() throws {
        let p = try DeviceRequest.assistPause.packet()
        #expect(p == PacketData(messageType: 2, ble: 2))
        #expect(p.message.isEmpty)
    }

    /// 指示灯（fp=23）：真机实测 colorType 0/1/2/3/4/5 = 熄灭/蓝/绿/青/红/紫，count 是闪烁次数。
    @Test func indicatorCarriesColorTypeAndCount() throws {
        let p = try DeviceRequest.setIndicator(colorType: 4, count: 3).packet()
        #expect(p.messageType == 5 && p.fpMessageType == 23)
        let body = try JSONSerialization.jsonObject(with: Data(p.message.utf8)) as? [String: Int]
        #expect(body?["colorType"] == 4)
        #expect(body?["count"] == 3)
    }

    @Test func descriptionTerminatesForEveryCase() {
        let all: [DeviceRequest] = [
            .queryVersion, .pair, .reportMacState(MacState()), .setDefaultPassword("x"),
            .setPassword(id: 1, password: "x"), .queryFingerprints, .startEnroll(id: 1, rejectDuplicate: true),
            .cancelEnroll, .identify(targetId: nil), .identify(targetId: 2), .deleteFingerprint(id: 3),
            .assistOn, .assistOff, .assistPause, .setIndicator(colorType: 3, count: 1),
        ]
        for request in all { #expect(!"\(request)".isEmpty) }
        #expect("\(DeviceRequest.queryVersion)" == "queryVersion")
    }

    @Test func descriptionNeverContainsPassword() {
        #expect(!"\(DeviceRequest.setDefaultPassword("hunter2"))".contains("hunter2"))
        #expect(!"\(DeviceRequest.setPassword(id: 1, password: "hunter2"))".contains("hunter2"))
    }
}

@Suite struct EventTests {
    private func event(messageType: Int, ble: Int = 0, pw: Int = 0, fp: Int = 0, message: String = "") -> DeviceEvent {
        DeviceEvent(PacketData(messageType: messageType, ble: ble, pw: pw, fp: fp, message: message))
    }

    private func unknownMessage(_ e: DeviceEvent) -> String? {
        if case .unknown(let p) = e { return p.message }
        return nil
    }

    @Test func versionReply() {
        #expect(event(messageType: 7, message: #"{"firmwareVersion":"1.0.3"}"#) == .version("1.0.3"))
    }

    @Test func pairingReplies() {
        #expect(event(messageType: 2, ble: 4) == .pairing(success: true))
        #expect(event(messageType: 2, ble: 5) == .pairing(success: false))
    }

    @Test func enrollProgressAndSuccess() {
        #expect(event(messageType: 5, fp: 6, message: #"{"id":1,"step":2,"totalSteps":6}"#)
                == .enrollProgress(id: 1, step: 2, totalSteps: 6))
        #expect(event(messageType: 5, fp: 7) == .enrollSucceeded)
    }

    @Test func enrollFailureKinds() {
        let body = #"{"id":1,"reason":"fp already exists"}"#
        #expect(event(messageType: 5, fp: 11, message: body)
                == .enrollFailed(id: 1, failure: .alreadyExists, reason: "fp already exists"))
        #expect(event(messageType: 5, fp: 9, message: body) == .enrollFailed(id: 1, failure: .timeout, reason: "fp already exists"))
        #expect(event(messageType: 5, fp: 10, message: body) == .enrollFailed(id: 1, failure: .cancelled, reason: "fp already exists"))
        #expect(event(messageType: 5, fp: 12, message: body) == .enrollFailed(id: 1, failure: .duplicateID, reason: "fp already exists"))
        #expect(event(messageType: 5, fp: 8, message: "not json") == .enrollFailed(id: nil, failure: .generic, reason: nil))
    }

    @Test func identifyResults() {
        #expect(event(messageType: 5, fp: 15, message: #"{"matchId":3}"#) == .identified(matchId: 3))
        #expect(event(messageType: 5, fp: 16) == .identifyFailed)
        #expect(event(messageType: 5, fp: 27) == .identifyTimeout)
    }

    @Test func deleteResults() {
        #expect(event(messageType: 5, fp: 18, message: #"{"id":2}"#) == .deleted(id: 2, success: true))
        #expect(event(messageType: 5, fp: 19, message: #"{"id":2}"#) == .deleted(id: 2, success: false))
    }

    @Test func fingerprintInfoToleratesMissingFields() {
        let full = event(messageType: 5, fp: 1,
                         message: #"{"maxFingerprint":5,"registeredIdsCount":2,"enrollTotalSteps":6,"registeredIds":[1,3]}"#)
        #expect(full == .fingerprintInfo(.init(maxFingerprint: 5, registeredIdsCount: 2, enrollTotalSteps: 6, registeredIds: [1, 3])))
        #expect(event(messageType: 5, fp: 1, message: "garbage")
                == .fingerprintInfo(.init(maxFingerprint: nil, registeredIdsCount: nil, enrollTotalSteps: nil, registeredIds: [])))
    }

    /// 真机固件 1.0.4 的实测回包（保存自 touchprobe info --raw）。
    @Test func realDeviceFingerprintInfoReply() {
        let message = #"{"maxFingerprint":100,"registeredIdsCount":2,"enrollTotalSteps":6,"registeredIds":[0,1]}"#
        #expect(event(messageType: 5, fp: 1, message: message)
                == .fingerprintInfo(.init(maxFingerprint: 100, registeredIdsCount: 2, enrollTotalSteps: 6, registeredIds: [0, 1])))
    }

    @Test func nextFreeIDStartsAtZeroAndFillsGaps() {
        #expect(FingerprintInfo(maxFingerprint: 100, registeredIds: []).nextFreeID == 0)
        #expect(FingerprintInfo(maxFingerprint: 100, registeredIds: [0, 1]).nextFreeID == 2)
        #expect(FingerprintInfo(maxFingerprint: 100, registeredIds: [1, 2]).nextFreeID == 0)
        #expect(FingerprintInfo(maxFingerprint: 100, registeredIds: [0, 2]).nextFreeID == 1)
    }

    @Test func nextFreeIDStaysInsideCapacity() {
        // 有效范围是 0..<max：全部占满时没有空位，不能返回 max。
        #expect(FingerprintInfo(maxFingerprint: 3, registeredIds: [0, 1, 2]).nextFreeID == nil)
        #expect(FingerprintInfo(maxFingerprint: 3, registeredIds: [0, 1]).nextFreeID == 2)
        #expect(FingerprintInfo(maxFingerprint: 0, registeredIds: []).nextFreeID == nil)
        #expect(FingerprintInfo(registeredIds: []).nextFreeID == 0)
    }

    @Test func handedOverPasswordKeepsOnlyTheMatchID() {
        let e = event(messageType: 3, pw: 11, message: #"{"matchId":1,"pw":"hunter2"}"#)
        #expect(e == .passwordHandedOver(matchId: 1))
        #expect(!"\(e)".contains("hunter2"))
    }

    @Test func handedOverWithGarbageStillDoesNotLeak() {
        let e = event(messageType: 3, pw: 11, message: "hunter2")
        #expect(e == .passwordHandedOver(matchId: -1))
        #expect(!"\(e)".contains("hunter2"))
    }

    @Test func passwordEventsNeverCarryTheMessage() {
        // pw=2 会把明文密码回显在 message 里，事件里不应保留。
        #expect(event(messageType: 3, pw: 2, message: "hunter2") == .defaultPasswordSet(success: true))
        #expect(event(messageType: 3, pw: 9) == .passwordTyped)
    }

    @Test func unknownPasswordAndBoundPasswordPacketsAreRedacted() {
        #expect(unknownMessage(event(messageType: 3, pw: 77, message: "hunter2")) == "<redacted>")
        #expect(unknownMessage(event(messageType: 5, fp: 25, message: #"{"id":1,"pw":"hunter2"}"#)) == "<redacted>")
        #expect(unknownMessage(event(messageType: 8, message: "log")) == "log")
    }
}

@Suite struct PasswordPolicyTests {
    @Test func acceptsEveryPrintableASCII() {
        for byte in UInt8(0x20)...0x7e {
            #expect(PasswordPolicy.isValid(String(UnicodeScalar(byte))), "0x\(String(byte, radix: 16)) 应被接受")
        }
        #expect(!PasswordPolicy.isValid("\u{7f}"))
    }

    @Test func rejectsEmptyTooLongAndNonASCII() {
        #expect(!PasswordPolicy.isValid(""))
        #expect(!PasswordPolicy.isValid(String(repeating: "a", count: PasswordPolicy.maxLength + 1)))
        #expect(PasswordPolicy.isValid(String(repeating: "a", count: PasswordPolicy.maxLength)))
        #expect(!PasswordPolicy.isValid("密码"))
        #expect(!PasswordPolicy.isValid("a\tb"))
        #expect(!PasswordPolicy.isValid("😀"))
    }
}
