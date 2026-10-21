import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../i18n.dart';
import '../src/rust/api/ai.dart' as ai;
import '../src/rust/api/terminal.dart' as terminal;
import '../terminal/terminal_session.dart';
import '../theme.dart';

class _Conversation {
  final messages = <Map<String, String>>[];
  String draft = '';
  String context = '';
  String? error;
  bool pending = false;
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
  double _rightWidth = 380;
  double _bottomHeight = 310;

  Future<void> _send(_Conversation chat, {bool retry = false}) async {
    if (chat.pending || (!retry && chat.draft.trim().isEmpty)) return;
    setState(() {
      if (!retry) {
        chat.messages.add({'role': 'user', 'content': chat.draft.trim()});
        chat.draft = '';
      }
      chat.error = null;
      chat.pending = true;
    });
    try {
      final reply = await ai.aiChat(
        messagesJson: jsonEncode(chat.messages),
        context: chat.context,
      );
      if (!mounted) return;
      setState(
        () => chat.messages.add({'role': 'assistant', 'content': reply}),
      );
    } catch (error) {
      if (mounted) setState(() => chat.error = '$error');
    } finally {
      if (mounted) setState(() => chat.pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final live = app.tabs
        .whereType<TerminalTab>()
        .expand((tab) => tab.sessions)
        .toSet();
    _conversations.removeWhere(
      (session, chat) =>
          session != null && !live.contains(session) && !chat.pending,
    );
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (!app.aiVisible) return content;
    final session = app.activeSession;
    final chat = _conversations.putIfAbsent(session, _Conversation.new);
    final right = (app.config['ai'] as Map?)?['panelPosition'] != 'bottom';
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _rightWidth.clamp(
          280.0,
          (constraints.maxWidth * .65).clamp(280.0, 600.0),
        );
        final maxHeight = math.min(650.0, constraints.maxHeight * .75);
        final minHeight = math.min(240.0, maxHeight);
        final height = _bottomHeight.clamp(minHeight, maxHeight);
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
        );
        final divider = MouseRegion(
          cursor: vertical
              ? SystemMouseCursors.resizeUpDown
              : SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (event) => setState(() {
              if (vertical) {
                _bottomHeight = (height - event.delta.dy).clamp(
                  minHeight,
                  maxHeight,
                );
              } else {
                _rightWidth = (width - event.delta.dx).clamp(
                  280.0,
                  constraints.maxWidth * .65,
                );
              }
            }),
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
              SizedBox(height: height, child: panel),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: content),
            divider,
            SizedBox(width: width, child: panel),
          ],
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
  });
  final _Conversation chat;
  final bool dockAtBottom;
  final TerminalSession? session;
  final VoidCallback onChanged;
  final VoidCallback onSend;
  final VoidCallback onRetry;

  @override
  State<_AiPanel> createState() => _AiPanelState();
}

class _AiPanelState extends State<_AiPanel> {
  late final AppState _app;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

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
    if (widget.chat.pending || oldWidget.chat != widget.chat) {
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
          app.toggleAi();
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
                    chat.pending
                        ? null
                        : () {
                            chat.messages.clear();
                            chat.error = null;
                            chat.context = '';
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
            Expanded(
              child: chat.messages.isEmpty
                  ? _empty(configured)
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                      children: [
                        for (final message in chat.messages)
                          _Message(message: message),
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
                                  tr('正在思考…'),
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
                                  child: Text(tr('重试')),
                                ),
                              ],
                            ),
                          ),
                      ],
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
                    enabled: !chat.pending,
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
                        Expanded(child: Text(
                          tr('仅发送输入和附加内容'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: colors.textDim),
                        )),
                        IconButton.filled(
                          tooltip: tr('发送'),
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.arrow_upward, size: 17),
                          onPressed:
                              configured &&
                                  !chat.pending &&
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
          ],
        ),
      ),
    );
  }

  Widget _empty(bool configured) {
    final colors = AppTheme.of(context);
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
  final Map<String, String> message;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = message['role'] == 'user';
    final content = message['content']!;
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
              else
                SelectableText(
                  blocks[index].trim(),
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.text,
                    height: 1.6,
                  ),
                ),
        ],
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
