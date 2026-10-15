import DurianCore
import Foundation

// 真机探测工具：连接设备，发一条请求，打印设备回的所有事件。
// 不接受也不打印密码；密码域的报文内容在 DeviceEvent 里已被抹掉。

let usage = """
用法: touchprobe <命令> [参数] [--seconds N] [--raw]
  --raw  同时打印设备回的原始 JSON（密码域回包可能含明文密码，别贴出去）
  listen                    只连接并打印事件（默认）
  version                   查询固件版本
  info                      查询指纹信息
  pair                      配对（设备需处于配对模式）
  identify [id]             识别指纹，可指定目标 id
  enroll <id>               录入指纹
  cancel                    取消录入
  delete <id>               删除指纹
  raw <messageType> <ble> <pw> <fp> [message]
                            发送任意报文，用来试未确认的取值（不要把密码放在 message 里）
  stress <led|hb>          稳定性压测：持续发指示灯指令或心跳，定期查版本
  blocktest                 诊断：先发识别请求，2 秒后再查版本；
                            用来确认「有识别请求挂着时设备是否还会处理别的消息」
"""

var args = Array(CommandLine.arguments.dropFirst())
let showRaw = args.contains("--raw")
args.removeAll { $0 == "--raw" }
var seconds = 30.0
if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Double(args[i + 1]) {
    seconds = s
    args.removeSubrange(i...(i + 1))
}
let command = args.first ?? "listen"

func intArg(_ index: Int) -> Int? { index < args.count ? Int(args[index]) : nil }

func makeAction() -> ((BLEClient) throws -> Void)? {
    switch command {
    case "listen": return { _ in }
    case "version": return { try $0.send(.queryVersion) }
    case "info": return { try $0.send(.queryFingerprints) }
    case "pair": return { try $0.send(.pair) }
    case "identify": return { try $0.send(.identify(targetId: intArg(1))) }
    case "cancel": return { try $0.send(.cancelEnroll) }
    case "enroll":
        guard let id = intArg(1) else { return nil }
        return { try $0.send(.startEnroll(id: id, rejectDuplicate: true)) }
    case "delete":
        guard let id = intArg(1) else { return nil }
        return { try $0.send(.deleteFingerprint(id: id)) }
    case "blocktest":
        return { client in
            print("[test]  发送识别请求；2 秒后再查版本，看回包是被立刻处理还是拖到识别超时之后")
            try client.send(.identify(targetId: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("[test]  +2s 发送版本查询")
                try? client.send(.queryVersion)
            }
        }
    case "stress":
        // 稳定性压测：持续发同一种消息，每 20 条查一次版本确认设备还在响应。
        // 用途是定位「设备偶尔卡死」到底由哪种流量触发。
        // kind: led（指示灯）/ hb（心跳）/ mixed（心跳夹灯效与武装切换）
        let kind = args.count > 1 ? args[1] : "led"
        return { client in
            let interval: TimeInterval = kind == "led" ? 3.0 : 0.7
            print("[test]  压测开始：\(kind)，间隔 \(interval) 秒")
            var sent = 0
            let timer = Timer(timeInterval: interval, repeats: true) { _ in
                sent += 1
                switch kind {
                case "led":
                    try? client.send(.setIndicator(colorType: 3, count: 1))
                case "mixed":
                    try? client.send(.reportMacState(MacState()))
                    if sent % 4 == 0 { try? client.send(.setIndicator(colorType: 3, count: 1)) }
                    if sent % 10 == 0 { try? client.send(sent % 20 == 0 ? .assistOn : .assistPause) }
                default:
                    try? client.send(.reportMacState(MacState()))
                }
                if sent % 20 == 0 {
                    print("[test]  已发 \(sent) 条 \(kind)；查版本确认设备是否还在响应")
                    try? client.send(.queryVersion)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    case "raw":
        guard let t = intArg(1), let b = intArg(2), let p = intArg(3), let f = intArg(4) else { return nil }
        let message = args.count > 5 ? args[5] : ""
        return { try $0.send(packet: PacketData(messageType: t, ble: b, pw: p, fp: f, message: message)) }
    default: return nil
    }
}

guard let action = makeAction() else {
    print(usage)
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
let client = BLEClient()
var sent = false

client.onLog = { print("[ble]   \($0)") }
client.onEvent = { print("[event] \($0)") }
if showRaw { client.onRawPacket = { print("[raw]   \($0)") } }
client.onStateChange = { state in
    print("[state] \(state)")
    guard state == .ready, !sent else { return }
    sent = true
    do { try action(client) } catch { print("[error] \(error)") }
}

print("touchprobe: \(command)，最长运行 \(Int(seconds)) 秒（Ctrl-C 退出）")
client.start()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("[done]  超时退出")
    exit(0)
}
RunLoop.main.run()
