import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hotkeys.dart';

/// 窗口操作。macOS 走原生通道（标题栏融合、关闭确认在 MainFlutterWindow.swift）；
/// Windows 用系统标题栏，关闭确认走 AppLifecycleListener.onExitRequested，
/// 全局快捷键与全屏由 windows/runner/flutter_window.cpp 处理。
abstract final class WindowControl {
  static const channel = MethodChannel('cterminal/window');

  static bool get _mac => Platform.isMacOS;

  /// 不需要返回值的窗口操作：原生侧没实现（例如测试环境、其他平台）时只记录，不打断界面
  static void _send(String method, [Object? arguments]) {
    unawaited(channel.invokeMethod<void>(method, arguments).catchError((Object error) {
      debugPrint('窗口操作 $method 失败：$error');
    }));
  }

  static void startDrag() {
    if (_mac) _send('startDrag');
  }

  static void zoom() {
    if (_mac) _send('zoom');
  }

  static void toggleFullScreen() {
    _send('toggleFullScreen');
  }

  /// 全局显示 / 隐藏窗口的快捷键；null 表示取消
  static void setGlobalHotkey(Hotkey? hotkey) {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    _send('setGlobalHotkey', hotkey == null
        ? null
        : {'key': hotkey.key, 'meta': hotkey.meta, 'ctrl': hotkey.ctrl, 'alt': hotkey.alt, 'shift': hotkey.shift});
  }

  /// 调用前调用方已完成确认和状态保存
  static Future<void> close() async {
    if (_mac) {
      await channel.invokeMethod('close');
      return;
    }
    exit(0);
  }

  /// Flutter 桌面多窗口尚未稳定：新窗口 = 新进程
  static void newWindow() {
    if (_mac) {
      _send('newWindow');
      return;
    }
    Process.start(Platform.resolvedExecutable, const [], mode: ProcessStartMode.detached);
  }
}
