import Darwin
import Foundation

/// Watches only the nickname root directory. It never changes the directory or its contents.
@MainActor
final class LibraryFolderMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?

    func start(watching libraryURL: URL, onChange: @escaping @MainActor () -> Void) throws {
        stop()

        let descriptor = open(libraryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw AlbumError.invalidFolder(
                "无法监听 nickname 文件夹变化：\(String(cString: strerror(errno)))"
            )
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pendingScan?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard self != nil else { return }
                onChange()
            }
            pendingScan = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}
