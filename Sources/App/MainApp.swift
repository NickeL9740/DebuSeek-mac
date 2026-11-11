import Cocoa
import SwiftUI

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    
    var petController: PetController!
    
    // 必须强引用，否则窗口会被瞬间释放
    var settingsWindow: NSWindow?
    var chatWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon for menu-bar only app
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize pet controller（必须在启动时初始化）
        petController = PetController.shared
        petController.handleOfflineCompensation()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        petController?.saveLastOnlineTimestamp()
        PetState.shared.saveState()
        ConfigManager.shared.saveConfig()
    }
    
    // MARK: - Window Management（标准 LSUIElement 弹窗流程）
    
    func showSettingsWindow() {
        print("⚙️ Settings window triggered")
        
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false // 关闭时不要销毁，复用
            window.level = .floating            // 悬浮在最前面
            
            // 必须用 NSHostingController 包装 SwiftUI 视图，并补齐 @EnvironmentObject
            let root = SettingsView()
                .environmentObject(ConfigManager.shared)
                .environmentObject(PetState.shared)
                .environmentObject(PetController.shared)
            window.contentViewController = NSHostingController(rootView: root)
            
            window.center()
            self.settingsWindow = window
        }
        
        // 强制抢夺焦点，并推到最前
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    func showChatWindow() {
        print("💬 Chat window triggered")
        
        if chatWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = .floating
            
            let root = ChatView()
                .environmentObject(PetController.shared)
                .environmentObject(ChatHistoryManager.shared)
            window.contentViewController = NSHostingController(rootView: root)
            
            window.center()
            self.chatWindow = window
        }
        
        NSApp.activate(ignoringOtherApps: true)
        chatWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pure AppKit Entry Point（无 SwiftUI @main / Scene）

@main
struct DesktopPetLauncher {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.run()
    }
}
