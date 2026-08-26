import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AlbumPanels {
    static func chooseDatabaseSnapshot() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入旧数据库备份"
        panel.message = "选择一份一致性的 .sqlite 备份；App 只读取它，并将副本导入自己的数据目录。"
        panel.prompt = "导入副本"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .database]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum AlbumLayout {
    static let defaultSidebarWidth = 280.0
    static let defaultEditorWidth = 420.0
    static let sidebarWidthRange = 240.0...380.0
    static let editorWidthRange = 340.0...560.0
    static let sidebarCollapseWidth: CGFloat = 900
    static let inspectorCollapseWidth: CGFloat = 1_180
    static let minimumWindowWidth: CGFloat = 760
    static let minimumWindowHeight: CGFloat = 560

    static func shouldCollapseSidebar(at windowWidth: CGFloat) -> Bool {
        windowWidth < sidebarCollapseWidth
    }

    static func shouldCollapseInspector(at windowWidth: CGFloat) -> Bool {
        windowWidth < inspectorCollapseWidth
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isConfigured {
                AlbumMainView()
            } else {
                SetupView()
            }
        }
        .alert("发生错误", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.flushAutosave()
            }
        }
    }
}

private struct SetupView: View {
    @EnvironmentObject private var model: AlbumViewModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("个人相册")
                .font(.largeTitle.bold())
            Text("请选择 nickname 文件夹。只有你主动新建、重命名，\n或将文件拖入预览区时，应用才会改变媒体库。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("选择 nickname 文件夹…") {
                chooseLibraryFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("先导入旧数据库备份…") {
                if let url = AlbumPanels.chooseDatabaseSnapshot() {
                    model.importDatabaseSnapshot(url)
                }
            }
            .help("数据库副本只会写入 App 数据目录")

            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .padding(40)
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 nickname 文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.configure(libraryURL: url)
        }
    }
}

