import 'dart:async';
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../src/rust/api/terminal.dart';

/// 一个终端窗格背后的会话。帧在 vsync 时才拉取：Rust 端的 wakeup 在拉取前只发一次，
/// 所以 `cat` 大文件时最多每帧拉一次，不会被通知淹没。
class TerminalSession extends ChangeNotifier {
  TerminalSession({required Map<String, dynamic> profile, this.cwd = ''}) : profile = Map.of(profile);

  static int _nextId = 1;

  /// 当前 profile（本地 shell 继承目录时 options.cwd 会被改写，所以存一份副本）
  final Map<String, dynamic> profile;
  final String cwd;

  int _id = 0;
  int get id => _id;
  StreamSubscription<TermEvent>? _events;
  bool _framePending = false;

  TermFrame? frame;
  /// 最近一次的终端尺寸，重启 / 重连时沿用
  TermSize? lastSize;
  /// 每次响铃 +1，视图据此做视觉响铃
  final ValueNotifier<int> bells = ValueNotifier(0);
  String programTitle = '';
  /// SSH 窗格是否展开 SFTP 面板（界面状态）
  bool sftpVisible = false;
  bool exited = false;
  String exitReason = '';
  bool get started => _id != 0;

  /// 由上层（标签页）设置
  void Function(TerminalSession session)? onExit;
  void Function(TerminalSession session)? onBell;
  void Function(TerminalSession session)? onTitle;
  /// 窗格外观（标题、结束状态）变化，给标签栏用
  final ValueNotifier<int> meta = ValueNotifier(0);

  String get profileName => profile['name'] as String? ?? '';
  String get profileType => profile['type'] as String? ?? 'local';
  String get profileId => profile['id'] as String? ?? '';

  String get title {
    final disableDynamic = profile['disableDynamicTitle'] == true;
    if (!disableDynamic && programTitle.isNotEmpty) return programTitle;
    return profileName;
  }

  void start(TermSize size) {
    if (started) return;
    lastSize = size;
    _id = _nextId++;
    exited = false;
    exitReason = '';
    final opened = Map<String, dynamic>.of(profile);
    if (cwd.isNotEmpty && opened['type'] == 'local') {
      final options = Map<String, dynamic>.of(opened['options'] as Map<String, dynamic>);
      options['cwd'] = cwd;
      opened['options'] = options;
    }
    _events = termOpen(id: _id, profileJson: jsonEncode(opened), size: size).listen(_onEvent, onError: (Object error) {
      _markExited('$error');
    });
  }

  void _onEvent(TermEvent event) {
    switch (event.kind) {
      case 'wakeup':
        _scheduleFrame();
      case 'title':
        programTitle = event.text;
        meta.value++;
        onTitle?.call(this);
      case 'bell':
        bells.value++;
        onBell?.call(this);
      case 'copy':
        Clipboard.setData(ClipboardData(text: event.text));
      case 'exit':
        _scheduleFrame();
        _markExited(event.text);
    }
  }

  void _markExited(String reason) {
    exited = true;
    exitReason = reason;
    meta.value++;
    notifyListeners();
    onExit?.call(this);
  }

  void _scheduleFrame() {
    if (_framePending) return;
    _framePending = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _framePending = false;
      refresh();
    });
  }

  /// 立即拉取一帧（滚动、选区等本地操作之后调用）
  void refresh() {
    if (!started) return;
    frame = termFrame(id: _id);
    notifyListeners();
  }

  void resize(TermSize size) {
    lastSize = size;
    if (!started) return;
    termResize(id: _id, size: size);
    refresh();
  }

  /// 重新连接 / 重启：关掉旧会话，用同一 profile 新开
  void restart() {
    final size = lastSize;
    if (size == null) return;
    _shutdown();
    programTitle = '';
    frame = null;
    start(size);
    meta.value++;
  }

  void _shutdown() {
    if (!started) return;
    _events?.cancel();
    _events = null;
    termClose(id: _id);
    _id = 0;
  }

  @override
  void dispose() {
    _shutdown();
    meta.dispose();
    bells.dispose();
    super.dispose();
  }
}
