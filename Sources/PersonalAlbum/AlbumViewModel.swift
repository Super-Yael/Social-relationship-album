import AppKit
import Foundation

@MainActor
final class AlbumViewModel: ObservableObject {
    @Published var libraryURL: URL?
    @Published var people: [PersonRecord] = []
    @Published var selectedPersonID: Int64?
    @Published var draft = PersonDraft()
    @Published var draftAccounts: [SocialAccountRecord] = []
    @Published var platforms: [PlatformRecord] = []
    @Published var mediaItems: [MediaItem] = []
    @Published var isLoadingMedia = false
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var statusMessage = ""
    @Published var backupCount = 0

    private var store: SQLiteStore?
    private var mediaLoadGeneration = UUID()

    init() {
        if let libraryURL = AppPaths.configuredLibraryURL {
            configure(libraryURL: libraryURL)
        }
    }

    var isConfigured: Bool { store != nil && libraryURL != nil }

    var selectedPerson: PersonRecord? {
        guard let selectedPersonID else { return nil }
        return people.first { $0.id == selectedPersonID }
    }

    func configure(libraryURL: URL) {
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AlbumError.invalidFolder("选择的位置不是有效文件夹。")
            }

            let normalized = libraryURL.standardizedFileURL
            let store = try SQLiteStore(
                databaseURL: AppPaths.databaseURL(for: normalized),
                backupDirectoryURL: AppPaths.backupDirectoryURL(for: normalized),
                backupLimitBytes: AppPaths.backupLimitBytes
            )
            self.store = store
            self.libraryURL = normalized
            AppPaths.rememberLibrary(normalized)
            try store.saveLibraryRoot(normalized.path)

