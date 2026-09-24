#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdlib>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "cterminal/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleWindowCall(call, std::move(result));
  });
  // 子窗口（Flutter 视图）不接收拖放时，系统会交给带 WS_EX_ACCEPTFILES 的父窗口
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

namespace {

constexpr int kToggleHotkeyId = 1;

// 与 Dart 侧 Hotkey 的按键名一致
UINT VirtualKeyFor(const std::string& key) {
  if (key.size() == 1) {
    char c = key[0];
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return static_cast<UINT>(c);
    switch (c) {
      case '=': return VK_OEM_PLUS;
      case '-': return VK_OEM_MINUS;
      case ',': return VK_OEM_COMMA;
      case '.': return VK_OEM_PERIOD;
      case '/': return VK_OEM_2;
      case ';': return VK_OEM_1;
      case '`': return VK_OEM_3;
      case '[': return VK_OEM_4;
      case '\\': return VK_OEM_5;
      case ']': return VK_OEM_6;
      case '\'': return VK_OEM_7;
    }
    return 0;
  }
  if (key.size() >= 2 && key[0] == 'F') {
    int number = std::atoi(key.c_str() + 1);
    if (number >= 1 && number <= 12) return static_cast<UINT>(VK_F1 + number - 1);
  }
  if (key == "Space") return VK_SPACE;
  if (key == "Enter") return VK_RETURN;
  if (key == "Tab") return VK_TAB;
  if (key == "Escape") return VK_ESCAPE;
  if (key == "Backspace") return VK_BACK;
  if (key == "Delete") return VK_DELETE;
  if (key == "Home") return VK_HOME;
  if (key == "End") return VK_END;
  if (key == "PageUp") return VK_PRIOR;
  if (key == "PageDown") return VK_NEXT;
  if (key == "Left") return VK_LEFT;
  if (key == "Right") return VK_RIGHT;
  if (key == "Up") return VK_UP;
  if (key == "Down") return VK_DOWN;
  return 0;
}

bool FlagOf(const flutter::EncodableMap& map, const char* name) {
  auto found = map.find(flutter::EncodableValue(name));
  if (found == map.end()) return false;
  const bool* value = std::get_if<bool>(&found->second);
  return value != nullptr && *value;
}

}  // namespace

void FlutterWindow::HandleWindowCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "setGlobalHotkey") {
    UnregisterHotKey(GetHandle(), kToggleHotkeyId);
    const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
    if (map != nullptr) {
      auto key = map->find(flutter::EncodableValue("key"));
      const std::string* name = key == map->end() ? nullptr : std::get_if<std::string>(&key->second);
      UINT vk = name == nullptr ? 0 : VirtualKeyFor(*name);
      if (vk != 0) {
        UINT modifiers = MOD_NOREPEAT;
        if (FlagOf(*map, "ctrl")) modifiers |= MOD_CONTROL;
        if (FlagOf(*map, "alt")) modifiers |= MOD_ALT;
        if (FlagOf(*map, "shift")) modifiers |= MOD_SHIFT;
        if (FlagOf(*map, "meta")) modifiers |= MOD_WIN;
        RegisterHotKey(GetHandle(), kToggleHotkeyId, modifiers, vk);
      }
    }
    result->Success();
    return;
  }
  if (call.method_name() == "toggleFullScreen") {
    ToggleFullScreen();
    result->Success();
    return;
  }
  result->NotImplemented();
}

// 无边框铺满当前显示器；再次调用恢复原来的样式和位置
void FlutterWindow::ToggleFullScreen() {
  HWND hwnd = GetHandle();
  if (!full_screen_) {
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    saved_style_ = GetWindowLong(hwnd, GWL_STYLE);
    if (!GetWindowPlacement(hwnd, &saved_placement_) ||
        !GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &monitor)) {
      return;
    }
    SetWindowLong(hwnd, GWL_STYLE, saved_style_ & ~static_cast<LONG>(WS_OVERLAPPEDWINDOW));
    const RECT& area = monitor.rcMonitor;
    SetWindowPos(hwnd, HWND_TOP, area.left, area.top, area.right - area.left, area.bottom - area.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    full_screen_ = true;
    return;
  }
  SetWindowLong(hwnd, GWL_STYLE, saved_style_);
  SetWindowPlacement(hwnd, &saved_placement_);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  full_screen_ = false;
}

void FlutterWindow::ToggleVisibility() {
  HWND hwnd = GetHandle();
  if (IsWindowVisible(hwnd) && !IsIconic(hwnd) && GetForegroundWindow() == hwnd) {
    ShowWindow(hwnd, SW_HIDE);
    return;
  }
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::OnDestroy() {
  UnregisterHotKey(GetHandle(), kToggleHotkeyId);
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_HOTKEY:
      if (static_cast<int>(wparam) == kToggleHotkeyId) ToggleVisibility();
      return 0;
    case WM_DROPFILES: {
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      POINT point;
      DragQueryPoint(drop, &point);
      flutter::EncodableList paths;
      UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT index = 0; index < count; index++) {
        UINT length = DragQueryFileW(drop, index, nullptr, 0);
        std::wstring wide(length, L'\0');
        DragQueryFileW(drop, index, wide.data(), length + 1);
        int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
        std::string utf8(size, '\0');
        WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), utf8.data(), size, nullptr, nullptr);
        paths.push_back(flutter::EncodableValue(utf8));
      }
      DragFinish(drop);
      if (window_channel_) {
        // 坐标是客户区物理像素，Dart 侧按设备像素比换算
        flutter::EncodableMap arguments{
            {flutter::EncodableValue("paths"), flutter::EncodableValue(paths)},
            {flutter::EncodableValue("x"), flutter::EncodableValue(static_cast<double>(point.x))},
            {flutter::EncodableValue("y"), flutter::EncodableValue(static_cast<double>(point.y))},
            {flutter::EncodableValue("physical"), flutter::EncodableValue(true)},
        };
        window_channel_->InvokeMethod("dropFiles", std::make_unique<flutter::EncodableValue>(arguments));
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
