import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hotkeys.dart';
import 'i18n.dart';
import 'pane_tree.dart';
import 'src/rust/api/settings.dart' as rust;
import 'src/rust/api/terminal.dart';
import 'terminal/terminal_painter.dart';
import 'terminal/terminal_session.dart';
import 'window_control.dart';

int _tabCounter = 0;

sealed class AppTab {
  final String key = 'tab-${_tabCounter++}';
  String customTitle = '';
  String color = '';
  /// 固定的标签页排在最左、标签栏里只显示图标，“关闭其他”不会关掉它，单独关闭要确认
  bool pinned = false;

  String get title;
}

class TerminalTab extends AppTab {
  TerminalTab(TerminalSession first) : tree = PaneTree(first), focused = first;

  final PaneTree<TerminalSession> tree;
  TerminalSession focused;
  TerminalSession? maximized;
  /// 同时输入到所有窗格
  bool broadcast = false;

  List<TerminalSession> get sessions => tree.panes;

  @override
  String get title => customTitle.isNotEmpty ? customTitle : focused.title;
}

class SettingsTab extends AppTab {
  SettingsTab(this.page);
  String page;

  @override
  String get title => tr('设置');
}

class WelcomeTab extends AppTab {
  @override
  String get title => tr('欢迎');
}

/// 可以序列化进 state.json / 关闭栈的窗格布局
Map<String, dynamic> _serializeNode(PaneNode<TerminalSession> node) {
  switch (node) {
    case LeafNode<TerminalSession>():
      final session = node.pane;
      final cwd = session.started && session.profileType == 'local' ? termCwd(id: session.id) : session.cwd;
      return {'profile': session.profile, 'cwd': cwd};
    case SplitNode<TerminalSession>():
      return {
        'vertical': node.vertical,
        'ratios': node.ratios,
        'children': [for (final child in node.children) _serializeNode(child)],
      };
  }
}

class AppState extends ChangeNotifier {
  // 命名参数不能是私有名，所以不用 this._config
  // ignore: prefer_initializing_formals
  AppState({required Map<String, dynamic> config}) : _config = config {
    _rebuildDerived();
  }

  Map<String, dynamic> _config;
  Map<String, dynamic> get config => _config;
  List<Map<String, dynamic>> profiles = [];
  List<Map<String, dynamic>> colorSchemes = [];
  final List<AppTab> tabs = [];
  int activeIndex = 0;
  final List<Map<String, dynamic>> _closedTabs = [];
  Map<Hotkey, String> _hotkeys = {};
  double fontSizeDelta = 0;
  bool fullScreen = false;
  /// 选择器 / 面板等弹层由 shell 注册
  Future<void> Function()? showProfileSelector;
  Future<void> Function()? showCommandPalette;
  Future<void> Function(String title, String initial, void Function(String) onDone)? showRenameDialog;
  /// 关闭固定的标签页前确认，由界面层注册
  Future<bool> Function(AppTab tab)? confirmClosePinned;
  final ValueNotifier<int> searchRequest = ValueNotifier(0);
  /// 同时输入到所有标签页（每个标签页的当前窗格；开了窗格广播的标签页是它的所有窗格）
  bool broadcastAllTabs = false;
  /// toggle-last-tab 用：当前和上一次激活的标签页
  AppTab? _currentTab;
  AppTab? _lastTab;
  Timer? _saveStateTimer;

