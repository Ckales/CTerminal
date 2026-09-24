// ZMODEM 上传的界面管道：远端 rz 的起始头 → 事件 → 原生文件面板 → 结果交回 Rust。
// 本机没有 lrzsz，用 printf 打出 rz 的 ZRINIT 头；文件面板返回空列表（用户取消），
// 验证面板被调用、终端显示已取消、之后恢复正常输入。协议收发本身由 Rust 测试覆盖。
// 需要先编译 rust/target/release/libcterminal_rust.dylib，并设置 CTERMINAL_CONFIG_DIR，用 tool/test.sh 运行。
@TestOn('mac-os')
library;

import 'dart:io';

import 'package:cterminal/src/rust/api/terminal.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/terminal/terminal_session.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _dylib = 'rust/target/release/libcterminal_rust.dylib';

String screen(TerminalSession session) {
  final frame = session.frame;
  if (frame == null) return '';
  return frame.lines.map((line) => line.runs.map((run) => run.text).join().trimRight()).join('\n');
}

void main() {
  final ready = Platform.environment['CTERMINAL_CONFIG_DIR'] != null && File(_dylib).existsSync();

  setUpAll(() async {
    if (!ready) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(_dylib));
  });

  testWidgets('rz 起始头弹出文件面板，取消后终端恢复', (tester) async {
    var pickCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(WindowControl.channel, (call) async {
      if (call.method == 'pickFiles') {
        pickCalls++;
        return <String>[];
      }
      return null;
    });
    final session = TerminalSession(profile: {
      'id': 'test:sh',
      'name': 'sh',
      'type': 'local',
      'options': {
        'command': '/bin/sh',
        'args': <String>[],
        'env': [
          ['PS1', r'$ '],
          ['ENV', ''],
        ],
      },
    });
    session.start(TermSize(cols: 80, rows: 10, cellWidth: 8, cellHeight: 16));

    Future<void> waitFor(bool Function() done, String what) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        session.refresh();
        if (done()) return;
      }
      fail('等待超时：$what\n当前屏幕：\n${screen(session)}');
    }

    await waitFor(() => screen(session).contains(r'$'), '提示符');
    // lrzsz 的 rz 启动时发的 ZRINIT（\030 = ZDLE，\212\021 = 行尾 + XON）
    termInput(id: session.id, data: "printf '**\\030B0100000023be50\\r\\212\\021'\r".codeUnits);
    await waitFor(() => screen(session).contains('ZMODEM 已取消'), '取消提示');
    expect(pickCalls, 1);

    termInput(id: session.id, data: 'echo after-$pickCalls\r'.codeUnits);
    await waitFor(() => screen(session).contains('after-1'), '传输结束后输入恢复');
    session.dispose();
  }, skip: !ready);
}
