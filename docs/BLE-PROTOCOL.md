# 榴莲指纹设备 BLE 协议

本文记录 TouchUnlock 用到的 BLE 报文格式，用于让第三方能对接同一款识别器（广播名 `Durian Touch`，固件 1.0.4 实测）。
只覆盖**与本应用交互所必需**的字段与流程；设备内部实现、厂商配套应用的行为不在本文范围内。

探测工具：仓库里的 `touchprobe`（只连接并收发报文，不做任何自动行为）。

## 1. 传输层

| 项 | 值 |
|---|---|
| 主服务 | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| RX 特征（主机 → 设备） | `beb5483e-36e1-4688-b7f5-ea07361b26a8`，WRITE，最大 512 字节 |
| TX 特征（设备 → 主机） | `beb5483e-36e1-4688-b7f5-ea07361b26a9`，READ + NOTIFY，最大 512 字节 |
| 广播名 | `Durian Touch` |

设备同时是一个蓝牙 HID 键盘。**键盘需要在 macOS「系统设置 → 蓝牙」里单独配对**；本应用只通过 CoreBluetooth 使用上面的自定义服务。
系统蓝牙列表显示「已连接」不代表键盘可用，排障见第 5 节。

### 主机 → 设备：一次写入即一整包

每次写入 RX 的内容就是一整包 `PacketData` JSON（UTF-8），不带任何信封。

### 设备 → 主机：分片信封

每条通知是一个 `ChunkPacketData` JSON，除 `packetDataStr` 外全部是数字：

```
{"sessionId":N,"totalLength":N,"chunkIndex":N,"totalChunks":N,"isLastChunk":0|1,"packetDataStr":"…"}
```

- `isLastChunk` 输出的是**数字** 0 / 1，不是 JSON 布尔值。
- `chunkIndex` 从 0 开始；`totalLength` 是内层 JSON 的总字节数。
- 重组：同一 `sessionId` 下按 `chunkIndex` 拼接 `packetDataStr`，拼完即一整包 `PacketData` JSON。
- 内层载荷按字节切分，多字节 UTF-8 可能被切在字符中间；当前已知报文均为 ASCII。

**要收到回包必须先订阅 TX 特征的通知。**

## 2. PacketData

| 字段 | 类型 | 说明 |
|---|---|---|
| `fpStatus` | 整数 | 设备不使用，发 0 |
| `command` | 整数 | 设备不使用，发 0 |
| `messageType` | 整数 | 决定域，见第 3 节 |
| `bleMessageType` | 整数 | 蓝牙域子类型 |
| `pwMessageType` | 整数 | 密码域子类型 |
| `fpMessageType` | 整数 | 指纹域子类型 |
| `debugMessageType` | 整数 | 调试域子类型 |
| `message` | 字符串 | 载荷，常装嵌套 JSON 文本 |

## 3. messageType

| 值 | 域 | 子类型字段 |
|---|---|---|
| 2 | 蓝牙 | `bleMessageType` |
| 3 | 密码 | `pwMessageType` |
| 5 | 指纹 | `fpMessageType` |
| 6 | 版本查询（请求） | 无 |
| 7 | 版本查询（回包） | `message` = `{"firmwareVersion":"1.0.4"}` |
| 8 | 调试 | `debugMessageType` |

## 4. 各域取值

### 蓝牙域（`messageType=2`）

| 方向 | 值 | 含义 |
|---|---|---|
| 请求 | `ble=1` | 置「应用在运行」标志 |
| 请求 | `ble=2` | 清该标志；`message` 可带一句说明文本 |
| 请求 | `ble=3` | 配对：把当前连接的对端记为已配对主机（设备需先进入配对模式） |
| 回包 | `ble=4` | 配对成功，`message` = `Pairing successful` |
| 回包 | `ble=5` | 配对失败，`message` = `Pairing failed, not in pairing mode` |

配对模式：长按指纹模块上的按钮 3 秒以上，指示灯开始快速闪烁即已进入；约 1 分钟后自动退出，短按一次可提前退出。

### 密码域（`messageType=3`）

| 方向 | 值 | 含义 | message |
|---|---|---|---|
| 请求 | `pw=1` | 设置默认密码 | 密码字符串 |
| 回包 | `pw=2` / `pw=3` | 设置成功 / 失败 | 回显（**不要把回包内容写进日志**） |
| 请求 | `pw=4` | 为某枚指纹设置密码 | `{"id":N,"pw":"…"}` |
| 回包 | `pw=5` / `pw=6` | 设置成功 / 失败 | 结果文本 |
| 请求 | `pw=10` | 上报 Mac 状态 | 见下 |
| 事件 | `pw=9` | 设备已输入密码（指纹匹配后主动推送） | 空串 |

`pw=10` 的 `message` 是 7 个 JSON 布尔值，缺任意一个或类型不对都会收到 `pw=6`：

```
{"isScreenLocked":b,"isDisplaySleep":b,"isSystemSleep":b,"isScreensaver":b,
 "hasAccessibilityPermission":b,"hasExternalScreen":b,"isTouchIDAvailability":b}
```

成功时设备不回包，只更新内部状态。其中：

