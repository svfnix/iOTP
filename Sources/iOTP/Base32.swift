import Foundation

/// RFC 4648 base32 (the encoding every authenticator app uses for OTP secrets).
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static let reverse: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        // A couple of forgiving aliases for hand-typed secrets.
        map["0"] = map["O"]
        map["1"] = map["L"]
        map["8"] = map["B"]
        return map
    }()

    static func decode(_ string: String) -> Data? {
        var buffer: UInt32 = 0
        var bitsLeft = 0
        var out = Data()

        for raw in string.uppercased() {
            if raw == "=" || raw == " " || raw == "-" || raw == "\n" || raw == "\r" || raw == "\t" { continue }
            guard let value = reverse[raw] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                out.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }

    static func encode(_ data: Data) -> String {
        var buffer: UInt32 = 0
        var bitsLeft = 0
        var out = ""
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                out.append(alphabet[Int((buffer >> UInt32(bitsLeft)) & 0x1F)])
            }
        }
        if bitsLeft > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bitsLeft)) & 0x1F)])
        }
        return out
    }
}
