import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Wraps the form in a scroll view that only actually scrolls when the content outgrows the window.
private struct ScrollIfNeeded: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView(.vertical) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct EntryEditorWindow: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var editor: EditorController

    @State private var revealPassword = false
    @State private var manualSecret = ""
    @State private var showAdvanced = false
    @State private var isDropTargeted = false
    @State private var status: Status?
    @State private var foundConfigs: [OTPConfig] = []

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
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.isNew ? "Add Password" : "Edit Password")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                field("Name") {
                    TextField("", text: $editor.draft.name, prompt: Text("Gmail, Binance, …"))
                }
                field("Password") {
                    HStack(spacing: 6) {
                        if revealPassword {
                            TextField("", text: $editor.draft.password)
                        } else {
                            SecureField("", text: $editor.draft.password)
                        }
                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealPassword ? "Hide password" : "Show password")
                    }
                }
            }

            qrSection

            if let status {
                Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(status.isError ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                if !editor.isNew {
                    Button("Delete", role: .destructive) {
                        store.delete(ids: [editor.draft.id])
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(editor.isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        // The window is a fixed 470×620; the scroll view is just insurance for when the
        // advanced section and a status line are both open.
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ScrollIfNeeded())
        .onAppear { syncManualSecret() }
        .onChange(of: editor.draft.id) { _ in
            revealPassword = false
            status = nil
            foundConfigs = []
            showAdvanced = false
            syncManualSecret()
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 74, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - QR / secret

    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Authenticator QR")
                    .font(.headline)
                Spacer()
                if editor.draft.hasOTP {
                    Text(previewCode)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            VStack(spacing: 10) {
                Image(systemName: editor.draft.hasOTP ? "checkmark.seal.fill" : "qrcode.viewfinder")
                    .font(.system(size: 28))
                    .foregroundStyle(editor.draft.hasOTP ? Color.green : Color.secondary)
                Text(editor.draft.hasOTP ? secretSummary : "Drop a QR image here, or use a button below")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4]))
            )
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            HStack(spacing: 8) {
                Button("Scan from Screen…") { scanScreen() }
                Button("Choose Image…") { chooseImage() }
                Button("Paste") { pasteFromClipboard() }
                Spacer()
            }

            if foundConfigs.count > 1 {
                Picker("Account", selection: Binding(
                    get: { selectedConfigIndex },
                    set: { apply(foundConfigs[$0]) }
                )) {
                    ForEach(Array(foundConfigs.enumerated()), id: \.offset) { index, config in
                        Text(config.displayName).tag(index)
                    }
                }
                .help("This QR contained several accounts — pick the one for this password.")
            }

            DisclosureGroup("Enter the setup key manually", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Secret (base32)", text: $manualSecret, prompt: Text("JBSWY3DPEHPK3PXP"))
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: manualSecret) { newValue in applyManualSecret(newValue) }

                    HStack(spacing: 12) {
                        Picker("Algorithm", selection: $editor.draft.algorithm) {
                            ForEach(OTPAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 170)

                        Picker("Digits", selection: $editor.draft.digits) {
                            Text("6").tag(6)
                            Text("7").tag(7)
                            Text("8").tag(8)
                        }
                        .frame(width: 110)

                        Picker("Period", selection: $editor.draft.period) {
                            Text("30s").tag(30)
                            Text("60s").tag(60)
                        }
                        .frame(width: 120)
                    }
                    .labelsHidden()
                    .font(.callout)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var previewCode: String {
        editor.draft.code(at: store.now) ?? ""
    }

    private var secretSummary: String {
        var parts = ["Secret set"]
        if !editor.draft.issuer.isEmpty || !editor.draft.account.isEmpty {
            parts.append(editor.draft.subtitle)
        }
        parts.append("\(editor.draft.algorithm.rawValue) · \(editor.draft.digits) digits · \(editor.draft.period)s")
        return parts.joined(separator: "\n")
    }

    private var selectedConfigIndex: Int {
        foundConfigs.firstIndex { $0.secret == editor.draft.secret } ?? 0
    }

    private var canSave: Bool {
        !editor.draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            || editor.draft.hasOTP
            || !editor.draft.password.isEmpty
    }

    // MARK: - Actions

    private func dismiss() {
        AppDelegate.shared?.closeEditor()
    }

    private func save() {
        var entry = editor.draft
        entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.name.isEmpty {
            entry.name = [entry.issuer, entry.account].first { !$0.isEmpty } ?? "Untitled"
        }

        if editor.isNew {
            store.add(entry)
        } else {
            store.update(entry)
        }
        dismiss()
    }

    private func syncManualSecret() {
        manualSecret = editor.draft.hasOTP ? Base32.encode(editor.draft.secret) : ""
    }

    private func applyManualSecret(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth") {
            ingest([trimmed])
            return
        }
        guard !trimmed.isEmpty else {
            editor.draft.secret = Data()
            return
        }
        if let secret = Base32.decode(trimmed) {
            editor.draft.secret = secret
            status = nil
        } else {
            status = .failure("That is not a valid base32 secret.")
        }
    }

    private func scanScreen() {
        do {
            ingest(try QRScanner.payloadsFromScreenSelection())
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Scan"
        panel.message = "Choose a screenshot or image of the QR code"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            ingest(try QRScanner.payloads(inFileAt: url))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func pasteFromClipboard() {
        do {
            ingest(try QRScanner.payloadsFromPasteboard())
        } catch {
            status = .failure("The clipboard has no QR image or otpauth:// link.")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    do { ingest(try QRScanner.payloads(inFileAt: url)) }
                    catch { status = .failure(error.localizedDescription) }
                }
            }
            return
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                DispatchQueue.main.async {
                    do { ingest(try QRScanner.payloads(in: image)) }
                    catch { status = .failure(error.localizedDescription) }
                }
            }
            return
        }

        status = .failure("That item is not an image.")
    }

    /// Turns raw QR payloads into a usable secret, keeping every account found for the picker.
    private func ingest(_ payloads: [String]) {
        var configs: [OTPConfig] = []
        var lastError: Error?

        for payload in payloads {
            do { configs.append(contentsOf: try OTPAuthURL.parse(payload)) }
            catch { lastError = error }
        }

        guard let first = configs.first else {
            status = .failure(lastError?.localizedDescription ?? "No usable OTP code found.")
            return
        }

        foundConfigs = configs
        apply(first)
        status = .success(configs.count > 1
                          ? "Found \(configs.count) accounts — pick the right one below."
                          : "QR code read successfully.")
    }

    private func apply(_ config: OTPConfig) {
        editor.draft.secret = config.secret
        editor.draft.issuer = config.issuer
        editor.draft.account = config.account
        editor.draft.algorithm = config.algorithm
        editor.draft.digits = config.digits
        editor.draft.period = config.period
        if editor.draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            editor.draft.name = config.displayName
        }
        syncManualSecret()
    }
}
