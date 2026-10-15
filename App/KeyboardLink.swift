import Foundation
import IOKit

/// 设备要靠蓝牙 HID 键盘输入密码。系统蓝牙列表里显示「已连接」不代表键盘可用：
/// 配对记录不一致时，系统不会为它创建 HID 设备，设备发出的按键无人接收。
/// 这里只读 IORegistry，不打开设备，不需要「输入监控」权限。
enum KeyboardLink {
    static let productName = "Durian Touch"
    static let transport = "Bluetooth Low Energy"

    // 这几个常量若每次都新建，一次查询就要为每台 HID 设备分配若干 CFString。
    private static let transportKey = "Transport" as CFString
    private static let productKey = "Product" as CFString
    private static let transportValue = "Bluetooth Low Energy" as CFString

    static func isPresent() -> Bool {
        // 在匹配阶段就把范围收窄到「低功耗蓝牙」的 HID 设备：原先会把系统里所有 HID 设备
        // （键盘、鼠标、触控板以及各种虚拟设备）都枚举一遍，每台都要取两个属性。
        guard let match = IOServiceMatching("IOHIDDevice") else { return false }
        CFDictionarySetValue(match,
                             Unmanaged.passUnretained(transportKey).toOpaque(),
                             Unmanaged.passUnretained(transportValue).toOpaque())
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if property(entry, productKey) == productName { return true }
        }
        return false
    }

    private static func property(_ entry: io_registry_entry_t, _ key: CFString) -> String? {
        IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
