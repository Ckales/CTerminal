// 端到端：真实 Rust 内核 + 真实 /bin/sh，界面用 WidgetTester 驱动（无头，不碰鼠标）。
// 需要先编译 rust/target/release/libcterminal_rust.dylib，并设置 CTERMINAL_CONFIG_DIR，
// 用 tool/test.sh 运行。
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/settings.dart' as rust;
import 'package:cterminal/src/rust/api/terminal.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/terminal/terminal_session.dart';
import 'package:cterminal/ui/app_shell.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _dylib = 'rust/target/release/libcterminal_rust.dylib';

final _shProfile = {
  'id': 'test:sh',
  'name': 'sh',
  'type': 'local',
  'behaviorOnSessionEnd': 'keep',
  'options': {
    'command': '/bin/sh',
    'args': <String>[],
    'env': [
      ['PS1', r'$ '],
      ['ENV', ''],
    ],
  },
};

String screen(TerminalSession session) {
  final frame = session.frame;
  if (frame == null) return '';
  return frame.lines.map((line) => line.runs.map((run) => run.text).join().trimRight()).join('\n');
}

/// 真实的异步 I/O 要在 runAsync 里等，再 pump 让界面拉帧
TerminalSession? _watched;

Future<void> waitFor(WidgetTester tester, bool Function() done, {String what = ''}) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (done()) return;
  }
  final watched = _watched;
  fail('等待超时：$what\n当前屏幕：\n${watched == null ? '' : screen(watched)}');
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool meta = false, bool shift = false}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

