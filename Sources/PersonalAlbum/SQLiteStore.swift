import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStore {
    let databaseURL: URL
    let backupDirectoryURL: URL
    let backupLimitBytes: Int64

    private var database: OpaquePointer?

    init(databaseURL: URL, backupDirectoryURL: URL, backupLimitBytes: Int64) throws {
        self.databaseURL = databaseURL
        self.backupDirectoryURL = backupDirectoryURL
        self.backupLimitBytes = backupLimitBytes

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(database)
            database = nil
            throw AlbumError.database("无法打开数据库：\(message)")
        }

        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = FULL;")
        let versionBeforeMigration = try schemaVersion()
        if versionBeforeMigration > 0 && versionBeforeMigration < 4 {
            try createBackup()
        }
        try migrateSchema(from: versionBeforeMigration)
    }

    deinit {
        sqlite3_close(database)
    }

    func saveLibraryRoot(_ path: String) throws {
        try execute(
            "INSERT INTO settings(key, value) VALUES('library_root', ?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            bindings: [.text(path)]
        )
    }

    func personCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM people;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError(prefix: "无法统计人物记录")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func listPeople(search: String = "") throws -> [PersonRecord] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        let bindings: [Binding]
        if trimmed.isEmpty {
            sql = """
                SELECT id, nickname, folder_path, notes, created_at, updated_at
                FROM people
                ORDER BY nickname COLLATE NOCASE, folder_path COLLATE NOCASE;
                """
            bindings = []
        } else {
            sql = """
                SELECT DISTINCT p.id, p.nickname, p.folder_path,
                       p.notes, p.created_at, p.updated_at
                FROM people p
                LEFT JOIN social_accounts a ON a.person_id = p.id
                WHERE p.nickname LIKE ? ESCAPE '\\'
                   OR p.folder_path LIKE ? ESCAPE '\\'
                   OR p.notes LIKE ? ESCAPE '\\'
                   OR a.platform LIKE ? ESCAPE '\\'
                   OR a.value LIKE ? ESCAPE '\\'
                ORDER BY p.nickname COLLATE NOCASE, p.folder_path COLLATE NOCASE;
                """
            let pattern = "%\(escapeLike(trimmed))%"
            bindings = Array(repeating: .text(pattern), count: 5)
        }

        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var records: [PersonRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(readPerson(statement))
        }
        return records
    }

    func socialAccounts(for personID: Int64) throws -> [SocialAccountRecord] {
        let statement = try prepare(
            """
            SELECT id, person_id, platform, value, sort_order
            FROM social_accounts
            WHERE person_id = ?
            ORDER BY sort_order, id;
            """,
            bindings: [.integer(personID)]
        )
        defer { sqlite3_finalize(statement) }

        var records: [SocialAccountRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(
                SocialAccountRecord(
                    id: sqlite3_column_int64(statement, 0),
                    personID: sqlite3_column_int64(statement, 1),
                    platform: columnText(statement, 2),
                    value: columnText(statement, 3),
                    sortOrder: Int(sqlite3_column_int(statement, 4))
                )
            )
        }
        return records
    }

    @discardableResult
    func addPerson(folder: ScannedFolder) throws -> Int64 {
        try backupBeforeMutation()
        var newID: Int64 = 0
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                INSERT INTO people(
                    nickname, folder_path, notes, created_at, updated_at
                ) VALUES(?, ?, '', ?, ?);
                """,
                bindings: [
                    .text(folder.nickname), .text(folder.path), .double(now), .double(now)
                ]
            )
            newID = sqlite3_last_insert_rowid(database)
            try importLegacyValue(folder.finderComment, for: newID)
        }
        try createBackup()
        return newID
    }

    func importMissingFolders(_ folders: [ScannedFolder]) throws -> Int {
        let existing = Set(try listPeople().map(\.folderPath))
        let missing = folders.filter { !existing.contains($0.path) }
        guard !missing.isEmpty else { return 0 }

        try backupBeforeMutation()
        try transaction {
            let sql = """
                INSERT INTO people(
                    nickname, folder_path, notes, created_at, updated_at
                ) VALUES(?, ?, '', ?, ?);
                """
            for folder in missing {
                let now = Date().timeIntervalSince1970
                try execute(
                    sql,
                    bindings: [
                        .text(folder.nickname), .text(folder.path), .double(now), .double(now)
                    ]
                )
                let personID = sqlite3_last_insert_rowid(database)
                try importLegacyValue(folder.finderComment, for: personID)
            }
        }
        try createBackup()
        return missing.count
    }

    func updatePerson(id: Int64, draft: PersonDraft, accounts: [SocialAccountRecord]) throws {
        let cleanPath = URL(fileURLWithPath: draft.folderPath, isDirectory: true).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AlbumError.invalidFolder("文件夹不存在，无法保存路径：\(cleanPath)")
        }

        try backupBeforeMutation()
        try transaction {
            let now = Date().timeIntervalSince1970
            try execute(
                """
                UPDATE people
                SET nickname = ?, folder_path = ?, notes = ?, updated_at = ?
                WHERE id = ?;
                """,
                bindings: [
                    .text(URL(fileURLWithPath: cleanPath).lastPathComponent),
                    .text(cleanPath), .text(draft.notes), .double(now), .integer(id)
                ]
            )
            try execute("DELETE FROM social_accounts WHERE person_id = ?;", bindings: [.integer(id)])
            var platformOrder: [String: Int] = [:]
            for account in accounts {
                let value = account.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard SocialPlatform.allCases.contains(where: { $0.rawValue == account.platform }),
                      !value.isEmpty else { continue }
                let order = platformOrder[account.platform, default: 0]
                try insertSocialAccount(
                    personID: id,
                    platform: account.platform,
                    value: value,
                    sortOrder: order
                )
                platformOrder[account.platform] = order + 1
            }
        }
        try createBackup()
    }

    /// Returns a warning when the database change succeeded but its post-change backup failed.
    func renamePersonFolderRecord(id: Int64, from oldFolderURL: URL, to newFolderURL: URL) throws -> String? {
        let oldPath = oldFolderURL.standardizedFileURL.path
        let newURL = newFolderURL.standardizedFileURL
        let newPath = newURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: newPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AlbumError.invalidFolder("重命名后的文件夹不存在，数据库未修改：\(newPath)")
        }

        try backupBeforeMutation()
        try transaction {
            try execute(
                """
                UPDATE people
                SET nickname = ?, folder_path = ?, updated_at = ?
                WHERE id = ? AND folder_path = ?;
                """,
                bindings: [
                    .text(newURL.lastPathComponent), .text(newPath),
                    .double(Date().timeIntervalSince1970), .integer(id), .text(oldPath)
                ]
            )
            guard sqlite3_changes(database) == 1 else {
                throw AlbumError.database("人物记录已发生变化，数据库未更新。")
            }
        }

        do {
            try createBackup()
            return nil
        } catch {
            return "文件夹和数据库已经同步，但写入后的数据库备份失败：\(error.localizedDescription)"
        }
    }

    func deletePerson(id: Int64) throws {
        try backupBeforeMutation()
        try execute("DELETE FROM people WHERE id = ?;", bindings: [.integer(id)])
        try createBackup()
    }

    func backupNow() throws {
        try createBackup()
    }

    func backupFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backupDirectoryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "sqlite" }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func migrateSchema(from originalVersion: Int) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS settings(
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS people(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nickname TEXT NOT NULL,
                folder_path TEXT NOT NULL UNIQUE,
                notes TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sources(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                platform TEXT NOT NULL DEFAULT '',
                identifier TEXT NOT NULL DEFAULT '',
                source_nickname TEXT NOT NULL DEFAULT '',
                profile_url TEXT NOT NULL DEFAULT '',
                notes TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS social_accounts(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                person_id INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                platform TEXT NOT NULL,
                value TEXT NOT NULL COLLATE NOCASE,
                sort_order INTEGER NOT NULL DEFAULT 0,
                UNIQUE(person_id, platform, value)
            );

            CREATE INDEX IF NOT EXISTS idx_people_nickname ON people(nickname);
            CREATE INDEX IF NOT EXISTS idx_sources_person ON sources(person_id);
            CREATE INDEX IF NOT EXISTS idx_sources_identifier ON sources(identifier);
            CREATE INDEX IF NOT EXISTS idx_social_person_platform
                ON social_accounts(person_id, platform, sort_order);
            CREATE INDEX IF NOT EXISTS idx_social_value ON social_accounts(value);
            """
        )

        if originalVersion > 0 && originalVersion < 3 {
            try transaction {
                try migrateLegacySocialValues()
                for column in ["finder_comment", "wechat", "qq", "x_account", "telegram", "douyin"] {
                    if try columnExists(column, in: "people") {
                        try execute("ALTER TABLE people DROP COLUMN \(column);")
                    }
                }
            }
        }
        if originalVersion > 0 && originalVersion < 4 {
            try transaction {
                for column in ["aliases", "review_status"] {
                    if try columnExists(column, in: "people") {
                        try execute("ALTER TABLE people DROP COLUMN \(column);")
                    }
                }
            }
        }
        try execute("PRAGMA user_version = 4;")
    }

    private func migrateLegacySocialValues() throws {
        let idStatement = try prepare("SELECT id FROM people ORDER BY id;")
        var personIDs: [Int64] = []
        while sqlite3_step(idStatement) == SQLITE_ROW {
            personIDs.append(sqlite3_column_int64(idStatement, 0))
        }
        sqlite3_finalize(idStatement)

        let legacyColumns: [(column: String, platform: SocialPlatform)] = [
            ("wechat", .wechat),
            ("qq", .qq),
            ("x_account", .x),
            ("telegram", .telegram),
            ("douyin", .douyin)
        ]

        for personID in personIDs {
            for entry in legacyColumns {
                guard try columnExists(entry.column, in: "people") else { continue }
                let rawValue = try textValue(column: entry.column, personID: personID)
                let values = rawValue
                    .split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for (order, value) in values.enumerated() {
                    try insertSocialAccount(
                        personID: personID,
                        platform: entry.platform.rawValue,
                        value: value,
                        sortOrder: order
                    )
                }
            }

            if try columnExists("finder_comment", in: "people") {
                let finderValue = try textValue(column: "finder_comment", personID: personID)
                try importLegacyValue(finderValue, for: personID)
            }
        }
    }

    private func importLegacyValue(_ rawValue: String, for personID: Int64) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let classified = LegacySocialImporter.classify(rawValue)
        var nextOrders: [String: Int] = [:]
        for account in classified.accounts {
            let order: Int
            if let cached = nextOrders[account.platform] {
                order = cached
            } else {
                order = try nextSortOrder(personID: personID, platform: account.platform)
            }
            try insertSocialAccount(
                personID: personID,
                platform: account.platform,
                value: account.value,
                sortOrder: order
            )
            nextOrders[account.platform] = order + 1
        }

        if !classified.unclassified.isEmpty {
            let message = "未分类导入：\(classified.unclassified.joined(separator: " "))"
            try execute(
                """
                UPDATE people
                SET notes = CASE WHEN notes = '' THEN ? ELSE notes || char(10) || ? END
                WHERE id = ?;
                """,
                bindings: [.text(message), .text(message), .integer(personID)]
            )
        }
    }

    private func insertSocialAccount(
        personID: Int64,
        platform: String,
        value: String,
        sortOrder: Int
    ) throws {
        try execute(
            """
            INSERT OR IGNORE INTO social_accounts(person_id, platform, value, sort_order)
            VALUES(?, ?, ?, ?);
            """,
            bindings: [
                .integer(personID), .text(platform), .text(value), .integer(Int64(sortOrder))
            ]
        )
    }

    private func nextSortOrder(personID: Int64, platform: String) throws -> Int {
        let statement = try prepare(
            """
            SELECT COALESCE(MAX(sort_order) + 1, 0)
            FROM social_accounts WHERE person_id = ? AND platform = ?;
            """,
            bindings: [.integer(personID), .text(platform)]
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func textValue(column: String, personID: Int64) throws -> String {
        let statement = try prepare(
            "SELECT \(column) FROM people WHERE id = ?;",
            bindings: [.integer(personID)]
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return "" }
        return columnText(statement, 0)
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError(prefix: "无法读取数据库版本")
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func columnExists(_ column: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == column { return true }
        }
        return false
    }

    private func backupBeforeMutation() throws {
        try createBackup()
    }

    private func createBackup() throws {
        try FileManager.default.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "个人相册-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlite"
        let destinationURL = backupDirectoryURL.appendingPathComponent(filename)

        var destinationDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            destinationURL.path,
            &destinationDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK else {
            let message = destinationDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(destinationDatabase)
            throw AlbumError.backup("无法创建数据库备份：\(message)")
        }
        defer { sqlite3_close(destinationDatabase) }

        guard let backup = sqlite3_backup_init(destinationDatabase, "main", database, "main") else {
            throw AlbumError.backup("无法启动 SQLite 一致性备份。")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw AlbumError.backup("SQLite 备份失败，已取消本次字段修改。")
        }

        try pruneBackups(keeping: destinationURL)
    }

    private func pruneBackups(keeping newest: URL) throws {
        var files = try FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "sqlite" }

        func size(of url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values?.fileSize ?? 0)
        }

        var total = files.reduce(Int64(0)) { $0 + size(of: $1) }
        files.sort {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left < right
        }

        for file in files where total > backupLimitBytes {
            if file.standardizedFileURL == newest.standardizedFileURL { continue }
            let fileSize = size(of: file)
            try FileManager.default.removeItem(at: file)
            total -= fileSize
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case double(Double)
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        if bindings.isEmpty && sql.contains(";") {
            var errorMessage: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "未知 SQLite 错误"
                sqlite3_free(errorMessage)
                throw AlbumError.database(message)
            }
            return
        }

        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError(prefix: "数据库写入失败")
        }
    }

    private func prepare(_ sql: String, bindings: [Binding] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw currentError(prefix: "无法准备数据库操作")
        }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch binding {
                case .text(let value):
                    result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
                case .integer(let value):
                    result = sqlite3_bind_int64(statement, index, value)
                case .double(let value):
                    result = sqlite3_bind_double(statement, index, value)
                }
                guard result == SQLITE_OK else {
                    throw currentError(prefix: "无法绑定数据库字段")
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func readPerson(_ statement: OpaquePointer) -> PersonRecord {
        PersonRecord(
            id: sqlite3_column_int64(statement, 0),
            nickname: columnText(statement, 1),
            folderPath: columnText(statement, 2),
            notes: columnText(statement, 3),
            createdAt: sqlite3_column_double(statement, 4),
            updatedAt: sqlite3_column_double(statement, 5)
        )
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func currentError(prefix: String) -> AlbumError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        return .database("\(prefix)：\(message)")
    }

    private func escapeLike(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