private struct AlbumMainView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isInspectorPresented = true
    @State private var sidebarVisibilityBeforeAutomaticCollapse: NavigationSplitViewVisibility?
    @State private var inspectorVisibilityBeforeAutomaticCollapse: Bool?
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingCreateFolder = false
    @State private var isShowingPlatformManagement = false
    @State private var newFolderName = ""

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $columnVisibility) {
                peopleSidebar
                    .frame(minWidth: AlbumLayout.sidebarWidthRange.lowerBound)
                    .navigationSplitViewColumnWidth(
                        min: AlbumLayout.sidebarWidthRange.lowerBound,
                        ideal: AlbumLayout.defaultSidebarWidth,
                        max: AlbumLayout.sidebarWidthRange.upperBound
                    )
            } detail: {
                if model.selectedPerson != nil {
                    MediaBrowserView()
                } else {
                    ContentUnavailableView(
                        "没有人物记录",
                        systemImage: "person.crop.rectangle.stack",
                        description: Text("扫描 nickname 或添加一个已有文件夹。")
                    )
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .inspector(isPresented: $isInspectorPresented) {
                PersonEditorView(isShowingDeleteConfirmation: $isShowingDeleteConfirmation)
                    .inspectorColumnWidth(
                        min: AlbumLayout.editorWidthRange.lowerBound,
                        ideal: AlbumLayout.defaultEditorWidth,
                        max: AlbumLayout.editorWidthRange.upperBound
                    )
            }
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                    ToolbarItemGroup {
                        addPersonMenu
                        albumActionsMenu
                        inspectorToggleButton
                    }
                } else {
                    ToolbarItemGroup(placement: .secondaryAction) {
                        addPersonMenu
                        albumActionsMenu
                        inspectorToggleButton
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.statusMessage.isEmpty {
                    HStack {
                        Text(model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("备份 \(model.backupCount) 份 · 上限 50 MiB")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .alert("新建人物文件夹", isPresented: $isShowingCreateFolder) {
                TextField("nickname", text: $newFolderName)
                Button("新建") {
                    let name = newFolderName
                    newFolderName = ""
                    model.createPersonFolder(named: name)
                }
                Button("取消", role: .cancel) {
                    newFolderName = ""
                }
            } message: {
                Text("只会在 nickname 根目录创建一个空文件夹。")
            }
            .sheet(isPresented: $isShowingPlatformManagement) {
                PlatformManagementView()
                    .environmentObject(model)
            }
            .onAppear {
                adaptChrome(to: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in
                adaptChrome(to: width)
            }
            .onChange(of: model.interfaceAction) { _, action in
                guard let action else { return }
                switch action {
                case .createFolder:
                    newFolderName = ""
                    isShowingCreateFolder = true
                case .addExistingFolder:
                    addExistingFolder()
                case .importDatabase:
                    if let url = AlbumPanels.chooseDatabaseSnapshot() {
                        model.importDatabaseSnapshot(url)
                    }
                case .managePlatforms:
                    isShowingPlatformManagement = true
                }
                model.consumeInterfaceAction()
            }
        }
    }

    private var peopleSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(sidebarSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                platformFilterMenu
                peopleSortMenu
                if model.peopleListOptions.platform != nil {
                    Button {
                        model.setPlatformFilter(nil)
                    } label: {
                        Label("清除平台筛选", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("显示全部人物")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                if model.people.isEmpty, let platform = model.peopleListOptions.platform {
                    VStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("没有 \(platform) 记录")
                            .font(.headline)
                        Button("显示全部人物") {
                            model.setPlatformFilter(nil)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(selection: Binding(
                        get: { model.selectedPersonID },
                        set: { model.selectPerson($0) }
                    )) {
                        ForEach(model.people) { person in
                            HStack(spacing: 9) {
                                Image(systemName: person.folderExists ? "folder.fill" : "exclamationmark.folder.fill")
                                    .foregroundStyle(person.folderExists ? Color.accentColor : Color.orange)
                                Text(person.nickname)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .tag(person.id)
                            .accessibilityLabel(person.nickname)
                            .accessibilityHint(
                                person.folderExists ? "打开人物相册" : "人物文件夹不存在"
                            )
                        }
                    }
                }
            }
            .searchable(
                text: $model.searchText,
                placement: .sidebar,
                prompt: "搜索昵称、账号、备注"
            )
            .onSubmit(of: .search) { model.reloadPeople() }
            .onChange(of: model.searchText) { _, _ in
                model.reloadPeople(selectFirstIfNeeded: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func adaptChrome(to windowWidth: CGFloat) {
        if AlbumLayout.shouldCollapseInspector(at: windowWidth) {
            if inspectorVisibilityBeforeAutomaticCollapse == nil {
                inspectorVisibilityBeforeAutomaticCollapse = isInspectorPresented
            }
            isInspectorPresented = false
        } else if let previousVisibility = inspectorVisibilityBeforeAutomaticCollapse {
            isInspectorPresented = previousVisibility
            inspectorVisibilityBeforeAutomaticCollapse = nil
        }

        if AlbumLayout.shouldCollapseSidebar(at: windowWidth) {
            if sidebarVisibilityBeforeAutomaticCollapse == nil {
                sidebarVisibilityBeforeAutomaticCollapse = columnVisibility
            }
            columnVisibility = .detailOnly
        } else if let previousVisibility = sidebarVisibilityBeforeAutomaticCollapse {
            columnVisibility = previousVisibility
            sidebarVisibilityBeforeAutomaticCollapse = nil
        }
    }

    private var platformFilterMenu: some View {
        Menu {
            Picker("平台筛选", selection: Binding(
                get: { model.peopleListOptions.platform },
                set: { model.setPlatformFilter($0) }
            )) {
                Text("全部人物").tag(nil as String?)
                ForEach(model.platforms) { platform in
                    Text(platform.name).tag(Optional(platform.name))
                }
            }
        } label: {
            Label(
                model.peopleListOptions.platform.map { "筛选：\($0)" } ?? "筛选人物",
                systemImage: model.peopleListOptions.platform == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.peopleListOptions.platform.map { "当前筛选：\($0)" } ?? "按平台筛选人物")
        .accessibilityLabel(
            model.peopleListOptions.platform.map { "平台筛选，当前为 \($0)" } ?? "平台筛选，当前显示全部人物"
        )
    }

    private var peopleSortMenu: some View {
        Menu {
            Picker("排序依据", selection: Binding(
                get: { model.peopleListOptions.sortField },
                set: { model.setPeopleSortField($0) }
            )) {
                ForEach(PeopleSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }

            Divider()

            Picker("排序顺序", selection: Binding(
                get: { model.peopleListOptions.sortDirection },
                set: { model.setPeopleSortDirection($0) }
            )) {
                ForEach(PeopleSortDirection.allCases) { direction in
                    Text(direction.title).tag(direction)
                }
            }
        } label: {
            Label("排序人物", systemImage: "arrow.up.arrow.down.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按\(model.peopleListOptions.sortField.title)\(model.peopleListOptions.sortDirection.title)排序")
        .accessibilityLabel(
            "人物排序，当前按\(model.peopleListOptions.sortField.title)\(model.peopleListOptions.sortDirection.title)"
        )
    }

    private var addPersonMenu: some View {
        Menu {
            Button {
                newFolderName = ""
                isShowingCreateFolder = true
            } label: {
                Label("新建人物文件夹…", systemImage: "folder.badge.plus")
            }

            Button {
                addExistingFolder()
            } label: {
                Label("加入已有文件夹…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("添加人物", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .help("新建或加入人物文件夹")
        .accessibilityLabel("添加人物")
    }

    private var inspectorToggleButton: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Label(
                isInspectorPresented ? "隐藏资料栏" : "显示资料栏",
                systemImage: "sidebar.right"
            )
        }
        .help(isInspectorPresented ? "隐藏资料栏" : "显示资料栏")
    }

    private var albumActionsMenu: some View {
        Menu {
            Button {
                model.scanForNewFolders()
            } label: {
                Label("扫描 nickname", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                model.createManualBackup()
            } label: {
                Label("立即备份数据库", systemImage: "externaldrive.badge.timemachine")
            }

            Divider()

            Button {
                isShowingPlatformManagement = true
            } label: {
                Label("平台管理…", systemImage: "rectangle.3.group")
            }
        } label: {
            Label("更多相册操作", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help("更多相册操作")
        .accessibilityLabel("更多相册操作")
    }

    private var sidebarSummary: String {
        let count = "\(model.people.count) 人"
        guard let platform = model.peopleListOptions.platform else { return count }
        return "\(platform) · \(count)"
    }

    private func addExistingFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择一个已有的人物文件夹"
        panel.prompt = "加入数据库"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.libraryURL
        if panel.runModal() == .OK, let url = panel.url {
            model.addFolder(url)
        }
    }
}

private struct PlatformManagementView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingAdd = false
    @State private var newPlatformName = ""
    @State private var renameTarget: PlatformRecord?
    @State private var renamedPlatformName = ""
    @State private var deleteTarget: PlatformRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("平台管理")
                        .font(.title2.bold())
                    Text("共 \(model.platforms.count) 个平台；右侧数字为 SQLite 中的账号记录数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增平台") {
                    newPlatformName = ""
                    isShowingAdd = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            List(model.platforms) { platform in
                HStack(spacing: 12) {
                    Image(systemName: "at")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(platform.name)
                        .font(.body.weight(.medium))
                    Spacer()
                    Text("\(platform.accountCount) 条数据")
                        .font(.caption)
                        .foregroundStyle(platform.accountCount == 0 ? .secondary : .primary)
                        .monospacedDigit()

                    Button {
                        renamedPlatformName = platform.name
                        renameTarget = platform
                    } label: {
                        Label("重命名 \(platform.name)", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("重命名“\(platform.name)”")

                    Button(role: .destructive) {
                        deleteTarget = platform
                    } label: {
                        Label("删除 \(platform.name)", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(platform.accountCount > 0)
                    .help(
                        platform.accountCount == 0
                            ? "删除空平台“\(platform.name)”"
                            : "仍有账号数据，不能删除"
                    )
                }
                .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Label("只有 0 条数据的平台才能删除。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 430)
        .alert("新增平台", isPresented: $isShowingAdd) {
            TextField("平台名称", text: $newPlatformName)
            Button("新增") {
                let name = newPlatformName
                newPlatformName = ""
                model.addPlatform(named: name)
            }
            Button("取消", role: .cancel) { newPlatformName = "" }
        } message: {
            Text("新平台会出现在每个人的平台字段中。")
        }
        .alert(
            "重命名平台",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("平台名称", text: $renamedPlatformName)
            Button("保存") {
                if let platform = renameTarget {
                    model.renamePlatform(platform, to: renamedPlatformName)
                }
                renameTarget = nil
                renamedPlatformName = ""
            }
            Button("取消", role: .cancel) {
                renameTarget = nil
                renamedPlatformName = ""
            }
        } message: {
            Text("已有账号会自动跟随新的平台名称。")
        }
        .confirmationDialog(
            "删除平台？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除空平台", role: .destructive) {
                if let platform = deleteTarget {
                    model.deletePlatform(platform)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("数据库将再次确认该平台没有任何账号数据。")
        }
    }
}

private struct MediaBrowserView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @State private var previewItem: MediaItem?
    @State private var selectedMediaID: MediaItem.ID?
    @State private var isDropTargeted = false
    @FocusState private var isMediaGridFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedPerson?.nickname ?? "")
                        .font(.title2.bold())
                    Text("拖入可移动文件 · \(model.mediaItems.count) 个媒体文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.revealSelectedFolder()
                } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                .disabled(model.selectedPerson?.folderExists != true)
            }
            .padding(14)
            Divider()

            if model.isLoadingMedia {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取文件夹内容…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.mediaItems.isEmpty {
                ContentUnavailableView(
                    "没有可预览媒体",
                    systemImage: "photo.stack",
                    description: Text("支持常见图片与视频格式，并会递归读取子文件夹。")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(model.mediaItems) { item in
                                MediaGridCell(item: item, isSelected: selectedMediaID == item.id)
                                // Animate each card as one geometric unit while a system
                                // sidebar or inspector changes the grid's available width.
                                .geometryGroup()
                                .onTapGesture(count: 2) {
                                    selectedMediaID = item.id
                                    previewItem = item
                                }
                                .onTapGesture {
                                    selectedMediaID = item.id
                                    isMediaGridFocused = true
                                }
                                .contextMenu {
                                    Button("预览") { previewItem = item }
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(
                                    "\(item.name)，\(item.kind == .image ? "图片" : "视频")"
                                )
                                .accessibilityHint("按空格键预览")
                                .accessibilityAddTraits(
                                    selectedMediaID == item.id ? .isSelected : []
                                )
                                .id(item.id)
                            }
                        }
                        .padding(14)
                    }
                    .focusable()
                    .focused($isMediaGridFocused)
                    .onChange(of: selectedMediaID) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    .onKeyPress(.space) {
                        previewSelectedMedia()
                    }
                    .onKeyPress(.return) {
                        previewSelectedMedia()
                    }
                    .onKeyPress(.leftArrow) {
                        moveMediaSelection(by: -1)
                    }
                    .onKeyPress(.upArrow) {
                        moveMediaSelection(by: -1)
                    }
                    .onKeyPress(.rightArrow) {
                        moveMediaSelection(by: 1)
                    }
                    .onKeyPress(.downArrow) {
                        moveMediaSelection(by: 1)
                    }
                }
            }
        }
        .onChange(of: model.selectedPersonID) { _, _ in
            selectedMediaID = nil
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.moveDroppedFiles(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.10)
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .padding(8)
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 34))
                        Text("移入“\(model.selectedPerson?.nickname ?? "当前人物")”")
                            .font(.headline)
                        Text("原文件会被移动，不会复制")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .allowsHitTesting(false)
            }
        }
        .sheet(item: $previewItem) { item in
            MediaPreviewSheet(item: item)
        }
    }

    private func previewSelectedMedia() -> KeyPress.Result {
        guard let selectedMediaID,
              let item = model.mediaItems.first(where: { $0.id == selectedMediaID }) else {
            return .ignored
        }
        previewItem = item
        return .handled
    }

    private func moveMediaSelection(by offset: Int) -> KeyPress.Result {
        guard !model.mediaItems.isEmpty else { return .ignored }
        let currentIndex = selectedMediaID.flatMap { selectedID in
            model.mediaItems.firstIndex(where: { $0.id == selectedID })
        } ?? (offset > 0 ? -1 : model.mediaItems.count)
        let nextIndex = min(max(currentIndex + offset, 0), model.mediaItems.count - 1)
        selectedMediaID = model.mediaItems[nextIndex].id
        return .handled
    }
}

private struct MediaGridCell: View {
    let item: MediaItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaThumbnailView(item: item)
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

private struct PersonEditorView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @Binding var isShowingDeleteConfirmation: Bool
    @State private var isShowingRenameFolder = false
    @State private var renamedFolderName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("资料字段")
                    .font(.title3.bold())

                Label {
                    Text(saveStateDescription)
                } icon: {
                    Image(systemName: saveStateSymbol)
                }
                .font(.caption)
                .foregroundStyle(model.saveState == .failed ? Color.red : Color.secondary)
                .accessibilityLabel("保存状态：\(saveStateDescription)")

                GroupBox("文件夹（唯一事实来源）") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("nickname", value: model.draft.nickname)
                        Text(model.draft.folderPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("重命名文件夹…") {
                                renamedFolderName = model.draft.nickname
                                isShowingRenameFolder = true
                            }
                            .disabled(model.selectedPerson?.folderExists != true)
                            .help("重命名 nickname 中的文件夹，并同步 SQLite")

                            Button("修正数据库中的路径…") { chooseReplacementFolder() }
                                .help("只修改 SQLite 路径字段，不移动或改名文件夹")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("平台字段") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.platforms) { platform in
                            platformFields(platform)
                            if platform.id != model.platforms.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("备注") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: Binding(
                                get: { model.draft.notes },
                                set: { model.updateNotes($0) }
                            ))
                                .frame(minHeight: 82)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                                .accessibilityLabel("备注")
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    Button("保存字段") {
                        model.saveSelectedPerson()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)

                    Spacer()

                    Button("删除数据库记录", role: .destructive) {
                        isShowingDeleteConfirmation = true
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .confirmationDialog(
            "只删除 SQLite 中的记录？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除数据库记录", role: .destructive) {
                model.deleteSelectedDatabaseRecord()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会删除、移动或修改对应文件夹及其中的任何内容。")
        }
        .alert("重命名人物文件夹", isPresented: $isShowingRenameFolder) {
            TextField("nickname", text: $renamedFolderName)
            Button("重命名") {
                let name = renamedFolderName
                renamedFolderName = ""
                model.renameSelectedPersonFolder(to: name)
            }
            Button("取消", role: .cancel) {
                renamedFolderName = ""
            }
        } message: {
            Text("将直接重命名 nickname 中的文件夹并同步 SQLite。不会修改文件夹内的文件。")
        }
    }

    private func platformFields(_ platform: PlatformRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(platform.name)
                .font(.caption.bold())

            ForEach(model.accounts(for: platform)) { account in
                HStack(spacing: 6) {
                    TextField(
                        platform.name,
                        text: Binding(
                            get: {
                                model.draftAccounts.first(where: { $0.id == account.id })?.value ?? ""
                            },
                            set: { model.updateAccount(id: account.id, value: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.saveSelectedPerson(silently: true)
                    }

                    Button {
                        model.removeAccount(id: account.id)
                    } label: {
                        Label("删除这一条 \(platform.name) 记录", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("删除这一条 \(platform.name) 记录")
                }
            }

            HStack {
                Spacer()
                Button {
                    model.addAccount(for: platform)
                } label: {
                    Label("增加一条 \(platform.name) 记录", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("增加一条 \(platform.name) 记录")
            }
        }
    }

    private func chooseReplacementFolder() {
        let panel = NSOpenPanel()
        panel.title = "修正 SQLite 中的文件夹路径"
        panel.prompt = "使用这个路径"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.libraryURL
        if panel.runModal() == .OK, let url = panel.url {
            model.replaceSelectedFolderPath(url)
        }
    }

    private var saveStateDescription: String {
        switch model.saveState {
        case .saved: "已自动保存"
        case .pending: "等待自动保存"
        case .saving: "正在保存"
        case .failed: "保存失败"
        }
    }

    private var saveStateSymbol: String {
        switch model.saveState {
        case .saved: "checkmark.circle"
        case .pending: "clock"
        case .saving: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        }
    }
}
