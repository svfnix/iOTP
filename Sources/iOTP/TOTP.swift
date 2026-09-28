import Foundation
import CryptoKit

enum OTPAlgorithm: String, Codable, CaseIterable, Identifiable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    var id: String { rawValue }
}

enum TOTP {
    private static let powers: [UInt32] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

    /// RFC 6238 time-based code. `counterOverride` exists so HOTP-style entries can reuse the math.
    static func code(secret: Data,
                     algorithm: OTPAlgorithm = .sha1,
                     digits: Int = 6,
                     period: Int = 30,
                     date: Date = Date()) -> String {
        let step = max(1, period)
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(step))))
        return code(secret: secret, algorithm: algorithm, digits: digits, counter: counter)
    }

    static func code(secret: Data, algorithm: OTPAlgorithm, digits: Int, counter: UInt64) -> String {
        guard !secret.isEmpty else { return String(repeating: "0", count: digits) }

        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)

        let mac: Data
        switch algorithm {
        case .sha1:
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])

        let clamped = min(max(digits, 1), 8)
        let value = truncated % powers[clamped]
        return String(format: "%0\(clamped)u", value)
    }

    /// Seconds remaining before the current code rolls over.
    static func secondsRemaining(period: Int, date: Date = Date()) -> Int {
        let step = max(1, period)
        let elapsed = Int(floor(date.timeIntervalSince1970)) % step
        return step - elapsed
    }

    static func progress(period: Int, date: Date = Date()) -> Double {
        let step = max(1, period)
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(step))
        return elapsed / Double(step)
    }
}
