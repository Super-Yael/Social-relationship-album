import Foundation

enum LibraryFolderManager {
    static func createPersonFolder(named rawName: String, in libraryURL: URL) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AlbumError.invalidFolder("文件夹名称不能为空。")
        }
        guard name != ".", name != "..", !name.hasPrefix(".") else {
            throw AlbumError.invalidFolder("不能创建隐藏名称、`.` 或 `..` 文件夹。")
        }
        guard !name.contains("/"), !name.contains("\0") else {
            throw AlbumError.invalidFolder("文件夹名称不能包含 `/` 或空字符。")
        }
        guard name.utf8.count <= 255 else {
            throw AlbumError.invalidFolder("文件夹名称过长。")
        }

        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            throw AlbumError.invalidFolder("nickname 根目录不存在。")
        }

        let normalizedRoot = libraryURL.standardizedFileURL
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
}
