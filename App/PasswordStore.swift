import Foundation
import Security

/// 登录钥匙串里的解锁密码副本。用于本机校验（删除指纹前确认）和给新指纹自动绑定密码。
/// 不联网、不同步 iCloud（kSecAttrSynchronizable = false）；钥匙串项的访问控制绑定本应用的代码签名。
///
/// 已知限制：`kSecAttrAccessible` 只对**数据保护钥匙串**生效（Apple 文档说明该属性配合
/// `kSecUseDataProtectionKeychain` 使用）。这里用的是登录钥匙串，属性会被忽略，
/// 所以这份副本会跟着钥匙串备份/迁移到别的 Mac。要挡住这一条得整体换到数据保护钥匙串，
/// 那会改变条目所在钥匙串，需要一条迁移路径，见交付说明。
enum PasswordStore {
    static let service = "local.touchunlock.password"
    static let defaultAccount = "default"

    /// 某枚指纹单独设置的密码存在这个账户下。没有单独设置时，该指纹用系统密码。
    static func fingerprintAccount(_ id: Int) -> String { "fp:\(id)" }

    enum StoreError: Error { case keychain(OSStatus) }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// 写入属性。`kSecAttrAccessible` 在登录钥匙串里不生效，但不会报错（已实测），
    /// 留着是为了迁移到数据保护钥匙串后自动获得「仅本机」保护。
    private static func attributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }

    static func save(_ password: String, account: String = defaultAccount) throws {
        let attributes = attributes(Data(password.utf8))
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound:
            var item = query(account)
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { throw StoreError.keychain(added) }
        default: throw StoreError.keychain(status)
        }
    }

    static func load(account: String = defaultAccount) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func exists(account: String = defaultAccount) -> Bool {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String = defaultAccount) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
