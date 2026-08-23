import SwiftUI

@main
struct PersonalAlbumApp: App {
    @StateObject private var model = AlbumViewModel()
    @AppStorage(AlbumLayout.sidebarWidthKey)
    private var sidebarWidth = AlbumLayout.defaultSidebarWidth
    @AppStorage(AlbumLayout.editorWidthKey)
    private var editorWidth = AlbumLayout.defaultEditorWidth

    var body: some Scene {
        WindowGroup("个人相册") {
            ContentView()
                .environmentObject(model)
                .frame(
                    minWidth: AlbumLayout.minimumWindowWidth(
                        sidebarWidth: sidebarWidth,
                        editorWidth: editorWidth
                    ),
                    minHeight: 720
                )
        }
        .defaultSize(width: 1_420, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .saveItem) {
                Button("保存资料字段") {
                    model.saveSelectedPerson()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedPersonID == nil)
            }
        }
    }
}
