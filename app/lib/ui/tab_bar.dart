import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../window_control.dart';
import 'profile_icons.dart';
import 'update_button.dart';
import '../i18n.dart';

/// 标签栏：放在标题栏里，左侧留出红绿灯，标签后面是 “+” 和配置选择按钮，最右是设置
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.vertical});

  final bool vertical;

  static const height = 38.0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final mac = Platform.isMacOS;
    final trafficLights = mac && !app.fullScreen && !vertical ? 78.0 : 0.0;

    final buttons = [
      _ChromeButton(icon: Icons.add, tooltip: tr('新建标签页'), onTap: () => app.newTab()),
      _ChromeButton(icon: Icons.web_asset_outlined, tooltip: tr('配置和连接'), onTap: () => app.showProfileSelector?.call()),
    ];

    if (vertical) {
      return Container(
        width: 200,
        color: colors.chrome,
        child: Column(children: [
          if (mac && !app.fullScreen) _DragArea(child: const SizedBox(height: height)),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: app.tabs.length,
              onReorderItem: app.moveTab,
              itemBuilder: (context, index) => ReorderableDragStartListener(
                key: ValueKey(app.tabs[index].key),
                index: index,
                child: _TabItem(tab: app.tabs[index], index: index, vertical: true),
              ),
            ),
          ),
          Row(children: [...buttons, const Spacer(), const UpdateButton(height: height), _settingsButton(app)]),
        ]),
      );
    }

    final flexible = app.appearance['flexibleTabs'] == true;
    return Container(
      height: height,
      color: colors.chrome,
      child: Row(children: [
        _DragArea(child: SizedBox(width: trafficLights, height: height)),
        Flexible(
          flex: flexible ? 1 : 0,
          child: LayoutBuilder(builder: (context, constraints) {
            final count = app.tabs.length;
            // 固定的标签页只显示序号和图标，定宽；其余标签页分剩下的宽度
            final pinnedCount = app.tabs.where((tab) => tab.pinned).length;
            final restCount = count - pinnedCount;
            final restWidth = constraints.maxWidth - pinnedCount * _pinnedWidth;
            final width = restCount == 0 ? 0.0 : (flexible ? restWidth / restCount : (restWidth / restCount).clamp(90.0, 200.0));
            return ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              shrinkWrap: true,
              itemCount: count,
              onReorderItem: app.moveTab,
              proxyDecorator: (child, index, animation) => Material(color: Colors.transparent, child: child),
              itemBuilder: (context, index) => ReorderableDragStartListener(
                key: ValueKey(app.tabs[index].key),
                index: index,
                child: SizedBox(width: app.tabs[index].pinned ? _pinnedWidth : width, child: _TabItem(tab: app.tabs[index], index: index, vertical: false)),
              ),
            );
          }),
        ),
        ...buttons,
        Expanded(flex: flexible ? 0 : 1, child: _DragArea(child: const SizedBox(height: height))),
        const UpdateButton(height: height),
        _settingsButton(app),
        const SizedBox(width: 4),
      ]),
    );
  }

  static const _pinnedWidth = 52.0;

  Widget _settingsButton(AppState app) => _ChromeButton(icon: CupertinoIcons.gear, tooltip: tr('设置'), onTap: () => app.openSettings());
}

/// 空白处拖动窗口、双击缩放（macOS 标题栏行为）
class _DragArea extends StatelessWidget {
  const _DragArea({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => WindowControl.startDrag(),
      onDoubleTap: WindowControl.zoom,
      child: child,
    );
  }
}

class _ChromeButton extends StatefulWidget {
  const _ChromeButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ChromeButton> createState() => _ChromeButtonState();
}

