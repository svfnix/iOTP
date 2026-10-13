// Compile with the sources under test:
//   swiftc -o /tmp/iotp-selftest tools/SelfTest.swift Sources/iOTP/TOTP.swift Sources/iOTP/Base32.swift Sources/iOTP/OTPAuthURL.swift && /tmp/iotp-selftest
import Foundation

var failures = 0

func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("  ok   \(label): \(actual)")
    } else {
        print("  FAIL \(label): got \(actual), expected \(expected)")
        failures += 1
    }
}

func check(_ label: String, _ condition: Bool) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

print("RFC 6238 test vectors")
let sha1Secret = Data("12345678901234567890".utf8)
let sha256Secret = Data("12345678901234567890123456789012".utf8)
let sha512Secret = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

check("SHA1  T=59", TOTP.code(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30, date: at(59)), "94287082")
check("SHA1  T=1111111109", TOTP.code(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30, date: at(1111111109)), "07081804")
check("SHA1  T=1234567890", TOTP.code(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30, date: at(1234567890)), "89005924")
check("SHA1  T=2000000000", TOTP.code(secret: sha1Secret, algorithm: .sha1, digits: 8, period: 30, date: at(2000000000)), "69279037")
check("SHA256 T=59", TOTP.code(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30, date: at(59)), "46119246")
check("SHA256 T=1111111109", TOTP.code(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30, date: at(1111111109)), "68084774")
check("SHA256 T=1234567890", TOTP.code(secret: sha256Secret, algorithm: .sha256, digits: 8, period: 30, date: at(1234567890)), "91819424")
check("SHA512 T=59", TOTP.code(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30, date: at(59)), "90693936")
check("SHA512 T=1111111109", TOTP.code(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30, date: at(1111111109)), "25091201")
check("SHA512 T=1234567890", TOTP.code(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30, date: at(1234567890)), "93441116")
check("SHA512 T=20000000000", TOTP.code(secret: sha512Secret, algorithm: .sha512, digits: 8, period: 30, date: at(20000000000)), "47863826")
check("6 digits truncates correctly", TOTP.code(secret: sha1Secret, algorithm: .sha1, digits: 6, period: 30, date: at(59)), "287082")

print("\nBase32")
check("decode/encode round trip", Base32.encode(Base32.decode("JBSWY3DPEHPK3PXP")!), "JBSWY3DPEHPK3PXP")
check("decodes ASCII secret", Base32.decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == sha1Secret)
check("ignores spaces and padding", Base32.decode("JBSW Y3DP EHPK 3PXP=") == Base32.decode("JBSWY3DPEHPK3PXP"))
check("rejects invalid characters", Base32.decode("!!!!") == nil)

print("\notpauth:// parsing")
do {
    let config = try OTPAuthURL.parseSingle("otpauth://totp/GitHub:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA256&digits=8&period=60")
    check("issuer", config.issuer, "GitHub")
    check("account", config.account, "alice@example.com")
    check("algorithm", config.algorithm.rawValue, "SHA256")
    check("digits", "\(config.digits)", "8")
    check("period", "\(config.period)", "60")
    check("secret", Base32.encode(config.secret), "JBSWY3DPEHPK3PXP")
} catch {
    print("  FAIL parse: \(error)")
    failures += 1
}

do {
    let config = try OTPAuthURL.parseSingle("otpauth://totp/alice%40example.com?secret=JBSWY3DPEHPK3PXP")
    check("label-only account", config.account, "alice@example.com")
    check("defaults", "\(config.algorithm.rawValue)/\(config.digits)/\(config.period)", "SHA1/6/30")
} catch {
    print("  FAIL parse minimal: \(error)")
    failures += 1
}

check("rejects hotp", (try? OTPAuthURL.parseSingle("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1")) == nil)
check("rejects non-otpauth", (try? OTPAuthURL.parseSingle("https://example.com")) == nil)
check("rejects missing secret", (try? OTPAuthURL.parseSingle("otpauth://totp/x")) == nil)

