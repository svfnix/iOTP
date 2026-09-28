import Foundation
import CryptoKit

enum StorageBackend: String, CaseIterable, Identifiable {
    case file
    case keychain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .file: return "Encrypted file"
        case .keychain: return "Login keychain"
        }
    }

    var explanation: String {
        switch self {
        case .file:
            return "Kept in ~/Library/Application Support/iOTP, encrypted and readable only by your "
                 + "user account. macOS never asks for a password."
        case .keychain:
            return "Guarded by macOS itself, but because this build is ad-hoc signed the system asks "
                 + "for your login password on nearly every access."
        }
    }
}

/// Reads and writes the vault blob. The file backend exists because an ad-hoc signed app has no
/// stable code identity, so the keychain cannot remember an "always allow" decision for it.
enum VaultStorage {
    static var backend: StorageBackend {
        get {
            UserDefaults.standard.string(forKey: AppSettings.storageBackendKey)
                .flatMap(StorageBackend.init(rawValue:)) ?? .file
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.storageBackendKey)
        }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iOTP", isDirectory: true)
    }

    private static var vaultURL: URL { directory.appendingPathComponent("vault.dat") }
    private static var keyURL: URL { directory.appendingPathComponent("key.bin") }

    // MARK: - Public API

    static func load() throws -> Data? {
        switch backend {
        case .keychain:
            return try Keychain.read()
        case .file:
            if let data = try readFile() { return data }
            // One-time hand-over from the keychain this app used to write to.
            guard Keychain.exists(), let legacy = try Keychain.read() else { return nil }
            try writeFile(legacy)
            try? Keychain.delete()
            return legacy
        }
    }

    static func save(_ data: Data) throws {
        switch backend {
        case .keychain: try Keychain.write(data)
        case .file: try writeFile(data)
        }
    }

    static func removeFile() {
        try? FileManager.default.removeItem(at: vaultURL)
    }

    // MARK: - Encrypted file

    private static func readFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return nil }
        let sealed = try Data(contentsOf: vaultURL)
        guard !sealed.isEmpty else { return nil }
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: fileKey())
    }

    private static func writeFile(_ data: Data) throws {
        try ensureDirectory()
        let sealed = try AES.GCM.seal(data, using: fileKey()).combined ?? Data()
        try sealed.write(to: vaultURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    /// The key sits next to the vault with 0600 permissions: the protection here is your account's
    /// file ownership, the encryption keeps the secrets out of backups and casual greps.
    private static func fileKey() throws -> SymmetricKey {
        try ensureDirectory()

        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try raw.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }

    private static func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
