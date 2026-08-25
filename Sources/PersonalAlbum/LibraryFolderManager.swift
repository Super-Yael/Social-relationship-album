import Foundation

struct MovedMediaFiles: Equatable, Sendable {
    let destinations: [URL]
    let skippedCount: Int
}

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

    static func moveMediaFiles(
        at sourceURLs: [URL],
        to personFolderURL: URL,
        in libraryURL: URL
    ) throws -> MovedMediaFiles {
        let fileManager = FileManager.default
        let normalizedRoot = try validatedRoot(libraryURL)
        let destinationFolder = personFolderURL.standardizedFileURL
        guard destinationFolder.deletingLastPathComponent() == normalizedRoot else {
            throw AlbumError.invalidFolder("只能将文件移入 nickname 的直属人物文件夹。")
        }

        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destinationFolder.path,
            isDirectory: &destinationIsDirectory
        ), destinationIsDirectory.boolValue else {
            throw AlbumError.invalidFolder("人物文件夹不存在，无法移入文件：\(destinationFolder.path)")
        }

        var seenSources = Set<String>()
        var seenDestinations = Set<String>()
        var plans: [(source: URL, destination: URL)] = []
        var skippedCount = 0

        for sourceURL in sourceURLs {
            guard sourceURL.isFileURL else {
                throw AlbumError.invalidFolder("只能拖入本地文件。")
            }
            let source = sourceURL.standardizedFileURL
            guard seenSources.insert(source.path).inserted else { continue }

            guard fileManager.fileExists(atPath: source.path) else {
                throw AlbumError.invalidFolder("要移动的文件不存在：\(source.path)")
            }
            let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
                throw AlbumError.invalidFolder("只支持拖入普通文件：\(source.lastPathComponent)")
            }

            let destination = destinationFolder
                .appendingPathComponent(source.lastPathComponent, isDirectory: false)
                .standardizedFileURL
            guard destination.deletingLastPathComponent() == destinationFolder else {
                throw AlbumError.invalidFolder("无法为文件生成安全的目标路径：\(source.lastPathComponent)")
            }
            if destination.path == source.path {
                skippedCount += 1
                continue
            }

            let collisionKey = destination.path.lowercased()
            guard seenDestinations.insert(collisionKey).inserted else {
                throw AlbumError.invalidFolder(
                    "多个拖入文件会使用同一目标名称：\(source.lastPathComponent)"
                )
            }
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw AlbumError.invalidFolder(
                    "人物文件夹中已存在“\(source.lastPathComponent)”，未覆盖任何文件。"
                )
            }
            plans.append((source, destination))
        }

        var completedPlans: [(source: URL, destination: URL)] = []
        do {
            for plan in plans {
                // This is a filesystem move. Do not replace it with copy + remove.
                try fileManager.moveItem(at: plan.source, to: plan.destination)
                completedPlans.append(plan)
            }
        } catch let moveError {
            var rollbackFailures: [String] = []
            for plan in completedPlans.reversed() {
                do {
                    try fileManager.moveItem(at: plan.destination, to: plan.source)
                } catch {
                    rollbackFailures.append("\(plan.destination.path): \(error.localizedDescription)")
                }
            }
            if !rollbackFailures.isEmpty {
                throw AlbumError.invalidFolder(
                    "批量移动中断，且部分文件无法恢复原位置。\n" +
                    "移动错误：\(moveError.localizedDescription)\n" +
                    "恢复错误：\(rollbackFailures.joined(separator: "\n"))"
                )
            }
            throw moveError
        }

        return MovedMediaFiles(
            destinations: plans.map(\.destination),
            skippedCount: skippedCount
        )
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
