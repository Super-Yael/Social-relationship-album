import CSQLite
import XCTest
@testable import PersonalAlbum

final class PersonalAlbumTests: XCTestCase {
    func testAlbumLayoutKeepsAdjustableColumnsInsideSafeRanges() {
        XCTAssertEqual(AlbumLayout.defaultSidebarWidth, 280)
        XCTAssertEqual(AlbumLayout.defaultEditorWidth, 420)
        XCTAssertEqual(AlbumLayout.mediaMinimumWidth, 500)
        XCTAssertEqual(AlbumLayout.clampedSidebarWidth(100), 220)
        XCTAssertEqual(AlbumLayout.clampedSidebarWidth(500), 420)
        XCTAssertEqual(AlbumLayout.clampedEditorWidth(100), 340)
        XCTAssertEqual(AlbumLayout.clampedEditorWidth(700), 560)
        XCTAssertGreaterThanOrEqual(
            AlbumLayout.minimumWindowWidth(sidebarWidth: 420, editorWidth: 560),
            420 + 560 + AlbumLayout.mediaMinimumWidth + AlbumLayout.dividerHitWidth * 2
        )
    }

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
            SocialAccountRecord(id: -5, personID: person.id, platform: "抖音", value: "douyin_test", sortOrder: 0),
            SocialAccountRecord(id: -6, personID: person.id, platform: "小蓝", value: "blued_test", sortOrder: 0)
        ]
        try store.updatePerson(id: person.id, draft: draft, accounts: accounts)

        XCTAssertEqual(try store.listPeople(search: "wxid_example").count, 1)
        let storedAccounts = try store.socialAccounts(for: person.id)
        XCTAssertEqual(Set(storedAccounts.map(\.platform)), Set(["微信", "QQ", "X", "TG", "抖音", "小蓝"]))
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

    func testPlatformManagementPreservesDataAndOnlyDeletesEmptyPlatforms() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumPlatformTests-\(UUID().uuidString)", isDirectory: true)
        let library = temporaryRoot.appendingPathComponent("nickname", isDirectory: true)
        let personFolder = library.appendingPathComponent("测试人物", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: personFolder, withIntermediateDirectories: true)

        let store = try SQLiteStore(
            databaseURL: temporaryRoot.appendingPathComponent("个人相册.sqlite"),
            backupDirectoryURL: temporaryRoot.appendingPathComponent("备份", isDirectory: true),
            backupLimitBytes: 512 * 1024
        )

        XCTAssertEqual(
            try store.listPlatforms().map(\.name),
            ["微信", "QQ", "X", "TG", "抖音", "小蓝"]
        )

        let customID = try store.addPlatform(named: "  微博  ")
        var custom = try XCTUnwrap(store.listPlatforms().first(where: { $0.id == customID }))
        XCTAssertEqual(custom.name, "微博")

        try store.renamePlatform(id: customID, to: "Weibo")
        custom = try XCTUnwrap(store.listPlatforms().first(where: { $0.id == customID }))
        XCTAssertEqual(custom.name, "Weibo")

        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 1)
        let person = try XCTUnwrap(store.listPeople().first)
        try store.updatePerson(
            id: person.id,
            draft: PersonDraft(person: person),
            accounts: [
                SocialAccountRecord(
                    id: -1,
                    personID: person.id,
                    platform: "Weibo",
                    value: "weibo_example",
                    sortOrder: 0
                )
            ]
        )

        custom = try XCTUnwrap(store.listPlatforms().first(where: { $0.id == customID }))
        XCTAssertEqual(custom.accountCount, 1)
        XCTAssertThrowsError(try store.deletePlatform(id: customID))
        XCTAssertEqual(try store.socialAccounts(for: person.id).map(\.value), ["weibo_example"])

        try store.renamePlatform(id: customID, to: "微博")
        XCTAssertEqual(try store.socialAccounts(for: person.id).map(\.platform), ["微博"])

        try store.updatePerson(id: person.id, draft: PersonDraft(person: person), accounts: [])
        try store.deletePlatform(id: customID)
        XCTAssertFalse(try store.listPlatforms().contains(where: { $0.id == customID }))
    }

    func testVersionFourDatabaseMigratesPlatformsWithoutLosingAccounts() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = temporaryRoot.appendingPathComponent("个人相册.sqlite")
        let backupURL = temporaryRoot.appendingPathComponent("备份", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let legacySQL = """
            PRAGMA foreign_keys = ON;
            CREATE TABLE people(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nickname TEXT NOT NULL,
                folder_path TEXT NOT NULL UNIQUE,
                notes TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE social_accounts(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                platform TEXT NOT NULL,
                value TEXT NOT NULL COLLATE NOCASE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                UNIQUE(person_id, platform, value)
            );
            INSERT INTO people(nickname, folder_path, notes, created_at, updated_at)
            VALUES('旧人物', '/tmp/legacy-person', '保留备注', 1, 1);
            INSERT INTO social_accounts(person_id, platform, value, sort_order)
            VALUES(1, '旧平台', 'legacy_account', 0);
            PRAGMA user_version = 4;
            """
        var errorMessage: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(database, legacySQL, nil, nil, &errorMessage), SQLITE_OK)
        if let errorMessage { sqlite3_free(errorMessage) }
        sqlite3_close(database)
        database = nil

        let store = try SQLiteStore(
            databaseURL: databaseURL,
            backupDirectoryURL: backupURL,
            backupLimitBytes: 512 * 1024
        )
        let person = try XCTUnwrap(store.listPeople().first)
        XCTAssertEqual(person.nickname, "旧人物")
        XCTAssertEqual(person.notes, "保留备注")
        XCTAssertEqual(try store.socialAccounts(for: person.id).map(\.value), ["legacy_account"])

        let names = try store.listPlatforms().map(\.name)
        XCTAssertEqual(Array(names.prefix(6)), ["微信", "QQ", "X", "TG", "抖音", "小蓝"])
        let migratedLegacyPlatform = try XCTUnwrap(
            store.listPlatforms().first(where: { $0.name == "旧平台" })
        )
        XCTAssertEqual(migratedLegacyPlatform.accountCount, 1)
        XCTAssertThrowsError(try store.deletePlatform(id: migratedLegacyPlatform.id))
        XCTAssertFalse(try store.backupFiles().isEmpty)
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

    func testRepeatedScansOnlyImportNewFolderPaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumRepeatedScanTests-\(UUID().uuidString)", isDirectory: true)
        let library = temporaryRoot.appendingPathComponent("nickname", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("已有人物", isDirectory: true),
            withIntermediateDirectories: true
        )
        let store = try SQLiteStore(
            databaseURL: temporaryRoot.appendingPathComponent("个人相册.sqlite"),
            backupDirectoryURL: temporaryRoot.appendingPathComponent("备份", isDirectory: true),
            backupLimitBytes: 512 * 1024
        )

        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 1)
        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 0)

        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("新人物", isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 1)
        XCTAssertEqual(Set(try store.listPeople().map(\.nickname)), Set(["已有人物", "新人物"]))
        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 0)
    }

    @MainActor
    func testFolderMonitorNotifiesWhenRootGetsANewFolder() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumMonitorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let notified = expectation(description: "检测到 nickname 根目录发生变化")
        let monitor = LibraryFolderMonitor()
        try monitor.start(watching: temporaryRoot) {
            notified.fulfill()
        }

        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("新人物", isDirectory: true),
            withIntermediateDirectories: false
        )
        wait(for: [notified], timeout: 3)
        monitor.stop()
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

    func testSafeFolderRenamePreservesMediaAndSocialAccounts() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalAlbumRenameTests-\(UUID().uuidString)", isDirectory: true)
        let library = temporaryRoot.appendingPathComponent("nickname", isDirectory: true)
        let originalFolder = library.appendingPathComponent("原昵称", isDirectory: true)
        let mediaURL = originalFolder.appendingPathComponent("保留内容.jpg")
        let originalData = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        try originalData.write(to: mediaURL)
        let originalFileNumber = try FileManager.default.attributesOfItem(atPath: mediaURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(originalFileNumber)

        let store = try SQLiteStore(
            databaseURL: temporaryRoot.appendingPathComponent("个人相册.sqlite"),
            backupDirectoryURL: temporaryRoot.appendingPathComponent("备份", isDirectory: true),
            backupLimitBytes: 512 * 1024
        )
        XCTAssertEqual(try store.importMissingFolders(LibraryScanner.scanPeople(in: library)), 1)
        let person = try XCTUnwrap(store.listPeople().first)
        try store.updatePerson(
            id: person.id,
            draft: PersonDraft(person: person),
            accounts: [
                SocialAccountRecord(
                    id: -1,
                    personID: person.id,
                    platform: "微信",
                    value: "wxid_example",
                    sortOrder: 0
                )
            ]
        )

        let renamedFolder = try LibraryFolderManager.renamePersonFolder(
            at: originalFolder,
            to: "新昵称",
            in: library
        )
        XCTAssertNil(
            try store.renamePersonFolderRecord(
                id: person.id,
                from: originalFolder,
                to: renamedFolder
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFolder.path))
        let renamedMediaURL = renamedFolder.appendingPathComponent(mediaURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: renamedMediaURL), originalData)
        let renamedFileNumber = try FileManager.default.attributesOfItem(atPath: renamedMediaURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(renamedFileNumber, originalFileNumber)

        let renamedPerson = try XCTUnwrap(store.listPeople().first)
        XCTAssertEqual(renamedPerson.nickname, "新昵称")
        XCTAssertEqual(renamedPerson.folderPath, renamedFolder.path)
        XCTAssertEqual(try store.socialAccounts(for: person.id).map(\.value), ["wxid_example"])

        let collision = library.appendingPathComponent("已存在", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try LibraryFolderManager.renamePersonFolder(at: renamedFolder, to: "已存在", in: library)
        )
        XCTAssertThrowsError(
            try LibraryFolderManager.renamePersonFolder(at: renamedFolder, to: "../越界", in: library)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedMediaURL.path))
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
