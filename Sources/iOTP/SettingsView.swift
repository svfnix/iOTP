import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: VaultStore

    @AppStorage(AppSettings.orderKey) private var order: ComposeOrder = .passwordThenCode
    @AppStorage(AppSettings.separatorKey) private var separator: String = ""
    @AppStorage(AppSettings.clearClipboardKey) private var clearClipboardSeconds: Int = 0
    @AppStorage(AppSettings.showCodesInMenuKey) private var showCodesInMenu: Bool = true
    @AppStorage(AppSettings.storageBackendKey) private var storageBackend: StorageBackend = .file
    @AppStorage(AppSettings.requireUnlockKey) private var requireUnlock: Bool = false

    var body: some View {
        Form {
            Section("Copying") {
                Picker("Copy as", selection: $order) {
                    ForEach(ComposeOrder.allCases) { Text($0.label).tag($0) }
                }
                TextField("Separator", text: $separator, prompt: Text("none"))
                    .help("Optional text placed between the password and the code.")
                Text(preview)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Picker("Clear clipboard", selection: $clearClipboardSeconds) {
                    Text("Never").tag(0)
                    Text("After 15 seconds").tag(15)
                    Text("After 30 seconds").tag(30)
                    Text("After 60 seconds").tag(60)
                }
            }

            Section("Menu bar") {
                Toggle("Show codes next to names", isOn: $showCodesInMenu)
            }

            Section("Security") {
                Toggle("Require \(BiometricLock.description) to unlock", isOn: $requireUnlock)
                    .disabled(!BiometricLock.isAvailable && !requireUnlock)
                    .onChange(of: requireUnlock) { enabled in
                        store.lockSettingChanged(enabled: enabled)
                    }
                Text(BiometricLock.isAvailable
                     ? "Locks again after 15 quiet minutes, or straight away with Lock Now."
                     : "No biometric sensor was found, so this would fall back to your login password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Store vault in", selection: $storageBackend) {
                    ForEach(StorageBackend.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: storageBackend) { backend in
                    store.changeStorage(to: backend)
                }
                Text(storageBackend.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BackupSection()
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: String {
        let sample = OTPEntry(name: "Example", password: "hunter2", secret: Base32.decode("JBSWY3DPEHPK3PXP") ?? Data())
        return "Preview:  " + store.composedValue(for: sample, order: order, separator: separator, at: Date())
    }
}