- `isDisplaySleep` / `isSystemSleep` / `isScreensaver` 用来决定键入前是否先发一次左 Ctrl 唤醒屏幕；
- `isSystemSleep` 为真时设备会跳过键入；
- `isTouchIDAvailability` 为真时，键入前多等 200 ms；
- `hasAccessibilityPermission` 与 `ble=1` 一起构成「设备是否自行键入」的开关（见第 6 节）。

### 指纹域（`messageType=5`）

| 方向 | 值 | 含义 | message |
|---|---|---|---|
| 请求 | `fp=2` | 查询指纹信息 | 空 |
| 回包 | `fp=1` | 指纹信息 | `{"maxFingerprint":100,"registeredIdsCount":N,"enrollTotalSteps":6,"registeredIds":[…]}`，ID 从 0 起 |
| 回包 | `fp=3` | 查询失败 | 文本 |
| 请求 | `fp=4` | 开始录入 | `{"id":N,"bln":0\|1}` |
| 回包 | `fp=5` | 录入已启动 | 文本 |
| 事件 | `fp=6` | 录入进度 | `{"id":N,"step":S,"totalSteps":T}` |
| 事件 | `fp=7` | 录入成功 | 空 |
| 事件 | `fp=8` | 录入失败 | `{"id":N,"reason":"…"}` |
| 事件 | `fp=9` | 录入超时 | 同上 |
| 事件 | `fp=10` | 录入已取消 | 同上 |
| 事件 | `fp=11` | 指纹已存在 | 同上 |
| 事件 | `fp=12` | 指纹 ID 重复 | 同上 |
| 请求 | `fp=10` | 取消录入 | 空 |
| 请求 | `fp=14` | 识别指纹 | 可选 `{"targetId":N}`，缺省匹配任意已录入指纹 |
| 回包 | `fp=15` | 识别成功 | `{"matchId":N}` |
| 回包 | `fp=16` | 识别失败 | 文本 |
| 回包 | `fp=27` | 识别超时（约 10 秒） | 文本 |
| 请求 | `fp=17` | 删除指纹（同时清除该 ID 的密码绑定） | `{"id":N}` |
| 回包 | `fp=18` / `fp=19` | 删除成功 / 失败 | `{"id":N}` |
| 请求 | `fp=23` | 设置指示灯 | `{"colorType":N,"count":M}` |

`fp=4` 与 `fp=10` 请求、事件值相同但方向不同：作为请求 `fp=10` 是取消，作为设备事件是「已取消」。

**指示灯**（`fp=23`，真机实测）：`colorType` 0=熄灭、1=蓝、2=绿、3=青（默认）、4=红、5=紫；`count` 是闪烁次数（上限 255，一次闪烁约 0.3 秒）。
注意：**不要在灯效尚未播完时反复下发**，实测会把效果引擎推进循环状态，灯持续闪烁，需要再发一条 `colorType=0` 才会停。

**设备不会主动上报识别结果**：只有收到 `fp=14` 才会回报一次。而且一条识别请求会让设备约 9 秒内不处理其他消息（实测版本查询被堵 7.2 秒），所以不要常驻轮询识别。

### 调试域（`messageType=8`）

`debug=1` 请求日志、设备回 `debug=3`（`message` 为日志文本）；`debug=2` 清日志。本应用不使用。

## 5. 键盘链路排障

设备靠自带的蓝牙 HID 键盘输入密码。系统蓝牙里显示「已连接」不代表键盘可用：若 macOS 的 HID 注册表里没有 `Durian Touch`，设备发出的按键无人接收（表现是设备报告已输入，屏幕上却没有字符）。

```
hidutil list | awk 'NR==1 || /Durian/'
```

没有输出时：在「系统设置 → 蓝牙」忘记设备后重新配对。本应用读 IORegistry（`IOHIDDevice`，`Product=Durian Touch` 且 `Transport=Bluetooth Low Energy`）检测这一状态，缺失时在界面里提示。

## 6. 本应用如何使用这套协议

- **武装/解除**：连上后发 `ble=1`，同时用 `pw=10` 上报 Mac 状态；不需要设备键入时发 `ble=2`。设备的键入判定同时看这个标志与「最近是否收到消息」，所以应用还会定期发 `pw=10` 作为心跳，超时约 2 秒即停止键入——应用崩溃或被强杀后设备不会继续键入。
- **锁屏与前台**：锁屏、屏保、或前台窗口正在等密码时才武装；其余情况解除，按指纹不会有任何输入。
- **密码**：系统密码用 `pw=1` 写入设备作为默认密码；某枚指纹的独立密码用 `pw=4` 写入。
- **永不读取设备上的既有密码**：本应用只写不读，日志与诊断信息都不包含 `message` 内容。

## 7. 传输层的注意点

两个特征都没有加密或认证标志，报文在链路上是明文。因此本应用：

- 只在自己发起设置时发送一次密码，收到回包后不记录其内容；
- 日志只记录报文的类型字段，不记录 `message`；
- 不提供读取密码的入口。

## 8. 未确认项

- `fp=4` 里 `bln` 的确切含义。
- `pw=9` 的 `message` 内容。
- 除响应请求外，设备是否还有其它主动事件。
