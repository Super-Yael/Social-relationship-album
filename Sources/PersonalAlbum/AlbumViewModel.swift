import AppKit
import Foundation

@MainActor
final class AlbumViewModel: ObservableObject {
    enum InterfaceAction: Equatable {
        case createFolder
        case addExistingFolder
        case importDatabase
        case managePlatforms
    }

    enum SaveState: Equatable {
        case saved
        case pending
        case saving
        case failed
    }

    @Published var libraryURL: URL?
    @Published var people: [PersonRecord] = []
    @Published var selectedPersonID: Int64?
    @Published var draft = PersonDraft()
    @Published var draftAccounts: [SocialAccountRecord] = []
    @Published var platforms: [PlatformRecord] = []
    @Published private(set) var peopleListOptions = PeopleListOptions()
    @Published var mediaItems: [MediaItem] = []
    @Published var isLoadingMedia = false
    @Published private(set) var isMovingDroppedFiles = false
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var statusMessage = ""
    @Published var backupCount = 0
    @Published private(set) var saveState: SaveState = .saved
    @Published var interfaceAction: InterfaceAction?

    private var store: SQLiteStore?
    private var mediaLoadGeneration = UUID()
    private let folderMonitor = LibraryFolderMonitor()
    private let libraryAccess = LibraryAccessController()
    private var autosaveTask: Task<Void, Never>?

    init() {
        do {
            if let libraryURL = try libraryAccess.restoreLibrary() {
                configure(libraryURL: libraryURL, persistAccess: false)
            }
        } catch {
            show(error)
        }
    }

    deinit {
        autosaveTask?.cancel()
    }

    var isConfigured: Bool { store != nil && libraryURL != nil }

    var selectedPerson: PersonRecord? {
        guard let selectedPersonID else { return nil }
        return people.first { $0.id == selectedPersonID }
    }

    func selectPerson(_ id: Int64?) {
        guard id != selectedPersonID else { return }
        if saveState == .pending || saveState == .failed {
            saveSelectedPerson(silently: true)
            guard saveState == .saved else { return }
        }
        selectedPersonID = id
        loadSelectedPerson()
    }

    func requestInterfaceAction(_ action: InterfaceAction) {
        interfaceAction = action
    }

    func consumeInterfaceAction() {
        interfaceAction = nil
    }

    func configure(libraryURL: URL) {
        configure(libraryURL: libraryURL, persistAccess: true)
    }

    private func configure(libraryURL: URL, persistAccess: Bool) {
        folderMonitor.stop()
        autosaveTask?.cancel()
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: libraryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AlbumError.invalidFolder("选择的位置不是有效文件夹。")
            }

            let normalized = persistAccess
                ? try libraryAccess.rememberAndAccessLibrary(libraryURL)
                : libraryURL.standardizedFileURL
            let dataDirectory = try AppPaths.prepareApplicationDataDirectory()
            let databaseURL = try AppPaths.databaseURL()
            let backupDirectoryURL = try AppPaths.backupDirectoryURL()
            guard AppPaths.isInsideApplicationData(databaseURL),
                  AppPaths.isInsideApplicationData(backupDirectoryURL) else {
                throw AlbumError.database("数据库和备份必须位于 App 数据目录内：\(dataDirectory.path)")
            }
            let store = try SQLiteStore(
                databaseURL: databaseURL,
                backupDirectoryURL: backupDirectoryURL,
                backupLimitBytes: AppPaths.backupLimitBytes,
                requiresApplicationDataLocation: true
            )
            self.store = store
            self.libraryURL = normalized
            try store.saveLibraryRoot(normalized.path)

