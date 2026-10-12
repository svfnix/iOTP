import Foundation
import AppKit
import Combine

enum ComposeOrder: String, Codable, CaseIterable, Identifiable {
    case passwordThenCode
    case codeThenPassword
    case codeOnly
    case passwordOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .passwordThenCode: return "Password + code"
        case .codeThenPassword: return "Code + password"
        case .codeOnly: return "Code only"
        case .passwordOnly: return "Password only"
        }
    }
}

struct OTPEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var password: String = ""
    var secret: Data = Data()
    var issuer: String = ""
    var account: String = ""
    var algorithm: OTPAlgorithm = .sha1
    var digits: Int = 6
    var period: Int = 30
    /// `nil` means "follow the global preference".
    var orderOverride: ComposeOrder?

    var title: String {
        if !name.isEmpty { return name }
        if !issuer.isEmpty { return issuer }
        if !account.isEmpty { return account }
        return "Unnamed"
    }

    var subtitle: String {
        var parts: [String] = []
        if !issuer.isEmpty, issuer != name { parts.append(issuer) }
        if !account.isEmpty { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    var hasOTP: Bool { !secret.isEmpty }

    func code(at date: Date) -> String? {
        guard hasOTP else { return nil }
        return TOTP.code(secret: secret, algorithm: algorithm, digits: digits, period: period, date: date)
    }

    /// Decoding stays tolerant so vaults written by older builds keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        secret = try container.decodeIfPresent(Data.self, forKey: .secret) ?? Data()
        issuer = try container.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        account = try container.decodeIfPresent(String.self, forKey: .account) ?? ""
        algorithm = try container.decodeIfPresent(OTPAlgorithm.self, forKey: .algorithm) ?? .sha1
        digits = try container.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        period = try container.decodeIfPresent(Int.self, forKey: .period) ?? 30
        orderOverride = try container.decodeIfPresent(ComposeOrder.self, forKey: .orderOverride)
    }

    init(name: String = "",
         password: String = "",
         secret: Data = Data(),
         issuer: String = "",
         account: String = "",
         algorithm: OTPAlgorithm = .sha1,
         digits: Int = 6,
         period: Int = 30,
         orderOverride: ComposeOrder? = nil) {
        self.name = name
        self.password = password
        self.secret = secret
        self.issuer = issuer
        self.account = account
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.orderOverride = orderOverride
    }

    init(config: OTPConfig, name: String = "", password: String = "") {
        self.init(name: name.isEmpty ? config.displayName : name,
                  password: password,
                  secret: config.secret,
                  issuer: config.issuer,
                  account: config.account,
                  algorithm: config.algorithm,
                  digits: config.digits,
                  period: config.period)
    }
}

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var entries: [OTPEntry] = []
    @Published var now: Date = Date()
    @Published var storageError: String?
    /// Set when the vault could not be persisted, so the UI can warn instead of silently losing data.
    @Published private(set) var isPersistent = true

    /// True when the Touch ID lock is on and the vault has not been unlocked yet this session.
    @Published private(set) var isLocked = false

    private var ticker: AnyCancellable?
    private var clipboardClearWorkItem: DispatchWorkItem?
    private var lastActivity = Date()
    private static let autoLockAfter: TimeInterval = 15 * 60

    init(loadImmediately: Bool = true) {
        if lockEnabled {
            isLocked = true
        } else if loadImmediately {
            load()
        }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    /// The refresh period shared by most entries — what the menu-bar countdown follows.
    var dominantPeriod: Int? {
        let periods = entries.filter(\.hasOTP).map(\.period)
        guard !periods.isEmpty else { return nil }
        let counts = Dictionary(grouping: periods, by: { $0 }).mapValues(\.count)
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// 0 right after a code appears, 1 the instant before it rolls over.
    /// Falls back to the standard 30-second cycle so the ring is there before the first entry exists.
    var menuBarProgress: Double {
        TOTP.progress(period: dominantPeriod ?? 30, date: now)
    }

    // MARK: - Lock

    var lockEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.requireUnlockKey)
    }

    func noteActivity() {
        lastActivity = Date()
    }

    /// Called before the menu opens: drops the decrypted entries again after a quiet stretch.
    func lockIfIdle() {
        guard lockEnabled, !isLocked, Date().timeIntervalSince(lastActivity) > Self.autoLockAfter else { return }
        lock()
    }

    func lock() {
        entries = []
        isLocked = true
    }

    func unlock(completion: ((Bool) -> Void)? = nil) {
        guard isLocked else {
            completion?(true)
            return
        }
        BiometricLock.authenticate(reason: "unlock your iOTP passwords") { [weak self] success in
            guard let self else { return }
            if success {
                self.isLocked = false
                self.noteActivity()
                self.load()
            }
            completion?(success)
        }
    }

    /// Turning the lock off should leave the vault usable straight away.
    func lockSettingChanged(enabled: Bool) {
        if enabled {
            noteActivity()
        } else if isLocked {
            isLocked = false
            load()
        }
    }

    // MARK: - Persistence

    func load() {
        do {
            guard let data = try VaultStorage.load() else {
                entries = []
                isPersistent = true
                return
            }
            entries = try JSONDecoder().decode([OTPEntry].self, from: data)
            isPersistent = true
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            isPersistent = false
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try VaultStorage.save(data)
            isPersistent = true
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            isPersistent = false
        }
    }

    /// Moves the vault between the encrypted file and the keychain. The entries are already in
    /// memory, so this just rewrites them through the new backend and clears the old copy.
    func changeStorage(to backend: StorageBackend) {
        VaultStorage.backend = backend
        save()

        // Drop whatever the other backend still holds so there is only ever one copy.
        switch backend {
        case .file: try? Keychain.delete()
        case .keychain: VaultStorage.removeFile()
        }
    }

    // MARK: - Mutations

    func add(_ entry: OTPEntry) {
        entries.append(entry)
        save()
    }

    func add(contentsOf newEntries: [OTPEntry]) {
        guard !newEntries.isEmpty else { return }
        entries.append(contentsOf: newEntries)
        save()
    }

    func update(_ entry: OTPEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Shifts one entry a single step. Backs the Move Up / Move Down commands, which work even
    /// where a drag is awkward — the rows carry buttons and menus that can swallow the gesture.
    func move(id: UUID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
        save()
    }

    func canMove(id: UUID, by offset: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return entries.indices.contains(index + offset)
    }

    // MARK: - Clipboard

    /// Builds the string a Copy button puts on the clipboard.
    func composedValue(for entry: OTPEntry,
                       order: ComposeOrder,
                       separator: String,
                       at date: Date? = nil) -> String {
        let effectiveOrder = entry.orderOverride ?? order
        let code = entry.code(at: date ?? now) ?? ""

        switch effectiveOrder {
        case .passwordOnly:
            return entry.password
        case .codeOnly:
            return code
        case .passwordThenCode:
            guard !entry.password.isEmpty else { return code }
            guard !code.isEmpty else { return entry.password }
            return entry.password + separator + code
        case .codeThenPassword:
            guard !entry.password.isEmpty else { return code }
            guard !code.isEmpty else { return entry.password }
            return code + separator + entry.password
        }
    }

    func copyToClipboard(_ value: String, clearAfter seconds: Int) {
        clipboardClearWorkItem?.cancel()
        clipboardClearWorkItem = nil

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        guard seconds > 0 else { return }
        let changeCount = pasteboard.changeCount
        let work = DispatchWorkItem {
            // Only clear if nothing else took over the clipboard meanwhile.
            if NSPasteboard.general.changeCount == changeCount {
                NSPasteboard.general.clearContents()
            }
        }
        clipboardClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }
}
