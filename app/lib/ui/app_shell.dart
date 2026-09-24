import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../cli.dart';
import '../src/rust/api/settings.dart' as rust;
import '../theme.dart';
import '../window_control.dart';
import 'profile_icons.dart';
import 'selector.dart';
import 'settings/settings_page.dart';
import 'split_view.dart';
import 'tab_bar.dart';
import 'welcome_page.dart';
import '../i18n.dart';

class CTerminalApp extends StatefulWidget {
  const CTerminalApp({super.key, required this.state, this.configError, this.cli});

  final AppState state;
  final String? configError;
  /// 命令行要求打开的内容（见 cli.dart）
  final CliRequest? cli;

  @override
  State<CTerminalApp> createState() => _CTerminalAppState();
}

class _CTerminalAppState extends State<CTerminalApp> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  AppState get app => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_onApp);
    WindowControl.channel.setMethodCallHandler(_onWindowCall);
    if (!Platform.isMacOS) _exitListener = AppLifecycleListener(onExitRequested: _onExitRequested);
    _startup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_onApp);
    _exitListener?.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  AppLifecycleListener? _exitListener;

  void _onApp() => setState(() {});

  /// 有运行中的会话时确认；返回 true 表示可以退出
  Future<bool> _confirmExit() async {
    final context = _navigator.currentContext;
    if (context != null && app.application['confirmOnClose'] == true && app.hasRunningSessions) {
      final count = app.tabs.whereType<TerminalTab>().fold<int>(0, (sum, tab) => sum + tab.sessions.length);
      final ok = await showConfirm(context, title: '退出 CTerminal？', message: tr('还有 {count} 个会话正在运行，退出后会全部结束。', {'count': count}), confirm: '退出', danger: true);
      if (!ok) return false;
    }
    await app.saveState();
    return true;
  }

  Future<AppExitResponse> _onExitRequested() async => await _confirmExit() ? AppExitResponse.exit : AppExitResponse.cancel;

  Future<void> _startup() async {
    BuildContext navigatorContext() => _navigator.currentContext!;
    app.showProfileSelector = () => showProfileSelector(navigatorContext());
    app.showCommandPalette = () => showCommandPalette(navigatorContext());
    app.showRenameDialog = (title, initial, onDone) async {
      final value = await showTextPrompt(navigatorContext(), title: title, initial: initial);
      if (value != null) onDone(value.trim());
    };
    app.confirmClosePinned = (tab) => showConfirm(
          navigatorContext(),
          title: '关闭固定的标签页？',
          message: tr('「{title}」已固定，确定要关闭吗？', {'title': tab.title}),
          confirm: '关闭',
          danger: true,
        );
    app.confirmMultilinePaste = (text) => showConfirm(
          navigatorContext(),
          title: '粘贴多行内容？',
          message: text.length > 2000 ? '${text.substring(0, 2000)}…' : text,
          confirm: '粘贴',
        );

    var restored = false;
    if (app.application['restoreTabs'] == true) restored = await app.restoreState();
    if (app.application['enableWelcomeTab'] == true) {
      app.openWelcome();
    }
    final cli = widget.cli;
    if (cli != null) {
      await _openFromCli(cli);
    } else if (!restored) {
      await app.newTab();
    }
    if (app.application['enableWelcomeTab'] == true) app.selectTab(0);

    final error = widget.configError;
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showConfirm(navigatorContext(), title: '配置文件有误', message: tr('{error}\n\n本次使用默认设置运行，原文件未被修改；修改设置时会先把原文件备份到同目录。', {'error': error}), confirm: '知道了');
      });
    }
  }

  Future<void> _openFromCli(CliRequest request) async {
    switch (request) {
      case OpenDirectory(:final path):
        await app.newTab(cwd: Directory(path).existsSync() ? Directory(path).absolute.path : '');
      case RunCommand(:final command, :final args):
        await app.newTab(profile: {
          'id': 'cli:run',
          'name': command.split(Platform.pathSeparator).last,
          'type': 'local',
          'behaviorOnSessionEnd': 'keep',
          'options': {'command': command, 'args': args, 'cwd': Directory.current.path, 'env': <List<String>>[]},
        });
      case OpenProfile(:final name):
        final found = app.profiles.where((profile) => (profile['name'] as String).toLowerCase() == name.toLowerCase()).firstOrNull;
        await app.newTab(profile: found);
        if (found == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final context = _navigator.currentContext;
            if (context != null) showConfirm(context, title: '找不到配置', message: tr('没有名为「{name}」的配置，已用默认配置打开。', {'name': name}), confirm: '知道了');
          });
        }
      case OpenSettings(:final page):
        if (app.tabs.isEmpty) await app.newTab();
        app.openSettings(page);
      case QuickConnect(:final target):
        await app.newTab(profile: parseQuickConnect(target.contains('@') || target.contains('.') ? target : 'ssh://$target'));
    }
  }

  Future<dynamic> _onWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'requestClose':
        if (await _confirmExit()) await WindowControl.close();
      case 'dropFiles':
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        var position = Offset((arguments['x'] as num).toDouble(), (arguments['y'] as num).toDouble());
        if (arguments['physical'] == true) {
          position = position / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
        }
        app.dropFiles(List<String>.from(arguments['paths'] as List), position);
      case 'fullScreenChanged':
        app.fullScreen = call.arguments == true;
        setState(() {});
    }
  }

  AppColors _colors() {
    // 每次重建时按设置同步界面语言（Rust 侧的提示语也随之切换）
    final language = resolveLanguage(app.application['language'] as String? ?? 'system');
    if (language != currentLanguage) {
      setLanguage(language);
      rust.setLanguage(code: language);
    }
    final theme = app.appearance['theme'] as String? ?? 'dark';
    if (theme == 'system') {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark ? AppColors.dark : AppColors.light;
    }
    return theme == 'light' ? AppColors.light : AppColors.dark;
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors();
    final zoom = ((app.appearance['zoom'] as num?) ?? 1).toDouble();
    return AppScope(
      state: app,
      child: AppTheme(
        colors: colors,
        child: MaterialApp(
          navigatorKey: _navigator,
          debugShowCheckedModeBanner: false,
          title: 'CTerminal',
          theme: materialTheme(colors),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(zoom)),
            child: child!,
          ),
          home: _PlatformMenus(child: _Workspace(colors: colors)),
        ),
      ),
    );
  }
}