            let scanned = try LibraryScanner.scanPeople(in: normalized)
            let count = try store.importMissingFolders(scanned)
            statusMessage = count == 0
                ? "启动扫描完成，没有发现新的一级文件夹。"
                : "启动扫描新增了 \(count) 条数据库记录；媒体文件未改变。"
            try store.backupNow()
            platforms = try store.listPlatforms()
            var restoredOptions = try store.loadPeopleListOptions()
            if let filteredPlatform = restoredOptions.platform {
                restoredOptions.platform = platforms.first(where: {
                    $0.name.caseInsensitiveCompare(filteredPlatform) == .orderedSame
                })?.name
            }
            peopleListOptions = restoredOptions
            try store.savePeopleListOptions(restoredOptions)
            reloadPeople(selectFirstIfNeeded: true)
            refreshBackupCount()
            do {
                try folderMonitor.start(watching: normalized) { [weak self] in
                    self?.scanForNewFoldersAutomatically()
                }
            } catch {
                statusMessage += " 实时监听未启动，请使用工具栏中的“扫描 nickname”。"
                show(error)
            }
        } catch {
            folderMonitor.stop()
            self.store = nil
            self.libraryURL = nil
            self.platforms = []
            if persistAccess {
                libraryAccess.stopAccessingLibrary()
            }
            show(error)
        }
    }

    func reloadPeople(selectFirstIfNeeded: Bool = false) {
        guard let store else { return }
        if saveState == .pending || saveState == .failed {
            saveSelectedPerson(silently: true)
            guard saveState == .saved else { return }
        }
        do {
            let previousSelection = selectedPersonID
            people = try store.listPeople(
                search: searchText,
                platform: peopleListOptions.platform,
                sortField: peopleListOptions.sortField,
                sortDirection: peopleListOptions.sortDirection
            )
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
        autosaveTask?.cancel()
        guard let person = selectedPerson else {
            draft = PersonDraft()
            draftAccounts = []
            mediaItems = []
            saveState = .saved
            return
        }
        draft = PersonDraft(person: person)
        do {
            draftAccounts = try store?.socialAccounts(for: person.id) ?? []
            saveState = .saved
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
        scanForNewFolders(announceWhenEmpty: true)
    }

    func setPlatformFilter(_ platform: String?) {
        guard let store else { return }
        flushAutosave()
        guard saveState == .saved else { return }
        let canonicalPlatform = platform.flatMap { requested in
            platforms.first(where: {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
            })?.name
        }
        guard canonicalPlatform != peopleListOptions.platform else { return }
        var options = peopleListOptions
        options.platform = canonicalPlatform
        do {
            try store.savePeopleListOptions(options)
            peopleListOptions = options
            reloadPeople(selectFirstIfNeeded: true)
            statusMessage = canonicalPlatform.map { "已筛选出 \($0) 平台有记录的人物。" }
                ?? "已显示全部人物。"
        } catch {
            show(error)
        }
    }

    func setPeopleSortField(_ field: PeopleSortField) {
        updatePeopleListOptions { $0.sortField = field }
    }

    func setPeopleSortDirection(_ direction: PeopleSortDirection) {
        updatePeopleListOptions { $0.sortDirection = direction }
    }

    private func scanForNewFoldersAutomatically() {
        scanForNewFolders(announceWhenEmpty: false)
    }

    private func scanForNewFolders(announceWhenEmpty: Bool) {
        guard let store, let libraryURL else { return }
        do {
            let scanned = try LibraryScanner.scanPeople(in: libraryURL)
            let count = try store.importMissingFolders(scanned)
            if count > 0 {
                platforms = try store.listPlatforms()
                reloadPeople(selectFirstIfNeeded: true)
                statusMessage = announceWhenEmpty
                    ? "新增了 \(count) 条数据库记录；媒体文件未改变。"
                    : "检测到新的 nickname 文件夹，已自动新增 \(count) 条数据库记录。"
                refreshBackupCount()
            } else if announceWhenEmpty {
                statusMessage = "没有发现新的一级文件夹。"
            }
        } catch {
            show(error)
        }
    }

    func saveSelectedPerson(silently: Bool = false) {
        guard let store, let id = selectedPersonID else { return }
        autosaveTask?.cancel()
        saveState = .saving
        do {
            let previousFolderPath = selectedPerson?.folderPath
            try store.updatePerson(id: id, draft: draft, accounts: draftAccounts)
            platforms = try store.listPlatforms()
            saveState = .saved
            if silently {
                let needsQueryRefresh = peopleListOptions.platform != nil
                    || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if needsQueryRefresh {
                    reloadPeople(selectFirstIfNeeded: true)
                } else if let index = people.firstIndex(where: { $0.id == id }) {
                    people[index].nickname = URL(fileURLWithPath: draft.folderPath).lastPathComponent
                    people[index].folderPath = draft.folderPath
                    people[index].notes = draft.notes
                    people[index].updatedAt = Date().timeIntervalSince1970
                    if previousFolderPath != draft.folderPath {
                        loadMedia(for: people[index])
                    }
                }
                statusMessage = "更改已自动保存。"
            } else {
                reloadPeople()
                selectedPersonID = id
                loadSelectedPerson()
                statusMessage = "字段已保存到 SQLite；文件夹内容未改变。"
            }
            refreshBackupCount()
        } catch {
            saveState = .failed
            show(error)
        }
    }

    func updateNotes(_ value: String) {
        guard draft.notes != value else { return }
        draft.notes = value
        scheduleAutosave()
    }

    func flushAutosave() {
        if saveState == .pending {
            saveSelectedPerson(silently: true)
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
        scheduleAutosave()
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
            if peopleListOptions.platform?.caseInsensitiveCompare(platform.name) == .orderedSame {
                var options = peopleListOptions
                options.platform = normalized
                try store.savePeopleListOptions(options)
                peopleListOptions = options
                reloadPeople(selectFirstIfNeeded: true)
            }
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
            if peopleListOptions.platform?.caseInsensitiveCompare(platform.name) == .orderedSame {
                var options = peopleListOptions
                options.platform = nil
                try store.savePeopleListOptions(options)
                peopleListOptions = options
                reloadPeople(selectFirstIfNeeded: true)
            }
            statusMessage = "已删除空平台“\(platform.name)”。"
            refreshBackupCount()
        } catch {
            show(error)
        }
    }

    func updateAccount(id: Int64, value: String) {
        guard let index = draftAccounts.firstIndex(where: { $0.id == id }) else { return }
        draftAccounts[index].value = value
        scheduleAutosave()
    }

    func removeAccount(id: Int64) {
        draftAccounts.removeAll { $0.id == id }
        scheduleAutosave()
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

    func importDatabaseSnapshot(_ sourceURL: URL) {
        let currentLibraryURL = libraryURL
        let didStartSourceAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSourceAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        folderMonitor.stop()
        autosaveTask?.cancel()

        if saveState == .pending || saveState == .failed {
            saveSelectedPerson(silently: true)
            guard saveState == .saved else { return }
        }

        do {
            try store?.backupNow()
            store = nil
            let destinationURL = try AppPaths.databaseURL()
            try SQLiteStore.importSnapshot(from: sourceURL, to: destinationURL)

            if let currentLibraryURL {
                configure(libraryURL: currentLibraryURL, persistAccess: false)
                statusMessage = "旧数据库已导入 App 数据目录，并已创建新的安全备份。"
            } else {
                statusMessage = "旧数据库已导入 App 数据目录。现在请选择 nickname 文件夹。"
            }
        } catch {
            if let currentLibraryURL {
                configure(libraryURL: currentLibraryURL, persistAccess: false)
            }
            show(error)
        }
    }

    func revealSelectedFolder() {
        guard let person = selectedPerson, person.folderExists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([person.folderURL])
    }

    @discardableResult
    func moveDroppedFiles(_ sourceURLs: [URL]) -> Bool {
        guard !sourceURLs.isEmpty else { return false }
        guard !isMovingDroppedFiles else {
            show(AlbumError.invalidFolder("上一批文件仍在移动，请稍后再试。"))
            return false
        }
        guard let libraryURL, let person = selectedPerson, person.folderExists else {
            show(AlbumError.invalidFolder("请先选择一个文件夹存在的人物。"))
            return false
        }

        let personID = person.id
        let personName = person.nickname
        let destinationFolder = person.folderURL
        let scopedURLs = sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
        isMovingDroppedFiles = true
        statusMessage = "正在将 \(sourceURLs.count) 个文件移入“\(personName)”…"

        Task {
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
                isMovingDroppedFiles = false
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryFolderManager.moveMediaFiles(
                        at: sourceURLs,
                        to: destinationFolder,
                        in: libraryURL
                    )
                }.value

                if selectedPersonID == personID, let currentPerson = selectedPerson {
                    loadMedia(for: currentPerson)
                }
                let movedCount = result.destinations.count
                if movedCount == 0 {
                    statusMessage = "文件已在“\(personName)”文件夹中，无需移动。"
                } else if result.skippedCount == 0 {
                    statusMessage = "已将 \(movedCount) 个文件移入“\(personName)”。"
                } else {
                    statusMessage = "已将 \(movedCount) 个文件移入“\(personName)”；\(result.skippedCount) 个已在目标中。"
                }
            } catch {
                show(error)
                statusMessage = "文件移动未完成。"
            }
        }
        return true
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

    private func scheduleAutosave() {
        guard selectedPersonID != nil else { return }
        autosaveTask?.cancel()
        saveState = .pending
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.saveSelectedPerson(silently: true)
        }
    }

    private func updatePeopleListOptions(_ update: (inout PeopleListOptions) -> Void) {
        guard let store else { return }
        flushAutosave()
        guard saveState == .saved else { return }
        var options = peopleListOptions
        update(&options)
        guard options != peopleListOptions else { return }
        do {
            try store.savePeopleListOptions(options)
            peopleListOptions = options
            reloadPeople(selectFirstIfNeeded: true)
            statusMessage = "人物排序已更新。"
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
