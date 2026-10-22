import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_state.dart';
import '../i18n.dart';
import '../src/rust/api/ai.dart' as ai;
import '../src/rust/api/terminal.dart' as terminal;
import '../terminal/terminal_session.dart';
import '../theme.dart';

class _Conversation {
  final messages = <Map<String, dynamic>>[];
  String draft = '';
  String context = '';
  String? error;
  bool pending = false;
  String partial = '';
  String status = '';
  String? presetId;
  int? requestId;
  StreamSubscription<ai.AiChatEvent>? subscription;
  List<Map<String, dynamic>>? requestMessages;
  Map<String, dynamic>? toolCall;
  int? terminalId;
  String terminalTitle = '';
  bool executing = false;
  int toolRounds = 0;
  String? executingCallId;
  String requestContext = '';
  String requestPreset = '';
  bool autoExecute = false;
}

/// The dock owns conversations so changing its position or hiding it keeps drafts.
class AiWorkspace extends StatefulWidget {
  const AiWorkspace({super.key, required this.child});
  final Widget child;

  @override
  State<AiWorkspace> createState() => _AiWorkspaceState();
}

class _AiWorkspaceState extends State<AiWorkspace> {
  final _conversations = <TerminalSession?, _Conversation>{};
  final _contentKey = GlobalKey();
  final _panelKey = GlobalKey();
  final _dockSize = ValueNotifier<Offset>(const Offset(380, 310));
  double _rightWidth = 380;
  double _bottomHeight = 310;

  Timer? _renderTimer;

  void _refresh() {
    _renderTimer ??= Timer(const Duration(milliseconds: 32), () {
      _renderTimer = null;
      if (mounted) setState(() {});
    });
  }

  void _finish(_Conversation chat, int id, String kind, String text) {
    if (!mounted || chat.requestId != id) return;
    final subscription = chat.subscription;
    setState(() {
      chat.pending = false;
      chat.requestId = null;
      chat.subscription = null;
      if (kind == 'done' && chat.toolCall != null) {
        chat.partial = '';
        chat.status = tr('等待确认执行');
      } else if (kind == 'done' && chat.partial.trim().isNotEmpty) {
        chat.messages.add({'role': 'assistant', 'content': chat.partial});
        chat.partial = '';
        chat.status = text;
      } else if (kind == 'cancelled') {
        chat.status = tr('已停止');
      } else {
        chat.error = text.isNotEmpty ? text : tr('AI 没有返回文本，请检查模型或重试。');
      }
    });
    if (subscription != null) unawaited(subscription.cancel());
    if (kind == 'done' && chat.toolCall != null && chat.autoExecute) {
      final call = (chat.toolCall!['tool_calls'] as List).single as Map;
      final args =
          jsonDecode((call['function'] as Map)['arguments'] as String) as Map;
      // The core policy must explicitly allow this exact command. Unknowns stay ask.
      if (ai.aiToolCanAutoExecute(command: args['command'] as String)) {
        unawaited(_resolveTool(chat, true));
      }
    }
  }

  void _stop(_Conversation chat) {
    if (chat.executing &&
        chat.executingCallId != null &&
        chat.terminalId != null) {
      ai.aiToolCancel(
        terminalId: chat.terminalId!,
        callId: chat.executingCallId!,
      );
      setState(() => chat.status = tr('正在停止命令…'));
      return;
    }
    final id = chat.requestId;
    if (id == null) return;
    final subscription = chat.subscription;
    setState(() {
      chat.requestId = null;
      chat.subscription = null;
      chat.pending = false;
      chat.status = tr('已停止');
    });
    ai.aiChatCancel(requestId: id);
    if (subscription != null) unawaited(subscription.cancel());
  }

