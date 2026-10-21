import AppKit

/// 指纹触发的快捷键：虚拟键码加修饰键。
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` 的原始值，只保留 ⌃⌥⇧⌘。
    var modifiers: UInt
    /// 录入时按键的字符，只用于显示。
    var label: String

    private static let mask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// 常用的非字符键。字符键直接取事件里的字符。
    private static let names: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags.intersection(Self.mask).rawValue
        label = Self.names[event.keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
            + label
    }

    /// 向系统发出这组按键。需要「辅助功能」授权，否则事件会被丢弃。
    func post() {
        // NSEvent 与 CGEvent 的修饰键位相同。
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// 用系统按键事件把一段文字逐字打出来，再按回车。需要「辅助功能」授权。
enum KeyTyper {
    static func typeAndReturn(_ text: String) {
        DispatchQueue.global(qos: .userInteractive).async {
            for character in text {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.post(tap: .cghidEventTap)
                }
                usleep(12_000)
            }
            usleep(60_000)
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }
}
