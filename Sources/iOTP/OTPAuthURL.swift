import Foundation

/// A TOTP configuration parsed out of an `otpauth://` URI or a Google Authenticator export.
struct OTPConfig: Equatable {
    var secret: Data
    var issuer: String = ""
    var account: String = ""
    var algorithm: OTPAlgorithm = .sha1
    var digits: Int = 6
    var period: Int = 30

    var displayName: String {
        switch (issuer.isEmpty, account.isEmpty) {
        case (false, false): return "\(issuer) (\(account))"
        case (false, true): return issuer
        case (true, false): return account
        case (true, true): return "Unnamed"
        }
    }
}

enum OTPAuthURL {
    enum ParseError: LocalizedError {
        case notOTPAuth
        case unsupportedType(String)
        case missingSecret
        case badSecret

        var errorDescription: String? {
            switch self {
            case .notOTPAuth:
                return "This is not an otpauth:// link or a Google Authenticator export."
            case .unsupportedType(let type):
                return "OTP type “\(type)” is not supported — only time-based (TOTP) codes are."
            case .missingSecret:
                return "The link has no secret parameter."
            case .badSecret:
                return "The secret is not valid base32."
            }
        }
    }

    /// Parses either a single `otpauth://totp/...` URI or an `otpauth-migration://` export payload.
    static func parse(_ text: String) throws -> [OTPConfig] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth-migration://") {
            return try MigrationPayload.parse(trimmed)
        }
        return [try parseSingle(trimmed)]
    }

    static func parseSingle(_ text: String) throws -> OTPConfig {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "otpauth" else {
            throw ParseError.notOTPAuth
        }

        let type = (components.host ?? "").lowercased()
        guard type == "totp" else { throw ParseError.unsupportedType(type.isEmpty ? "unknown" : type) }

        let items = components.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let secretString = query("secret"), !secretString.isEmpty else { throw ParseError.missingSecret }
        guard let secret = Base32.decode(secretString) else { throw ParseError.badSecret }

        // Label is "/Issuer:account" or just "/account".
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        label = label.removingPercentEncoding ?? label

        var issuer = query("issuer")?.removingPercentEncoding ?? ""
        var account = label
        if let separator = label.firstIndex(where: { $0 == ":" }) {
            let prefix = String(label[label.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let rest = String(label[label.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                if issuer.isEmpty { issuer = prefix }
                account = rest
            }
        }

        var config = OTPConfig(secret: secret, issuer: issuer, account: account)
        if let algorithm = query("algorithm"), let parsed = OTPAlgorithm(rawValue: algorithm.uppercased()) {
            config.algorithm = parsed
        }
        if let digits = query("digits"), let parsed = Int(digits), (6...8).contains(parsed) {
            config.digits = parsed
        }
        if let period = query("period"), let parsed = Int(period), parsed > 0 {
            config.period = parsed
        }
        return config
    }
}

/// Minimal reader for the protobuf payload behind Google Authenticator's "Transfer accounts" QR code.
private enum MigrationPayload {
    static func parse(_ urlString: String) throws -> [OTPConfig] {
        guard let components = URLComponents(string: urlString),
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw OTPAuthURL.ParseError.notOTPAuth
        }

        var base64 = encoded
        // URLComponents already percent-decodes, but some QR payloads double-encode the "+".
        base64 = base64.replacingOccurrences(of: " ", with: "+")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { throw OTPAuthURL.ParseError.notOTPAuth }

        var configs: [OTPConfig] = []
        for field in Wire.fields(in: data) where field.number == 1 {
            guard case .bytes(let payload) = field.value else { continue }
            if let config = parseParameters(payload) { configs.append(config) }
        }
        guard !configs.isEmpty else { throw OTPAuthURL.ParseError.missingSecret }
        return configs
    }

    private static func parseParameters(_ data: Data) -> OTPConfig? {
        var secret: Data?
        var name = ""
        var issuer = ""
        var algorithm = OTPAlgorithm.sha1
        var digits = 6
        var isTOTP = true

        for field in Wire.fields(in: data) {
            switch (field.number, field.value) {
            case (1, .bytes(let value)):
                secret = value
            case (2, .bytes(let value)):
                name = String(data: value, encoding: .utf8) ?? ""
            case (3, .bytes(let value)):
                issuer = String(data: value, encoding: .utf8) ?? ""
            case (4, .varint(let value)):
                // 1 = SHA1, 2 = SHA256, 3 = SHA512, 4 = MD5 (unsupported).
                algorithm = value == 2 ? .sha256 : (value == 3 ? .sha512 : .sha1)
            case (5, .varint(let value)):
                digits = value == 2 ? 8 : 6
            case (6, .varint(let value)):
                isTOTP = value != 1 // 1 = HOTP, 2 = TOTP
            default:
                break
            }
        }

        guard isTOTP, let secret, !secret.isEmpty else { return nil }

        // The export packs "Issuer:account" into the name field as well.
        var account = name
        if let separator = name.firstIndex(of: ":") {
            let prefix = String(name[name.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                if issuer.isEmpty { issuer = prefix }
                account = String(name[name.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return OTPConfig(secret: secret, issuer: issuer, account: account, algorithm: algorithm, digits: digits)
    }
}

/// Just enough protobuf wire-format decoding for the migration payload above.
private enum Wire {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed(UInt64)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    static func fields(in data: Data) -> [Field] {
        var result: [Field] = []
        var index = data.startIndex

        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < data.endIndex {
            guard let key = varint() else { break }
            let number = Int(key >> 3)
            switch key & 0x07 {
            case 0:
                guard let value = varint() else { return result }
                result.append(Field(number: number, value: .varint(value)))
            case 1:
                guard data.distance(from: index, to: data.endIndex) >= 8 else { return result }
                let end = data.index(index, offsetBy: 8)
                let chunk = data[index..<end]
                index = end
                result.append(Field(number: number, value: .fixed(chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })))
            case 2:
                guard let length = varint(),
                      data.distance(from: index, to: data.endIndex) >= Int(length) else { return result }
                let end = data.index(index, offsetBy: Int(length))
                result.append(Field(number: number, value: .bytes(Data(data[index..<end]))))
                index = end
            case 5:
                guard data.distance(from: index, to: data.endIndex) >= 4 else { return result }
                let end = data.index(index, offsetBy: 4)
                let chunk = data[index..<end]
                index = end
                result.append(Field(number: number, value: .fixed(chunk.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })))
            default:
                return result
            }
        }
        return result
    }
}
