import Foundation

/// UserDefaults keys shared by the views, the menu and the storage layer.
enum AppSettings {
    static let orderKey = "composeOrder"
    static let separatorKey = "composeSeparator"
    static let clearClipboardKey = "clearClipboardSeconds"
    static let showCodesInMenuKey = "showCodesInMenu"
    static let storageBackendKey = "storageBackend"
    static let requireUnlockKey = "requireUnlock"
}