  void _send(_Conversation chat, {bool retry = false}) {
    if (!_conversations.values.contains(chat)) return;
    if (chat.pending ||
        chat.executing ||
        chat.toolCall != null ||
        (!retry && chat.draft.trim().isEmpty)) {
      return;
    }
    if (retry && chat.requestMessages == null) return;
    final app = AppScope.read(context);
    final defaultPreset =
        (app.config['ai'] as Map?)?['activePreset'] as String? ?? 'general';
    final session = _conversations.entries
        .firstWhere((entry) => identical(entry.value, chat))
        .key;
    final restarted = chat.terminalId != null && chat.terminalId != session?.id;
    if (retry && restarted) {
      setState(() => chat.error = tr('终端已重启，请发送新消息开始对话'));
      return;
    }
    setState(() {
      if (restarted) {
        chat.messages.clear();
        chat.partial = '';
        chat.requestMessages = null;
      }
      if (retry) {
        chat.messages
          ..clear()
          ..addAll(chat.requestMessages!.map(Map<String, dynamic>.of));
      } else {
        if (chat.partial.isNotEmpty) {
          chat.messages.add({'role': 'assistant', 'content': chat.partial});
        }
        chat.messages.add({'role': 'user', 'content': chat.draft.trim()});
        chat.draft = '';
        chat.requestMessages = chat.messages
            .map(Map<String, dynamic>.of)
            .toList();
      }
      chat.terminalId = session?.started == true && session?.exited == false
          ? session!.id
          : null;
      chat.terminalTitle = session == null
          ? tr('独立对话')
          : '${session.title} · #${session.id}';
      chat.requestPreset = chat.presetId ?? defaultPreset;
      chat.requestContext = chat.context;
      chat.toolRounds = 0;
    });
    _startStream(chat);
  }

  void _startStream(_Conversation chat) {
    setState(() {
      chat.partial = '';
      chat.error = null;
      chat.status = '';
      chat.pending = true;
    });
    try {
      final id = ai.aiChatPrepare();
      chat.requestId = id;
      final stream = chat.terminalId == null
          ? ai.aiChatStream(
              requestId: id,
              presetId: chat.requestPreset,
              messagesJson: jsonEncode(chat.messages),
              context: chat.requestContext,
            )
          : ai.aiAgentStream(
              requestId: id,
              presetId: chat.requestPreset,
              messagesJson: jsonEncode(chat.messages),
              context: chat.requestContext,
              terminalId: chat.terminalId!,
            );
      chat.subscription = stream.listen(
        (event) {
          if (!mounted || chat.requestId != id) return;
          if (event.kind == 'delta') {
            chat.partial += event.text;
            _refresh();
          } else if (event.kind == 'tool_calls') {
            try {
              final message = Map<String, dynamic>.from(
                jsonDecode(event.text) as Map,
              );
              message['content'] = chat.partial;
              // Rust validates the tool schema before emitting this complete message.
              setState(() {
                chat.messages.add(message);
                chat.toolCall = message;
                chat.partial = '';
                chat.toolRounds++;
              });
            } catch (_) {
              ai.aiChatCancel(requestId: id);
              _finish(chat, id, 'error', tr('工具调用格式无效'));
            }
          } else {
            _finish(chat, id, event.kind, event.text);
          }
        },
        onError: (Object error) => _finish(chat, id, 'error', '$error'),
        onDone: () {
          if (chat.requestId == id) {
            _finish(chat, id, 'error', tr('连接已中断，回复尚未完成。'));
          }
        },
      );
    } catch (error) {
      final id = chat.requestId;
      if (id != null) ai.aiChatCancel(requestId: id);
      setState(() {
        chat.requestId = null;
        chat.pending = false;
        chat.error = '$error';
      });
    }
  }

  void _resetRestarted(TerminalSession session, _Conversation old) {
    final requestId = old.requestId;
    old.requestId = null;
    if (requestId != null) ai.aiChatCancel(requestId: requestId);
    unawaited(old.subscription?.cancel() ?? Future<void>.value());
    if (old.executingCallId != null && old.terminalId != null) {
      ai.aiToolCancel(
        terminalId: old.terminalId!,
        callId: old.executingCallId!,
      );
    }
    _conversations[session] = _Conversation()
      ..draft = old.draft
      ..presetId = old.presetId
      ..autoExecute = old.autoExecute
      ..status = tr('终端已重启，请发送新消息开始对话');
  }

