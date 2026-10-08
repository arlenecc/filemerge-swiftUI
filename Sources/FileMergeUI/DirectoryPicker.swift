import AppKit
import Foundation

/// 目录选择器（NSOpenPanel 封装）。
/// 面板以附着到当前窗口的 sheet 方式弹出；仅在应用未激活时才调用 activate()
/// （已激活状态下调用会致 sheet 在 macOS 26 上被立即取消）；
/// 无可附加窗口时回退到 runModal。
@MainActor
enum DirectoryPicker {
    static func pickDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择一个目录"
        panel.prompt = "选择"

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            // 仅在应用尚未激活时才激活：实测 macOS 26 上对已激活应用调用 activate()
            // 会导致随后弹出的 sheet 被立即取消（表现为点击无反应）
            if !NSApp.isActive {
                if #available(macOS 14.0, *) {
                    NSApp.activate()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}
