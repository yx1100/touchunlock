#!/usr/bin/env python3
"""从源码收集界面英文文案，配上下面的中文表，生成 App/Resources 里的 xcstrings。

用法（在项目根目录）：  python3 scripts/l10n.py

流程：先把 Localizable.xcstrings 清空，让编译器只按当前源码导出键，
再与 ZH 对照。缺译、多余的翻译都会报错退出，避免删掉的界面留下死文案。
"""
import glob
import html
import json
import os
import re
import subprocess
import sys
import tempfile

ZH = {
    "Enter Pairing Mode": "进入配对模式",
    "Press and hold the button on the reader for more than 3 seconds.": "长按指纹模块上的按钮 3 秒以上。",
    "The light starts blinking quickly, which means it is in pairing mode.": "指示灯开始快速闪烁，即表示已进入配对模式。",
    "Pairing mode lasts about a minute, and a short press ends it early.": "配对模式持续约 1 分钟，短按指纹一次可提前退出。",
    "Pairing again replaces the device this reader was bound to before.": "重新配对会覆盖此前绑定的设备。",
    "Only needed when the reader has to learn this Mac again, for example after forgetting it in Bluetooth settings.": "只有在识别器需要重新认这台 Mac 时才用得着，例如你在系统蓝牙里把它忘记过。",
    "Recognized: %@": "已识别：%@",
    "Stop Testing": "结束测试",
    # UI 重构新增（权限改名、指纹改名、版本号）
    "Device Control and Data Access": "设备控制和数据访问",
    "Allowed": "已允许",
    "Allow…": "允许…",
    "Open System Settings…": "打开系统设置…",
    "Already said no once?": "之前拒绝过？",
    "Device Control and Data Access is allowed, so TouchUnlock can tell when a window is asking for a password.": "已允许「设备控制和数据访问」，触达可以判断前台窗口是不是在等密码。",
    "System Settings → Privacy & Security → Device Control and Data Access. If the switch there is already on, remove TouchUnlock from the list and add it again.": "系统设置 → 隐私与安全 → 设备控制和数据访问。如果那里的开关已经是打开的，请把列表里的触达移除后重新添加一次。",
    "Rename": "改名",
    "Rename Fingerprint %lld": "重命名指纹 %lld",
    "Name": "名字",
    "The name is kept on this Mac only. The device stores fingerprints by number, so a name never travels with the reader.": "名字只保存在这台 Mac 上。设备按编号存指纹，名字不会跟着识别器走。",
    "Version": "版本",
    "About": "关于",
    "No finger was detected.": "未检测到手指。",
    "Permissions": "权限",
    "Feedback": "反馈",
    "Show On-Screen Notifications": "显示屏幕提示",
    "Has its own password": "已单独设置密码",
    "Uses the system password": "跟随系统密码",
    "Use the System Password": "改用系统密码",
    "Password…": "密码…",
    "Save": "保存",
    "Password saved for fingerprint %lld.": "已为指纹 %lld 保存密码。",
    "Could not save the password to the keychain.": "无法把密码保存到本机钥匙串。",
    "The device did not confirm the password.": "设备没有确认这次密码设置。",
    "Fingerprint recognized. Password typed.": "已识别指纹，密码已输入。",
    "This finger is not enrolled.": "这根手指没有录入。",
    "When a window is asking for a password, this fingerprint types the password set here. At the lock screen the system password is always used.": "有窗口在等密码时，这根指纹会输入这里设置的密码。锁屏时一律使用系统密码。",
    "TouchUnlock reads whether the frontmost window is asking for a password, so the reader types only when there is somewhere to type. Without this permission it can still notice secure password prompts, but not every password field. You will find the switch in System Settings → Privacy & Security → Device Control and Data Access.": "触达会读取前台窗口是否在等密码，只有在有地方可以输入时识别器才会键入。没有这个权限时，它仍能识别安全密码输入提示，但覆盖不到所有密码框。开关在「系统设置 → 隐私与安全 → 设备控制和数据访问」里。",
    "Pulse the Reader's Light": "有窗口等密码时闪灯",
    "A small panel appears at the top of the screen after the device types a password, and after a manual test from the Fingerprints page. The reader's light blinks slowly while a window is asking for a password, so you know the reader will type when you touch it.": "设备输入密码之后、以及在指纹页手动测试之后，屏幕顶部会出现一个小提示面板。有窗口在等密码时识别器的灯会慢闪，提示你现在按指纹就会输入。",
    "Allow Device Control and Data Access so TouchUnlock can tell when a window is asking for a password. Without it, a finger press only types at secure password prompts.": "请允许「设备控制和数据访问」，触达才能判断前台窗口是不是在等密码。没有这个权限时，只有屏幕上出现安全密码输入提示时按压指纹才会输入。",
    "%@ · firmware %@": "%@ · 固件 %@",
    "%lld enrolled.": "已录入 %lld 枚。",
    "%lld of %lld": "%lld / %lld",
    "%lld step(s) left.": "还差 %lld 步。",
    "Add Fingerprint": "添加指纹",
    "Add a fingerprint to unlock with a touch.": "添加指纹后，轻触传感器即可解锁。",
    "Advanced": "高级",
    "How It Works": "工作方式",
    "The device types the password only while this app is running. When the app is not running, touching the sensor does nothing.": "只有本应用运行时，设备才会键入密码。应用没有运行时，触碰传感器不会有任何反应。",
    "The device types the password only while TouchUnlock is running. Quit the app and touching the sensor does nothing, so keep the app running and turn on Open at Login in Settings. Fingerprint unlock at the lock screen keeps working as long as the app is running.": "只有触达运行时，设备才会键入密码。退出应用后触碰传感器不会有任何反应，所以请让应用保持运行，并在“设置”里打开“登录时打开”。只要应用在运行，锁屏界面的指纹解锁照常可用。",
    "Allow Bluetooth for TouchUnlock in Privacy & Security.": "请在“隐私与安全性”中允许触达使用蓝牙。",
    "Almost done.": "马上就好。",
    "Bluetooth Settings": "蓝牙设置",
    "Bluetooth Settings…": "蓝牙设置…",
    "Bluetooth access denied": "蓝牙权限被拒绝",
    "Bluetooth is not supported": "此 Mac 不支持蓝牙",
    "Bluetooth is off": "蓝牙已关闭",
    "Bluetooth is the only permission it asks for.": "应用只申请蓝牙这一项权限。",
    "Cancel": "取消",
    "Clear Log": "清除日志",
    "Close": "关闭",
    "Connect": "连接",
    "Connect the device": "连接设备",
    "Connect the device to manage fingerprints.": "连接设备后才能管理指纹。",
    "Connect the device to save a password.": "连接设备后才能保存密码。",
    "Connect the device to see its fingerprints.": "连接设备后可查看其中的指纹。",
    "Connected": "已连接",
    "Connecting…": "正在连接…",
    "Copy Log": "复制日志",
    "Copy in this Mac's keychain": "本机钥匙串中的副本",
    "Could not change the login item: %@": "无法修改登录项：%@",
    "Could not delete the fingerprint.": "无法删除指纹。",
    "Could not read the fingerprint list.": "无法读取指纹列表。",
    "Delete": "删除",
    "Delete this fingerprint?": "删除这枚指纹？",
    "Device": "设备",
    "Device connected": "设备已连接",
    "Disconnect": "断开连接",
    "Dismiss": "关闭提示",
    "Done": "完成",
    "Enroll a fingerprint": "录入指纹",
    "Enroll at least one finger.": "至少录入一根手指。",
    "Enrolled · %lld of %lld": "已录入 · %lld / %lld",
    "Enrolling Fingerprint %lld": "正在录入指纹 %lld",
    "Enrollment Did Not Finish": "录入未完成",
    "Enrollment cancelled.": "录入已取消。",
    "Enrollment did not finish.": "录入没有完成。",
    "Enter the unlock password to confirm. This cannot be undone.": "输入解锁密码以确认。此操作无法撤销。",
    "Enter your Mac login password once.": "输入一次 Mac 登录密码。",
    "Fingerprint %lld": "指纹 %lld",
    "Fingerprint %lld Enrolled": "指纹 %lld 已录入",
    "Fingerprint deleted.": "指纹已删除。",
    "Fingerprints": "指纹",
    "Firmware %@": "固件 %@",
    "Forget": "忘记",
    "Forget Device": "忘记设备",
    "Forget This Device": "忘记此设备",
    "Forget this device?": "忘记此设备？",
    "Forgetting only makes the app look for a device again. It does not erase anything on the device.": "忘记设备只会让应用重新搜索设备，不会清除设备里的任何数据。",
    "General": "通用",
    "Get Ready": "准备工作",
    "Good to Know": "使用须知",
    "Linking the Password": "正在关联密码",
    "Log": "日志",
    "Mac login password": "Mac 登录密码",
    "Make sure the device is powered on.": "请确认设备已通电。",
    "No Fingerprints": "没有指纹",
    "No Log Entries": "没有日志",
    "No finger was detected in time.": "等待手指超时。",
    "No network access. The app has no networking code.": "不联网。应用里没有任何网络代码。",
    "None": "无",
    "Not connected": "未连接",
    "On This Mac": "本机",
    "Open Privacy Settings…": "打开隐私设置…",
    "Open TouchUnlock": "打开触达",
    "Open at Login": "登录时打开",
    "Open…": "打开…",
    "Overview": "概览",
    "Pair": "配对",
    "Pair the Bluetooth keyboard": "配对蓝牙键盘",
    "Pair with This Mac": "与这台 Mac 配对",
    "Paired with this Mac.": "已与这台 Mac 配对。",
    "Pairing failed. Put the device into pairing mode first.": "配对失败。请先让设备进入配对模式。",
    "Password": "密码",
    "Password saved.": "密码已保存。",
    "Place a finger on the sensor, lift it, then place it again.": "把手指放在传感器上，抬起，再按压，如此重复。",
    "Place the finger on the sensor.": "请把手指放在传感器上。",
    "Power on the device and keep it near the Mac.": "给设备通电，并放在 Mac 附近。",
    "Privacy": "隐私",
    "Quit TouchUnlock": "退出触达",
    "Ready to unlock": "随时可以解锁",
    "Remove Copy": "移除副本",
    "Removed the copy on this Mac. The device keeps its own copy.": "已移除本机上的副本，设备里仍保留着密码。",
    "Save to Device": "保存到设备",
    "Saved on the device and in this Mac's keychain.": "已保存到设备和本机钥匙串。",
    "Searching for the device…": "正在搜索设备…",
    "Set Password": "设置密码",
    "Set the unlock password": "设置解锁密码",
    "Set the unlock password first.": "请先设置解锁密码。",
    "Settings": "设置",
    "Show in Dock": "在程序坞中显示",
    "When the Dock icon is hidden, the app stays in the menu bar.": "隐藏程序坞图标后，应用只留在菜单栏。",
    "Setup": "准备情况",
    "Some fingerprints were not updated. Save the password again.": "有指纹没有更新成功，请重新保存一次密码。",
    "Step %lld of %lld. Lift your finger, then place it again.": "第 %lld / %lld 次。抬起手指，再次按压。",
    "Still updating the enrolled fingerprints. Try again in a moment.": "正在更新已录入指纹的密码，请稍后再试。",
    "Test": "测试",
    "That fingerprint slot is already in use.": "该指纹位已被占用。",
    "The Mac has no keyboard for the device": "Mac 没有为设备创建键盘",
    "The app reconnects automatically.": "应用会自动重新连接。",
    "The app will search for a device again.": "应用将重新搜索设备。",
    "The connection to the device was lost.": "与设备的连接已断开。",
    "The device accepted the password, but saving it to the keychain failed.": "设备已接受密码，但保存到钥匙串失败。",
    "The device is not connected.": "设备未连接。",
    "The device rejected the password.": "设备拒绝了该密码。",
    "The device stores the password and types it after a fingerprint match. Saving also updates every enrolled fingerprint.": "密码保存在设备中，指纹匹配后由设备键入。保存时会同步更新所有已录入指纹。",
    "The fingerprint was enrolled, but binding the password failed.": "指纹已录入，但关联密码失败。",
    "The log never contains passwords.": "日志不包含密码。",
    "The password copy stays in the keychain of this Mac.": "密码副本只保存在本机钥匙串中。",
    "The password is incorrect.": "密码不正确。",
    "There is no free fingerprint slot.": "没有空闲的指纹位。",
    "This Mac cannot use Bluetooth Low Energy.": "这台 Mac 无法使用低功耗蓝牙。",
    "This cannot be undone.": "此操作无法撤销。",
    "This finger is already enrolled.": "这根手指已经录入过。",
    "Touch an enrolled finger to unlock.": "触碰已录入的手指即可解锁。",
    "Touch the sensor with this finger to unlock.": "用这根手指触碰传感器即可解锁。",
    "Try Again": "重试",
    "Turn Bluetooth on to connect.": "请打开蓝牙后再连接。",
    "Unlock Password": "解锁密码",
    "Unlock password": "解锁密码",
    "Use 1 to %lld printable ASCII characters.": "请使用 1 到 %lld 个可打印的 ASCII 字符。",
    "Use printable ASCII only, up to %lld characters.": "仅限可打印的 ASCII 字符，最多 %lld 个。",
    "Used to link new fingerprints automatically and to confirm deleting one. It never leaves this Mac.": "用于给新指纹自动关联密码，以及删除指纹前的确认。它不会离开这台 Mac。",
    "macOS has no keyboard for the device. Forget it in Bluetooth settings and pair it again.": "macOS 没有为设备创建键盘。请在蓝牙设置中忘记它，然后重新配对。",
    "macOS recognizes the device as a keyboard.": "macOS 已把设备识别为键盘。",
}

