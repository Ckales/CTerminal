// 界面截图：用真实系统字体渲染各个界面状态并输出 PNG，供人工核对视觉效果。
// 只在设置了 CTERMINAL_SHOTS（输出目录）时运行：
//   CTERMINAL_SHOTS=/tmp/shots CTERMINAL_CONFIG_DIR=$(mktemp -d) flutter test test/visual_test.dart
@TestOn('mac-os')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cterminal/app_state.dart';
import 'package:cterminal/pane_tree.dart';
import 'package:cterminal/src/rust/api/settings.dart' as rust;
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/ui/app_shell.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

const _dylib = 'rust/target/release/libcterminal_rust.dylib';
final _boundary = GlobalKey();

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    if (File(path).existsSync()) loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['CTERMINAL_SHOTS']!;
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() async {
    final boundary = _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final shots = Platform.environment['CTERMINAL_SHOTS'];
  final ready = shots != null && Platform.environment['CTERMINAL_CONFIG_DIR'] != null && File(_dylib).existsSync();

  setUpAll(() async {
    if (!ready) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(_dylib));
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
    await _loadFont('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    // 测试环境默认字体是方块字；界面字体、终端字体都换成系统字体
    await _loadFont('Roboto', ['/System/Library/Fonts/PingFang.ttc', '/System/Library/Fonts/Supplemental/Arial Unicode.ttf']);
    await _loadFont('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
    await _loadFont('PingFang SC', ['/System/Library/Fonts/PingFang.ttc']);
    // 连字截图用：本机没装连字字体时借用 JetBrains IDE 自带的，找不到就跳过那两张
    const jbr = '/Applications/GoLand.app/Contents/jbr/Contents/Home/lib/fonts';
    await _loadFont('JetBrains Mono', ['$jbr/JetBrainsMono-Regular.ttf', '$jbr/JetBrainsMono-Bold.ttf']);
  });

  testWidgets('截图', (tester) async {
    final config = jsonDecode(rust.configDefaults()) as Map<String, dynamic>;
    config['application']['enableWelcomeTab'] = false;
    config['application']['restoreTabs'] = false;
    config['application']['defaultProfile'] = 'shot:sh';
    config['groups'] = [
      {'id': 'g1', 'name': '生产环境', 'collapsed': false},
    ];
    config['profiles'] = [
      {
        'id': 'shot:sh',
        'name': 'sh',
        'type': 'local',
        'options': {
          'command': '/bin/sh',
          'args': ['-c', r'printf "\033[32m~/project\033[0m $ ls\n\033[34msrc\033[0m  README.md  \033[31merror.log\033[0m\n中文宽字符 ┌──┐\n"; exec /bin/sh'],
          'env': [
            ['PS1', r'$ '],
          ],
        },
      },
      {
        'id': 'shot:web',
        'name': 'web-01',
        'type': 'ssh',
        'group': 'g1',
        'color': '#5da9f6',
        'options': {'host': '192.0.2.10', 'port': 22, 'user': 'deploy', 'auth': 'auto'},
      },
      {
        'id': 'shot:db',
        'name': 'db-master',
        'type': 'ssh',
        'group': 'g1',
        'options': {'host': 'db.example.com', 'port': 2222, 'user': 'admin', 'jumpHost': 'shot:web'},
      },
    ];
    final saved = await tester.runAsync(() => rust.configSave(json: jsonEncode(config)));
    final app = AppState(config: jsonDecode(saved!) as Map<String, dynamic>);
    await tester.runAsync(app.reloadProfiles);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(WindowControl.channel, (call) async => null);
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    await tester.pumpWidget(RepaintBoundary(key: _boundary, child: CTerminalApp(state: app)));
    await _settle(tester);
    await _shot(tester, '01-terminal');

    app.split(SplitSide.right);
    await _settle(tester);
    await _shot(tester, '02-split');

    for (final page in ['application', 'appearance', 'colorScheme', 'terminal', 'profiles', 'hotkeys', 'ssh', 'vault', 'about']) {
      app.openSettings(page);
      await _settle(tester);
      await _shot(tester, '10-settings-$page');
    }

    app.openSettings('profiles:shot:db');
    await _settle(tester);
    await _shot(tester, '11-profile-editor-ssh');

    app.selectTab(0);
    await _settle(tester);
    app.showProfileSelector!();
    await _settle(tester);
    await _shot(tester, '20-profile-selector');
    await tester.enterText(find.byType(TextField).last, 'root@192.0.2.8:2200');
    await _settle(tester);
    await _shot(tester, '21-quick-connect');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    app.showCommandPalette!();
    await _settle(tester);
    await _shot(tester, '22-command-palette');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);

    app.runAction('search');
    await _settle(tester);
    await _shot(tester, '23-search');

    if (File('/Applications/GoLand.app/Contents/jbr/Contents/Home/lib/fonts/JetBrainsMono-Regular.ttf').existsSync()) {
      await tester.runAsync(() => app.updateConfig((config) {
            config['terminal']['font'] = 'JetBrains Mono';
            config['terminal']['ligatures'] = true;
          }));
      await tester.runAsync(() => app.newTab(profile: {
            'id': 'shot:liga',
            'name': 'ligatures',
            'type': 'local',
            'options': {
              'command': '/bin/sh',
              'args': ['-c', r'printf "a -> b  != c  >= d  => e  === f  <= g  |> h  :: i  www\n\033[32mif (x != y && y >= 0) { return a => b; }\033[0m\n"; exec /bin/sh'],
              'env': [
                ['PS1', r'$ '],
              ],
            },
          }));
      // 顺便看固定标签页：第一个标签页固定后只显示序号和图标
      app.togglePin(app.tabs.first);
      await _settle(tester);
      // 光标停在 -> 的 > 上：光标格单独成段，不和 - 连成一个字形
      tester.testTextInput.enterText('x->y != z');
      await _settle(tester);
      for (var i = 0; i < 7; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      }
      await _settle(tester);
      await _shot(tester, '24-ligatures-on');
      await tester.runAsync(() => app.updateConfig((config) => config['terminal']['ligatures'] = false));
      await _settle(tester);
      await _shot(tester, '25-ligatures-off');
    }

    await tester.runAsync(() => app.updateConfig((config) => config['appearance']['theme'] = 'light'));
    app.openSettings('appearance');
    await _settle(tester);
    await _shot(tester, '30-light-settings');

    await tester.pumpWidget(const SizedBox());
    app.dispose();
  }, skip: !ready);
}
