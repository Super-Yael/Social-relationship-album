import SwiftUI

@main
struct PersonalAlbumApp: App {
    @StateObject private var model = AlbumViewModel()

    var body: some Scene {
        WindowGroup("个人相册") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_120, minHeight: 720)
        }
        .defaultSize(width: 1_420, height: 900)
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
