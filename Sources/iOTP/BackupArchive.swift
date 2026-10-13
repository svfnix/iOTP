import Foundation
import CryptoKit
import CommonCrypto

/// Reads and writes the passphrase-protected backup file.
///
/// The vault on disk is encrypted with a key that sits beside it, which is fine against casual
/// snooping but useless as a backup: lose the disk and you lose the key. A backup has to travel,
/// so it is sealed with a key derived from a passphrase the person types — nothing about it depends
/// on this machine.
enum BackupArchive {
    static let fileExtension = "iotpbackup"

    private static let format = "iotp.backup"
    private static let currentVersion = 1
    private static let kdfName = "PBKDF2-HMAC-SHA256"
    private static let iterations = 310_000  // OWASP's 2023 floor for PBKDF2-HMAC-SHA256
    private static let saltSize = 16
    private static let keySize = 32

    enum ArchiveError: LocalizedError {
        case malformed
        case unsupportedVersion(Int)
        case unsupportedKDF(String)
        case wrongPassphrase
        case emptyPassphrase
        case derivationFailed

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "That file is not an iOTP backup."
            case .unsupportedVersion(let version):
                return "This backup was written by a newer version of iOTP (format \(version))."
            case .unsupportedKDF(let name):
                return "This backup uses an unknown key derivation (\(name))."
            case .wrongPassphrase:
                return "Wrong passphrase, or the backup file has been altered."
            case .emptyPassphrase:
                return "Choose a passphrase — a backup with an empty one protects nothing."
            case .derivationFailed:
                return "Could not derive a key from that passphrase."
            }
        }
    }

    /// The envelope is plain JSON so a future version — or a careful human — can tell what it is
    /// and how it was sealed without having to guess.
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var payload: Data
        var createdAt: Date
    }

    // MARK: - Sealing

    static func seal(_ payload: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw ArchiveError.emptyPassphrase }

        var salt = Data(count: saltSize)
        let generated = salt.withUnsafeMutableBytes { buffer -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, buffer.baseAddress!)
        }
        guard generated == errSecSuccess else { throw ArchiveError.derivationFailed }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw ArchiveError.derivationFailed }

        let envelope = Envelope(format: format,
                                version: currentVersion,
                                kdf: kdfName,
                                iterations: iterations,
                                salt: salt,
                                payload: combined,
                                createdAt: Date())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    static func open(_ archive: Data, passphrase: String) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let envelope = try? decoder.decode(Envelope.self, from: archive),
              envelope.format == format else {
            throw ArchiveError.malformed
        }
        guard envelope.version <= currentVersion else {
            throw ArchiveError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == kdfName else {
            throw ArchiveError.unsupportedKDF(envelope.kdf)
        }
        guard envelope.iterations > 0, !envelope.salt.isEmpty else {
            throw ArchiveError.malformed
        }

        let key = try deriveKey(passphrase: passphrase,
                                salt: envelope.salt,
                                iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.payload),
              let opened = try? AES.GCM.open(box, using: key) else {
            // GCM fails the same way for a wrong key and for tampering; both mean "don't trust it".
            throw ArchiveError.wrongPassphrase
        }
        return opened
    }

    /// Describes a file without decrypting it, so the restore sheet can show what is being opened.
    static func inspect(_ archive: Data) -> Date? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: archive),
              envelope.format == format else { return nil }
        return envelope.createdAt
    }

    // MARK: - Key derivation

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: keySize)

        let status = passwordBytes.withUnsafeBufferPointer { password in
            password.baseAddress!.withMemoryRebound(to: CChar.self, capacity: password.count) { passwordChars in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordChars,
                                         password.count,
                                         saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations),
                                         &derived,
                                         keySize)
                }
            }
        }

        guard status == kCCSuccess else { throw ArchiveError.derivationFailed }
        return SymmetricKey(data: Data(derived))
    }
}