class _ChromeButtonState extends State<_ChromeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Tooltip(
      message: tr(widget.tooltip),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 36,
            height: AppTabBar.height,
            color: _hover ? colors.tabHover : Colors.transparent,
            child: Icon(widget.icon, size: 17, color: _hover ? colors.text : colors.textDim),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  const _TabItem({required this.tab, required this.index, required this.vertical});

  final AppTab tab;
  final int index;
  final bool vertical;

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final tab = widget.tab;
    final active = app.activeTab == tab;
    final tabColor = parseHexColor(tab.color);
    final showIcon = app.appearance['showTabProfileIcon'] != false;
    final exited = tab is TerminalTab && tab.focused.exited;

    IconData icon;
    switch (tab) {
      case TerminalTab():
        icon = profileIcon(tab.focused.profile);
      case SettingsTab():
        icon = CupertinoIcons.gear;
      case WelcomeTab():
        icon = Icons.waving_hand_outlined;
    }

    final highlight = tabColor ?? (active ? colors.textDim : Colors.transparent);
    // 横向标签栏里固定的标签页只显示序号和图标（标题放进悬停提示）
    final compact = tab.pinned && !widget.vertical;
    final item = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) app.requestCloseTab(tab);
        },
        child: GestureDetector(
          onTap: () => app.selectTab(widget.index),
          onSecondaryTapUp: (details) => _showMenu(context, app, details.globalPosition),
          onDoubleTap: () => app.runAction('rename-tab'),
          child: Container(
            height: widget.vertical ? 34 : AppTabBar.height,
            decoration: BoxDecoration(
              color: active ? colors.tabActive : (_hover ? colors.tabHover : Colors.transparent),
              border: widget.vertical
                  ? Border(left: BorderSide(color: highlight, width: 2))
                  : Border(top: BorderSide(color: highlight, width: tabColor != null ? 2 : 1)),
            ),
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(children: [
              SizedBox(
                width: 16,
                child: Text('${widget.index + 1}', style: TextStyle(fontSize: 11, color: colors.textDim)),
              ),
              if (showIcon || compact) ...[
                Icon(icon, size: 14, color: exited ? colors.danger : colors.textDim),
                const SizedBox(width: 6),
              ],
              if (compact) const Spacer(),
              if (!compact)
                Expanded(
                  child: Text(
                    tab.title.isEmpty ? tr('终端') : tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: active ? colors.text : colors.textDim),
                  ),
                ),
              if (tab.pinned && !compact)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Icon(CupertinoIcons.pin, size: 11, color: colors.textDim),
                ),
              if (!compact && tab is TerminalTab && tab.sessions.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Text('${tab.sessions.length}', style: TextStyle(fontSize: 10, color: colors.textDim)),
                ),
              if (!compact && !tab.pinned && app.appearance['showTabCloseButton'] != false)
                Opacity(
                  opacity: _hover || active ? 1 : 0,
                  child: InkWell(
                    onTap: () => app.requestCloseTab(tab),
                    borderRadius: BorderRadius.circular(3),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close, size: 13, color: colors.textDim),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
    if (!compact) return item;
    return Tooltip(message: tab.title.isEmpty ? tr('终端') : tab.title, waitDuration: const Duration(milliseconds: 500), child: item);
  }

  Future<void> _showMenu(BuildContext context, AppState app, Offset position) async {
    final colors = AppTheme.of(context);
    final tab = widget.tab;
    PopupMenuItem<String> item(String value, String label) =>
        PopupMenuItem(value: value, height: 30, child: Text(tr(label), style: TextStyle(fontSize: 13, color: colors.text)));
    final remote = tab is TerminalTab && tab.focused.profileType != 'local';
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        item('close', '关闭'),
        item('close-others', '关闭其他标签页'),
        item('close-right', '关闭右侧标签页'),
        item('close-left', '关闭左侧标签页'),
        const PopupMenuDivider(height: 8),
        item('rename', '重命名'),
        item('pin', tab.pinned ? '取消固定' : '固定标签页'),
        if (tab is TerminalTab) item('duplicate', '复制标签页'),
        if (tab is TerminalTab && tab.sessions.length > 1) item('explode', '把窗格拆成标签页'),
        if (tab is TerminalTab) item('restart', remote ? '重新连接' : '重启会话'),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          enabled: false,
          height: 34,
          child: Row(children: [
            for (final color in ['', ...tabColors])
              GestureDetector(
                onTap: () {
                  Navigator.of(context).pop();
                  app.setTabColor(tab, color);
                },
                child: Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: parseHexColor(color),
                    shape: BoxShape.circle,
                    border: Border.all(color: tab.color == color ? colors.text : colors.border),
                  ),
                  child: color.isEmpty ? Icon(Icons.block, size: 12, color: colors.textDim) : null,
                ),
              ),
          ]),
        ),
      ],
    );
    switch (chosen) {
      case 'close':
        app.requestCloseTab(tab);
      case 'pin':
        app.togglePin(tab);
      case 'close-others':
        app.closeOtherTabs(tab);
      case 'close-right':
        app.closeOtherTabs(tab, onlyRight: true);
      case 'close-left':
        app.closeOtherTabs(tab, onlyLeft: true);
      case 'rename':
        app.selectTab(app.tabs.indexOf(tab));
        app.runAction('rename-tab');
      case 'duplicate':
        app.duplicateTab(tab);
      case 'explode':
        if (tab is TerminalTab) app.explodeTab(tab);
      case 'restart':
        if (tab is TerminalTab) app.restartSession(tab.focused);
    }
  }
}
