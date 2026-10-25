import 'dart:async';
import 'dart:convert';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/ai.dart' as ai;
import 'package:cterminal/src/rust/api/terminal.dart' as terminal;
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
  String history = '[]';
  bool failHistoryLoad = false;

  @override
  String crateApiAiAiHistoryLoad() {
    if (failHistoryLoad) throw StateError('invalid history');
    return history;
  }

  @override
  void crateApiAiAiHistorySave({required String json}) {
    history = json;
  }

  @override
  String crateApiAiAiHistoryResume({required String messagesJson}) =>
      messagesJson;

  bool hasApiKey = true;
  int nextRequestId = 100;
  final agentChats =
      <
        ({
          int requestId,
          String presetId,
          String messages,
          String context,
          int terminalId,
          StreamController<ai.AiChatEvent> events,
        })
      >[];
  final toolExecutions = <({int terminalId, String callId, String command})>[];
  final openedTerminalIds = <int>[];
  final closedTerminalIds = <int>[];
  final _terminalEvents = <int, StreamController<terminal.TermEvent>>{};
  Completer<String>? nextToolExecution;
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
  String crateApiTerminalTermCwd({required int id}) => '/tmp';

  @override
  Future<void> crateApiSettingsStateSave({required String json}) async {}

  @override
  bool crateApiAiAiStatus() => hasApiKey;

  @override
  bool crateApiAiAiToolCanAutoExecute({required String command}) =>
      command == 'pwd';

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
  Stream<ai.AiChatEvent> crateApiAiAiAgentStream({
    required int requestId,
    required String presetId,
    required String messagesJson,
    required String context,
    required int terminalId,
  }) {
    final events = StreamController<ai.AiChatEvent>();
    agentChats.add((
      requestId: requestId,
      presetId: presetId,
      messages: messagesJson,
      context: context,
      terminalId: terminalId,
      events: events,
    ));
    return events.stream;
  }

  @override
  Future<String> crateApiAiAiToolExecute({
    required int terminalId,
    required String callId,
    required String command,
  }) {
    toolExecutions.add((
      terminalId: terminalId,
      callId: callId,
      command: command,
    ));
    return nextToolExecution?.future ??
        Future.value(
          jsonEncode({
            'output': '/tmp/example',
            'exitCode': 0,
            'status': 'completed',
          }),
        );
  }

  @override
  void crateApiAiAiToolCancel({
    required int terminalId,
    required String callId,
  }) {}

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

  @override
  Stream<terminal.TermEvent> crateApiTerminalTermOpen({
    required int id,
    required String profileJson,
    required terminal.TermSize size,
  }) {
    openedTerminalIds.add(id);
    final events = StreamController<terminal.TermEvent>();
    _terminalEvents[id] = events;
    return events.stream;
  }

  @override
  void crateApiTerminalTermClose({required int id}) {
    closedTerminalIds.add(id);
    _terminalEvents.remove(id)?.close();
  }
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

void _emitToolCall(
  StreamController<ai.AiChatEvent> events, {
  String command = 'pwd',
  bool done = true,
}) {
  events.add(
    ai.AiChatEvent(
      kind: 'tool_calls',
      text: jsonEncode({
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {
              'name': 'execute_terminal_command',
              'arguments': jsonEncode({
                'command': command,
                'description': '查看当前目录',
              }),
            },
          },
        ],
      }),
    ),
  );
  if (done) events.add(const ai.AiChatEvent(kind: 'done', text: ''));
}