            if try store.personCount() == 0 {
                let scanned = try LibraryScanner.scanPeople(in: normalized)
                let count = try store.importMissingFolders(scanned)
                statusMessage = "首次读取了 \(count) 个 nickname 文件夹；没有修改任何媒体文件。"
            }
            try store.backupNow()
            platforms = try store.listPlatforms()
            reloadPeople(selectFirstIfNeeded: true)
            refreshBackupCount()
        } catch {
            self.store = nil
            self.libraryURL = nil
            self.platforms = []
            show(error)
        }
    }

    func reloadPeople(selectFirstIfNeeded: Bool = false) {
        guard let store else { return }
        do {
            let previousSelection = selectedPersonID
            people = try store.listPeople(search: searchText)
            if let previousSelection, people.contains(where: { $0.id == previousSelection }) {
                selectedPersonID = previousSelection
            } else if selectFirstIfNeeded || selectedPersonID != nil {
                selectedPersonID = people.first?.id
            }
            loadSelectedPerson()
        } catch {
            show(error)
        }
    }

    func loadSelectedPerson() {
        guard let person = selectedPerson else {
            draft = PersonDraft()
            draftAccounts = []
            mediaItems = []
            return
        }
        draft = PersonDraft(person: person)
        do {
            draftAccounts = try store?.socialAccounts(for: person.id) ?? []
            loadMedia(for: person)
        } catch {
            show(error)
        }
    }

    func addFolder(_ url: URL) {
        guard let store, let libraryURL else { return }
        do {
            let normalized = url.standardizedFileURL
            guard normalized.deletingLastPathComponent().standardizedFileURL == libraryURL.standardizedFileURL else {
                throw AlbumError.invalidFolder("只能加入 nickname 的直属子文件夹。")
            }
            let folder = ScannedFolder(
                nickname: normalized.lastPathComponent,
                path: normalized.path,
                finderComment: FinderCommentReader.extendedAttributeComment(at: normalized) ?? ""
            )
            let newID = try store.addPerson(folder: folder)
            platforms = try store.listPlatforms()
            searchText = ""
            reloadPeople()
            selectedPersonID = newID
            loadSelectedPerson()
            statusMessage = "已新增数据库记录；文件夹内容未改变。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func createPersonFolder(named name: String) {
        guard let store, let libraryURL else { return }
        do {
            let folderURL = try LibraryFolderManager.createPersonFolder(named: name, in: libraryURL)
            do {
                let newID = try store.addPerson(
                    folder: ScannedFolder(
                        nickname: folderURL.lastPathComponent,
                        path: folderURL.path,
                        finderComment: ""
                    )
                )
                searchText = ""
                reloadPeople()
                selectedPersonID = newID
                loadSelectedPerson()
                statusMessage = "已在 nickname 中新建空文件夹；没有创建任何媒体文件。"
                refreshBackupCount()
            } catch {
                throw AlbumError.database(
                    "空文件夹已经成功创建，但数据库记录写入失败。请点击“扫描 nickname”补录。\n\(error.localizedDescription)"
                )
            }
        } catch {
            show(error)
        }
    }

    func renameSelectedPersonFolder(to newName: String) {
        guard let store, let libraryURL, let person = selectedPerson else { return }
        let personID = person.id
        let oldFolderURL = person.folderURL.standardizedFileURL

        do {
            // Refuse the filesystem mutation unless a consistent pre-rename snapshot exists.
            try store.backupNow()
            let newFolderURL = try LibraryFolderManager.renamePersonFolder(
                at: oldFolderURL,
                to: newName,
                in: libraryURL
            )
            guard newFolderURL.path != oldFolderURL.path else {
                statusMessage = "文件夹名称没有变化。"
                refreshBackupCount()
                return
            }
            mediaLoadGeneration = UUID()
            isLoadingMedia = false

            do {
                let backupWarning = try store.renamePersonFolderRecord(
                    id: personID,
                    from: oldFolderURL,
                    to: newFolderURL
                )
                searchText = ""
                selectedPersonID = personID
                reloadPeople()
                statusMessage = backupWarning
                    ?? "已重命名文件夹并同步 SQLite；文件夹内的内容未修改。"
                refreshBackupCount()
            } catch let databaseError {
                var rollbackError: Error?
                do {
                    _ = try LibraryFolderManager.renamePersonFolder(
                        at: newFolderURL,
                        to: oldFolderURL.lastPathComponent,
                        in: libraryURL
                    )
                } catch {
                    rollbackError = error
                }

                if let rollbackError {
                    throw AlbumError.database(
                        "数据库同步失败，且文件夹名称无法自动恢复。数据库仍指向：\(oldFolderURL.path)\n" +
                        "实际文件夹可能位于：\(newFolderURL.path)\n" +
                        "数据库错误：\(databaseError.localizedDescription)\n" +
                        "恢复错误：\(rollbackError.localizedDescription)"
                    )
                }
                throw AlbumError.database(
                    "数据库同步失败，文件夹已安全恢复为“\(oldFolderURL.lastPathComponent)”。\n" +
                    databaseError.localizedDescription
                )
            }
        } catch {
            show(error)
        }
    }

    func scanForNewFolders() {
        guard let store, let libraryURL else { return }
        do {
            let scanned = try LibraryScanner.scanPeople(in: libraryURL)
            let count = try store.importMissingFolders(scanned)
            platforms = try store.listPlatforms()
            reloadPeople(selectFirstIfNeeded: true)
            statusMessage = count == 0 ? "没有发现新的一级文件夹。" : "新增了 \(count) 条数据库记录；媒体文件未改变。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func saveSelectedPerson(silently: Bool = false) {
        guard let store, let id = selectedPersonID else { return }
        do {
            try store.updatePerson(id: id, draft: draft, accounts: draftAccounts)
            platforms = try store.listPlatforms()
            if !silently {
                reloadPeople()
                selectedPersonID = id
                loadSelectedPerson()
                statusMessage = "字段已保存到 SQLite；文件夹内容未改变。"
            }
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func deleteSelectedDatabaseRecord() {
        guard let store, let id = selectedPersonID else { return }
        do {
            try store.deletePerson(id: id)
            platforms = try store.listPlatforms()
            selectedPersonID = nil
            reloadPeople(selectFirstIfNeeded: true)
            statusMessage = "数据库记录已删除；对应文件夹及其中内容完全未动。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func replaceSelectedFolderPath(_ url: URL) {
        guard let libraryURL else { return }
        let normalized = url.standardizedFileURL
        guard normalized.deletingLastPathComponent().standardizedFileURL == libraryURL.standardizedFileURL else {
            show(AlbumError.invalidFolder("路径必须是 nickname 的直属子文件夹。"))
            return
        }
        draft.folderPath = normalized.path
        draft.nickname = normalized.lastPathComponent
    }

    func accounts(for platform: PlatformRecord) -> [SocialAccountRecord] {
        draftAccounts
            .filter { $0.platform.caseInsensitiveCompare(platform.name) == .orderedSame }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func addAccount(for platform: PlatformRecord) {
        guard let id = selectedPersonID else { return }
        let nextOrder = accounts(for: platform).count
        draftAccounts.append(
            .empty(personID: id, platform: platform.name, sortOrder: nextOrder)
        )
    }

    func addPlatform(named name: String) {
        guard let store else { return }
        do {
            _ = try store.addPlatform(named: name)
            platforms = try store.listPlatforms()
            statusMessage = "已新增平台“\(name.trimmingCharacters(in: .whitespacesAndNewlines))”。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func renamePlatform(_ platform: PlatformRecord, to name: String) {
        guard let store else { return }
        do {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.renamePlatform(id: platform.id, to: normalized)
            for index in draftAccounts.indices
            where draftAccounts[index].platform.caseInsensitiveCompare(platform.name) == .orderedSame {
                draftAccounts[index].platform = normalized
            }
            platforms = try store.listPlatforms()
            statusMessage = "已将平台“\(platform.name)”重命名为“\(normalized)”，关联账号已同步。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func deletePlatform(_ platform: PlatformRecord) {
        guard let store else { return }
        let hasDraftData = draftAccounts.contains {
            $0.platform.caseInsensitiveCompare(platform.name) == .orderedSame
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !hasDraftData || platform.accountCount > 0 else {
            show(AlbumError.database(
                "平台“\(platform.name)”当前有尚未保存的账号数据，请先清空或保存。"
            ))
            return
        }
        do {
            try store.deletePlatform(id: platform.id)
            draftAccounts.removeAll {
                $0.platform.caseInsensitiveCompare(platform.name) == .orderedSame
            }
            platforms = try store.listPlatforms()
            statusMessage = "已删除空平台“\(platform.name)”。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func updateAccount(id: Int64, value: String) {
        guard let index = draftAccounts.firstIndex(where: { $0.id == id }) else { return }
        draftAccounts[index].value = value
    }

    func removeAccount(id: Int64) {
        draftAccounts.removeAll { $0.id == id }
    }

    func createManualBackup() {
        guard let store else { return }
        do {
            try store.backupNow()
            refreshBackupCount()
            statusMessage = "已创建一致性数据库备份。"
        } catch {
            show(error)
        }
    }

    func revealSelectedFolder() {
        guard let person = selectedPerson, person.folderExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([person.folderURL])
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadMedia(for person: PersonRecord) {
        let generation = UUID()
        mediaLoadGeneration = generation
        mediaItems = []
        guard person.folderExists else {
            isLoadingMedia = false
            statusMessage = "记录中的文件夹路径不存在，请修正路径。"
            return
        }

        isLoadingMedia = true
        let folderURL = person.folderURL
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try MediaScanner.scanMedia(in: folderURL)
                }.value
                guard mediaLoadGeneration == generation else { return }
                mediaItems = items
                isLoadingMedia = false
            } catch {
                guard mediaLoadGeneration == generation else { return }
                isLoadingMedia = false
                show(error)
            }
        }
    }

    private func refreshBackupCount() {
        guard let store else { return }
        backupCount = (try? store.backupFiles().count) ?? 0
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
