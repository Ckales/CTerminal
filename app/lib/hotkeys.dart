import 'dart:io';

import 'package:flutter/services.dart';
import 'i18n.dart';

/// 快捷键字符串格式："⌘-Shift-D"、"Ctrl-Tab"、"⌥-Left"、"⌘--"（⌘ 加减号）
class Hotkey {
  const Hotkey({required this.key, this.meta = false, this.ctrl = false, this.alt = false, this.shift = false});

  final String key;
  final bool meta;
  final bool ctrl;
  final bool alt;
  final bool shift;

  static Hotkey? parse(String text) {
    final tokens = <String>[];
    final parts = text.split('-');
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part.isEmpty) {
        // 连续的 "-" 表示减号键本身
        if (index + 1 < parts.length && parts[index + 1].isEmpty) {
          tokens.add('-');
          index++;
        }
        continue;
      }
      tokens.add(part);
    }
    if (tokens.isEmpty) return null;
    var meta = false, ctrl = false, alt = false, shift = false;
    for (final token in tokens.sublist(0, tokens.length - 1)) {
      switch (token) {
        case '⌘':
        case 'Cmd':
        case 'Meta':
          meta = true;
        case 'Ctrl':
          ctrl = true;
        case '⌥':
        case 'Alt':
        case 'Option':
          alt = true;
        case 'Shift':
          shift = true;
        default:
          return null;
      }
    }
    return Hotkey(key: tokens.last, meta: meta, ctrl: ctrl, alt: alt, shift: shift);
  }

  String format() {
    final mac = Platform.isMacOS;
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (meta) mac ? '⌘' : 'Meta',
      if (alt) mac ? '⌥' : 'Alt',
      if (shift) 'Shift',
      key,
    ];
    return parts.join('-');
  }

  /// 菜单里显示用：⌘⇧D
  String display() {
    if (!Platform.isMacOS) return format().replaceAll('-', '+');
    final symbol = {'Left': '←', 'Right': '→', 'Up': '↑', 'Down': '↓', 'Enter': '↩', 'Backspace': '⌫', 'Tab': '⇥', 'Escape': '⎋'};
    return '${ctrl ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${meta ? '⌘' : ''}${symbol[key] ?? key}';
  }

  @override
  bool operator ==(Object other) =>
      other is Hotkey && other.key == key && other.meta == meta && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, meta, ctrl, alt, shift);
}

final _physicalNames = <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.equal: '=',
  PhysicalKeyboardKey.minus: '-',
  PhysicalKeyboardKey.comma: ',',
  PhysicalKeyboardKey.period: '.',
  PhysicalKeyboardKey.slash: '/',
  PhysicalKeyboardKey.backslash: '\\',
  PhysicalKeyboardKey.semicolon: ';',
  PhysicalKeyboardKey.quote: "'",
  PhysicalKeyboardKey.bracketLeft: '[',
  PhysicalKeyboardKey.bracketRight: ']',
  PhysicalKeyboardKey.backquote: '`',
  PhysicalKeyboardKey.digit0: '0',
  PhysicalKeyboardKey.digit1: '1',
  PhysicalKeyboardKey.digit2: '2',
  PhysicalKeyboardKey.digit3: '3',
  PhysicalKeyboardKey.digit4: '4',
  PhysicalKeyboardKey.digit5: '5',
  PhysicalKeyboardKey.digit6: '6',
  PhysicalKeyboardKey.digit7: '7',
  PhysicalKeyboardKey.digit8: '8',
  PhysicalKeyboardKey.digit9: '9',
};

final _logicalNames = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.arrowLeft: 'Left',
  LogicalKeyboardKey.arrowRight: 'Right',
  LogicalKeyboardKey.arrowUp: 'Up',
  LogicalKeyboardKey.arrowDown: 'Down',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.space: 'Space',
  LogicalKeyboardKey.f1: 'F1',
  LogicalKeyboardKey.f2: 'F2',
  LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4',
  LogicalKeyboardKey.f5: 'F5',
  LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7',
  LogicalKeyboardKey.f8: 'F8',
  LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10',
  LogicalKeyboardKey.f11: 'F11',
  LogicalKeyboardKey.f12: 'F12',
};

final _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.capsLock,
  LogicalKeyboardKey.fn,
};

/// 按键名：数字和符号按物理键取（Shift 不改变它），字母按逻辑键取（兼容 Dvorak 等布局）
String? keyName(KeyEvent event) {
  if (_modifierKeys.contains(event.logicalKey)) return null;
  final named = _logicalNames[event.logicalKey];
  if (named != null) return named;
  final physical = _physicalNames[event.physicalKey];
  if (physical != null) return physical;
  final label = event.logicalKey.keyLabel;
  if (label.length == 1) return label.toUpperCase();
  return null;
}

