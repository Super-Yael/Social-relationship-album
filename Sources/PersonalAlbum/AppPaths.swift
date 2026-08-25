import Foundation

enum AppPaths {
    static let applicationDataDirectoryName = "local.yael.personal-album"
    static let databaseFilename = "个人相册.sqlite"
    static let backupDirectoryName = "个人相册数据库备份"
    static let libraryBookmarkFilename = "library-root.bookmark"
    static let backupLimitBytes: Int64 = 50 * 1024 * 1024

    static func applicationDataURL(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent(applicationDataDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    static func prepareApplicationDataDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationDataURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try applicationDataURL(fileManager: fileManager)
            .appendingPathComponent(databaseFilename, isDirectory: false)
    }

    static func backupDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try applicationDataURL(fileManager: fileManager)
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    static func libraryBookmarkURL(fileManager: FileManager = .default) throws -> URL {
        try applicationDataURL(fileManager: fileManager)
            .appendingPathComponent(libraryBookmarkFilename, isDirectory: false)
    }

    static func isInsideApplicationData(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let root = try? applicationDataURL(fileManager: fileManager) else { return false }
        let rootPath = resolvedPath(root, fileManager: fileManager) + "/"
        let candidatePath = resolvedPath(url, fileManager: fileManager)
        return candidatePath.hasPrefix(rootPath)
    }

    private static func resolvedPath(_ url: URL, fileManager: FileManager) -> String {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }

        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}

/// Owns the single long-lived security-scoped access grant for the selected media library.
/// The bookmark itself is configuration data and therefore lives inside the app data directory.
final class LibraryAccessController {
    private let fileManager: FileManager
    private let bookmarkURLOverride: URL?
    private var activeURL: URL?
    private var didStartSecurityScope = false

    init(fileManager: FileManager = .default, bookmarkURL: URL? = nil) {
        self.fileManager = fileManager
        bookmarkURLOverride = bookmarkURL
    }

    deinit {
        stopAccessingLibrary()
    }

    func restoreLibrary() throws -> URL? {
        let bookmarkURL = try configuredBookmarkURL()
        guard fileManager.fileExists(atPath: bookmarkURL.path) else { return nil }

        let bookmarkData = try Data(contentsOf: bookmarkURL)
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL

        if isStale {
            try persistBookmark(for: url)
        }
        activate(url)
        return url
    }

    func rememberAndAccessLibrary(_ url: URL) throws -> URL {
        let normalized = url.standardizedFileURL
        try persistBookmark(for: normalized)
        activate(normalized)
        return normalized
    }

    func stopAccessingLibrary() {
        if didStartSecurityScope {
            activeURL?.stopAccessingSecurityScopedResource()
        }
        activeURL = nil
        didStartSecurityScope = false
    }

    private func persistBookmark(for url: URL) throws {
        let bookmarkURL = try configuredBookmarkURL()
        try fileManager.createDirectory(
            at: bookmarkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try bookmarkData.write(to: bookmarkURL, options: .atomic)
    }

    private func configuredBookmarkURL() throws -> URL {
        let url = try bookmarkURLOverride ?? AppPaths.libraryBookmarkURL(fileManager: fileManager)
        guard AppPaths.isInsideApplicationData(url, fileManager: fileManager) else {
            throw AlbumError.database("拒绝在 App 数据目录之外保存媒体库书签。")
        }
        return url
    }

    private func activate(_ url: URL) {
        stopAccessingLibrary()
        activeURL = url
        // Outside an App Sandbox (for example `swift test`) this can return false even
        // though the URL is accessible. In a sandbox, a true result is balanced in stop().
        didStartSecurityScope = url.startAccessingSecurityScopedResource()
    }
}
