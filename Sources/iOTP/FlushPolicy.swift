import Foundation

/// Decides whether writing the in-memory entries back to disk is safe.
///
/// The write on quit exists to repair a vault file that vanished under a running app, so it must
/// never become the thing that destroys one. Three situations leave the in-memory list empty or
/// untrustworthy, and in each of them writing it out would replace real data with nothing.
enum FlushPolicy {
    static func shouldWrite(isLoaded: Bool, isLocked: Bool, entryCount: Int) -> Bool {
        // Locked: the list was deliberately emptied from memory, the file is the only copy.
        guard !isLocked else { return false }
        // Never loaded, or loading failed: what is in memory is not what is on disk.
        guard isLoaded else { return false }
        // Nothing to write. Deleting the last entry already saved immediately.
        return entryCount > 0
    }
}
