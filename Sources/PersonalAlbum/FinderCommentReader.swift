import Darwin
import Foundation

enum FinderCommentReader {
    private static let attributeName = "com.apple.metadata:kMDItemFinderComment"
    private static let commentMarker = Data("cmmtustr".utf8)

    static func commentsInDSStore(parentDirectory: URL, folderNames: [String]) -> [String: String] {
        let dsStoreURL = parentDirectory.appendingPathComponent(".DS_Store")
        guard let data = try? Data(contentsOf: dsStoreURL), !data.isEmpty else { return [:] }

        var result: [String: String] = [:]
        for name in folderNames {
            let encodedName = utf16BigEndianData(name)
            var nameLength = UInt32(name.utf16.count).bigEndian
            var needle = Data(bytes: &nameLength, count: MemoryLayout<UInt32>.size)
            needle.append(encodedName)
            needle.append(commentMarker)

            var searchStart = data.startIndex
            while searchStart < data.endIndex,
                  let range = data.range(of: needle, options: [], in: searchStart..<data.endIndex) {
                let lengthOffset = range.upperBound
                if let comment = readUnicodeString(data: data, lengthOffset: lengthOffset),
                   !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result[name] = comment
                }
                searchStart = range.upperBound
            }
        }
        return result
    }

    static func extendedAttributeComment(at url: URL) -> String? {
        let path = url.path
        let length = path.withCString { pathPointer in
            attributeName.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, 0)
            }
        }
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let readCount = data.withUnsafeMutableBytes { buffer in
            path.withCString { pathPointer in
                attributeName.withCString { namePointer in
                    getxattr(pathPointer, namePointer, buffer.baseAddress, length, 0, 0)
                }
            }
        }
        guard readCount == length else { return nil }

        if let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let comment = value as? String,
           !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return comment
        }
        return nil
    }

    private static func readUnicodeString(data: Data, lengthOffset: Data.Index) -> String? {
        guard lengthOffset + 4 <= data.endIndex else { return nil }
        let unitCount = readUInt32BigEndian(data, at: lengthOffset)
        guard unitCount <= 4_096 else { return nil }
        let byteCount = Int(unitCount) * 2
        let start = lengthOffset + 4
        guard start + byteCount <= data.endIndex else { return nil }
        return String(data: data[start..<(start + byteCount)], encoding: .utf16BigEndian)
    }

    private static func readUInt32BigEndian(_ data: Data, at offset: Data.Index) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func utf16BigEndianData(_ value: String) -> Data {
        var data = Data(capacity: value.utf16.count * 2)
        for unit in value.utf16 {
            var bigEndian = unit.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
