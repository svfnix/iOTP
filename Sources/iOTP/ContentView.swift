import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: VaultStore
    @EnvironmentObject private var editor: EditorController

    @AppStorage(AppSettings.orderKey) private var order: ComposeOrder = .passwordThenCode
    @AppStorage(AppSettings.separatorKey) private var separator: String = ""
    @AppStorage(AppSettings.clearClipboardKey) private var clearClipboardSeconds: Int = 0

    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var copiedID: UUID?

    private var filtered: [OTPEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.title.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !store.isPersistent {
                warningBanner
            }

            if store.isLocked {
                lockedState
            } else if store.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    /// The window is created by AppKit, so the controls live in the view instead of an NSToolbar.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Spacer()

            Button {
                AppDelegate.shared?.openEditorForNew()
            } label: {
                Label("Add Password", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Add a new password")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { entry in
                EntryRow(entry: entry,
                         justCopied: copiedID == entry.id,
                         // Reordering is relative to the full list, so it is held back while a
                         // search hides part of it and the result would look arbitrary.
                         canReorder: search.isEmpty,
                         canMoveUp: search.isEmpty && store.canMove(id: entry.id, by: -1),
                         canMoveDown: search.isEmpty && store.canMove(id: entry.id, by: 1),
                         onCopy: { copy(entry) },
                         onEdit: { edit(entry) },
                         onDelete: { store.delete(ids: [entry.id]) },
                         onCopyCode: { copyPart(entry, order: .codeOnly) },
                         onCopyPassword: { copyPart(entry, order: .passwordOnly) },
                         onMoveUp: { store.move(id: entry.id, by: -1) },
                         onMoveDown: { store.move(id: entry.id, by: 1) },
                         onDropEntry: { dragged in store.move(id: dragged, onto: entry.id) })
                    .tag(entry.id)
            }
        }
        .onDeleteCommand {
            store.delete(ids: selection)
            selection.removeAll()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No passwords yet")
                .font(.title3.weight(.medium))
            Text("Add one, then it shows up in the menu bar next to the clock.")
                .foregroundStyle(.secondary)
            Button("Add Password…") { AppDelegate.shared?.openEditorForNew() }
                .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Locked")
                .font(.title3.weight(.medium))
            Button("Unlock with \(BiometricLock.description)") { store.unlock() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningBanner: some View {
        Label(store.storageError ?? "The keychain is unavailable — entries are only kept until you quit.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
    }

    private func edit(_ entry: OTPEntry) {
        AppDelegate.shared?.openEditor(for: entry)
    }

    private func copy(_ entry: OTPEntry) {
        store.copyToClipboard(store.composedValue(for: entry, order: order, separator: separator, at: Date()),
                              clearAfter: clearClipboardSeconds)
        flashCopied(entry.id)
    }

    private func copyPart(_ entry: OTPEntry, order: ComposeOrder) {
        var stripped = entry
        stripped.orderOverride = order
        store.copyToClipboard(store.composedValue(for: stripped, order: order, separator: separator, at: Date()),
                              clearAfter: clearClipboardSeconds)
        flashCopied(entry.id)
    }

    private func flashCopied(_ id: UUID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { copiedID = nil }
        }
    }
}

struct EntryRow: View {
    let entry: OTPEntry
    let justCopied: Bool
    let canReorder: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onCopyCode: () -> Void
    let onCopyPassword: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDropEntry: (UUID) -> Bool

    @EnvironmentObject private var store: VaultStore
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 12) {
            if canReorder {
                // The handle is the only drag source: starting the drag anywhere else would fight
                // with the row's buttons, its menu and the double-click to edit.
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.trailing, 2)
                    .contentShape(Rectangle())
                    .help("Drag to reorder")
                    .onHover { inside in
                        if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                    }
                    .draggable(entry.id.uuidString) {
                        Label(entry.title, systemImage: "line.3.horizontal")
                            .padding(6)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let code = entry.code(at: store.now) {
                HStack(spacing: 8) {
                    Text(grouped(code))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(remaining <= 5 ? Color.orange : Color.primary)
                    CountdownRing(progress: TOTP.progress(period: entry.period, date: store.now),
                                  remaining: remaining)
                }
            } else {
                Text("no code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: onCopy) {
                Label(justCopied ? "Copied" : "Copy", systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    .frame(width: 74)
            }
            .buttonStyle(.borderedProminent)

            Menu {
                Button("Copy code only", action: onCopyCode)
                Button("Copy password only", action: onCopyPassword)
                Divider()
                moveCommands
                Divider()
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        // The whole row stays a drop target even though only the handle starts a drag.
        .dropDestination(for: String.self) { items, _ in
            guard canReorder,
                  let first = items.first,
                  let dragged = UUID(uuidString: first) else { return false }
            return onDropEntry(dragged)
        } isTargeted: { targeted in
            isDropTarget = targeted && canReorder
        }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Copy code only", action: onCopyCode)
            Button("Copy password only", action: onCopyPassword)
            Divider()
            moveCommands
            Divider()
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var moveCommands: some View {
        Button("Move Up", action: onMoveUp)
            .disabled(!canMoveUp)
        Button("Move Down", action: onMoveDown)
            .disabled(!canMoveDown)
    }

    private var remaining: Int {
        TOTP.secondsRemaining(period: entry.period, date: store.now)
    }

    private func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}

struct CountdownRing: View {
    let progress: Double
    let remaining: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - progress))
                .stroke(remaining <= 5 ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 9, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 22, height: 22)
        .help("\(remaining) seconds until the code changes")
    }
}
