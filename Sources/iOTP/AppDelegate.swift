import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) weak var shared: AppDelegate?

    let store = VaultStore()
    let editor = EditorController()

    private var statusItem: NSStatusItem?
    private var editorWindow: NSWindow?
    private var manageWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var terminationSignal: DispatchSourceSignal?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        routeTerminationSignalThroughQuit()

        // Test hook: `iOTP --open-window editor|manage|settings` opens a window straight away and
        // prints what actually ended up on screen, so windows can be exercised without clicking.
        if let index = CommandLine.arguments.firstIndex(of: "--open-window"),
           index + 1 < CommandLine.arguments.count {
            let which = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                switch which {
                case "editor": self.openEditorForNew()
                case "manage": self.openManagePasswords()
                case "settings": self.openSettingsPanel()
                default: print("unknown window: \(which)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let visible = NSApp.windows.filter(\.isVisible).map(\.title)
                // stderr is unbuffered, so this shows up even when piped to a file.
                FileHandle.standardError.write(Data("visible windows: \(visible)\n".utf8))
            }
        }

        // SwiftUI normally installs the main menu; without it text fields lose ⌘C/⌘V.
        if NSApp.mainMenu == nil { NSApp.mainMenu = Self.makeMainMenu() }
        DispatchQueue.main.async {
            if NSApp.mainMenu == nil { NSApp.mainMenu = Self.makeMainMenu() }
        }
    }

    /// Quit, log out and shut down all end here, so the vault is written one last time.
    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    /// A plain SIGTERM (what `pkill` and most process managers send) ends the process outright and
    /// never reaches applicationWillTerminate. Turning it into a normal quit makes it flush too.
    private func routeTerminationSignalThroughQuit() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "net.wallgold.iotp.statusitem"

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "iOTP")
            button.image?.isTemplate = true
            button.toolTip = "iOTP"
        }

        // The menu is attached to the status item, so it opens instantly on click and the
        // delegate refreshes the codes each time it is about to appear.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        store.lockIfIdle()

        if store.isLocked {
            menu.addItem(item("Unlock with \(BiometricLock.description)", #selector(unlockVault)))
            menu.addItem(.separator())
            menu.addItem(item("Settings", #selector(openSettingsFromMenu)))
            menu.addItem(.separator())
            menu.addItem(item("Quit iOTP", #selector(quit)))
            return
        }

        let showCodes = UserDefaults.standard.object(forKey: AppSettings.showCodesInMenuKey) as? Bool ?? true

        if store.entries.isEmpty {
            let empty = NSMenuItem(title: "No passwords yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in store.entries {
                let title: String
                if showCodes, let code = entry.code(at: Date()) {
                    title = "\(entry.title) (\(code))"
                } else {
                    title = entry.title
                }
                let item = NSMenuItem(title: title, action: #selector(copyEntryFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.image = Self.copyGlyph
                item.toolTip = "Copy password + code"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Manage Passwords", #selector(openManageFromMenu)))
        if store.lockEnabled {
            menu.addItem(item("Lock Now", #selector(lockVault)))
        }
        menu.addItem(item("Settings", #selector(openSettingsFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit iOTP", #selector(quit)))
    }

    /// Marks the rows that copy when clicked. A template image lets macOS recolour it for light,
    /// dark and the blue highlight on its own.
    private static let copyGlyph: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }()

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyEntryFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = store.entries.first(where: { $0.id == id }) else { return }
        copy(entry)
    }

    @objc private func unlockVault() {
        store.unlock()
    }

    @objc private func lockVault() {
        store.lock()
    }

    /// Shared by the menu and the manage window so both honour the same preferences.
    func copy(_ entry: OTPEntry) {
        store.noteActivity()
        let defaults = UserDefaults.standard
        let order = (defaults.string(forKey: AppSettings.orderKey).flatMap(ComposeOrder.init(rawValue:)))
            ?? .passwordThenCode
        let separator = defaults.string(forKey: AppSettings.separatorKey) ?? ""
        let clearAfter = defaults.integer(forKey: AppSettings.clearClipboardKey)

        store.copyToClipboard(store.composedValue(for: entry, order: order, separator: separator, at: Date()),
                              clearAfter: clearAfter)
    }

    // MARK: - Windows

    @objc private func openManageFromMenu() {
        openManagePasswords()
    }

    @objc private func openSettingsFromMenu() {
        openSettingsPanel()
    }

    func openManagePasswords() {
        if manageWindow == nil {
            let view = ContentView()
                .environmentObject(store)
                .environmentObject(editor)
            manageWindow = makeWindow(title: "iOTP Passwords",
                                      content: view,
                                      resizable: true,
                                      contentSize: NSSize(width: 660, height: 460))
        }
        present(manageWindow)
    }

    func openSettingsPanel() {
        if settingsWindow == nil {
            let view = SettingsView()
                .environmentObject(store)
            settingsWindow = makeWindow(title: "iOTP Settings",
                                        content: view,
                                        resizable: false,
                                        contentSize: NSSize(width: 460, height: 680))
        }
        present(settingsWindow)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func openEditorForNew() {
        editor.startNew()
        showEditorWindow(title: "Add Password")
    }

    func openEditor(for entry: OTPEntry) {
        editor.start(editing: entry)
        showEditorWindow(title: "Edit Password")
    }

    func closeEditor() {
        editorWindow?.close()
    }

    private func showEditorWindow(title: String) {
        if editorWindow == nil {
            let view = EntryEditorWindow()
                .environmentObject(store)
                .environmentObject(editor)
            editorWindow = makeWindow(title: title,
                                      content: view,
                                      resizable: false,
                                      contentSize: NSSize(width: 470, height: 620))
        }
        editorWindow?.title = title
        present(editorWindow)
    }

    /// Always sizes explicitly: letting NSHostingController drive the size from SwiftUI's ideal
    /// height sends AppKit into a constraint-update loop when the content can grow (it throws).
    private func makeWindow<V: View>(title: String,
                                     content: V,
                                     resizable: Bool,
                                     contentSize: NSSize?) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = resizable
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.titled, .closable]
        window.isReleasedWhenClosed = false
        if let contentSize { window.setContentSize(contentSize) }
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main menu fallback

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "iOTP")
        appMenu.addItem(withTitle: "Settings", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iOTP", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iOTP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        return main
    }
}
