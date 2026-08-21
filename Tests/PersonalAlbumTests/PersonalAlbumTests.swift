import XCTest
@testable import PersonalAlbum

final class PersonalAlbumTests: XCTestCase {
    func testBackupLimitIsFiftyMiB() {
        XCTAssertEqual(AppPaths.backupLimitBytes, 50 * 1024 * 1024)
    }

    func testCRUDAndBackupsNeverChangeLibraryContents() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumTests-\(UUID().uuidString)", isDirectory: true)
        let library = temporaryRoot.appendingPathComponent("nickname", isDirectory: true)
        let personFolder = library.appendingPathComponent("测试昵称", isDirectory: true)
        let mediaURL = personFolder.appendingPathComponent("原文件.jpg")
        let databaseURL = temporaryRoot.appendingPathComponent("个人相册.sqlite")
        let backupURL = temporaryRoot.appendingPathComponent("备份", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: personFolder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: mediaURL)
        let originalContents = try relativeContents(of: library)

        let store = try SQLiteStore(
            databaseURL: databaseURL,
            backupDirectoryURL: backupURL,
            backupLimitBytes: 80 * 1024
        )
        let folders = try LibraryScanner.scanPeople(in: library)
        XCTAssertEqual(try store.importMissingFolders(folders), 1)

        let person = try XCTUnwrap(store.listPeople().first)
        var draft = PersonDraft(person: person)
        draft.notes = "只存在数据库"
        let accounts = [
            SocialAccountRecord(id: -1, personID: person.id, platform: "微信", value: "wxid_example", sortOrder: 0),
            SocialAccountRecord(id: -2, personID: person.id, platform: "QQ", value: "1234567890", sortOrder: 0),
            SocialAccountRecord(id: -3, personID: person.id, platform: "X", value: "x_test", sortOrder: 0),
            SocialAccountRecord(id: -4, personID: person.id, platform: "TG", value: "tg_test", sortOrder: 0),
            SocialAccountRecord(id: -5, personID: person.id, platform: "抖音", value: "douyin_test", sortOrder: 0)
        ]
        try store.updatePerson(id: person.id, draft: draft, accounts: accounts)

        XCTAssertEqual(try store.listPeople(search: "wxid_example").count, 1)
        let storedAccounts = try store.socialAccounts(for: person.id)
        XCTAssertEqual(Set(storedAccounts.map(\.platform)), Set(["微信", "QQ", "X", "TG", "抖音"]))
        XCTAssertEqual(storedAccounts.first(where: { $0.platform == "QQ" })?.value, "1234567890")
        XCTAssertEqual(try relativeContents(of: library), originalContents)

        try store.backupNow()
        try store.backupNow()
        let backups = try store.backupFiles()
        let sizes = try backups.map {
            Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertFalse(backups.isEmpty)
        XCTAssertTrue(sizes.reduce(0, +) <= 80 * 1024 || backups.count == 1)

        try store.deletePerson(id: person.id)
        XCTAssertEqual(try store.personCount(), 0)
        XCTAssertEqual(try relativeContents(of: library), originalContents)
    }

    func testLibraryScannerFindsOnlyVisibleFolders() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumScanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("示例人物", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent(".隐藏人物", isDirectory: true),
            withIntermediateDirectories: true
        )

        let folders = try LibraryScanner.scanPeople(in: temporaryRoot)
        XCTAssertEqual(folders.map(\.nickname), ["示例人物"])
    }

    func testLegacyFinderCommentClassification() {
        let classified = LegacySocialImporter.classify(
            "1234567890 wxid_example @telegram_user " +
            "https://x.com/x_user https://v.douyin.com/example"
        )
        XCTAssertEqual(
            classified.accounts.map { "\($0.platform):\($0.value)" },
            [
                "QQ:1234567890",
                "微信:wxid_example",
                "TG:@telegram_user",
                "X:https://x.com/x_user",
                "抖音:https://v.douyin.com/example"
            ]
        )
        XCTAssertTrue(classified.unclassified.isEmpty)
    }

    func testSafeNicknameFolderCreation() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumFolderTests-\(UUID().uuidString)", isDirectory: true)
        let library = temporaryRoot.appendingPathComponent("nickname", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let created = try LibraryFolderManager.createPersonFolder(named: "  新人物  ", in: library)
        XCTAssertEqual(created.lastPathComponent, "新人物")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: created.path), [])

        XCTAssertThrowsError(try LibraryFolderManager.createPersonFolder(named: "../越界", in: library))
        XCTAssertThrowsError(try LibraryFolderManager.createPersonFolder(named: ".隐藏", in: library))
        XCTAssertThrowsError(try LibraryFolderManager.createPersonFolder(named: "新人物", in: library))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent("越界").path))
    }

    private func relativeContents(of root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count))
        }
        .sorted()
    }
}
