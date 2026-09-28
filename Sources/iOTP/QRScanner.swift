import Foundation
import AppKit
import CoreImage

enum QRScanner {
    enum ScanError: LocalizedError {
        case noImage
        case noCode
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .noImage: return "Could not read that image."
            case .noCode: return "No QR code was found in the image."
            case .captureFailed: return "Screen capture was cancelled or failed."
            }
        }
    }

    private static let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: CIContext(options: [.useSoftwareRenderer: false]),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    /// Returns every QR payload found in the image, largest feature first.
    static func payloads(in image: CIImage) -> [String] {
        guard let detector else { return [] }
        let features = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
        return features
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .compactMap { $0.messageString }
            .filter { !$0.isEmpty }
    }

    static func payloads(inFileAt url: URL) throws -> [String] {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let image = CIImage(contentsOf: url) else { throw ScanError.noImage }
        let found = payloads(in: image)
        guard !found.isEmpty else { throw ScanError.noCode }
        return found
    }

    static func payloads(in nsImage: NSImage) throws -> [String] {
        guard let tiff = nsImage.tiffRepresentation, let image = CIImage(data: tiff) else {
            throw ScanError.noImage
        }
        let found = payloads(in: image)
        guard !found.isEmpty else { throw ScanError.noCode }
        return found
    }

    /// Reads a QR image or an otpauth:// string straight off the clipboard.
    static func payloadsFromPasteboard() throws -> [String] {
        let pasteboard = NSPasteboard.general

        if let string = pasteboard.string(forType: .string),
           string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("otpauth") {
            return [string]
        }
        if let url = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let first = url.first,
           first.isFileURL {
            return try payloads(inFileAt: first)
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first {
            return try payloads(in: image)
        }
        throw ScanError.noImage
    }

    /// Lets the user drag a selection over whatever is on screen (a QR shown in a browser, for example).
    /// macOS will ask for Screen Recording permission the first time.
    static func payloadsFromScreenSelection() throws -> [String] {
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iotp-scan-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", target.path]
        try process.run()
        process.waitUntilExit()

        defer { try? FileManager.default.removeItem(at: target) }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: target.path) else {
            throw ScanError.captureFailed
        }
        return try payloads(inFileAt: target)
    }
}
