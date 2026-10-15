import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// 退出前清掉设备的「激活」标志。等设备确认写入（或超时）后再真正退出，
    /// 免得退出太快把这条写入丢掉，设备停在「应用还在」的状态里。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.leaveAssistMode(completion: { NSApp.reply(toApplicationShouldTerminate: true) }) else {
            return .terminateNow
        }
        return .terminateLater
    }

    // 关掉窗口后继续留在菜单栏里工作。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct TouchUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 菜单栏放在前面：它是主场景，启动时只驻菜单栏，不自动开窗口。
        // 实测「窗口 + 菜单栏」的应用，窗口场景一被构建就要多占约 25MB，
        // 而日常使用几乎不需要那个窗口。
        MenuBarExtra {
            MenuBarView(model: .shared)
        } label: {
            MenuBarIcon(model: .shared)
        }

        // 窗口按需拉起：菜单栏「打开触达」调用 openWindow(id: "main")。
        Window("TouchUnlock", id: "main") {
            RootView(model: .shared)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 780, height: 560)
    }
}
