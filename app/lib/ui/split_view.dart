import 'package:flutter/material.dart';

import '../app_state.dart';
import '../pane_tree.dart';
import '../terminal/terminal_session.dart';
import '../terminal/terminal_view.dart';
import '../theme.dart';
import 'sftp_panel.dart';
import '../i18n.dart';

/// 渲染一个终端标签页的分屏树
class SplitView extends StatelessWidget {
  const SplitView({super.key, required this.tab, required this.visible});

  final TerminalTab tab;
  /// 标签页是否在前台（后台标签页也保持挂载，会话不中断）
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final maximized = tab.maximized;
    if (maximized != null) return _pane(context, maximized);
    return _node(context, tab.tree.root);
  }

  Widget _pane(BuildContext context, TerminalSession session) {
    final colors = AppTheme.of(context);
    final multiple = tab.sessions.length > 1;
    final focused = tab.focused == session;
    final app = AppScope.of(context);
    final ssh = session.profileType == 'ssh' && session.started && !session.exited;
    return Container(
      key: ObjectKey(session),
      decoration: BoxDecoration(
        border: multiple
            ? Border.all(color: focused ? colors.accent.withValues(alpha: 0.6) : Colors.transparent, width: 1)
            : null,
      ),
      child: LayoutBuilder(builder: (context, constraints) => Stack(children: [
        Positioned.fill(child: TerminalView(session: session, tab: tab, active: visible && focused)),
        if (ssh && !session.sftpVisible)
          Positioned(
            top: 6,
            right: 14,
            child: SftpButton(onTap: () {
              app.focusPane(tab, session);
              app.runAction('open-sftp');
            }),
          ),
        if (session.sftpVisible && session.started)
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: (constraints.maxWidth * 0.6).clamp(280.0, 520.0),
            child: SftpPanel(
              key: ObjectKey(session),
              session: session,
              onClose: () {
                app.focusPane(tab, session);
                app.runAction('open-sftp');
              },
            ),
          ),
        if (tab.broadcast)
          Positioned(
            top: 4,
            left: 4,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: colors.danger.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(3)),
                child: Text(tr('广播输入'), style: TextStyle(fontSize: 11, color: Colors.white)),
              ),
            ),
          ),
      ])),
    );
  }

  Widget _node(BuildContext context, PaneNode<TerminalSession> node) {
    switch (node) {
      case LeafNode<TerminalSession>():
        return _pane(context, node.pane);
      case SplitNode<TerminalSession>():
        return _SplitBranch(node: node, builder: (child) => _node(context, child));
    }
  }
}

class _SplitBranch extends StatefulWidget {
  const _SplitBranch({required this.node, required this.builder});

  final SplitNode<TerminalSession> node;
  final Widget Function(PaneNode<TerminalSession> child) builder;

  @override
  State<_SplitBranch> createState() => _SplitBranchState();
}

class _SplitBranchState extends State<_SplitBranch> {
  static const _divider = 5.0;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final colors = AppTheme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final total = (node.vertical ? constraints.maxHeight : constraints.maxWidth) - _divider * (node.children.length - 1);
      final children = <Widget>[];
      for (var i = 0; i < node.children.length; i++) {
        final extent = total * node.ratios[i];
        children.add(SizedBox(
          width: node.vertical ? null : extent,
          height: node.vertical ? extent : null,
          child: KeyedSubtree(key: ObjectKey(node.children[i]), child: widget.builder(node.children[i])),
        ));
        if (i < node.children.length - 1) {
          children.add(MouseRegion(
            cursor: node.vertical ? SystemMouseCursors.resizeRow : SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) {
                final delta = (node.vertical ? details.delta.dy : details.delta.dx) / total;
                final a = node.ratios[i] + delta;
                final b = node.ratios[i + 1] - delta;
                if (a < 0.05 || b < 0.05) return;
                setState(() {
                  node.ratios[i] = a;
                  node.ratios[i + 1] = b;
                });
              },
              child: Container(
                width: node.vertical ? null : _divider,
                height: node.vertical ? _divider : null,
                color: colors.chrome,
              ),
            ),
          ));
        }
      }
      return node.vertical
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
          : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    });
  }
}
