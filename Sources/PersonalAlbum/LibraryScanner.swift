import Foundation
import UniformTypeIdentifiers

enum LibraryScanner {
    static func scanPeople(in libraryURL: URL) throws -> [ScannedFolder] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let folders = try urls.filter { url in
            let values = try url.resourceValues(forKeys: keys)
            return values.isDirectory == true && values.isHidden != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let dsStoreComments = FinderCommentReader.commentsInDSStore(
            parentDirectory: libraryURL,
            folderNames: folders.map(\.lastPathComponent)
        )

        return folders.map { folderURL in
            let name = folderURL.lastPathComponent
            let comment = dsStoreComments[name]
                ?? FinderCommentReader.extendedAttributeComment(at: folderURL)
                ?? ""
            return ScannedFolder(
                nickname: name,
                path: folderURL.standardizedFileURL.path,
                finderComment: comment
            )
        }
    }
}

enum MediaScanner {
    static func scanMedia(in folderURL: URL) throws -> [MediaItem] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isHiddenKey, .contentTypeKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var media: [MediaItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }

            let contentType = values?.contentType
            let kind: MediaItem.Kind?
            if contentType?.conforms(to: .image) == true {
                kind = .image
            } else if contentType?.conforms(to: .movie) == true {
                kind = .video
            } else {
                kind = fallbackKind(forExtension: url.pathExtension)
            }
            guard let kind else { continue }

            media.append(
                MediaItem(
                    url: url,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    fileSize: Int64(values?.fileSize ?? 0),
                    kind: kind
                )
            )
        }

        return media.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func fallbackKind(forExtension fileExtension: String) -> MediaItem.Kind? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "avif":
            return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp":
            return .video
        default:
            return nil
        }
    }
}
