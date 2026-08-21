import Foundation

enum AppPaths {
    static let databaseFilename = "个人相册.sqlite"
    static let backupDirectoryName = "个人相册数据库备份"
    static let backupLimitBytes: Int64 = 50 * 1024 * 1024

    static var configuredLibraryURL: URL? {
        if let stored = UserDefaults.standard.string(forKey: "libraryRootPath"),
           isDirectory(stored) {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        return nil
    }

    static func databaseURL(for libraryURL: URL) -> URL {
        libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent(databaseFilename, isDirectory: false)
    }

    static func backupDirectoryURL(for libraryURL: URL) -> URL {
        libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent(backupDirectoryName, isDirectory: true)
    }

    static func rememberLibrary(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "libraryRootPath")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
