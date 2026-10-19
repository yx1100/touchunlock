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
    "Press and hold the button on the reader for 3 seconds.": "长按识别器上的按钮 3 秒。",
    "The light blinks quickly to confirm pairing mode.": "指示灯快速闪烁即已进入配对模式。",
    "Pairing mode lasts about a minute; a short press ends it early.": "配对模式持续约 1 分钟，短按一次可提前结束。",
    "Pairing replaces the device this reader was bound to before.": "重新配对会覆盖此前绑定的设备。",
    "Needed only when the reader has to learn this Mac again, for example after it was forgotten in Bluetooth settings.": "仅在识别器需要重新认这台 Mac 时使用，例如曾在系统蓝牙中忘记过它。",
    "Recognized: %@": "已识别：%@",
    "Stop Testing": "结束测试",
    # UI 重构新增（权限改名、指纹改名、版本号）
    "Device Control and Data Access": "设备控制和数据访问",
    "Allowed": "已允许",
    "Allow…": "允许…",
    "Open System Settings…": "打开系统设置…",
    "Already denied once?": "此前拒绝过？",
    "Device Control and Data Access is allowed.": "已允许「设备控制和数据访问」。",
    "Rename": "改名",
    "Add a fingerprint first.": "请先添加一枚指纹。",
    "Test the reader": "测试识别器",
    "Rename Fingerprint %lld": "重命名指纹 %lld",
    "Name": "名字",
    "The name is kept on this Mac only. Fingerprints are stored by number on the device.": "名字仅保存在本机。设备按编号存储指纹。",
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
    "Types this password when a window is asking for one. The lock screen always uses the system password.": "有窗口等待密码时输入此处设置的密码。锁屏一律使用系统密码。",
    "Lets the app tell when a window is asking for a password. Without it only secure password prompts are recognized.": "用于判断前台窗口是否在等待密码。未授权时只能识别安全密码输入框。",
    "Pulse the Reader's Light": "有窗口等密码时闪灯",
    "A panel appears after the device types a password or a manual test runs. The reader's light blinks while a window is asking for a password.": "设备输入密码后或手动测试后会显示提示面板。有窗口在等待密码时，识别器指示灯闪烁。",
    "Allow Device Control and Data Access so the app can tell when a window is asking for a password.": "请允许「设备控制和数据访问」，应用需要据此判断窗口是否在等待密码。",
    "%@ · firmware %@": "%@ · 固件 %@",
    "%lld enrolled.": "已录入 %lld 枚。",
    "%lld of %lld": "%lld / %lld",
    "%lld step(s) left.": "还差 %lld 步。",
    "Add Fingerprint": "添加指纹",
    "Add a fingerprint to unlock with a touch.": "添加指纹后，轻触传感器即可解锁。",
    "Advanced": "高级",
    "How It Works": "工作方式",
    "The device types the password only while this app is running.": "仅在触达运行时，设备才会键入密码。",
    "The device types the password only while this app is running. Keep it running and turn on Open at Login.": "仅在触达运行时，设备才会键入密码。请保持其运行，并开启「登录时打开」。",
    "Allow Bluetooth for TouchUnlock in Privacy & Security.": "请在“隐私与安全性”中允许触达使用蓝牙。",
    "Almost done.": "马上就好。",
    "Bluetooth Settings": "蓝牙设置",
    "Bluetooth Settings…": "蓝牙设置…",
    "Bluetooth access denied": "蓝牙权限被拒绝",
    "Bluetooth is not supported": "此 Mac 不支持蓝牙",
    "Bluetooth is off": "蓝牙已关闭",
    "Bluetooth is the only permission it requests.": "只申请蓝牙一项权限。",
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
    "Shortcut…": "快捷键…",
    "Click to Record": "点击录制",
    "Press a shortcut…": "请按下快捷键…",
    "Clear": "清除",
    "Presses this shortcut when the finger is recognized and no window is asking for a password.": "识别到这根手指、且没有窗口在等密码时，按下此快捷键。",
    "Shortcut not sent: allow Device Control and Data Access first.": "快捷键未发出：请先允许「设备控制和数据访问」。",
    "Ignored Apps": "忽略的应用",
    "Add App…": "添加应用…",
    "Remove": "移除",
    "Choose an app to ignore": "选择要忽略的应用",
    "The device does not type a password while one of these apps is in front. The lock screen is not affected.": "这些应用位于前台时，设备不会输入密码。锁屏不受影响。",
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
    "Search Again": "重新搜索",
    "Search for the Device Again": "重新搜索设备",
    "Search for the device again?": "重新搜索设备？",
    "Use this when the app cannot find the device, for example after pairing it again in Bluetooth settings. Nothing on the device is erased.": "在应用找不到设备时使用，例如曾在系统蓝牙里重新配对过。不会清除设备中的任何数据。",
    "General": "通用",
    "Get Ready": "准备工作",
    "Good to Know": "使用须知",
    "Linking the Password": "正在关联密码",
    "Log": "日志",
    "Mac login password": "Mac 登录密码",
    "Make sure the device is powered on.": "请确认设备已通电。",
    "New fingerprints will no longer link automatically, and deleting one will no longer ask for the password.": "新录入的指纹将不再自动关联密码，删除指纹时也不再要求输入密码。",
    "No Fingerprints": "没有指纹",
    "No Log Entries": "没有日志",
    "No finger was detected in time.": "等待手指超时。",
    "No network access. The app contains no networking code.": "不联网。应用不含任何网络代码。",
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
    "Remove the copy from this Mac?": "移除本机上的副本？",
    "Remove Copy": "移除副本",
    "Removed the copy on this Mac. The device keeps its own copy.": "已移除本机上的副本，设备里仍保留着密码。",
    "Save to Device": "保存到设备",
    "Saved on the device and in this Mac's keychain.": "已保存到设备和本机钥匙串。",
    "Searching for the device…": "正在搜索设备…",
    "Set Password": "设置密码",
    "Set the unlock password": "设置解锁密码",
    "Set the unlock password first.": "请先设置解锁密码。",
    "Settings": "设置",
    "Show Password": "显示密码",
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
    "The app restarts its search. Nothing on the device is erased.": "应用将重新开始搜索。不会清除设备中的任何数据。",
    "The connection to the device was lost.": "与设备的连接已断开。",
    "The device accepted the password, but saving it to the keychain failed.": "设备已接受密码，但保存到钥匙串失败。",
    "The device is not connected.": "设备未连接。",
    "The device rejected the password.": "设备拒绝了该密码。",
    "Stored on the device and typed after a fingerprint match. Saving also updates every enrolled fingerprint.": "密码保存在设备中，指纹匹配后由设备键入。保存时同步更新全部已录入指纹。",
    "The fingerprint was enrolled, but binding the password failed.": "指纹已录入，但关联密码失败。",
    "The log never contains passwords.": "日志不包含密码。",
    "The password copy stays in this Mac's keychain.": "密码副本保存在本机钥匙串中。",
    "The password is incorrect.": "密码不正确。",
    "There is no free fingerprint slot.": "没有空闲的指纹位。",
    "This Mac cannot use Bluetooth Low Energy.": "这台 Mac 无法使用低功耗蓝牙。",
    "This cannot be undone.": "此操作无法撤销。",
    "This finger is already enrolled.": "这根手指已经录入过。",
    "Touch an enrolled finger to unlock.": "触碰已录入的手指即可解锁。",
    "Touch the sensor with this finger to unlock.": "用这根手指触碰传感器即可解锁。",
    "Try Again": "重试",
    "Turn Bluetooth on to connect.": "请打开蓝牙后再连接。",
    "Unlock password not set": "尚未设置解锁密码",
    "Unlock password set": "解锁密码已设置",
    "Unlock Password": "解锁密码",
    "Unlock password": "解锁密码",
    "Use 1 to %lld printable ASCII characters.": "请使用 1 到 %lld 个可打印的 ASCII 字符。",
    "Use printable ASCII only, up to %lld characters.": "仅限可打印的 ASCII 字符，最多 %lld 个。",
    "Links new fingerprints and confirms deletions. It never leaves this Mac.": "用于关联新指纹与确认删除操作。不会离开这台 Mac。",
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