Hotkey? hotkeyFromEvent(KeyEvent event) {
  final name = keyName(event);
  if (name == null) return null;
  final keyboard = HardwareKeyboard.instance;
  return Hotkey(
    key: name,
    meta: keyboard.isMetaPressed,
    ctrl: keyboard.isControlPressed,
    alt: keyboard.isAltPressed,
    shift: keyboard.isShiftPressed,
  );
}

/// 动作的显示名（已按界面语言翻译）
String actionName(String id) {
  if (id.startsWith('tab-')) return tr('切换到标签页 {n}', {'n': id.substring(4)});
  final pane = RegExp(r'^pane-nav-(\d)$').firstMatch(id);
  if (pane != null) return tr('聚焦第 {n} 个窗格', {'n': pane.group(1)});
  return tr(hotkeyActionNames[id] ?? id);
}

/// 每个配置可绑定一个快捷键直接打开，存在 hotkeys 里的 key 是 `profile:<配置 id>`
const profileHotkeyPrefix = 'profile:';

/// 动作 id → 中文名（设置页、命令面板用）
final hotkeyActionNames = <String, String>{
  'copy': '复制',
  'ctrl-c': '智能 Ctrl-C（有选区时复制，否则中断）',
  'copy-current-path': '复制当前路径',
  'paste': '粘贴',
  'clear': '清屏',
  'select-all': '全选',
  'zoom-in': '放大字号',
  'zoom-out': '缩小字号',
  'reset-zoom': '重置字号',
  'home': '光标到行首',
  'end': '光标到行尾',
  'previous-word': '光标前移一个单词',
  'next-word': '光标后移一个单词',
  'delete-previous-word': '删除前一个单词',
  'delete-line': '删除整行',
  'delete-next-word': '删除后一个单词',
  'search': '搜索',
  'pane-focus-all': '同时输入到所有窗格',
  'focus-all-tabs': '同时输入到所有标签页',
  'scroll-to-top': '滚动到顶部',
  'scroll-page-up': '向上翻页',
  'scroll-up': '向上滚动一行',
  'scroll-down': '向下滚动一行',
  'scroll-page-down': '向下翻页',
  'scroll-to-bottom': '滚动到底部',
  'settings': '打开设置',
  'new-tab': '新建标签页',
  'new-window': '新建窗口',
  'toggle-fullscreen': '切换全屏',
  'close-tab': '关闭标签页',
  'reopen-tab': '重新打开关闭的标签页',
  'rename-tab': '重命名标签页',
  'next-tab': '下一个标签页',
  'previous-tab': '上一个标签页',
  'toggle-last-tab': '切换到上一次的标签页',
  'pin-tab': '固定 / 取消固定标签页',
  'move-tab-left': '标签页左移',
  'move-tab-right': '标签页右移',
  'duplicate-tab': '复制标签页',
  'restart-tab': '重启会话',
  'restart-ssh-session': '重启 SSH 会话',
  'restart-telnet-session': '重启 Telnet 会话',
  'restart-serial-session': '重启串口会话',
  'reconnect-tab': '重新连接',
  'disconnect-tab': '断开连接',
  'open-sftp': '打开 SFTP 文件面板',
  'toggle-window': '显示 / 隐藏窗口（全局）',
  'explode-tab': '把窗格拆成独立标签页',
  'combine-tabs': '合并所有标签页为窗格',
  'split-right': '向右拆分',
  'split-bottom': '向下拆分',
  'split-left': '向左拆分',
  'split-top': '向上拆分',
  'pane-nav-right': '聚焦右侧窗格',
  'pane-nav-down': '聚焦下方窗格',
  'pane-nav-up': '聚焦上方窗格',
  'pane-nav-left': '聚焦左侧窗格',
  'pane-nav-previous': '聚焦上一个窗格',
  'pane-nav-next': '聚焦下一个窗格',
  for (var n = 1; n <= 9; n++) 'pane-nav-$n': '聚焦第 $n 个窗格',
  'pane-maximize': '最大化窗格',
  'close-pane': '关闭窗格',
  'pane-increase-vertical': '增加窗格高度',
  'pane-decrease-vertical': '减小窗格高度',
  'pane-increase-horizontal': '增加窗格宽度',
  'pane-decrease-horizontal': '减小窗格宽度',
  'profile-selector': '选择配置并新建标签页',
  'switch-profile': '切换当前标签页的配置',
  'command-selector': '命令面板',
  'serial': '新建串口连接',
  for (var n = 1; n <= 20; n++) 'tab-$n': '切换到标签页 $n',
};
