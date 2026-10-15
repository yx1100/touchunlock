# TouchUnlock

用一枚指纹识别器解锁 Mac、并在密码框里自动输入密码的 macOS 应用。

配合 **Durian Touch**（榴莲）蓝牙指纹识别器使用：设备本身就是一个蓝牙 HID 键盘，密码由设备直接敲出来，应用只负责判断「现在该不该输入」以及把密码下发给设备。

- 锁屏、息屏、屏保状态下按指纹 → 亮屏、输入系统密码、回车解锁
- 未锁屏时按前台焦点判断：窗口正在等密码才输入，否则什么都不做
- 不同指纹可以绑定不同密码
- 应用没运行（或崩溃）时，设备不会输入任何内容
- 有窗口在等密码时，识别器指示灯闪烁提示
- 识别结果以小面板提示，采用 macOS 26/27 的 Liquid Glass 材质

界面提供简体中文与英文。

## 系统要求

- macOS 14 或更高（Liquid Glass 材质需要 macOS 26+）
- Durian Touch 指纹识别器（固件 1.0.4）
- 设备需在「系统设置 → 蓝牙」里单独配对为键盘，否则按键无人接收

## 构建

需要 Xcode 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
xcodegen generate
xcodebuild -project TouchUnlock.xcodeproj -scheme TouchUnlock -configuration Release build
```

`project.yml` 里的 `CODE_SIGN_IDENTITY` 默认指向一台机器上的本地自签证书。换机器时改成你自己的证书，或直接免签名构建：

```bash
xcodebuild -project TouchUnlock.xcodeproj -scheme TouchUnlock \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build
```

### 权限

应用需要「隐私与安全 → 设备控制和数据访问」授权，用来判断前台窗口是否在等密码。未授权时仍能识别安全密码输入提示（例如终端里的 `sudo`），但覆盖不到所有密码框。

### 测试

```bash
swift test
```

## 仓库结构

| 路径 | 说明 |
|---|---|
| `App/` | 应用本身（SwiftUI） |
| `Sources/DurianCore/` | BLE 客户端与协议编解码，独立成包便于测试 |
| `Sources/touchprobe/` | 命令行探测工具，用于查看设备回包、排查问题 |
| `Tests/` | 协议层单元测试 |
| `scripts/l10n.py` | 从源码提取文案、同步中文翻译到字符串目录 |
| `docs/BLE-PROTOCOL.md` | 设备的 BLE 报文格式 |

## 隐私

- 没有网络代码，应用不联网
- 只申请蓝牙一项权限
- 密码保存在设备里；本机钥匙串只存一份副本，用于给新指纹自动关联密码和删除指纹前确认，不会离开这台 Mac
- 日志只记录报文类型，绝不记录密码字段

## 已知限制

- 整机睡眠时蓝牙链路会断开，因此**睡眠状态下无法用指纹唤醒**（能覆盖的是锁屏 + 显示器休眠）
- 发布包使用本地自签证书签名、未经公证，首次打开需要在「系统设置 → 隐私与安全性」里放行，或右键选择「打开」
- 设备不自带电量以外的状态指示，识别结果需要靠应用界面确认

## 许可

本仓库暂未附带开源许可，默认保留所有权利。如需以其他方式使用，请先联系作者。
