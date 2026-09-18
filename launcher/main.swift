// VoiceType 的啟動器。
//
// 為什麼需要它：真正在做事的是 Hammerspoon 裡的模組，本身沒有 Dock 或
// Launchpad 的存在感。使用者會去那裡找，找不到就以為沒裝成功。
//
// 為什麼是常駐的 App 而不是跑完就結束的腳本：跑完就結束的話 Dock 永遠
// 不會出現圖示（或只閃一下），而且點 Dock 圖示也沒辦法把視窗叫回來。
// 這裡留著不結束，只為了提供 Dock 存在感與處理重新開啟事件。

import Cocoa

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        showWindow()
    }

    // 點 Dock 圖示（App 已經在跑）時把視窗叫回來
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    private func hammerspoonRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.hammerspoon.Hammerspoon").isEmpty
    }

    private func showWindow() {
        guard let url = URL(string: "hammerspoon://voicetype") else { return }
        if hammerspoonRunning() {
            NSWorkspace.shared.open(url)
            return
        }
        // Hammerspoon 沒在跑就先起它，等它載入完設定再送 URL
        guard let hs = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "org.hammerspoon.Hammerspoon") else {
            let a = NSAlert()
            a.messageText = "找不到 Hammerspoon"
            a.informativeText = "VoiceType 需要 Hammerspoon 才能運作。\n請重新執行安裝指令。"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        NSWorkspace.shared.openApplication(at: hs, configuration: .init()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // .regular = 在 Dock 顯示
app.run()
