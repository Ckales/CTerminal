import Carbon
import Cocoa
import FlutterMacOS

/// 把标签栏画进标题栏：隐藏标题、透明标题栏、内容铺满整个窗口。
/// 标题栏那一条的拖动默认被窗口服务器接管（标签页在这里拖不动），所以关掉 isMovable，
/// 由 Dart 在空白处按下时调 startDrag，临时打开 isMovable 交给系统拖动。
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel?
  private var allowClose = false
  private var englishInputOnActivate = false
  private var inputSourceBeforeActivation: TISInputSource?
  private var didSelectEnglishInput = false
  /// Dart 在拖动越过阈值后才调 startDrag，系统拖动要拿最初的 mouseDown 才能让窗口跟住鼠标
  private var lastMouseDown: NSEvent?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown { lastMouseDown = event }
    super.sendEvent(event)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // 终端背景透明度设置需要 Flutter 视图本身透明
    flutterViewController.backgroundColor = .clear
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    isMovable = false
    // 不可移动的窗口在显示器拔掉 / 重排时系统不会帮忙挪回来，窗口完全落在屏幕外时自己居中
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      if let self = self, self.screen == nil { self.center() }
    }
    NotificationCenter.default.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.captureInputSource()
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.selectEnglishInputSource()
    }
    NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.restoreInputSource()
    }
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      self?.restoreInputSource()
    }
    isOpaque = false
    backgroundColor = .clear
    contentMinSize = NSSize(width: 480, height: 320)
    setContentSize(NSSize(width: 1100, height: 700))
    center()
    setFrameAutosaveName("CTerminalMain")
    delegate = self

    let channel = FlutterMethodChannel(name: "cterminal/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "startDrag":
        if let event = self.lastMouseDown {
          self.isMovable = true
          self.performDrag(with: event)
          // 系统拖动期间不一定回送 mouseUp，按键松开后再关回去
          Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            if NSEvent.pressedMouseButtons & 1 != 0 { return }
            self?.isMovable = false
            timer.invalidate()
          }
        }
        result(nil)
      case "zoom":
        // 与系统设置“双击标题栏”行为一致
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        if action == "Minimize" { self.miniaturize(nil) } else if action != "None" { self.zoom(nil) }
        result(nil)
      case "toggleFullScreen":
        self.toggleFullScreen(nil)
        result(nil)
      case "isFullScreen":
        result(self.styleMask.contains(.fullScreen))
      case "setOpacity":
        self.alphaValue = CGFloat((call.arguments as? Double) ?? 1.0)
        result(nil)
      case "close":
        self.allowClose = true
        self.performClose(nil)
        result(nil)
      case "setGlobalHotkey":
        GlobalHotkey.shared.register(call.arguments as? [String: Any]) { [weak self] in self?.toggleVisibility() }
        result(nil)
      case "setEnglishInputOnActivate":
        self.englishInputOnActivate = call.arguments as? Bool == true
        if self.englishInputOnActivate {
          if NSApp.isActive { self.selectEnglishInputSource() }
        } else {
          self.restoreInputSource()
        }
        result(nil)
      case "pickFiles":
        // ZMODEM 上传（远端 rz 在等）、选私钥：多选文件，取消返回空列表
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let directory = (call.arguments as? [String: Any])?["directory"] as? String, !directory.isEmpty {
          panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.urls.map { $0.path } : [String]())
        }
      case "newWindow":
        // Flutter 桌面多窗口尚未稳定，新窗口 = 新开一个进程实例
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
    registerForDraggedTypes([.fileURL])
  }

  // 拖文件进窗口：Flutter 视图本身不是拖放目标，由窗口接住后把路径和位置交给 Dart
  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return .copy
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return .copy
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
      return false
    }
    let height = contentView?.bounds.height ?? frame.height
    let location = sender.draggingLocation
    channel?.invokeMethod("dropFiles", arguments: [
      "paths": urls.map { $0.path },
      "x": Double(location.x),
      "y": Double(height - location.y),
      "physical": false,
    ])
    return true
  }

  /// 全局快捷键：前台可见时隐藏，否则激活并显示
  private func toggleVisibility() {
    if NSApp.isActive && isVisible && !isMiniaturized {
      NSApp.hide(nil)
    } else {
      NSApp.activate(ignoringOtherApps: true)
      if isMiniaturized { deminiaturize(nil) }
      makeKeyAndOrderFront(nil)
    }
  }

  /// 关闭前问 Dart 是否有运行中的会话需要确认；Dart 同意后调用 "close"
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if allowClose { return true }
    channel?.invokeMethod("requestClose", arguments: nil)
    return false
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    channel?.invokeMethod("fullScreenChanged", arguments: true)
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    channel?.invokeMethod("fullScreenChanged", arguments: false)
  }

  private func captureInputSource() {
    guard englishInputOnActivate, inputSourceBeforeActivation == nil else { return }
    inputSourceBeforeActivation = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
  }

  private func selectEnglishInputSource() {
    guard englishInputOnActivate, !didSelectEnglishInput else { return }
    captureInputSource()
    guard inputSourceBeforeActivation != nil, let source = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue() else {
      inputSourceBeforeActivation = nil
      return
    }
    let status = TISSelectInputSource(source)
    if status == noErr {
      didSelectEnglishInput = true
    } else {
      inputSourceBeforeActivation = nil
      NSLog("选择英文输入法失败：%d", status)
    }
  }

  private func restoreInputSource() {
    defer {
      inputSourceBeforeActivation = nil
      didSelectEnglishInput = false
    }
    guard didSelectEnglishInput, let source = inputSourceBeforeActivation else { return }
    let status = TISSelectInputSource(source)
    if status != noErr { NSLog("恢复原输入法失败：%d", status) }
  }
}

