// Optional AI interface screenshots for local visual review.
// Run with: CTERMINAL_AI_SHOTS=/tmp/cterminal-ai-shots flutter test test/ai_visual_test.dart
@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/ai.dart' as ai;
import 'package:cterminal/src/rust/api/terminal.dart' as terminal;
import 'package:cterminal/terminal/terminal_session.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/theme.dart';
import 'package:cterminal/ui/ai_workspace.dart';
import 'package:cterminal/ui/settings/ai_page.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _flutterRoot = '/opt/homebrew/share/flutter';
final _boundary = GlobalKey();

class _FakeApi extends Fake implements RustLibApi {
  @override
  String crateApiSettingsColorSchemes() => '[]';

  @override
  bool crateApiAiAiStatus() => false;

  @override
  int crateApiAiAiChatPrepare() => 100;

  @override
  void crateApiAiAiChatCancel({required int requestId}) {}

  @override
  Stream<terminal.TermEvent> crateApiTerminalTermOpen({
    required int id,
    required String profileJson,
    required terminal.TermSize size,
  }) => const Stream.empty();

  @override
  void crateApiTerminalTermClose({required int id}) {}

  @override
  Stream<ai.AiChatEvent> crateApiAiAiAgentStream({
    required int requestId,
    required String presetId,
    required String messagesJson,
    required String context,
    required int terminalId,
  }) async* {
    yield ai.AiChatEvent(
      kind: 'tool_calls',
      text: jsonEncode({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'preview',
            'type': 'function',
            'function': {
              'name': 'execute_terminal_command',
              'arguments': jsonEncode({
                'description': '查看 Nginx 配置文件列表',
                'command': 'ls -lah /etc/nginx/conf.d\nls -lah /etc/nginx/sites-enabled',
              }),
            },
          },
        ],
      }),
    );
    yield const ai.AiChatEvent(kind: 'done', text: '');
  }

  @override
  String crateApiAiAiPresetsDefaults() => jsonEncode([
    {'id': 'general', 'name': '通用', 'prompt': ''},
  ]);
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
    }
  }
  await loader.load();
}

Future<void> _saveShot(WidgetTester tester, String name, String dir) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Map<String, dynamic> _config({
  String position = 'right',
  bool sample = false,
}) => {
  'hotkeys': <String, dynamic>{},
  'application': <String, dynamic>{'englishInputOnActivate': false},
  'appearance': <String, dynamic>{},
  'ai': <String, dynamic>{
    'baseUrl': sample ? 'https://api.example.com/v1' : '',
    'model': sample ? 'demo-model' : '',
    'panelPosition': position,
  },
};

Widget _frame(AppState app, Widget child) => RepaintBoundary(
  key: _boundary,
  child: AppScope(
    state: app,
    child: AppTheme(
      colors: AppColors.dark,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: materialTheme(AppColors.dark),
        home: Scaffold(body: child),
      ),
    ),
  ),
);

Widget _terminalExample() => Container(
  color: const Color(0xff171717),
  padding: const EdgeInsets.fromLTRB(32, 26, 32, 26),
  alignment: Alignment.topLeft,
  child: const Text(
    'demo@workstation:~/project\$ ls\n'
    'README.md  lib/  test/\n'
    'demo@workstation:~/project\$ curl https://example.com\n'
    'Example Domain\n'
    'demo@workstation:~/project\$ ',
    style: TextStyle(
      fontFamily: 'Menlo',
      fontSize: 14,
      height: 1.6,
      color: Color(0xffd0d0d0),
    ),
  ),
);

void main() {
  final outputDir = Platform.environment['CTERMINAL_AI_SHOTS'];
  final enabled = outputDir != null && outputDir.trim().isNotEmpty;

  setUpAll(() async {
    if (!enabled) return;
    RustLib.initMock(api: _FakeApi());
    await _loadFont('MaterialIcons', [
      '$_flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]);
    await _loadFont('Roboto', [
      '/System/Library/Fonts/PingFang.ttc',
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    ]);
    await _loadFont('PingFang SC', ['/System/Library/Fonts/PingFang.ttc']);
    await _loadFont('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
  });

  testWidgets('capture AI dock empty states and responsive settings', (
    tester,
  ) async {
    final dir = outputDir!;
    Directory(dir).createSync(recursive: true);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      WindowControl.channel,
      (_) async => null,
    );
    final app = AppState(config: _config());

    await tester.binding.setSurfaceSize(const Size(1200, 760));
    app.aiVisible = true;
    await tester.pumpWidget(
      _frame(app, AiWorkspace(child: _terminalExample())),
    );
    await tester.pumpAndSettle();
    await _saveShot(tester, '01-ai-empty-right', dir);

    app.config['ai']['panelPosition'] = 'bottom';
    app.notifyListeners();
    await tester.pumpAndSettle();
    await _saveShot(tester, '02-ai-empty-bottom', dir);

    app.config['ai']['baseUrl'] = 'https://api.example.com/v1';
    app.config['ai']['model'] = 'demo-model';
    await tester.pumpWidget(_frame(app, const AiPage()));
    await tester.pumpAndSettle();
    await _saveShot(tester, '03-ai-settings-wide', dir);

    await tester.binding.setSurfaceSize(const Size(760, 760));
    await tester.pump();
    await _saveShot(tester, '04-ai-settings-medium', dir);

    await tester.binding.setSurfaceSize(const Size(560, 760));
    await tester.pump();
    await _saveShot(tester, '05-ai-settings-narrow', dir);

    await tester.pumpWidget(const SizedBox());
    app.dispose();

    await tester.binding.setSurfaceSize(const Size(1200, 760));
    final session = TerminalSession(
      profile: {
        'id': 'preview',
        'name': '本地终端',
        'type': 'local',
        'options': <String, dynamic>{},
      },
    );
    session.start(
      const terminal.TermSize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16),
    );
    final approvalApp = AppState(config: _config(sample: true))
      ..aiVisible = true;
    approvalApp.tabs.add(TerminalTab(session));
    await tester.pumpWidget(
      _frame(approvalApp, AiWorkspace(child: _terminalExample())),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      '列出 Nginx 配置文件',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-tool-approval')), findsOneWidget);
    await _saveShot(tester, '06-ai-command-approval', dir);
    await tester.pumpWidget(const SizedBox());
    approvalApp.dispose();
  }, skip: !enabled);
}
