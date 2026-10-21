import 'dart:async';
import 'dart:convert';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/terminal/terminal_session.dart';
import 'package:cterminal/theme.dart';
import 'package:cterminal/ui/ai_workspace.dart';
import 'package:cterminal/ui/settings/ai_page.dart';
import 'package:cterminal/window_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends Fake implements RustLibApi {
  bool hasApiKey = true;
  bool failNextChat = false;
  final chats =
      <({String messages, String context, Completer<String> reply})>[];
  final apiKeys = <String>[];
  final savedConfigs = <String>[];

  @override
  String crateApiSettingsColorSchemes() => '[]';

  @override
  bool crateApiAiAiStatus() => hasApiKey;

  @override
  Future<void> crateApiAiAiSetApiKey({required String value}) async {
    apiKeys.add(value);
    hasApiKey = value.isNotEmpty;
  }

  @override
  Future<String> crateApiAiAiChat({
    required String messagesJson,
    required String context,
  }) {
    if (failNextChat) {
      failNextChat = false;
      return Future.error(StateError('temporary failure'));
    }
    final reply = Completer<String>();
    chats.add((messages: messagesJson, context: context, reply: reply));
    return reply.future;
  }

  @override
  Future<String> crateApiSettingsConfigSave({required String json}) async {
    savedConfigs.add(json);
    return json;
  }

  @override
  Future<String> crateApiSettingsProfilesList() async => '[]';

  @override
  void crateApiTerminalTermApplySettings() {}
}

Map<String, dynamic> _config({bool service = true}) => {
  'hotkeys': <String, dynamic>{},
  'application': <String, dynamic>{'englishInputOnActivate': false},
  'appearance': <String, dynamic>{},
  'ai': <String, dynamic>{
    'baseUrl': service ? 'https://api.example.com/v1' : '',
    'model': service ? 'test-model' : '',
    'panelPosition': 'right',
  },
};

TerminalSession _session(String id) => TerminalSession(
  profile: {
    'id': id,
    'name': id,
    'type': 'local',
    'options': <String, dynamic>{},
  },
);

void main() {
  late _FakeApi api;

  setUpAll(() {
    api = _FakeApi();
    RustLib.initMock(api: api);
  });

  setUp(() {
    api.hasApiKey = true;
    api.failNextChat = false;
    api.chats.clear();
    api.apiKeys.clear();
    api.savedConfigs.clear();
  });

  Future<AppState> mountWorkspace(
    WidgetTester tester, {
    bool service = true,
    List<TerminalSession>? sessions,
  }) async {
    final app = AppState(config: _config(service: service));
    for (final session in sessions ?? <TerminalSession>[]) {
      app.tabs.add(TerminalTab(session));
    }
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      WindowControl.channel,
      (_) async => null,
    );
    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: AppTheme(
          colors: AppColors.dark,
          child: MaterialApp(
            theme: materialTheme(AppColors.dark),
            home: Scaffold(
              body: AiWorkspace(child: const ColoredBox(color: Colors.black)),
            ),
          ),
        ),
      ),
    );
    app.toggleAi();
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('未配置服务显示入口且发送不可用', (tester) async {
    final app = await mountWorkspace(tester, service: false);
    expect(find.text('连接你的 AI 服务后即可开始。'), findsOneWidget);
    expect(find.text('配置 AI 服务'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'hello');
    await tester.pump();
    final sendButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    expect(tester.widget<IconButton>(sendButton).onPressed, isNull);
    expect(api.chats, isEmpty);
    app.dispose();
  });

  testWidgets('发送失败可重试，代码块可复制', (tester) async {
    final app = await mountWorkspace(tester);
    api.failNextChat = true;
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'show a command',
    );
    await tester.pump();
    final sendButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);
    await tester.tap(sendButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary failure'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(api.chats, hasLength(1));
    final sent = jsonDecode(api.chats.single.messages) as List;
    expect(sent.single['content'], 'show a command');
    api.chats.single.reply.complete('```sh\necho ready\n```');
    await tester.pumpAndSettle();
    expect(find.text('echo ready'), findsOneWidget);

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(clipboard, 'echo ready');
    app.dispose();
  });

  testWidgets('切换 session 保留草稿，pending 回复归属于原 session', (tester) async {
    final first = _session('first');
    final second = _session('second');
    final app = await mountWorkspace(tester, sessions: [first, second]);

    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'first draft',
    );
    app.selectTab(1);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'second question',
    );
    await tester.pump();
    final sendButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '发送',
    );
    await tester.tap(sendButton);
    await tester.pump();
    expect(api.chats, hasLength(1));

    app.selectTab(0);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'first draft',
    );
    api.chats.single.reply.complete('answer for second');
    await tester.pumpAndSettle();
    expect(find.text('answer for second'), findsNothing);

    app.selectTab(1);
    await tester.pumpAndSettle();
    expect(find.text('answer for second'), findsOneWidget);
    app.dispose();
  });

  testWidgets('隐藏重开和切换面板位置后仍保留草稿', (tester) async {
    final app = await mountWorkspace(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'keep this draft',
    );
    app.toggleAi();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-input')), findsNothing);
    app.toggleAi();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'keep this draft',
    );

    app.config['ai']['panelPosition'] = 'bottom';
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-input')))
          .controller!
          .text,
      'keep this draft',
    );
    expect(find.byType(Column), findsWidgets);
    app.dispose();
  });

  testWidgets('设置页保存 API Key 时密钥不进入配置 JSON', (tester) async {
    final app = AppState(config: _config(service: false));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      WindowControl.channel,
      (_) async => null,
    );
    await tester.pumpWidget(
      AppScope(
        state: app,
        child: AppTheme(
          colors: AppColors.dark,
          child: MaterialApp(
            theme: materialTheme(AppColors.dark),
            home: const Scaffold(body: AiPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    await tester.enterText(
      find.byWidget(fields[0]),
      'https://api.example.com/v1',
    );
    await tester.enterText(find.byWidget(fields[1]), 'test-model');
    await tester.enterText(find.byWidget(fields[2]), 'private-test-key');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final json = jsonEncode(app.config);
    expect(json, isNot(contains('private-test-key')));
    expect(api.apiKeys, ['private-test-key']);
    expect(api.savedConfigs, hasLength(1));
    app.dispose();
  });
}