  Future<void> _resolveTool(_Conversation chat, bool approve) async {
    if (!_conversations.values.contains(chat)) return;
    final session = _conversations.entries
        .firstWhere((entry) => identical(entry.value, chat))
        .key;
    if (session != null && chat.terminalId != session.id) {
      setState(() => _resetRestarted(session, chat));
      return;
    }
    final message = chat.toolCall;
    if (message == null || chat.pending || chat.executing) return;
    final call = (message['tool_calls'] as List).single as Map;
    final args =
        jsonDecode((call['function'] as Map)['arguments'] as String) as Map;
    final callId = call['id'] as String;
    final terminalId = chat.terminalId;
    setState(() {
      chat.toolCall = null;
      chat.executing = approve;
      chat.executingCallId = approve ? callId : null;
      chat.status = approve ? tr('正在执行命令…') : tr('已拒绝执行');
      chat.error = null;
    });
    String result;
    if (approve && terminalId != null) {
      try {
        result = await ai.aiToolExecute(
          terminalId: terminalId,
          callId: callId,
          command: args['command'] as String,
        );
      } catch (error) {
        result = jsonEncode({
          'status': 'error',
          'output': '$error',
          'exitCode': null,
        });
      }
    } else {
      result = jsonEncode({
        'status': 'denied',
        'output': tr('用户拒绝执行，未运行命令。'),
        'exitCode': null,
      });
    }
    // The originating session may have been closed while the command was running.
    if (!mounted || !_conversations.values.contains(chat)) return;
    setState(() {
      chat.executing = false;
      chat.executingCallId = null;
      chat.messages.add({
        'role': 'tool',
        'tool_call_id': callId,
        'content': result,
      });
      // Retry resumes from the recorded result, never repeats an approved command automatically.
      chat.requestMessages = chat.messages
          .map(Map<String, dynamic>.of)
          .toList();
      chat.status = '';
    });
    if (chat.toolRounds >= 8) {
      setState(() => chat.status = tr('已达到本轮命令上限，请发送新消息继续'));
      return;
    }
    _startStream(chat);
  }

