import Foundation

enum SocialPlatform: String, CaseIterable, Identifiable {
    case wechat = "微信"
    case qq = "QQ"
    case x = "X"
    case telegram = "TG"
    case douyin = "抖音"
    case xiaolan = "小蓝"

    var id: String { rawValue }
}

struct PlatformRecord: Identifiable, Hashable {
    let id: Int64
    var name: String
    var sortOrder: Int
    var accountCount: Int
}

struct PersonRecord: Identifiable, Hashable {
    let id: Int64
    var nickname: String
    var folderPath: String
    var notes: String
    var createdAt: Double
    var updatedAt: Double

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct SocialAccountRecord: Identifiable, Hashable {
    var id: Int64
    var personID: Int64
    var platform: String
    var value: String
    var sortOrder: Int

    static func empty(personID: Int64, platform: String, sortOrder: Int) -> SocialAccountRecord {
        SocialAccountRecord(
            id: -Int64.random(in: 1...Int64.max),
            personID: personID,
            platform: platform,
            value: "",
            sortOrder: sortOrder
        )
    }
}

struct PersonDraft: Equatable {
    var nickname: String = ""
    var folderPath: String = ""
    var notes: String = ""

    init() {}

    init(person: PersonRecord) {
        nickname = person.nickname
        folderPath = person.folderPath
        notes = person.notes
    }
}

struct ScannedFolder: Hashable {
    let nickname: String
    let path: String
    let finderComment: String
}

struct MediaItem: Identifiable, Hashable {
    let url: URL
    let modifiedAt: Date
    let fileSize: Int64
    let kind: Kind

    enum Kind: String, Hashable {
        case image
        case video
    }

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum AlbumError: LocalizedError {
    case notConfigured
    case invalidFolder(String)
    case database(String)
    case backup(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未选择 nickname 文件夹。"
        case .invalidFolder(let message), .database(let message), .backup(let message):
            return message
        }
    }
}
