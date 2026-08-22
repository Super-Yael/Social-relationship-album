import Foundation

enum LibraryFolderManager {
    static func createPersonFolder(named rawName: String, in libraryURL: URL) throws -> URL {
        let name = try validatedName(rawName)
        let normalizedRoot = try validatedRoot(libraryURL)
        let destination = normalizedRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == normalizedRoot else {
            throw AlbumError.invalidFolder("新文件夹必须位于 nickname 根目录内。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AlbumError.invalidFolder("已经存在名为“\(name)”的文件或文件夹。")
        }

        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: nil
        )
        return destination
    }

    static func renamePersonFolder(at sourceURL: URL, to rawName: String, in libraryURL: URL) throws -> URL {
        let name = try validatedName(rawName)
        let normalizedRoot = try validatedRoot(libraryURL)
        let source = sourceURL.standardizedFileURL
        guard source.deletingLastPathComponent() == normalizedRoot else {
            throw AlbumError.invalidFolder("只能重命名 nickname 的直属子文件夹。")
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            throw AlbumError.invalidFolder("原文件夹不存在，无法重命名：\(source.path)")
        }

        let destination = normalizedRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == normalizedRoot else {
            throw AlbumError.invalidFolder("新名称必须仍位于 nickname 根目录内。")
        }
        if destination.path == source.path {
            return source
        }

        let isCaseOnlyRename = destination.path.caseInsensitiveCompare(source.path) == .orderedSame
        if isCaseOnlyRename {
            return try renameChangingOnlyCase(source: source, destination: destination, root: normalizedRoot)
        }

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AlbumError.invalidFolder("已经存在名为“\(name)”的文件或文件夹。")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private static func validatedName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AlbumError.invalidFolder("文件夹名称不能为空。")
        }
        guard name != ".", name != "..", !name.hasPrefix(".") else {
            throw AlbumError.invalidFolder("不能使用隐藏名称、`.` 或 `..`。")
        }
        guard !name.contains("/"), !name.contains("\0") else {
            throw AlbumError.invalidFolder("文件夹名称不能包含 `/` 或空字符。")
        }
        guard name.utf8.count <= 255 else {
            throw AlbumError.invalidFolder("文件夹名称过长。")
        }
        return name
    }

    private static func validatedRoot(_ libraryURL: URL) throws -> URL {
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            throw AlbumError.invalidFolder("nickname 根目录不存在。")
        }
        return libraryURL.standardizedFileURL
    }

    private static func renameChangingOnlyCase(source: URL, destination: URL, root: URL) throws -> URL {
        let temporary = root.appendingPathComponent(
            ".personal-album-rename-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: source, to: temporary)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            do {
                try FileManager.default.moveItem(at: temporary, to: source)
            } catch let rollbackError {
                throw AlbumError.invalidFolder(
                    "大小写重命名失败，且无法恢复原名称。临时文件夹：\(temporary.path)\n" +
                    "原错误：\(error.localizedDescription)\n恢复错误：\(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }
}