INFO = {
    "CFBundleDisplayName": "触达",
    "CFBundleName": "触达",
    "NSBluetoothAlwaysUsageDescription": "触达通过蓝牙连接你的指纹设备。",
}

# 中英文相同，不需要翻译的键。
UNTRANSLATED = {"TouchUnlock"}

APP_CATALOG = "App/Resources/Localizable.xcstrings"
INFO_CATALOG = "App/Resources/InfoPlist.xcstrings"


def write_catalog(path, entries):
    catalog = {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {
            key: {
                "extractionState": "manual",
                "localizations": {"zh-Hans": {"stringUnit": {"state": "translated", "value": value}}},
            }
            for key, value in sorted(entries.items())
        },
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")


# conda 环境激活后会注入 CC / LD / SDKROOT 这类变量，xcodebuild 会照着它们挑编译器和
# 链接器，表现得像工程编译失败（ld: unknown option: -Xlinker）。生成工程和导出文案
# 都不该受这些变量影响，所以调用前把它们摘掉。
POISONED_ENV = {
    "CC", "CXX", "CPP", "CC_FOR_BUILD", "CXX_FOR_BUILD", "CPP_FOR_BUILD",
    "LD", "AR", "AS", "NM", "STRIP", "LIPO", "OTOOL", "NMEDIT", "LIBTOOL",
    "INSTALL_NAME_TOOL", "SEGEDIT", "SDKROOT", "HOST", "BUILD",
    "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LDFLAGS_LD",
    "DEBUG_CFLAGS", "DEBUG_CXXFLAGS", "MESON_ARGS", "CMAKE_ARGS", "CMAKE_PREFIX_PATH",
}


def clean_env():
    return {k: v for k, v in os.environ.items() if k not in POISONED_ENV}


def exported_keys():
    write_catalog(APP_CATALOG, {})  # 空基础：只按当前源码收集
    subprocess.run(["xcodegen", "generate"], check=True, capture_output=True, env=clean_env())
    # 中间产物一律放工作区内：默认的 ~/Library/Developer/Xcode/DerivedData 在受限环境下
    # 会出现 actool 写不进 DerivedSources（Operation not permitted），导出就会整个失败。
    derived = os.path.join(os.getcwd(), ".build", "l10n-derived")
    with tempfile.TemporaryDirectory() as out:
        subprocess.run(
            ["xcodebuild", "-exportLocalizations", "-project", "TouchUnlock.xcodeproj", "-scheme", "TouchUnlock",
             "-derivedDataPath", derived,
             "-localizationPath", out, "-exportLanguage", "zh-Hans"],
            check=True, capture_output=True, env=clean_env())
        xliff = glob.glob(out + "/**/*.xliff", recursive=True)[0]
        text = open(xliff, encoding="utf-8").read()
    return [html.unescape(k) for k in re.findall(r'<trans-unit id="([^"]*)"', text)]


def main():
    # 导出过程要先清空目录；任何一步出错都把原内容放回去，
    # 不让一次失败的运行把已有译文清掉。
    original = open(APP_CATALOG, encoding="utf-8").read()
    written = False
    try:
        keys = [k for k in exported_keys() if k not in INFO and k not in UNTRANSLATED]
        missing = sorted(k for k in keys if k not in ZH)
        extra = sorted(k for k in ZH if k not in keys)
        if missing or extra:
            print("缺少翻译:", *missing, sep="\n  ")
            print("多余的翻译（源码里已不存在）:", *extra, sep="\n  ")
            sys.exit(1)
        write_catalog(APP_CATALOG, {k: ZH[k] for k in keys})
        write_catalog(INFO_CATALOG, INFO)
        written = True
    finally:
        if not written:
            with open(APP_CATALOG, "w", encoding="utf-8") as f:
                f.write(original)
    print(f"已写入 {len(keys)} 条界面文案和 {len(INFO)} 条系统文案")


if __name__ == "__main__":
    main()
