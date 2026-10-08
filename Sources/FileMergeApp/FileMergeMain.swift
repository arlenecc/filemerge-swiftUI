import FileMergeUI
import SwiftUI

@main
struct FileMergeMainApp: App {
    var body: some Scene {
        WindowGroup("文件去重合并工具") {
            ContentView()
                .environmentObject(AppViewModel())
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
