import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Watches the active Brewfile for external changes — edits from another
/// editor, atomic saves, deletion — and posts `.barkeepRefresh` so the UI
/// reloads. Self-initiated writes from within Barkeep also fire the
/// watcher; the resulting refresh is harmless because stable IDs let the
/// selection survive a reparse.
@MainActor
final class BrewfileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?

    func start(url: URL) {
        if watchedURL == url, source != nil { return }
        stop()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let mask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.fileChanged()
        }
        src.setCancelHandler {
            close(fd)
        }

        watchedURL = url
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedURL = nil
    }

    private func fileChanged() {
        // After an atomic save (rename), our fd points at an unlinked inode.
        // Reopen on the same path so we keep watching the live file.
        let savedURL = watchedURL
        stop()
        if let savedURL { start(url: savedURL) }
        NotificationCenter.default.post(name: .barkeepRefresh, object: nil)
    }
}