/// macOS 菜单栏：不给编辑类菜单绑定 ⌘C / ⌘V，否则会抢在终端快捷键之前被系统吃掉
class _PlatformMenus extends StatelessWidget {
  const _PlatformMenus({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 用 defaultTargetPlatform：测试环境里宿主是 macOS，但没有原生菜单通道
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    final app = AppScope.read(context);
    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'CTerminal', menus: [
          if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about))
            const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
          PlatformMenuItemGroup(members: [
            PlatformMenuItem(label: tr('设置…'), onSelected: () => app.openSettings()),
          ]),
          const PlatformMenuItemGroup(members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
          ]),
          const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
        ]),
        PlatformMenu(label: tr('终端'), menus: [
          PlatformMenuItem(label: tr('新建标签页'), onSelected: () => app.newTab()),
          PlatformMenuItem(label: tr('选择配置…'), onSelected: () => app.showProfileSelector?.call()),
          PlatformMenuItem(label: tr('新建窗口'), onSelected: () => app.runAction('new-window')),
          PlatformMenuItem(label: tr('命令面板…'), onSelected: () => app.showCommandPalette?.call()),
        ]),
        PlatformMenu(label: tr('窗口'), menus: const [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
        ]),
      ],
      child: child,
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final location = app.appearance['tabsLocation'] as String? ?? 'top';
    final vertical = location == 'left' || location == 'right';
    final active = app.activeTab;

    // 所有标签页常驻（Offstage），切换时会话、滚动位置都保留
    final content = Stack(children: [
      for (final tab in app.tabs)
        Positioned.fill(
          key: ValueKey(tab.key),
          child: Offstage(
            offstage: tab != active,
            child: TickerMode(
              enabled: tab == active,
              child: switch (tab) {
                TerminalTab() => SplitView(tab: tab, visible: tab == active),
                SettingsTab() => SettingsPage(tab: tab),
                WelcomeTab() => WelcomePage(tab: tab),
              },
            ),
          ),
        ),
    ]);

    final tabBar = AppTabBar(vertical: vertical);
    Widget body;
    if (vertical) {
      body = Row(children: [
        if (location == 'left') tabBar,
        Expanded(child: content),
        if (location == 'right') tabBar,
      ]);
    } else if (location == 'bottom') {
      body = Column(children: [
        // 底部标签栏时标题栏区域留一条可拖动的空白给红绿灯
        if (Platform.isMacOS && !app.fullScreen)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => WindowControl.startDrag(),
            onDoubleTap: WindowControl.zoom,
            child: Container(height: 28, color: colors.chrome),
          ),
        Expanded(child: content),
        tabBar,
      ]);
    } else {
      body = Column(children: [tabBar, Expanded(child: content)]);
    }

    return Scaffold(
      // 透明：终端背景不透明度小于 1 时要能透出桌面，标签栏和设置页各自有底色
      backgroundColor: Colors.transparent,
      // 终端外（设置页等）也响应全局快捷键
      body: Focus(
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final action = app.actionFor(event);
            if (action == null) return KeyEventResult.ignored;
            // 设置页里的文本框自己处理复制粘贴
            if (app.activeTab is! TerminalTab && const {'copy', 'paste', 'select-all'}.contains(action)) {
              return KeyEventResult.ignored;
            }
            return app.runAction(action) ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: body,
        ),
    );
  }
}
