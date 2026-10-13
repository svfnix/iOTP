import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Backup block of the Settings window: write a passphrase-protected copy of the vault, and
/// read one back.
struct BackupSection: View {
    @EnvironmentObject private var store: VaultStore

    @State private var sheet: Sheet?
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var replaceOnRestore = false
    @State private var pendingArchive: Data?
    @State private var pendingArchiveDate: Date?
    @State private var status: Status?

    private enum Sheet: Identifiable {
        case export
        case restore

        var id: Int { self == .export ? 0 : 1 }
    }

    private enum Status {
        case success(String)
        case failure(String)

        var text: String {
            switch self {
            case .success(let message), .failure(let message): return message
            }
        }

        var isError: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    var body: some View {
        Section("Backup") {
            HStack(spacing: 10) {
                Button("Export Backup") { begin(.export) }
                    .disabled(store.entries.isEmpty)
                Button("Restore from Backup") { chooseArchive() }
                Spacer()
            }

            Text("A backup is a single file, sealed with a passphrase you choose rather than with "
                 + "anything stored on this Mac — so it still opens if this machine is gone. "
                 + "Keep the passphrase somewhere other than here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status {
                Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(status.isError ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .export: exportSheet
            case .restore: restoreSheet
            }
        }
    }

    // MARK: - Export

    private var exportSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a backup passphrase")
                .font(.headline)
            Text("You will need this exact passphrase to restore. It is not stored anywhere, and "
                 + "there is no way to recover the backup without it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase", text: $passphrase)
            SecureField("Repeat passphrase", text: $confirmation)

            if !confirmation.isEmpty, confirmation != passphrase {
                Text("The two passphrases differ.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { performExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || passphrase != confirmation)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func performExport() {
        let secret = passphrase
        dismissSheet()

        do {
            let archive = try store.exportBackup(passphrase: secret)

            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: BackupArchive.fileExtension) ?? .data]
            panel.nameFieldStringValue = "iOTP-\(Self.dateStamp()).\(BackupArchive.fileExtension)"
            panel.message = "Save the encrypted backup"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            try archive.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = .success("Backed up \(store.entries.count) "
                              + (store.entries.count == 1 ? "entry" : "entries") + " to \(url.lastPathComponent).")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Restore

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an iOTP backup file"
        if let type = UTType(filenameExtension: BackupArchive.fileExtension) {
            panel.allowedContentTypes = [type, .json, .data]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            guard let created = BackupArchive.inspect(data) else {
                status = .failure("That file is not an iOTP backup.")
                return
            }
            pendingArchive = data
            pendingArchiveDate = created
            begin(.restore)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private var restoreSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from backup")
                .font(.headline)
            if let pendingArchiveDate {
                Text("Backup taken \(pendingArchiveDate.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("Passphrase", text: $passphrase)

            Picker("", selection: $replaceOnRestore) {
                Text("Merge into what is here").tag(false)
                Text("Replace everything").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(replaceOnRestore
                 ? "Every current entry is discarded and replaced by the backup."
                 : "Entries from the backup are added; ones already here with the same identity are updated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { performRestore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func performRestore() {
        guard let archive = pendingArchive else { return }
        let secret = passphrase
        let mode: VaultStore.RestoreMode = replaceOnRestore ? .replace : .merge
        dismissSheet()

        do {
            let count = try store.restoreBackup(archive, passphrase: secret, mode: mode)
            status = .success("Restored \(count) " + (count == 1 ? "entry" : "entries") + ".")
        } catch {
            status = .failure(error.localizedDescription)
        }
        pendingArchive = nil
        pendingArchiveDate = nil
    }

    // MARK: - Sheet plumbing

    private func begin(_ which: Sheet) {
        passphrase = ""
        confirmation = ""
        status = nil
        sheet = which
    }

    private func dismissSheet() {
        sheet = nil
        passphrase = ""
        confirmation = ""
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
