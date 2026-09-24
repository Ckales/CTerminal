import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// ⌘Q 也走窗口关闭确认
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }), window.isVisible {
      window.performClose(nil)
      return .terminateCancel
    }
    return .terminateNow
  }
}