  AppTab? get activeTab => tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];
  TerminalSession? get activeSession {
    final tab = activeTab;
    return tab is TerminalTab ? tab.focused : null;
  }

  Map<String, dynamic> get terminal => _config['terminal'] as Map<String, dynamic>;
  Map<String, dynamic> get appearance => _config['appearance'] as Map<String, dynamic>;
  Map<String, dynamic> get application => _config['application'] as Map<String, dynamic>;

  TerminalMetrics? _metrics;
  TerminalMetrics get metrics {
    final size = ((terminal['fontSize'] as num).toDouble() + fontSizeDelta).clamp(6.0, 72.0);
    final ligatures = terminal['ligatures'] == true;
    final candidate = _metrics;
    if (candidate != null &&
        candidate.fontFamily == terminal['font'] &&
        candidate.fontSize == size &&
        candidate.lineHeight == (terminal['lineHeight'] as num).toDouble() &&
        candidate.ligatures == ligatures) {
      return candidate;
    }
    return _metrics = TerminalMetrics(
      fontFamily: terminal['font'] as String,
      fontSize: size,
      lineHeight: (terminal['lineHeight'] as num).toDouble(),
      ligatures: ligatures,
    );
  }

  void _rebuildDerived() {
    final map = <Hotkey, String>{};
    final hotkeys = (_config['hotkeys'] as Map<String, dynamic>);
    hotkeys.forEach((action, keys) {
      for (final key in (keys as List)) {
        final parsed = Hotkey.parse(key as String);
        if (parsed != null) map[parsed] = action;
      }
    });
    _hotkeys = map;
    _applyGlobalHotkey();
    colorSchemes = List<Map<String, dynamic>>.from(jsonDecode(rust.colorSchemes()) as List);
  }

  Hotkey? _globalHotkey;
  bool _globalHotkeyApplied = false;

  /// 只在绑定变化时重新注册，避免每次改设置都去动系统快捷键
  void _applyGlobalHotkey() {
    final keys = hotkeysFor('toggle-window');
    final next = keys.isEmpty ? null : keys.first;
    if (_globalHotkeyApplied && next == _globalHotkey) return;
    _globalHotkeyApplied = true;
    _globalHotkey = next;
    WindowControl.setGlobalHotkey(next);
  }

  Future<void> reloadProfiles() async {
    profiles = List<Map<String, dynamic>>.from(jsonDecode(await rust.profilesList()) as List);
    notifyListeners();
  }

  /// 修改配置：改动在 [edit] 里就地进行，保存后以 Rust 规范化的结果为准
  Future<void> updateConfig(void Function(Map<String, dynamic> config) edit) async {
    final draft = jsonDecode(jsonEncode(_config)) as Map<String, dynamic>;
    edit(draft);
    final saved = await rust.configSave(json: jsonEncode(draft));
    _config = jsonDecode(saved) as Map<String, dynamic>;
    _rebuildDerived();
    termApplySettings();
    await reloadProfiles();
    for (final tab in tabs) {
      if (tab is TerminalTab) {
        for (final session in tab.sessions) {
          session.refresh();
        }
      }
    }
    notifyListeners();
  }

  Future<void> replaceConfigJson(String json) async {
    final saved = await rust.configSave(json: json);
    _config = jsonDecode(saved) as Map<String, dynamic>;
    _rebuildDerived();
    termApplySettings();
    await reloadProfiles();
    notifyListeners();
  }

  // ---------- 标签页 ----------

  TerminalSession _newSession(Map<String, dynamic> profile, {String cwd = ''}) {
    final session = TerminalSession(profile: profile, cwd: cwd);
    session.onExit = _onSessionExit;
    session.onBell = _onBell;
    session.onTitle = (_) => notifyListeners();
    return session;
  }

  Future<Map<String, dynamic>> defaultProfile() async {
    return jsonDecode(await rust.defaultProfile()) as Map<String, dynamic>;
  }

  Future<void> newTab({Map<String, dynamic>? profile, String cwd = ''}) async {
    profile ??= await defaultProfile();
    _rememberRecent(profile);
    final tab = TerminalTab(_newSession(profile, cwd: cwd));
    tabs.insert(tabs.isEmpty ? 0 : activeIndex + 1, tab);
    activeIndex = tabs.indexOf(tab);
    _changed();
  }

  void _rememberRecent(Map<String, dynamic> profile) {
    final id = profile['id'] as String? ?? '';
    if (id.isEmpty || id.startsWith('quick:')) return;
    final recent = List<String>.from(_config['recentProfiles'] as List);
    recent.remove(id);
    recent.insert(0, id);
    if (recent.length > 5) recent.removeRange(5, recent.length);
    if (recent.join() == (_config['recentProfiles'] as List).join()) return;
    unawaited(updateConfig((config) => config['recentProfiles'] = recent));
  }

  void openSettings([String page = 'application']) {
    final existing = tabs.whereType<SettingsTab>().firstOrNull;
    if (existing != null) {
      existing.page = page;
      activeIndex = tabs.indexOf(existing);
    } else {
      tabs.insert(tabs.isEmpty ? 0 : activeIndex + 1, SettingsTab(page));
      activeIndex = tabs.indexWhere((tab) => tab is SettingsTab);
    }
    _changed();
  }

  void openWelcome() {
    tabs.insert(0, WelcomeTab());
    activeIndex = 0;
    _changed();
  }

  void selectTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    activeIndex = index;
    _changed();
  }

  void closeTab(AppTab tab) {
    final index = tabs.indexOf(tab);
    if (index < 0) return;
    if (tab is TerminalTab) {
      _closedTabs.add(_serializeNode(tab.tree.root));
      if (_closedTabs.length > 20) _closedTabs.removeAt(0);
      for (final session in tab.sessions) {
        session.dispose();
      }
    }
    tabs.removeAt(index);
    if (activeIndex >= tabs.length) activeIndex = tabs.length - 1;
    if (activeIndex > index) activeIndex--;
    if (activeIndex < 0) activeIndex = 0;
    _changed();
    if (tabs.isEmpty) {
      // 最后一个标签页关闭后退出
      saveState().then((_) => WindowControl.close());
    }
  }

  void closeOtherTabs(AppTab keep, {bool onlyRight = false, bool onlyLeft = false}) {
    final index = tabs.indexOf(keep);
    final victims = <AppTab>[];
    for (var i = 0; i < tabs.length; i++) {
      if (i == index || tabs[i].pinned) continue;
      if (onlyRight && i < index) continue;
      if (onlyLeft && i > index) continue;
      victims.add(tabs[i]);
    }
    for (final tab in victims) {
      closeTab(tab);
    }
    activeIndex = tabs.indexOf(keep);
    _changed();
  }

  /// 用户主动关闭标签页（快捷键、关闭按钮、中键、右键菜单）：固定的标签页先确认
  Future<void> requestCloseTab(AppTab tab) async {
    if (tab.pinned) {
      final confirmed = await confirmClosePinned?.call(tab) ?? true;
      if (!confirmed) return;
    }
    closeTab(tab);
  }

  /// 固定 / 取消固定：固定时排到已固定标签页的末尾，取消时排到未固定标签页的最前
  void togglePin(AppTab tab) {
    final active = activeTab;
    tab.pinned = !tab.pinned;
    tabs.remove(tab);
    tabs.insert(tabs.where((other) => other.pinned).length, tab);
    activeIndex = active == null ? 0 : tabs.indexOf(active);
    _changed();
  }

  void moveTab(int from, int to) {
    if (from == to || from < 0 || from >= tabs.length) return;
    final active = activeTab;
    final tab = tabs.removeAt(from);
    tabs.insert(to.clamp(0, tabs.length), tab);
    activeIndex = active == null ? 0 : tabs.indexOf(active);
    _changed();
  }

  Future<void> reopenClosedTab() async {
    if (_closedTabs.isEmpty) return;
    final layout = _closedTabs.removeLast();
    final tab = _restoreTab(layout);
    if (tab == null) return;
    tabs.insert(tabs.isEmpty ? 0 : activeIndex + 1, tab);
    activeIndex = tabs.indexOf(tab);
    _changed();
  }

  TerminalTab? _restoreTab(Map<String, dynamic> layout) {
    PaneNode<TerminalSession>? build(Map<String, dynamic> node) {
      if (node['profile'] is Map) {
        return LeafNode(_newSession(Map<String, dynamic>.from(node['profile'] as Map), cwd: node['cwd'] as String? ?? ''));
      }
      final children = <PaneNode<TerminalSession>>[];
      for (final child in (node['children'] as List? ?? [])) {
        final built = build(Map<String, dynamic>.from(child as Map));
        if (built != null) children.add(built);
      }
      if (children.isEmpty) return null;
      if (children.length == 1) return children.single;
      final ratios = [for (final ratio in (node['ratios'] as List? ?? [])) (ratio as num).toDouble()];
      return SplitNode(vertical: node['vertical'] == true, children: children, ratios: ratios.length == children.length ? ratios : null);
    }

    final root = build(layout);
    if (root == null) return null;
    final panes = <TerminalSession>[];
    void collect(PaneNode<TerminalSession> node) {
      if (node is LeafNode<TerminalSession>) panes.add(node.pane);
      if (node is SplitNode<TerminalSession>) node.children.forEach(collect);
    }

    collect(root);
    final tab = TerminalTab(panes.first);
    tab.tree.root = root;
    root.parent = null;
    return tab;
  }

  Future<void> duplicateTab(AppTab tab) async {
    if (tab is! TerminalTab) return;
    final restored = _restoreTab(_serializeNode(tab.tree.root));
    if (restored == null) return;
    restored.color = tab.color;
    tabs.insert(tabs.indexOf(tab) + 1, restored);
    activeIndex = tabs.indexOf(restored);
    _changed();
  }

  /// 把一个标签页里的窗格拆成独立标签页
  void explodeTab(TerminalTab tab) {
    final sessions = tab.sessions;
    if (sessions.length < 2) return;
    var index = tabs.indexOf(tab);
    tabs.removeAt(index);
    for (final session in sessions) {
      tabs.insert(index++, TerminalTab(session));
    }
    activeIndex = index - 1;
    _changed();
  }

  /// 把所有终端标签页合并到当前标签页，依次向右拆分
  void combineTabs() {
    final target = activeTab;
    if (target is! TerminalTab) return;
    final others = tabs.whereType<TerminalTab>().where((tab) => tab != target).toList();
    for (final tab in others) {
      final anchor = target.sessions.last;
      final node = tab.tree.root;
      final leaf = target.tree.leafOf(anchor)!;
      final parent = leaf.parent;
      final branch = SplitNode<TerminalSession>(vertical: false, children: [leaf, node]);
      if (parent == null) {
        target.tree.root = branch;
      } else {
        parent.children[parent.children.indexOf(leaf)] = branch;
        branch.parent = parent;
      }
      tabs.remove(tab);
    }
    activeIndex = tabs.indexOf(target);
    _changed();
  }

  // ---------- 窗格 ----------

  Future<void> split(SplitSide side, {TerminalTab? tab, Map<String, dynamic>? profile}) async {
    tab ??= activeTab is TerminalTab ? activeTab as TerminalTab : null;
    if (tab == null) return;
    final current = tab.focused;
    var cwd = '';
    if (current.started && current.profileType == 'local') cwd = termCwd(id: current.id);
    final session = _newSession(profile ?? current.profile, cwd: cwd);
    tab.tree.split(current, session, side);
    tab.maximized = null;
    tab.focused = session;
    _changed();
  }

  void focusPane(TerminalTab tab, TerminalSession session) {
    if (tab.focused == session) return;
    tab.focused = session;
    notifyListeners();
  }

  void closePane(TerminalTab tab, TerminalSession session) {
    final empty = tab.tree.remove(session);
    if (empty || tab.sessions.isEmpty) {
      closeTab(tab);
      return;
    }
    session.dispose();
    if (tab.maximized == session) tab.maximized = null;
    if (tab.focused == session) tab.focused = tab.sessions.first;
    _changed();
  }

  void _onSessionExit(TerminalSession session) {
    final tab = tabs.whereType<TerminalTab>().where((tab) => tab.sessions.contains(session)).firstOrNull;
    if (tab == null) return;
    final behavior = session.profile['behaviorOnSessionEnd'] as String? ?? 'auto';
    final clean = session.exitReason.isEmpty;
    switch (behavior) {
      case 'close':
        closePane(tab, session);
      case 'keep':
        notifyListeners();
      case 'reconnect':
        if (session.profileType != 'local') {
          Future.delayed(const Duration(seconds: 1), () {
            if (tab.sessions.contains(session) && session.exited) restartSession(session);
          });
        }
        notifyListeners();
      default:
        if (clean) {
          closePane(tab, session);
        } else {
          notifyListeners();
        }
    }
  }

  void _onBell(TerminalSession session) {
    if (terminal['bell'] == 'audible') SystemSound.play(SystemSoundType.alert);
  }

  void restartSession(TerminalSession session) {
    session.restart();
    notifyListeners();
  }

  // ---------- 快捷键与动作 ----------

  String? actionFor(KeyEvent event) {
    final hotkey = hotkeyFromEvent(event);
    if (hotkey == null) return null;
    return _hotkeys[hotkey];
  }

  List<Hotkey> hotkeysFor(String action) {
    final keys = (_config['hotkeys'] as Map<String, dynamic>)[action] as List? ?? [];
    return [for (final key in keys) Hotkey.parse(key as String)].whereType<Hotkey>().toList();
  }

  /// 终端里的文本编辑动作：发给 shell 的固定序列（Readline / zle 通用）
  static const _editSequences = <String, String>{
    'home': '\x1bOH',
    'end': '\x1bOF',
    'previous-word': '\x1bb',
    'next-word': '\x1bf',
    'delete-previous-word': '\x1b\x7f',
    'delete-next-word': '\x1bd',
    'delete-line': '\x15',
  };

  /// 执行动作，返回是否处理
  bool runAction(String action) {
    final tab = activeTab;
    final session = activeSession;
    final sequence = _editSequences[action];
    if (sequence != null) {
      if (session == null || !session.started) return false;
      sendInput(utf8.encode(sequence));
      return true;
    }
    if (action.startsWith('tab-')) {
      final index = int.tryParse(action.substring(4));
      if (index != null) selectTab(index - 1);
      return true;
    }
    if (action.startsWith(profileHotkeyPrefix)) {
      final id = action.substring(profileHotkeyPrefix.length);
      final profile = profiles.where((profile) => profile['id'] == id).firstOrNull;
      if (profile == null) return false;
      newTab(profile: profile);
      return true;
    }
    final paneNumber = RegExp(r'^pane-nav-(\d)$').firstMatch(action);
    if (paneNumber != null) {
      if (tab is! TerminalTab) return false;
      final index = int.parse(paneNumber.group(1)!) - 1;
      if (index >= tab.sessions.length) return false;
      focusPane(tab, tab.sessions[index]);
      return true;
    }
    switch (action) {
      case 'new-tab':
        newTab();
      case 'new-window':
        WindowControl.newWindow();
      case 'settings':
        openSettings();
      case 'close-tab':
        if (tab != null) requestCloseTab(tab);
      case 'pin-tab':
        if (tab != null) togglePin(tab);
      case 'toggle-last-tab':
        final last = _lastTab;
        if (last == null || !tabs.contains(last)) return false;
        selectTab(tabs.indexOf(last));
      case 'reopen-tab':
        reopenClosedTab();
      case 'rename-tab':
        if (tab != null) {
          showRenameDialog?.call('重命名标签页', tab.customTitle.isNotEmpty ? tab.customTitle : tab.title, (value) {
            tab.customTitle = value;
            _changed();
          });
        }
      case 'next-tab':
        if (tabs.isNotEmpty) selectTab((activeIndex + 1) % tabs.length);
      case 'previous-tab':
        if (tabs.isNotEmpty) selectTab((activeIndex - 1 + tabs.length) % tabs.length);
      case 'move-tab-left':
        moveTab(activeIndex, activeIndex - 1);
      case 'move-tab-right':
        moveTab(activeIndex, activeIndex + 1);
      case 'duplicate-tab':
        if (tab != null) duplicateTab(tab);
      case 'explode-tab':
        if (tab is TerminalTab) explodeTab(tab);
      case 'combine-tabs':
        combineTabs();
      case 'toggle-fullscreen':
        WindowControl.toggleFullScreen();
      case 'profile-selector':
        showProfileSelector?.call();
      case 'command-selector':
        showCommandPalette?.call();
      case 'zoom-in':
        fontSizeDelta += 1;
        notifyListeners();
      case 'zoom-out':
        fontSizeDelta -= 1;
        notifyListeners();
      case 'reset-zoom':
        fontSizeDelta = 0;
        notifyListeners();
      case 'split-right':
        split(SplitSide.right);
      case 'split-bottom':
        split(SplitSide.bottom);
      case 'split-left':
        split(SplitSide.left);
      case 'split-top':
        split(SplitSide.top);
      case 'pane-nav-right' || 'pane-nav-left' || 'pane-nav-up' || 'pane-nav-down':
        if (tab is TerminalTab) {
          final side = switch (action) {
            'pane-nav-right' => SplitSide.right,
            'pane-nav-left' => SplitSide.left,
            'pane-nav-up' => SplitSide.top,
            _ => SplitSide.bottom,
          };
          final target = tab.tree.neighbor(tab.focused, side);
          if (target != null) focusPane(tab, target);
        }
      case 'pane-nav-next' || 'pane-nav-previous':
        if (tab is TerminalTab) {
          final panes = tab.sessions;
          final step = action == 'pane-nav-next' ? 1 : -1;
          focusPane(tab, panes[(panes.indexOf(tab.focused) + step + panes.length) % panes.length]);
        }
      case 'pane-maximize':
        if (tab is TerminalTab && tab.sessions.length > 1) {
          tab.maximized = tab.maximized == null ? tab.focused : null;
          notifyListeners();
        }
      case 'close-pane':
        if (tab is TerminalTab) closePane(tab, tab.focused);
      case 'pane-increase-vertical' || 'pane-decrease-vertical' || 'pane-increase-horizontal' || 'pane-decrease-horizontal':
        if (tab is TerminalTab) {
          tab.tree.resize(tab.focused, vertical: action.contains('vertical'), delta: action.contains('increase') ? 0.05 : -0.05);
          _changed();
        }
      case 'pane-focus-all':
        if (tab is TerminalTab) {
          tab.broadcast = !tab.broadcast;
          notifyListeners();
        }
      case 'focus-all-tabs':
        broadcastAllTabs = !broadcastAllTabs;
        notifyListeners();
      case 'restart-tab' || 'reconnect-tab':
        if (session != null) restartSession(session);
      case 'restart-ssh-session' || 'restart-telnet-session' || 'restart-serial-session':
        // 只重启对应类型的会话：restart-ssh-session → ssh
        final type = action.split('-')[1];
        if (session == null || session.profileType != type) return false;
        restartSession(session);
      case 'open-sftp':
        if (session == null || session.profileType != 'ssh') return false;
        session.sftpVisible = !session.sftpVisible;
        notifyListeners();
      case 'disconnect-tab':
        if (session != null && session.started) termClose(id: session.id);
      case 'serial':
        showProfileSelector?.call();
      case 'copy':
        if (session == null || !session.started) return false;
        final text = termSelectionText(id: session.id);
        if (text == null) return false;
        Clipboard.setData(ClipboardData(text: text));
      case 'ctrl-c':
        if (session == null || !session.started) return false;
        final text = termSelectionText(id: session.id);
        if (text == null) {
          sendInput(const [0x03]);
          return true;
        }
        Clipboard.setData(ClipboardData(text: text));
        termSelectClear(id: session.id);
        session.refresh();
      case 'copy-current-path':
        if (session == null || !session.started) return false;
        final path = termCwd(id: session.id);
        if (path.isEmpty) return false;
        Clipboard.setData(ClipboardData(text: path));
      case 'paste':
        if (session == null || !session.started) return false;
        pasteClipboard();
      case 'select-all':
        if (session == null || !session.started) return false;
        termSelectAll(id: session.id);
        session.refresh();
      case 'clear':
        if (session == null || !session.started) return false;
        termClear(id: session.id);
      case 'search':
        if (session == null) return false;
        searchRequest.value++;
      case 'scroll-to-top' || 'scroll-to-bottom' || 'scroll-page-up' || 'scroll-page-down' || 'scroll-up' || 'scroll-down':
        if (session == null || !session.started) return false;
        termScrollTo(id: session.id, target: action.substring('scroll-'.length).replaceFirst('to-', ''));
        session.refresh();
      default:
        return false;
    }
    return true;
  }

  /// 当前窗格（广播模式下为标签页里所有窗格，所有标签页广播时再加上其他标签页）
  List<TerminalSession> inputTargets() {
    final tab = activeTab;
    if (tab is! TerminalTab) return [];
    if (broadcastAllTabs) {
      final targets = <TerminalSession>[];
      for (final other in tabs.whereType<TerminalTab>()) {
        final panes = other.broadcast ? other.sessions : [other.focused];
        for (final session in panes) {
          if (session.started && !session.exited) targets.add(session);
        }
      }
      return targets;
    }
    if (tab.broadcast) return tab.sessions.where((session) => session.started && !session.exited).toList();
    return [tab.focused];
  }

  void sendInput(List<int> data) {
    for (final session in inputTargets()) {
      termInput(id: session.id, data: data);
    }
  }

  /// 各窗格在窗口中的位置（由 TerminalView 注册），拖放文件时找落点
  final Map<TerminalSession, Rect? Function()> paneLocators = {};
  /// 优先于窗格的拖放目标（SFTP 面板：拖进去就上传）
  final Map<Object, (Rect? Function(), void Function(List<String> paths))> dropTargets = {};

  /// 拖文件进窗口：把路径按目标 shell 的写法转义后粘贴到落点所在窗格
  void dropFiles(List<String> paths, Offset position) {
    for (final (locate, accept) in dropTargets.values) {
      final rect = locate();
      if (rect != null && rect.contains(position)) {
        accept(paths);
        return;
      }
    }
    final tab = activeTab;
    if (tab is! TerminalTab || paths.isEmpty) return;
    var target = tab.focused;
    for (final session in tab.sessions) {
      final rect = paneLocators[session]?.call();
      if (rect != null && rect.contains(position)) target = session;
    }
    if (!target.started) return;
    focusPane(tab, target);
    final profile = jsonEncode(target.profile);
    final text = paths.map((path) => rust.shellPath(path: path, profileJson: profile)).join(' ');
    termPaste(id: target.id, text: '$text ');
  }

  /// 多行粘贴确认由界面层（有 context 的地方）实现
  Future<bool> Function(String text)? confirmMultilinePaste;

  Future<void> pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (terminal['warnOnMultilinePaste'] == true && text.trimRight().contains('\n')) {
      final confirmed = await confirmMultilinePaste?.call(text) ?? true;
      if (!confirmed) return;
    }
    for (final session in inputTargets()) {
      termPaste(id: session.id, text: text);
    }
  }

  // ---------- 状态保存 / 恢复 ----------

  void _changed() {
    _keepPinnedFirst();
    _trackActiveTab();
    notifyListeners();
    _saveStateTimer?.cancel();
    _saveStateTimer = Timer(const Duration(seconds: 1), saveState);
  }

  /// 各处插入 / 拖动标签页后统一归位：固定的在前（保持各自相对顺序），当前标签页不变
  void _keepPinnedFirst() {
    final pinned = tabs.where((tab) => tab.pinned).toList();
    if (pinned.isEmpty) return;
    final ordered = [...pinned, ...tabs.where((tab) => !tab.pinned)];
    var same = true;
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i] != ordered[i]) same = false;
    }
    if (same) return;
    final active = activeTab;
    tabs
      ..clear()
      ..addAll(ordered);
    activeIndex = active == null ? 0 : tabs.indexOf(active);
  }

  void _trackActiveTab() {
    final active = activeTab;
    if (active == _currentTab) return;
    _lastTab = _currentTab;
    _currentTab = active;
  }

  Future<void> saveState() async {
    final layouts = [
      for (final tab in tabs)
        if (tab is TerminalTab) {'layout': _serializeNode(tab.tree.root), 'title': tab.customTitle, 'color': tab.color, 'pinned': tab.pinned},
    ];
    await rust.stateSave(json: jsonEncode({'tabs': layouts}));
  }

  Future<bool> restoreState() async {
    final raw = await rust.stateLoad();
    if (raw.isEmpty) return false;
    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in (state['tabs'] as List? ?? [])) {
        final map = Map<String, dynamic>.from(entry as Map);
        final tab = _restoreTab(Map<String, dynamic>.from(map['layout'] as Map));
        if (tab == null) continue;
        tab.customTitle = map['title'] as String? ?? '';
        tab.color = map['color'] as String? ?? '';
        tab.pinned = map['pinned'] == true;
        tabs.add(tab);
      }
    } on FormatException catch (error) {
      debugPrint('state.json 无法解析，忽略恢复：$error');
      return false;
    }
    activeIndex = 0;
    notifyListeners();
    return tabs.isNotEmpty;
  }

  bool get hasRunningSessions =>
      tabs.whereType<TerminalTab>().any((tab) => tab.sessions.any((session) => session.started && !session.exited));

  void setTabColor(AppTab tab, String color) {
    tab.color = color;
    _changed();
  }

  @override
  void dispose() {
    _saveStateTimer?.cancel();
    for (final tab in tabs) {
      if (tab is TerminalTab) {
        for (final session in tab.sessions) {
          session.dispose();
        }
      }
    }
    searchRequest.dispose();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