void main() {
  late _FakeApi api;

  setUpAll(() {
    api = _FakeApi();
    RustLib.initMock(api: api);
  });

  setUp(() {
    api.history = '[]';
    api.failHistoryLoad = false;
    api.hasApiKey = true;
    api.chats.clear();
    api.agentChats.clear();
    api.toolExecutions.clear();
    api.openedTerminalIds.clear();
    api.closedTerminalIds.clear();
    api.nextToolExecution = null;
    api.cancelledIds.clear();
    api.nextRequestId = 100;
    api.apiKeys.clear();
    api.savedConfigs.clear();
  });

  Future<AppState> mountWorkspace(
    WidgetTester tester, {
    bool service = true,
    List<TerminalSession>? sessions,
    bool startSessions = false,
  }) async {
    final app = AppState(config: _config(service: service));
    for (final session in sessions ?? <TerminalSession>[]) {
      app.tabs.add(TerminalTab(session));
      if (startSessions) {
        session.start(
          const terminal.TermSize(
            cols: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
          ),
        );
      }
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

  testWidgets('消息和草稿保存到本地，重建后可从历史恢复并独立续聊', (tester) async {
    final app = await mountWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'saved question');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    api.chats.single.events.add(const ai.AiChatEvent(kind: 'delta', text: 'saved answer'));
    api.chats.single.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'next draft');
    await app.saveState();
    final stored = jsonDecode(api.history) as List;
    expect(stored.single['messages'], [
      {'role': 'user', 'content': 'saved question'},
      {'role': 'assistant', 'content': 'saved answer'},
    ]);
    expect(stored.single['draft'], 'next draft');
    expect(stored.single.containsKey('terminalId'), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    final reopened = await mountWorkspace(tester, sessions: [_session('different')], startSessions: true);
    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('saved question'));
    await tester.pumpAndSettle();
    expect(find.text('saved answer'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-input'))).controller!.text, 'next draft');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(api.agentChats, isEmpty);
    expect(api.chats, hasLength(2));
    expect(jsonDecode(api.chats.last.messages), contains(equals({'role': 'assistant', 'content': 'saved answer'})));
    reopened.dispose();
  });

  testWidgets('新对话归档旧草稿，历史支持打开和删除', (tester) async {
    final app = await mountWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'archived draft');
    await tester.tap(find.byTooltip('新对话'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-input'))).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('archived draft'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-input'))).controller!.text, 'archived draft');
    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    expect(jsonDecode(api.history), hasLength(1), reason: api.history);
    await tester.tap(find.byTooltip('删除会话'));
    await tester.pumpAndSettle();
    expect(find.text('暂无历史会话'), findsOneWidget);
    expect(jsonDecode(api.history), isEmpty);
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    app.dispose();
  });

  testWidgets('关闭终端后历史仍保留未完成回复', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(tester, sessions: [session], startSessions: true);
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'partial question');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    api.agentChats.single.events.add(const ai.AiChatEvent(kind: 'delta', text: 'partial answer'));
    await tester.pump(const Duration(milliseconds: 40));
    app.closeTab(app.tabs.first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('partial question'));
    await tester.pumpAndSettle();
    expect(find.text('partial answer'), findsOneWidget);
    expect(api.cancelledIds, isNotEmpty);
    expect(api.toolExecutions, isEmpty);
    app.dispose();
  });

  testWidgets('终端关闭后迟到的执行结果仍写入历史', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(tester, sessions: [session], startSessions: true);
    api.nextToolExecution = Completer<String>();
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'inspect');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.ensureVisible(find.text('确认执行'));
    await tester.tap(find.text('确认执行'));
    await tester.pump();
    app.closeTab(app.tabs.first);
    await tester.pump();
    api.nextToolExecution!.complete(jsonEncode({'status': 'completed', 'output': 'late output', 'exitCode': 0}));
    await tester.pumpAndSettle();
    final messages = (jsonDecode(api.history) as List).single['messages'] as List;
    expect(messages.last['role'], 'tool');
    expect(jsonDecode(messages.last['content'] as String)['output'], 'late output');
    expect(api.agentChats, hasLength(1));
    app.dispose();
  });

  testWidgets('历史读取失败显示错误并保留原文件', (tester) async {
    api.history = '{';
    api.failHistoryLoad = true;
    final app = await mountWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-input')), 'do not overwrite');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('读取历史会话失败'), findsOneWidget);
    await app.saveState();
    expect(api.history, '{');
    app.dispose();
  });

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

  testWidgets('Enter 发送，Shift+Enter 换行，输入法组合时不发送', (tester) async {
    final app = await mountWorkspace(tester);
    final inputFinder = find.byKey(const ValueKey('ai-input'));
    await tester.enterText(inputFinder, 'send this');
    await tester.pump();
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(api.chats, hasLength(1));
    expect(
      (jsonDecode(api.chats.single.messages) as List).last['content'],
      'send this',
    );
    expect(tester.widget<TextField>(inputFinder).controller!.text, '');

    api.chats.single.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(inputFinder, 'line one');
    await tester.pump();
    await tester.tap(inputFinder);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(api.chats, hasLength(1));
    expect(
      tester.widget<TextField>(inputFinder).controller!.text,
      'line one\n',
    );

    final controller = tester.widget<TextField>(inputFinder).controller!;
    controller.value = const TextEditingValue(
      text: 'composing',
      composing: TextRange(start: 0, end: 9),
    );
    await tester.pump();
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(api.chats, hasLength(1));
    expect(controller.text, 'composing');
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

    await tester.pump();
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

  testWidgets('工具调用需要确认；批准后结果会继续发送给 AI', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'show current directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(api.agentChats, hasLength(1));
    expect(api.agentChats.single.terminalId, session.id);

    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('确认执行'), findsOneWidget);
    expect(find.text('拒绝执行'), findsOneWidget);
    expect(api.toolExecutions, isEmpty);
    final clearButton = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip('清空对话'),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(clearButton.onPressed, isNull);
    await tester.tap(find.byTooltip('清空对话'));
    await tester.pump();
    expect(find.text('确认执行'), findsOneWidget);
    expect(api.toolExecutions, isEmpty);

    final toolExecution = Completer<String>();
    api.nextToolExecution = toolExecution;
    await tester.tap(find.text('确认执行'));
    await tester.pump();
    expect(api.toolExecutions, [
      (terminalId: session.id, callId: 'call_1', command: 'pwd'),
    ]);
    expect(find.text('正在执行命令…'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find
                .ancestor(
                  of: find.byTooltip('清空对话'),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('清空对话'));
    await tester.pump();
    expect(find.textContaining('pwd'), findsOneWidget);
    expect(api.toolExecutions, hasLength(1));

    toolExecution.complete(
      jsonEncode({
        'output': '/tmp/example',
        'exitCode': 0,
        'status': 'completed',
      }),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.agentChats, hasLength(2));
    final continuedMessages =
        jsonDecode(api.agentChats.last.messages) as List<dynamic>;
    expect(
      continuedMessages.any(
        (message) =>
            message['role'] == 'assistant' && message['tool_calls'] is List,
      ),
      isTrue,
    );
    final toolResult = continuedMessages.singleWhere(
      (message) => message['role'] == 'tool',
    );
    expect(toolResult['tool_call_id'], 'call_1');
    expect(jsonDecode(toolResult['content'] as String), {
      'output': '/tmp/example',
      'exitCode': 0,
      'status': 'completed',
    });
    app.dispose();
  });

  testWidgets('确认卡内显示完整原始命令，批准后执行内容与预览一致', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    final command = List.generate(
      30,
      (index) => "printf '%s\\n' 'line $index'",
    ).join('\n');
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'inspect command',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events, command: command);
    await tester.pump(const Duration(milliseconds: 50));
    final card = find.byKey(const ValueKey('ai-tool-approval'));
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('查看当前目录')),
      findsOneWidget,
    );
    final preview = find.descendant(
      of: card,
      matching: find.byType(SelectableText),
    );
    expect(tester.widget<SelectableText>(preview).data, command);
    expect(tester.widget<SelectableText>(preview).maxLines, isNull);
    expect(api.toolExecutions, isEmpty);
    await tester.ensureVisible(find.text('确认执行'));
    await tester.pump();
    await tester.tap(find.text('确认执行'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions.single.command, command);
    app.dispose();
  });

  testWidgets('auto 自动执行低风险命令并继续对话，危险命令仍确认', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.tap(find.byKey(const ValueKey('ai-mode-auto')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'inspect directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions.single.command, 'pwd');
    expect(api.agentChats, hasLength(2));
    expect(find.text('确认执行'), findsNothing);
    _emitToolCall(api.agentChats.last.events, command: 'rm -rf example');
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions, hasLength(1));
    expect(find.text('确认执行'), findsOneWidget);
    await tester.ensureVisible(find.text('拒绝执行'));
    await tester.pump();
    await tester.tap(find.text('拒绝执行'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions, hasLength(1));
    app.dispose();
  });

  testWidgets('auto 收到工具调用后停止生成不会执行，迟到 done 也忽略', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.tap(find.byKey(const ValueKey('ai-mode-auto')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'inspect directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    final request = api.agentChats.single;
    _emitToolCall(request.events, done: false);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();
    request.events.add(const ai.AiChatEvent(kind: 'done', text: ''));
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions, isEmpty);
    expect(api.agentChats, hasLength(1));
    app.dispose();
  });

  testWidgets('auto 保留于原会话，切换标签和重开面板不改变模式', (tester) async {
    final first = _session('first');
    final second = _session('second');
    final app = await mountWorkspace(tester, sessions: [first, second]);
    bool autoSelected() =>
        tester
            .widget<Semantics>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('ai-mode-auto')),
                    matching: find.byType(Semantics),
                  )
                  .last,
            )
            .properties
            .selected ==
        true;
    await tester.tap(find.byKey(const ValueKey('ai-mode-auto')));
    await tester.pump();
    expect(autoSelected(), isTrue);
    app.selectTab(1);
    await tester.pumpAndSettle();
    expect(autoSelected(), isFalse);
    app.selectTab(0);
    await tester.pumpAndSettle();
    expect(autoSelected(), isTrue);
    app.toggleAi();
    await tester.pumpAndSettle();
    app.toggleAi();
    await tester.pumpAndSettle();
    expect(autoSelected(), isTrue);
    app.dispose();
  });

  testWidgets('auto 切回 ask 后低风险命令也等待确认', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.tap(find.byKey(const ValueKey('ai-mode-auto')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-mode-ask')));
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'inspect directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions, isEmpty);
    expect(find.text('确认执行'), findsOneWidget);
    app.dispose();
  });

  testWidgets('拒绝工具调用会回传拒绝结果且绝不执行', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'show current directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('拒绝执行'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.toolExecutions, isEmpty);
    expect(api.agentChats, hasLength(2));
    final continuedMessages =
        jsonDecode(api.agentChats.last.messages) as List<dynamic>;
    final toolResult = continuedMessages.singleWhere(
      (message) => message['role'] == 'tool',
    );
    expect(toolResult['tool_call_id'], 'call_1');
    expect(
      jsonDecode(toolResult['content'] as String),
      containsPair('status', 'denied'),
    );
    app.dispose();
  });

  testWidgets('切换标签后批准仍绑定发起时的终端 ID', (tester) async {
    final first = _session('first');
    final second = _session('second');
    final app = await mountWorkspace(
      tester,
      sessions: [first, second],
      startSessions: true,
    );
    final originalId = first.id;
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'show current directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));

    app.selectTab(1);
    await tester.pumpAndSettle();
    expect(find.text('确认执行'), findsNothing);
    app.selectTab(0);
    await tester.pumpAndSettle();
    expect(find.text('确认执行'), findsOneWidget);
    await tester.tap(find.text('确认执行'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.toolExecutions, [
      (terminalId: originalId, callId: 'call_1', command: 'pwd'),
    ]);
    expect(api.agentChats.last.terminalId, originalId);
    app.dispose();
  });

  testWidgets('重启终端后旧工具确认消失且不能执行旧命令', (tester) async {
    final session = _session('first');
    final app = await mountWorkspace(
      tester,
      sessions: [session],
      startSessions: true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-input')),
      'show current directory',
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    _emitToolCall(api.agentChats.single.events);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('确认执行'), findsOneWidget);
    final originalId = session.id;

    session.restart();
    expect(session.id, isNot(originalId));
    // Tap before the next frame rebuilds the panel to exercise the stale-card guard.
    await tester.tap(find.text('确认执行'));
    await tester.pump();

    expect(find.text('确认执行'), findsNothing);
    expect(find.text('终端已重启，请发送新消息开始对话'), findsOneWidget);
    expect(api.toolExecutions, isEmpty);
    expect(api.agentChats, hasLength(1));
    expect(api.openedTerminalIds, contains(session.id));
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
