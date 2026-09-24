import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../window_control.dart';
import 'profile_icons.dart';
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
          Row(children: [...buttons, const Spacer(), _settingsButton(app)]),
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
            final width = count == 0 ? 0.0 : (flexible ? constraints.maxWidth / count : (constraints.maxWidth / count).clamp(90.0, 200.0));
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
                child: SizedBox(width: width, child: _TabItem(tab: app.tabs[index], index: index, vertical: false)),
              ),
            );
          }),
        ),
        ...buttons,
        Expanded(flex: flexible ? 0 : 1, child: _DragArea(child: const SizedBox(height: height))),
        _settingsButton(app),
        const SizedBox(width: 4),
      ]),
    );
  }

  Widget _settingsButton(AppState app) => _ChromeButton(icon: Icons.settings_outlined, tooltip: tr('设置'), onTap: () => app.openSettings());
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
        icon = Icons.settings_outlined;
      case WelcomeTab():
        icon = Icons.waving_hand_outlined;
    }

    final highlight = tabColor ?? (active ? colors.textDim : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) app.closeTab(tab);
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
              if (showIcon) ...[
                Icon(icon, size: 14, color: exited ? colors.danger : colors.textDim),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  tab.title.isEmpty ? tr('终端') : tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: active ? colors.text : colors.textDim),
                ),
              ),
              if (tab is TerminalTab && tab.sessions.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Text('${tab.sessions.length}', style: TextStyle(fontSize: 10, color: colors.textDim)),
                ),
              if (app.appearance['showTabCloseButton'] != false)
                Opacity(
                  opacity: _hover || active ? 1 : 0,
                  child: InkWell(
                    onTap: () => app.closeTab(tab),
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
        app.closeTab(tab);
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
