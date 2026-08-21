import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AlbumViewModel

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
            Text("请选择 nickname 文件夹。应用只读取其中的媒体，\n不会创建、移动、重命名或删除文件夹内容。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("选择 nickname 文件夹…") {
                chooseLibraryFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingCreateFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationSplitView {
            peopleSidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 390)
        } detail: {
            if model.selectedPerson != nil {
                HSplitView {
                    MediaBrowserView()
                        .frame(minWidth: 500)
                    PersonEditorView(isShowingDeleteConfirmation: $isShowingDeleteConfirmation)
                        .frame(minWidth: 370, idealWidth: 420, maxWidth: 520)
                }
            } else {
                ContentUnavailableView(
                    "没有人物记录",
                    systemImage: "person.crop.rectangle.stack",
                    description: Text("扫描 nickname 或添加一个已有文件夹。")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addExistingFolder()
                } label: {
                    Label("添加已有文件夹", systemImage: "plus")
                }
                .help("只增加数据库记录，不创建文件夹")

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
    }

    private var peopleSidebar: some View {
        VStack(spacing: 0) {
            Button {
                newFolderName = ""
                isShowingCreateFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("在 nickname 中新建一个空的人物文件夹")

            Divider()
            List(selection: $model.selectedPersonID) {
                ForEach(model.people) { person in
                    HStack(spacing: 9) {
                        Image(systemName: person.folderExists ? "folder.fill" : "exclamationmark.folder.fill")
                            .foregroundStyle(person.folderExists ? Color.accentColor : Color.orange)
                        Text(person.nickname)
                            .lineLimit(1)
                        Spacer()
                    }
                    .tag(person.id)
                }
            }
            .onChange(of: model.selectedPersonID) { _, _ in
                model.loadSelectedPerson()
            }

            Divider()
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索昵称、ID、备注…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { model.reloadPeople() }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                        model.reloadPeople(selectFirstIfNeeded: true)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
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

private struct MediaBrowserView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @State private var previewItem: MediaItem?
    private let columns = [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedPerson?.nickname ?? "")
                        .font(.title2.bold())
                    Text("只读预览 · \(model.mediaItems.count) 个媒体文件")
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
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.mediaItems) { item in
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
                            .onTapGesture(count: 2) { previewItem = item }
                            .contextMenu {
                                Button("预览") { previewItem = item }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .sheet(item: $previewItem) { item in
            MediaPreviewSheet(item: item)
        }
    }
}

private struct PersonEditorView: View {
    @EnvironmentObject private var model: AlbumViewModel
    @Binding var isShowingDeleteConfirmation: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("资料字段")
                    .font(.title3.bold())

                GroupBox("文件夹（唯一事实来源）") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("nickname", value: model.draft.nickname)
                        Text(model.draft.folderPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("修正数据库中的路径…") { chooseReplacementFolder() }
                            .help("只修改 SQLite 路径字段，不移动或改名文件夹")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("平台字段") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(SocialPlatform.allCases) { platform in
                            platformFields(platform)
                            if platform != SocialPlatform.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("备注") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $model.draft.notes)
                                .frame(minHeight: 82)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
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
    }

    private func platformFields(_ platform: SocialPlatform) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(platform.rawValue)
                .font(.caption.bold())

            ForEach(model.accounts(for: platform)) { account in
                HStack(spacing: 6) {
                    TextField(
                        platform.rawValue,
                        text: Binding(
                            get: {
                                model.draftAccounts.first(where: { $0.id == account.id })?.value ?? ""
                            },
                            set: { model.updateAccount(id: account.id, value: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button {
                        model.removeAccount(id: account.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("删除这一条 \(platform.rawValue) 记录")
                }
            }

            HStack {
                Spacer()
                Button {
                    model.addAccount(for: platform)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("增加一条 \(platform.rawValue) 记录")
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
}
