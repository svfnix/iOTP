import Foundation

/// Holds the entry currently being edited so the single editor window can be reused.
@MainActor
final class EditorController: ObservableObject {
    @Published var draft = OTPEntry()
    @Published var isNew = true

    func startNew() {
        draft = OTPEntry()
        isNew = true
    }

    func start(editing entry: OTPEntry) {
        draft = entry
        isNew = false
    }
}