  @override
  void dispose() {
    _renderTimer?.cancel();
    _dockSize.dispose();
    for (final chat in _conversations.values) {
      final id = chat.requestId;
      if (id != null) ai.aiChatCancel(requestId: id);
      if (chat.executingCallId != null && chat.terminalId != null) {
        ai.aiToolCancel(
          terminalId: chat.terminalId!,
          callId: chat.executingCallId!,
        );
      }
      unawaited(chat.subscription?.cancel() ?? Future<void>.value());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final live = app.tabs
        .whereType<TerminalTab>()
        .expand((tab) => tab.sessions)
        .toSet();
    final closed = _conversations.keys
        .where((session) => session != null && !live.contains(session))
        .toList();
    for (final session in closed) {
      final chat = _conversations.remove(session)!;
      final id = chat.requestId;
      chat.requestId = null;
      if (id != null) ai.aiChatCancel(requestId: id);
      if (chat.executingCallId != null && chat.terminalId != null) {
        ai.aiToolCancel(
          terminalId: chat.terminalId!,
          callId: chat.executingCallId!,
        );
      }
      unawaited(chat.subscription?.cancel() ?? Future<void>.value());
    }
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (!app.aiVisible) return content;
    final session = app.activeSession;
    var chat = _conversations.putIfAbsent(
      session,
      () => _Conversation()
        ..presetId =
            ((app.config['ai'] as Map?)?['activePreset'] as String? ??
            'general'),
    );
    if (session != null &&
        chat.terminalId != null &&
        chat.terminalId != session.id) {
      _resetRestarted(session, chat);
      chat = _conversations[session]!;
    }
    final right = (app.config['ai'] as Map?)?['panelPosition'] != 'bottom';
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHeight = math.min(650.0, constraints.maxHeight * .75);
        final minHeight = math.min(240.0, maxHeight);
        // On a narrow window the bottom dock leaves the terminal usable.
        final vertical = !right || constraints.maxWidth < 650;
        final panel = _AiPanel(
          key: _panelKey,
          dockAtBottom: vertical,
          chat: chat,
          session: session,
          onChanged: () => setState(() {}),
          onSend: () => _send(chat),
          onRetry: () => _send(chat, retry: true),
          onStop: () => _stop(chat),
          onToolDecision: (approve) => _resolveTool(chat, approve),
        );
        return ValueListenableBuilder<Offset>(
          valueListenable: _dockSize,
          child: panel,
          builder: (context, size, panelChild) {
            final width = size.dx.clamp(
              280.0,
              (constraints.maxWidth * .65).clamp(280.0, 600.0),
            );
            final height = size.dy.clamp(minHeight, maxHeight);
            final divider = MouseRegion(
              cursor: vertical
                  ? SystemMouseCursors.resizeUpDown
                  : SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                key: const ValueKey('ai-dock-resize-handle'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (event) {
                  if (vertical) {
                    _bottomHeight =
                        (_dockSize.value.dy.clamp(minHeight, maxHeight) -
                                event.delta.dy)
                            .clamp(minHeight, maxHeight);
                  } else {
                    _rightWidth =
                        (_dockSize.value.dx.clamp(
                                  280.0,
                                  (constraints.maxWidth * .65).clamp(
                                    280.0,
                                    600.0,
                                  ),
                                ) -
                                event.delta.dx)
                            .clamp(
                              280.0,
                              (constraints.maxWidth * .65).clamp(280.0, 600.0),
                            );
                  }
                  _dockSize.value = Offset(_rightWidth, _bottomHeight);
                },
                child: Container(
                  width: vertical ? null : 4,
                  height: vertical ? 4 : null,
                  color: AppTheme.of(context).border,
                ),
              ),
            );
            if (vertical) {
              return Column(
                children: [
                  Expanded(child: content),
                  divider,
                  SizedBox(
                    key: const ValueKey('ai-dock-panel'),
                    height: height,
                    child: panelChild,
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: content),
                divider,
                SizedBox(
                  key: const ValueKey('ai-dock-panel'),
                  width: width,
                  child: panelChild,
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _AiPanel extends StatefulWidget {
  const _AiPanel({
    super.key,
    required this.dockAtBottom,
    required this.chat,
    required this.session,
    required this.onChanged,
    required this.onSend,
    required this.onRetry,
    required this.onStop,
    required this.onToolDecision,
  });
  final _Conversation chat;
  final bool dockAtBottom;
  final TerminalSession? session;
  final VoidCallback onChanged;
  final VoidCallback onSend;
  final VoidCallback onRetry;
  final VoidCallback onStop;
  final ValueChanged<bool> onToolDecision;

  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  late final AppState _app;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _followOutput = true;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _app.aiInputFocus = _focus;
    _input.text = widget.chat.draft;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _AiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dockAtBottom != widget.dockAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.chat.pending) _focus.requestFocus();
      });
    }
    if (_input.text != widget.chat.draft) {
      _input.value = TextEditingValue(
        text: widget.chat.draft,
        selection: TextSelection.collapsed(offset: widget.chat.draft.length),
      );
    }
    if (oldWidget.chat != widget.chat) _followOutput = true;
    if (_followOutput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    if (_app.aiInputFocus == _focus) _app.aiInputFocus = null;
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _attach() {
    final session = widget.session;
    if (session == null || !session.started) return;
    final text = terminal.termSelectionText(id: session.id) ?? '';
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('请先在终端中选中要发送的文字'))));
      return;
    }
    widget.chat.context = text;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final app = AppScope.of(context);
    final chat = widget.chat;
    final config = app.config['ai'] as Map? ?? {};
    final configured =
        (config['baseUrl'] as String? ?? '').isNotEmpty &&
        (config['model'] as String? ?? '').isNotEmpty;
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          if (chat.pending || chat.executing) {
            widget.onStop();
          } else {
            app.toggleAi();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter &&
            _focus.hasFocus) {
          if (!_input.value.composing.isCollapsed) {
            return KeyEventResult.ignored;
          }
          if (HardwareKeyboard.instance.isShiftPressed) {
            final value = _input.value;
            final selection = value.selection;
            final start = selection.isValid
                ? selection.start
                : value.text.length;
            final end = selection.isValid ? selection.end : value.text.length;
            final text = value.text.replaceRange(start, end, '\n');
            _input.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: start + 1),
            );
            chat.draft = text;
            widget.onChanged();
            return KeyEventResult.handled;
          }
          if (configured && !chat.pending && chat.draft.trim().isNotEmpty) {
            widget.onSend();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 42,
              padding: const EdgeInsets.only(left: 14, right: 4),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 16,
                    color: colors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    tr('AI 助手'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  _button(
                    Icons.tune,
                    tr('AI 设置'),
                    () => app.openSettings('ai'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: tr('面板位置'),
                    icon: Icon(
                      Icons.space_dashboard_outlined,
                      size: 16,
                      color: colors.textDim,
                    ),
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 120),
                    onSelected: (value) => app.updateConfig((config) {
                      (config['ai'] as Map<String, dynamic>)['panelPosition'] =
                          value;
                    }),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'right', child: Text(tr('右侧'))),
                      PopupMenuItem(value: 'bottom', child: Text(tr('底部'))),
                    ],
                  ),
                  _button(
                    Icons.delete_outline,
                    tr('清空对话'),
                    chat.pending || chat.executing || chat.toolCall != null
                        ? null
                        : () {
                            chat.messages.clear();
                            chat.error = null;
                            chat.context = '';
                            chat.partial = '';
                            chat.status = '';
                            chat.requestMessages = null;
                            widget.onChanged();
                          },
                  ),
                  _button(Icons.close, tr('关闭'), app.toggleAi),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
              child: Row(
                children: [
                  Icon(
                    widget.session?.profileType == 'ssh'
                        ? Icons.dns_outlined
                        : Icons.terminal,
                    size: 13,
                    color: colors.textDim,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.session?.title ?? tr('独立对话'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textDim),
                    ),
                  ),
                  if (configured)
                    Flexible(
                      child: Text(
                        config['model'] as String,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: colors.textDim),
                      ),
                    ),
                ],
              ),
            ),
            _presetSelector(config, chat),
            if (chat.messages.isEmpty && chat.status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Text(
                  chat.status,
                  style: TextStyle(fontSize: 11, color: colors.textDim),
                ),
              ),
            Expanded(
              child: chat.messages.isEmpty
                  ? _empty(configured)
                  : NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        _followOutput = notification.metrics.extentAfter < 72;
                        return false;
                      },
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                        children: [
                          for (final message in chat.messages)
                            _Message(message: message),
                          if (chat.toolCall != null && !chat.pending)
                            _approvalCard(chat),
                          if (chat.executing)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      tr('正在执行命令…'),
                                      style: TextStyle(
                                        color: colors.textDim,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: widget.onStop,
                                    child: Text(tr('停止命令')),
                                  ),
                                ],
                              ),
                            ),
                          if (chat.partial.isNotEmpty)
                            _Message(
                              message: {
                                'role': 'assistant',
                                'content': chat.partial,
                              },
                            ),
                          if (chat.status.isNotEmpty && !chat.executing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                chat.status,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.textDim,
                                ),
                              ),
                            ),
                          if (chat.pending)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    tr(
                                      chat.partial.isEmpty ? '正在思考…' : '正在生成…',
                                    ),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (chat.error != null)
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: colors.danger.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    chat.error!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.danger,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: chat.pending
                                        ? null
                                        : widget.onRetry,
                                    child: Text(
                                      tr(
                                        chat.presetId != chat.requestPreset
                                            ? '按当前预设重新生成'
                                            : '重试',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (!chat.pending &&
                              !chat.executing &&
                              chat.toolCall == null &&
                              chat.error == null &&
                              chat.requestMessages != null)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: widget.onRetry,
                                icon: const Icon(Icons.refresh, size: 14),
                                label: Text(tr('重新生成')),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            if (chat.context.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
                decoration: BoxDecoration(
                  color: colors.surfaceRaised,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('附加的终端选区'),
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.accent,
                            ),
                          ),
                          Text(
                            chat.context,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.textDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _button(Icons.close, tr('移除'), () {
                      chat.context = '';
                      widget.onChanged();
                    }),
                  ],
                ),
              ),
            Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              decoration: BoxDecoration(
                color: colors.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('ai-input'),
                    controller: _input,
                    focusNode: _focus,
                    minLines: 2,
                    maxLines: 4,
                    enabled: true,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: tr('描述你想完成的操作…'),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                    ),
                    onChanged: (value) {
                      chat.draft = value;
                      widget.onChanged();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 6, 4),
                    child: Row(
                      children: [
                        _button(
                          Icons.attach_file,
                          tr('附加终端选区'),
                          widget.session?.started == true && !chat.pending
                              ? _attach
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            tr('Enter 发送 · Shift+Enter 换行 · 手动附加终端内容'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.textDim,
                            ),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: tr(
                            chat.executing
                                ? '停止命令'
                                : chat.pending
                                ? '停止生成'
                                : '发送',
                          ),
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            chat.pending || chat.executing
                                ? Icons.stop
                                : Icons.arrow_upward,
                            size: 17,
                          ),
                          onPressed: chat.pending || chat.executing
                              ? () {
                                  widget.onStop();
                                  _focus.requestFocus();
                                }
                              : configured &&
                                    chat.toolCall == null &&
                                    chat.draft.trim().isNotEmpty
                              ? widget.onSend
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  for (final auto in [false, true])
                    Tooltip(
                      message: auto
                          ? tr('低风险命令自动执行，危险或未知命令仍需确认')
                          : tr('每条命令执行前询问'),
                      child: TextButton(
                        key: ValueKey(auto ? 'ai-mode-auto' : 'ai-mode-ask'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          visualDensity: VisualDensity.compact,
                          foregroundColor: chat.autoExecute == auto
                              ? colors.accent
                              : colors.textDim,
                          backgroundColor: chat.autoExecute == auto
                              ? colors.surfaceRaised
                              : Colors.transparent,
                        ),
                        onPressed: () {
                          chat.autoExecute = auto;
                          widget.onChanged();
                        },
                        child: Semantics(
                          selected: chat.autoExecute == auto,
                          child: Text(
                            auto ? 'auto' : 'ask',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _approvalCard(_Conversation chat) {
    final colors = AppTheme.of(context);
    final call = (chat.toolCall!['tool_calls'] as List).single as Map;
    final args =
        jsonDecode((call['function'] as Map)['arguments'] as String) as Map;
    final command = args['command'] as String;
    final description = args['description'] as String? ?? '';
    return Container(
      key: const ValueKey('ai-tool-approval'),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        border: Border.all(color: colors.accent),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('确认在「{terminal}」执行？', {'terminal': chat.terminalTitle}),
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          if (description.isNotEmpty) ...[
            Text(
              description,
              style: TextStyle(color: colors.text, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            tr('待执行命令'),
            style: TextStyle(color: colors.textDim, fontSize: 11),
          ),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.chrome,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(6),
            ),
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              // Show the exact tool argument, without Markdown parsing or truncation.
              child: SelectableText(
                command,
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 12,
                  color: colors.text,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Text(
            tr('请确认目标终端处于 shell 提示符。执行输出将发送给 AI 继续分析。'),
            style: TextStyle(color: colors.textDim, fontSize: 11, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => widget.onToolDecision(true),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(tr('确认执行')),
              ),
              TextButton(
                onPressed: () => widget.onToolDecision(false),
                child: Text(tr('拒绝执行')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _presetSelector(Map config, _Conversation chat) {
    final colors = AppTheme.of(context);
    final presets =
        (config['promptPresets'] as List?) ??
        jsonDecode(ai.aiPresetsDefaults()) as List;
    if (presets.isEmpty) return const SizedBox.shrink();
    var selected =
        chat.presetId ?? config['activePreset'] as String? ?? 'general';
    if (!presets.any((preset) => preset['id'] == selected)) {
      selected = presets.first['id'] as String;
      chat.presetId = selected;
    }
    final current =
        presets.firstWhere((preset) => preset['id'] == selected) as Map;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Icon(Icons.person_outline, size: 14, color: colors.textDim),
          const SizedBox(width: 6),
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: tr('对话预设'),
              enabled:
                  !chat.pending && !chat.executing && chat.toolCall == null,
              initialValue: selected,
              onSelected: (value) {
                chat.presetId = value;
                widget.onChanged();
              },
              itemBuilder: (_) => [
                for (final preset in presets)
                  CheckedPopupMenuItem(
                    value: preset['id'] as String,
                    checked: selected == preset['id'],
                    child: Text(tr(preset['name'] as String)),
                  ),
              ],
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr(current['name'] as String),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textDim),
                    ),
                  ),
                  Icon(Icons.expand_more, size: 14, color: colors.textDim),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(bool configured) {
    final colors = AppTheme.of(context);
    if (widget.dockAtBottom) {
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        child: Wrap(
          spacing: 24,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 320,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('从一句话开始'),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('编写命令、解释报错，或一起分析终端输出。'),
                    style: TextStyle(fontSize: 12, color: colors.textDim),
                  ),
                ],
              ),
            ),
            if (!configured)
              OutlinedButton.icon(
                onPressed: () => AppScope.read(context).openSettings('ai'),
                icon: const Icon(Icons.tune, size: 14),
                label: Text(tr('配置 AI 服务')),
              ),
            for (final text in ['帮我编写命令', '解释这段报错', '分析命令输出'])
              ActionChip(
                label: Text(tr(text), style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  widget.chat.draft = tr(text);
                  widget.onChanged();
                  _focus.requestFocus();
                },
              ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('从一句话开始'),
            style: TextStyle(
              fontSize: 18,
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('编写命令、解释报错，或一起分析终端输出。'),
            style: TextStyle(fontSize: 12, color: colors.textDim, height: 1.6),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final text in ['帮我编写命令', '解释这段报错', '分析命令输出'])
                ActionChip(
                  label: Text(tr(text), style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    widget.chat.draft = tr(text);
                    widget.onChanged();
                    _focus.requestFocus();
                  },
                ),
            ],
          ),
          if (!configured) ...[
            const SizedBox(height: 20),
            Text(
              tr('连接你的 AI 服务后即可开始。'),
              style: TextStyle(fontSize: 12, color: colors.textDim),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => AppScope.read(context).openSettings('ai'),
              icon: const Icon(Icons.tune, size: 14),
              label: Text(tr('配置 AI 服务')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        color: AppTheme.of(context).textDim,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        padding: const EdgeInsets.all(5),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.message});
  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = message['role'] == 'user';
    if (message['role'] == 'tool') {
      return _toolResult(context);
    }
    var content = message['content'] as String? ?? '';
    if (message['tool_calls'] is List) {
      final call = (message['tool_calls'] as List).single as Map;
      final args =
          jsonDecode((call['function'] as Map)['arguments'] as String) as Map;
      content +=
          '\n\n${args['description'] ?? ''}\n\n```shell\n${args['command']}\n```';
    }
    final blocks = content.split('```');
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: EdgeInsets.all(user ? 10 : 0),
      decoration: user
          ? BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              user ? tr('你') : tr('AI 助手'),
              style: TextStyle(fontSize: 10, color: colors.textDim),
            ),
          ),
          for (var index = 0; index < blocks.length; index++)
            if (blocks[index].trim().isNotEmpty)
              if (index.isOdd)
                _code(context, blocks[index])
              else if (user)
                SelectableText(
                  blocks[index].trim(),
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.text,
                    height: 1.6,
                  ),
                )
              else
                MarkdownBody(
                  data: blocks[index].trim(),
                  selectable: true,
                  imageBuilder: (uri, title, alt) =>
                      Text(alt ?? uri.toString()),
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        p: TextStyle(
                          fontSize: 13,
                          color: colors.text,
                          height: 1.6,
                        ),
                        code: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: colors.text,
                          backgroundColor: colors.chrome,
                        ),
                        blockSpacing: 8,
                      ),
                ),
        ],
      ),
    );
  }

  Widget _toolResult(BuildContext context) {
    final colors = AppTheme.of(context);
    final result = jsonDecode(message['content'] as String) as Map;
    final code = result['exitCode'];
    final status = result['status'] as String? ?? 'unknown';
    final statusText = switch (status) {
      'denied' => tr('已拒绝执行'),
      'error' => tr('执行失败'),
      'timeout' => tr('执行超时，命令可能仍在运行'),
      'closed' => tr('终端已断开，执行结果未知'),
      _ => tr('执行结果未知'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.chrome,
        borderRadius: BorderRadius.circular(6),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          title: Text(
            code == null
                ? tr('执行状态：{status}', {'status': statusText})
                : tr('命令退出码：{code}', {'code': code}),
            style: TextStyle(fontSize: 11, color: colors.textDim),
          ),
          children: [
            if (result['truncated'] == true)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  tr('输出过长，已截断'),
                  style: TextStyle(color: colors.textDim, fontSize: 11),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  result['output'] as String? ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: colors.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _code(BuildContext context, String block) {
    final colors = AppTheme.of(context);
    final newline = block.indexOf('\n');
    final code = (newline >= 0 ? block.substring(newline + 1) : block).trim();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.chrome,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.code, size: 13, color: colors.textDim),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(tr('已复制'))));
                  }
                },
                icon: const Icon(Icons.copy, size: 12),
                label: Text(tr('复制'), style: const TextStyle(fontSize: 10)),
              ),
            ],
          ),
          SelectableText(
            code,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'Menlo',
              color: colors.text,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
