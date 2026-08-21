//
//  SecretStore.swift
//  TermoraX
//
//  Session passwords live in an AES-GCM vault under Application Support.
//  The file is not readable as plaintext; the key is derived from a
//  compile-time pepper, this Mac's hardware UUID, and the login name.
//

import CommonCrypto
import CryptoKit
import Foundation
import IOKit
import Security

/// 会话密码保险库。文件在 Application Support；密钥绑定本机与当前用户。
enum SecretStore {
    private static let magic = Data([0x54, 0x58, 0x43, 0x31]) // TXC1
    private static let version: UInt8 = 1
    private static let saltLength = 16
    private static let pbkdfRounds: UInt32 = 80_000
    private static let keyLength = 32
    /// Split so `strings` on the binary does not yield a ready-made passphrase.
    private static let pepper: [UInt8] = [
        0x5C, 0xE1, 0x3A, 0x90, 0xB7, 0x2D, 0x4F, 0x18,
        0xC6, 0x81, 0x0E, 0xD4, 0x67, 0xA9, 0x33, 0xF2,
        0x1B, 0x8C, 0x55, 0xE7, 0x02, 0x9A, 0x4D, 0x70,
        0xBE, 0x14, 0x6F, 0xC3, 0x88, 0x21, 0xDA, 0x05,
    ]
    private static let keychainService = "com.gllis.TermoraX.session"

    private static let lock = NSLock()
    private static var cached: (salt: Data, key: SymmetricKey)?

    static func setPassword(_ password: String, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        migrateKeychainIfNeeded()
        var map = loadMap()
        if password.isEmpty {
            map.removeValue(forKey: id.uuidString)
        } else {
            map[id.uuidString] = password
        }
        saveMap(map)
    }

    static func password(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        migrateKeychainIfNeeded()
        return loadMap()[id.uuidString]
    }

    static func deletePassword(for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        migrateKeychainIfNeeded()
        var map = loadMap()
        map.removeValue(forKey: id.uuidString)
        saveMap(map)
    }

    private static var fileURL: URL {
        AppPaths.support.appendingPathComponent("credentials.vault")
    }

    private static func loadMap() -> [String: String] {
        guard let blob = try? Data(contentsOf: fileURL), blob.count > 8 else { return [:] }
        guard blob.starts(with: magic), blob[4] == version else { return [:] }
        let salt = blob.subdata(in: 5..<(5 + saltLength))
        let combined = blob.subdata(in: (5 + saltLength)..<blob.count)
        guard let key = key(salt: salt),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key),
              let map = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return [:] }
        return map
    }

    private static func saveMap(_ map: [String: String]) {
        let url = fileURL
        if map.isEmpty {
            try? FileManager.default.removeItem(at: url)
            cached = nil
            return
        }
        do {
            let salt = cached?.salt ?? randomBytes(saltLength)
            guard let key = key(salt: salt) else { return }
            let payload = try JSONEncoder().encode(map)
            let sealed = try AES.GCM.seal(payload, using: key)
            guard let combined = sealed.combined else { return }
            var blob = Data()
            blob.append(magic)
            blob.append(version)
            blob.append(salt)
            blob.append(combined)
            try blob.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        } catch {
            return
        }
    }

    private static func key(salt: Data) -> SymmetricKey? {
        if let cached, cached.salt == salt { return cached.key }
        var material = Data(pepper)
        material.append(machineID())
        material.append(Data(NSUserName().utf8))

        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            material.withUnsafeBytes { materialBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        materialBytes.bindMemory(to: CChar.self).baseAddress,
                        material.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdfRounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let key = SymmetricKey(data: derived)
        cached = (salt, key)
        return key
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }

    private static func machineID() -> Data {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return Data(NSUserName().utf8) }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return Data(NSUserName().utf8)
        }
        return Data(cf.utf8)
    }

    /// One-shot move from the previous Keychain store into the vault.
    private static func migrateKeychainIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]], !items.isEmpty else {
            return
        }
        var map = loadMap()
        var changed = false
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else { continue }
            if map[account] == nil {
                map[account] = password
                changed = true
            }
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
        if changed { saveMap(map) }
    }
}
