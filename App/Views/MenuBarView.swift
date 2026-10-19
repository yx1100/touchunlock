import DurianCore
import SwiftUI

/// 菜单栏图标：按状态换符号，让用户不用打开窗口就能看到是否需要处理。
struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        // 默认字号下 touchid 比其他菜单栏图标小一圈，放大一档与它们齐高。
        Image(systemName: model.menuBarSymbol)
            .imageScale(.large)
    }
}

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 菜单栏只留「连上没连上」这一条状态；固件版本在窗口的侧边栏和概览页都有，这里不重复。
        Text(model.bleState.title)
        if model.isReady, !model.keyboardLinked {
            Text("The Mac has no keyboard for the device")
        }
        Divider()
        Button("Open TouchUnlock") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.isReady {
            Button("Disconnect") { model.disconnect() }
        } else {
            Button("Connect") { model.reconnect() }
        }
        Divider()
        Button("Quit TouchUnlock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
