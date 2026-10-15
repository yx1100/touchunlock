import Foundation

/// 设备用固件里的 ASCII→HID 键码表输入密码，该表覆盖全部 95 个可打印 ASCII 字符，
/// 其余字符（中文、emoji 等）无法输入，会让解锁静默失败，所以设置时拒绝。
public enum PasswordPolicy {
    public static let maxLength = 64

    public static func isValid(_ password: String) -> Bool {
        let bytes = password.utf8
        return !bytes.isEmpty && bytes.count <= maxLength && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }
}
