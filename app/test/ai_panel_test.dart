import 'dart:async';
import 'dart:convert';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/ai.dart' as ai;
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
  int nextRequestId = 100;
  final chats =
      <
        ({
          int requestId,
          String presetId,
          String messages,
          String context,
          StreamController<ai.AiChatEvent> events,
        })
      >[];
  final cancelledIds = <int>[];
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
  int crateApiAiAiChatPrepare() => nextRequestId++;

  @override
  void crateApiAiAiChatCancel({required int requestId}) {
    cancelledIds.add(requestId);
  }

  @override
  Stream<ai.AiChatEvent> crateApiAiAiChatStream({
    required int requestId,
    required String presetId,
    required String messagesJson,
    required String context,
  }) {
    final events = StreamController<ai.AiChatEvent>();
    chats.add((
      requestId: requestId,
      presetId: presetId,
      messages: messagesJson,
      context: context,
      events: events,
    ));
    return events.stream;
  }

  @override
  String crateApiAiAiPresetsDefaults() => jsonEncode([
    {'id': 'general', 'name': '通用', 'prompt': 'Be helpful.'},
    {'id': 'concise', 'name': '简洁', 'prompt': 'Be concise.'},
  ]);

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
    'activePreset': 'general',
    'systemPrompt': '',
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
    api.chats.clear();
    api.cancelledIds.clear();
    api.nextRequestId = 100;
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

  testWidgets('流式增量立即显示；中断后重试不重复追加用户消息', (tester) async {
    final app = await mountWorkspace(tester);
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
    await tester.pump();
    expect(api.chats, hasLength(1));
    api.chats.single.events.add(
      const ai.AiChatEvent(kind: 'delta', text: 'partial '),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('partial', findRichText: true), findsOneWidget);

    api.chats.single.events.addError(StateError('temporary failure'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('temporary failure'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(api.chats, hasLength(2));
    final sent = jsonDecode(api.chats.last.messages) as List;
    expect(sent.where((message) => message['role'] == 'user'), hasLength(1));
    expect(sent.last['content'], 'show a command');
    expect(sent.any((message) => message['content'] == 'partial '), isFalse);
    api.chats.last.events.add(
      const ai.AiChatEvent(kind: 'delta', text: '```sh\necho ready\n```'),
    );
    api.chats.last.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pump(const Duration(milliseconds: 50));
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
    api.chats.single.events.add(
      const ai.AiChatEvent(kind: 'delta', text: 'answer for second'),
    );
    api.chats.single.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pumpAndSettle();
    expect(find.text('answer for second'), findsNothing);

    app.selectTab(1);
    await tester.pumpAndSettle();
    expect(find.text('answer for second'), findsOneWidget);
    app.dispose();
  });

  testWidgets('停止保留已生成内容并取消正确请求；迟到事件不进入下一轮', (tester) async {
    final app = await mountWorkspace(tester);
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'first request',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    final first = api.chats.single;
    first.events.add(const ai.AiChatEvent(kind: 'delta', text: 'kept partial'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.textContaining('kept partial', findRichText: true),
      findsOneWidget,
    );

    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('ai-input')),
    );
    expect(input.enabled, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'next request',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();
    expect(api.cancelledIds, [first.requestId]);
    expect(find.text('已停止'), findsOneWidget);
    expect(
      find.textContaining('kept partial', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(api.chats, hasLength(2));
    final second = api.chats.last;
    first.events.add(
      const ai.AiChatEvent(kind: 'delta', text: 'late stale text'),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.textContaining('late stale text', findRichText: true),
      findsNothing,
    );
    expect(second.presetId, 'general');
    second.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pump(const Duration(milliseconds: 50));
    app.dispose();
  });

  testWidgets('会话独立保存预设并将所选预设发送给 bridge', (tester) async {
    final first = _session('first');
    final second = _session('second');
    final app = await mountWorkspace(tester, sessions: [first, second]);

    final presetControl = find.byTooltip('对话预设');
    expect(presetControl, findsOneWidget);
    await tester.tap(presetControl);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('简洁').last);
    await tester.pump();
    final conciseMenuItem = find.ancestor(
      of: find.text('简洁').last,
      matching: find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String>,
      ),
    );
    await tester.tap(conciseMenuItem);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'first session',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(api.chats.single.presetId, 'concise');

    app.selectTab(1);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'second session',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(api.chats.last.presetId, 'general');
    expect(api.chats.last.requestId, isNot(api.chats.first.requestId));

    for (final chat in api.chats) {
      chat.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    }
    await tester.pump(const Duration(milliseconds: 50));
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
    final app = AppState(
      config: {
        ..._config(service: false),
        'ai': <String, dynamic>{
          'baseUrl': '',
          'model': '',
          'panelPosition': 'right',
          'activePreset': 'custom',
          'systemPrompt': '',
          'promptPresets': [
            {'id': 'custom', 'name': '我的预设', 'prompt': 'original'},
          ],
        },
      },
    );
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
    await tester.enterText(
      find.byKey(const ValueKey('ai-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-model')),
      'test-model',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-api-key')),
      'private-test-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-preset-prompt')),
      'persisted preset prompt',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-system-prompt')),
      'persisted system prompt',
    );
    await tester.ensureVisible(find.text('保存'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final json = jsonEncode(app.config);
    expect(json, isNot(contains('private-test-key')));
    expect(api.apiKeys, ['private-test-key']);
    expect(api.savedConfigs, hasLength(1));
    final savedAi = (jsonDecode(api.savedConfigs.single) as Map)['ai'] as Map;
    expect(savedAi['systemPrompt'], 'persisted system prompt');
    expect(savedAi['activePreset'], 'custom');
    expect(savedAi['promptPresets'], [
      {'id': 'custom', 'name': '我的预设', 'prompt': 'persisted preset prompt'},
    ]);
    app.dispose();
  });
}
