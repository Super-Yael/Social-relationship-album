import SwiftUI

@main
struct PersonalAlbumApp: App {
    @StateObject private var model = AlbumViewModel()

    var body: some Scene {
        WindowGroup("个人相册") {
            ContentView()
                .environmentObject(model)
                .frame(
                    minWidth: AlbumLayout.minimumWindowWidth,
                    minHeight: AlbumLayout.minimumWindowHeight
                )
        }
        .defaultSize(width: 1_420, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            InspectorCommands()

            CommandGroup(replacing: .newItem) {
                Button("新建人物文件夹…") {
                    model.requestInterfaceAction(.createFolder)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.isConfigured)

                Button("添加已有人物文件夹…") {
                    model.requestInterfaceAction(.addExistingFolder)
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!model.isConfigured)
            }

            CommandGroup(after: .saveItem) {
                Button("保存资料字段") {
                    model.saveSelectedPerson()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedPersonID == nil)
            }

            CommandMenu("相册") {
                Button("扫描 nickname") {
                    model.scanForNewFolders()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isConfigured)

                Button("立即备份数据库") {
                    model.createManualBackup()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!model.isConfigured)

                Divider()

                Menu("筛选人物") {
                    Picker("平台", selection: Binding(
                        get: { model.peopleListOptions.platform },
                        set: { model.setPlatformFilter($0) }
                    )) {
                        Text("全部人物").tag(nil as String?)
                        ForEach(model.platforms) { platform in
                            Text(platform.name).tag(Optional(platform.name))
                        }
                    }
                }
                .disabled(!model.isConfigured)

                Menu("人物排序") {
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
                }
                .disabled(!model.isConfigured)

                Divider()

                Button("导入旧数据库备份…") {
                    model.requestInterfaceAction(.importDatabase)
                }

                Divider()

                Button("平台管理…") {
                    model.requestInterfaceAction(.managePlatforms)
                }
                .disabled(!model.isConfigured)

                Button("在 Finder 中显示人物文件夹") {
                    model.revealSelectedFolder()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedPerson?.folderExists != true)
            }
        }
    }
}