print("\nGoogle Authenticator export payload")
// Hand-built MigrationPayload: two otp_parameters entries.
func varint(_ value: UInt64) -> Data {
    var v = value
    var out = Data()
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v > 0 { byte |= 0x80 }
        out.append(byte)
    } while v > 0
    return out
}
func lengthDelimited(field: Int, _ payload: Data) -> Data {
    varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload
}
func varintField(_ field: Int, _ value: UInt64) -> Data {
    varint(UInt64(field << 3)) + varint(value)
}

let paramA = lengthDelimited(field: 1, sha1Secret)
    + lengthDelimited(field: 2, Data("Acme:bob@acme.io".utf8))
    + lengthDelimited(field: 3, Data("Acme".utf8))
    + varintField(4, 1) + varintField(5, 1) + varintField(6, 2)
let paramB = lengthDelimited(field: 1, sha256Secret)
    + lengthDelimited(field: 2, Data("second@site.com".utf8))
    + lengthDelimited(field: 3, Data("Site".utf8))
    + varintField(4, 2) + varintField(5, 2) + varintField(6, 2)
let hotpParam = lengthDelimited(field: 1, sha1Secret)
    + lengthDelimited(field: 2, Data("counter-based".utf8))
    + varintField(6, 1)

let payload = lengthDelimited(field: 1, paramA) + lengthDelimited(field: 1, paramB)
    + lengthDelimited(field: 1, hotpParam) + varintField(2, 1)
let encoded = payload.base64EncodedString()
    .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

do {
    let configs = try OTPAuthURL.parse("otpauth-migration://offline?data=\(encoded)")
    check("skips HOTP entries, keeps 2", "\(configs.count)", "2")
    check("first issuer", configs[0].issuer, "Acme")
    check("first account", configs[0].account, "bob@acme.io")
    check("first code matches RFC vector",
          TOTP.code(secret: configs[0].secret, algorithm: configs[0].algorithm, digits: 8, period: 30, date: at(59)),
          "94287082")
    check("second algorithm/digits", "\(configs[1].algorithm.rawValue)/\(configs[1].digits)", "SHA256/8")
} catch {
    print("  FAIL migration parse: \(error)")
    failures += 1
}

print("\nEncrypted file storage")
// Points the storage layer at a scratch directory. This must be an explicit override: setting HOME
// does not move Application Support, so the test would otherwise destroy the real vault.
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iotp-storage-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
VaultStorage.directoryOverride = sandbox

// Guard the guard: if the override ever stops working, fail loudly instead of deleting real data.
let realVault = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("iOTP", isDirectory: true)
check("storage tests are sandboxed", VaultStorage.directory.path != realVault.path)
guard VaultStorage.directory.path != realVault.path else {
    print("\nRefusing to run storage tests against the real vault.")
    exit(1)
}

do {
    check("nothing stored yet", try VaultStorage.load() == nil)

    let secretPayload = Data(#"[{"name":"Gmail","password":"hunter2"}]"#.utf8)
    try VaultStorage.save(secretPayload)
    check("round trips", try VaultStorage.load() == secretPayload)

    let vaultFile = VaultStorage.directory.appendingPathComponent("vault.dat")
    let keyFile = VaultStorage.directory.appendingPathComponent("key.bin")
    let onDisk = try Data(contentsOf: vaultFile)
    check("password is not readable on disk", onDisk.range(of: Data("hunter2".utf8)) == nil)

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
    check("vault file is owner-only", String(format: "%o", try permissions(vaultFile)), "600")
    check("key file is owner-only", String(format: "%o", try permissions(keyFile)), "600")

    let updated = Data(#"[{"name":"Binance"}]"#.utf8)
    try VaultStorage.save(updated)
    check("overwrites cleanly", try VaultStorage.load() == updated)

    VaultStorage.removeFile()
    check("removeFile clears it", try VaultStorage.load() == nil)
} catch {
    print("  FAIL storage: \(error)")
    failures += 1
}
try? FileManager.default.removeItem(at: sandbox)

print("\nCountdown")
check("30s period at t=0", "\(TOTP.secondsRemaining(period: 30, date: at(0)))", "30")
check("30s period at t=25", "\(TOTP.secondsRemaining(period: 30, date: at(25)))", "5")
check("progress at t=15", "\(TOTP.progress(period: 30, date: at(15)))", "0.5")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