/// 模拟平台发来的输入法增量（与 macOS 组合输入时的消息一致）
Future<void> sendDeltas(WidgetTester tester, List<Map<String, dynamic>> deltas) async {
  final setClient = tester.testTextInput.log.lastWhere((call) => call.method == 'TextInput.setClient');
  final clientId = (setClient.arguments as List)[0] as int;
  final message = SystemChannels.textInput.codec.encodeMethodCall(
    MethodCall('TextInputClient.updateEditingStateWithDeltas', [clientId, {'deltas': deltas}]),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(SystemChannels.textInput.name, message, (_) {});
  await tester.pump();
}

Map<String, dynamic> delta(String oldText, String text, int start, int end, {int composingBase = -1, int composingExtent = -1}) => {
      'oldText': oldText,
      'deltaText': text,
      'deltaStart': start,
      'deltaEnd': end,
      'selectionBase': start + text.length,
      'selectionExtent': start + text.length,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': composingBase,
      'composingExtent': composingExtent,
    };

void main() {
  final configDir = Platform.environment['CTERMINAL_CONFIG_DIR'];
  final ready = configDir != null && File(_dylib).existsSync();

  setUpAll(() async {
    if (!ready) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(_dylib));
  });

  Future<AppState> boot(WidgetTester tester) async {
    final config = jsonDecode(rust.configDefaults()) as Map<String, dynamic>;
    config['application']['enableWelcomeTab'] = false;
    config['application']['restoreTabs'] = false;
    config['application']['defaultProfile'] = 'test:sh';
    config['profiles'] = [_shProfile];
    final saved = await tester.runAsync(() => rust.configSave(json: jsonEncode(config)));
    final app = AppState(config: jsonDecode(saved!) as Map<String, dynamic>);
    await tester.runAsync(app.reloadProfiles);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(WindowControl.channel, (call) async => null);
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    await tester.pumpWidget(CTerminalApp(state: app));
    await waitFor(tester, () => app.activeSession != null, what: '首个标签页');
    _watched = app.activeSession;
    await waitFor(tester, () => app.activeSession?.frame != null && screen(app.activeSession!).contains(r'$'), what: 'shell 提示符');
    return app;
  }

  group('真实内核', () {
    testWidgets('输入命令、看到输出、Ctrl-C 与退格', (tester) async {
      final app = await boot(tester);
      final session = app.activeSession!;

      tester.testTextInput.enterText('echo hel');
      await tester.pump();
      await press(tester, LogicalKeyboardKey.backspace);
      tester.testTextInput.enterText('llo 世界');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => screen(session).split('\n').contains('hello 世界'), what: 'echo 输出');

      tester.testTextInput.enterText('sleep 30');
      await press(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      tester.testTextInput.enterText('echo after-interrupt');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => screen(session).contains('\nafter-interrupt'), what: 'Ctrl-C 后继续执行');

      await tester.runAsync(app.saveState);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('输入法组合：组合中不发送，确认后只发送最终文字', (tester) async {
      final app = await boot(tester);
      final session = app.activeSession!;
      tester.testTextInput.enterText('echo ');
      await tester.pump();
      await sendDeltas(tester, [delta('', 'n', 0, 0, composingBase: 0, composingExtent: 1)]);
      await sendDeltas(tester, [delta('n', 'ni', 0, 1, composingBase: 0, composingExtent: 2)]);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(screen(session), isNot(contains('echo n')), reason: '组合中的拼音不能发给终端');
      await sendDeltas(tester, [delta('ni', '你好', 0, 2)]);
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => screen(session).split('\n').contains('你好'), what: '确认后的中文');
      expect(screen(session), isNot(contains('ni')));
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('快捷键：新建标签、拆分、切换、关闭、重新打开', (tester) async {
      final app = await boot(tester);
      expect(app.tabs.length, 1);

      await press(tester, LogicalKeyboardKey.keyT, meta: true);
      await waitFor(tester, () => app.tabs.length == 2, what: '⌘T 新建标签页');
      expect(app.activeIndex, 1);

      await press(tester, LogicalKeyboardKey.keyD, meta: true, shift: true);
      final tab = app.activeTab as TerminalTab;
      expect(tab.sessions.length, 2);
      expect(tab.focused, tab.sessions[1]);
      await waitFor(tester, () => tab.sessions.every((session) => session.frame != null), what: '拆分出的窗格启动');

      await press(tester, LogicalKeyboardKey.digit1, meta: true);
      expect(app.activeIndex, 0);

      await press(tester, LogicalKeyboardKey.keyW, meta: true);
      expect(app.tabs.length, 1);
      await press(tester, LogicalKeyboardKey.keyT, meta: true, shift: true);
      expect(app.tabs.length, 2);

      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('拖放文件：路径转义后粘贴到落点窗格', (tester) async {
      final app = await boot(tester);
      final session = app.activeSession!;
      app.dropFiles(['/tmp/with space/it\'s.txt'], const Offset(300, 300));
      await waitFor(tester, () => screen(session).contains(r"'/tmp/with space/it'\''s.txt'"), what: '粘贴路径');
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('exit 后标签页保留并可重启', (tester) async {
      final app = await boot(tester);
      final session = app.activeSession!;
      tester.testTextInput.enterText('exit 3');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => session.exited, what: '会话结束');
      expect(session.exitReason, contains('3'));
      expect(app.tabs.length, 1, reason: '非正常退出时按 behaviorOnSessionEnd=keep 保留');

      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => !session.exited && screen(session).contains(r'$'), what: '重启');
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('固定标签页、上一次标签页、按序号聚焦窗格、配置快捷键', (tester) async {
      final app = await boot(tester);
      final first = app.tabs.single;
      app.runAction('new-tab');
      await waitFor(tester, () => app.tabs.length == 2, what: '新建标签页');
      final second = app.tabs[1];

      expect(app.runAction('toggle-last-tab'), isTrue);
      expect(app.activeTab, first);
      app.runAction('toggle-last-tab');
      expect(app.activeTab, second);

      // 固定：排到最左，“关闭其他”关不掉它，单独关闭要确认
      app.runAction('pin-tab');
      expect(app.tabs, [second, first]);
      expect(second.pinned, isTrue);
      app.closeOtherTabs(first);
      expect(app.tabs, [second, first]);
      app.confirmClosePinned = (_) async => false;
      app.selectTab(0);
      app.runAction('close-tab');
      await tester.pump();
      expect(app.tabs.length, 2, reason: '取消确认时固定的标签页不关闭');
      // 新标签页不会插进固定区
      app.runAction('new-tab');
      await waitFor(tester, () => app.tabs.length == 3, what: '固定标签页后新建');
      expect(app.tabs.first, second);
      await tester.runAsync(app.saveState);
      final state = jsonDecode((await tester.runAsync(rust.stateLoad))!) as Map<String, dynamic>;
      expect([for (final tab in state['tabs'] as List) (tab as Map)['pinned']], [true, false, false]);

      // 按序号聚焦窗格
      app.selectTab(1);
      final tab = app.activeTab as TerminalTab;
      app.runAction('split-right');
      expect(tab.focused, tab.sessions[1]);
      expect(app.runAction('pane-nav-1'), isTrue);
      expect(tab.focused, tab.sessions[0]);
      expect(app.runAction('pane-nav-5'), isFalse);
      expect(app.runAction('restart-ssh-session'), isFalse, reason: '本地会话不响应重启 SSH');

      // 配置快捷键：profile:<id>
      await tester.runAsync(() => app.updateConfig((config) => config['hotkeys']['profile:test:sh'] = ['⌘-Shift-9']));
      final before = app.tabs.length;
      await press(tester, LogicalKeyboardKey.digit9, meta: true, shift: true);
      await waitFor(tester, () => app.tabs.length == before + 1, what: '配置快捷键打开标签页');
      expect(app.activeSession!.profileId, 'test:sh');

      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });

    testWidgets('智能 Ctrl-C、复制当前路径、同时输入到所有标签页', (tester) async {
      final app = await boot(tester);
      final session = app.activeSession!;
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      });

      tester.testTextInput.enterText('echo marker-one');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => screen(session).split('\n').contains('marker-one'), what: 'echo 输出');
      app.runAction('select-all');
      expect(app.runAction('ctrl-c'), isTrue);
      expect(clipboard, contains('marker-one'), reason: '有选区时复制');
      expect(termSelectionText(id: session.id), isNull, reason: '复制后清除选区');

      tester.testTextInput.enterText('sleep 30');
      await press(tester, LogicalKeyboardKey.enter);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      app.runAction('ctrl-c');
      tester.testTextInput.enterText('echo after-smart-ctrl-c');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(tester, () => screen(session).contains('\nafter-smart-ctrl-c'), what: '无选区时发送 ^C');

      clipboard = null;
      expect(app.runAction('copy-current-path'), isTrue);
      expect(clipboard, isNotNull);
      expect(Directory(clipboard!).existsSync(), isTrue);

      app.runAction('new-tab');
      await waitFor(tester, () => app.tabs.length == 2 && screen(app.activeSession!).contains(r'$'), what: '第二个标签页');
      final other = app.activeSession!;
      app.runAction('focus-all-tabs');
      tester.testTextInput.enterText('echo both-tabs');
      await press(tester, LogicalKeyboardKey.enter);
      await waitFor(
        tester,
        () => screen(session).split('\n').contains('both-tabs') && screen(other).split('\n').contains('both-tabs'),
        what: '两个标签页都收到输入',
      );
      app.runAction('focus-all-tabs');
      expect(app.inputTargets(), [other]);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
  }, skip: ready ? false : '需要编译 Rust 动态库并设置 CTERMINAL_CONFIG_DIR，请用 tool/test.sh 运行');
}
