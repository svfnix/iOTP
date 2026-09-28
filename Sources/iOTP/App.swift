import AppKit

/// Plain AppKit entry point. There is no SwiftUI `App`/`Scene` here on purpose: an accessory
/// (menu-bar) app never gets SwiftUI's scene commands delivered, which is why the Settings scene
/// could not be opened. Every window is created by AppDelegate instead.
@main
enum Main {
    /// NSApplication.delegate is weak, so the delegate has to be retained here.
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Main.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