/// 系统级快捷键。用 Carbon 的 RegisterEventHotKey：不需要“辅助功能”权限，应用在后台时也能触发
final class GlobalHotkey {
  static let shared = GlobalHotkey()
  private var reference: EventHotKeyRef?
  private var handlerInstalled = false
  private var action: (() -> Void)?

  /// arguments: {key, meta, ctrl, alt, shift}（与 Dart 的 Hotkey 一致），nil 表示取消
  func register(_ arguments: [String: Any]?, action: @escaping () -> Void) {
    if let reference = reference {
      UnregisterEventHotKey(reference)
      self.reference = nil
    }
    guard let arguments = arguments, let key = arguments["key"] as? String, let code = GlobalHotkey.keyCodes[key] else { return }
    self.action = action
    installHandler()
    var modifiers: UInt32 = 0
    if arguments["meta"] as? Bool == true { modifiers |= UInt32(cmdKey) }
    if arguments["ctrl"] as? Bool == true { modifiers |= UInt32(controlKey) }
    if arguments["alt"] as? Bool == true { modifiers |= UInt32(optionKey) }
    if arguments["shift"] as? Bool == true { modifiers |= UInt32(shiftKey) }
    let identifier = EventHotKeyID(signature: OSType(0x4354_4D4C), id: 1)  // 'CTML'
    RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
  }

  private func installHandler() {
    if handlerInstalled { return }
    handlerInstalled = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      DispatchQueue.main.async { GlobalHotkey.shared.action?() }
      return noErr
    }, 1, &spec, nil, nil)
  }

  private static let keyCodes: [String: UInt32] = {
    var codes: [String: UInt32] = [
      "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09,
      "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11, "O": 0x1F, "U": 0x20, "I": 0x22,
      "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28, "N": 0x2D, "M": 0x2E,
      "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
      "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,
      "Enter": 0x24, "Tab": 0x30, "Space": 0x31, "Backspace": 0x33, "Escape": 0x35, "Delete": 0x75,
      "Home": 0x73, "End": 0x77, "PageUp": 0x74, "PageDown": 0x79,
      "Left": 0x7B, "Right": 0x7C, "Down": 0x7D, "Up": 0x7E,
    ]
    let functionKeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    for (index, code) in functionKeys.enumerated() { codes["F\(index + 1)"] = code }
    return codes
  }()
}
