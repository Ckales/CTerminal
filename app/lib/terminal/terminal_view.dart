import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../src/rust/api/terminal.dart';
import '../theme.dart';
import 'terminal_painter.dart';
import 'terminal_session.dart';
import '../i18n.dart';

const _mods = (shift: 1, alt: 2, ctrl: 4, meta: 8);

int currentMods() {
  final keyboard = HardwareKeyboard.instance;
  var mods = 0;
  if (keyboard.isShiftPressed) mods |= _mods.shift;
  if (keyboard.isAltPressed) mods |= _mods.alt;
  if (keyboard.isControlPressed) mods |= _mods.ctrl;
  if (keyboard.isMetaPressed) mods |= _mods.meta;
  return mods;
}

/// 需要走按键编码（而不是文本输入）的键
final _specialKeys = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.insert: 'Insert',
  LogicalKeyboardKey.delete: 'Delete',
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

/// Ctrl 组合用的基础键：字母取逻辑键，符号取物理键
String? _controlBase(KeyEvent event) {
  final label = event.logicalKey.keyLabel;
  if (label.length == 1 && RegExp(r'[A-Za-z]').hasMatch(label)) return label.toLowerCase();
  final physical = <PhysicalKeyboardKey, String>{
    PhysicalKeyboardKey.bracketLeft: '[',
    PhysicalKeyboardKey.bracketRight: ']',
    PhysicalKeyboardKey.backslash: '\\',
    PhysicalKeyboardKey.space: ' ',
    PhysicalKeyboardKey.digit2: '2',
    PhysicalKeyboardKey.digit3: '3',
    PhysicalKeyboardKey.digit4: '4',
    PhysicalKeyboardKey.digit5: '5',
    PhysicalKeyboardKey.digit6: '6',
    PhysicalKeyboardKey.digit7: '7',
    PhysicalKeyboardKey.digit8: '8',
    PhysicalKeyboardKey.minus: '-',
    PhysicalKeyboardKey.slash: '?',
  };
  return physical[event.physicalKey];
}

final _urlPattern = RegExp(r'''(https?|ftp|file)://[^\s<>"'`]+|www\.[^\s<>"'`]+''');

void openExternal(String url) {
  if (!url.contains('://')) url = 'https://$url';
  if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else if (Platform.isWindows) {
    Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else {
    Process.run('xdg-open', [url]);
  }
}

class TerminalView extends StatefulWidget {
  const TerminalView({super.key, required this.session, required this.tab, required this.active});

  final TerminalSession session;
  final TerminalTab tab;
  /// 所在标签页是当前标签页、且本窗格是焦点窗格
  final bool active;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> with DeltaTextInputClient {
  final FocusNode _focus = FocusNode(debugLabel: 'terminal');
  final ParagraphCache _cache = ParagraphCache();
  TextInputConnection? _input;
  TextEditingValue _editing = TextEditingValue.empty;
  String _composing = '';
  Timer? _blink;
  bool _cursorOn = true;
  Size _lastSize = Size.zero;
  TermSize? _termSize;

  // 鼠标
  int _clickCount = 0;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastClickPosition = Offset.zero;
  bool _selecting = false;
  bool _reporting = false;
  int _pressedButton = 3;
  double _scrollRemainder = 0;
  bool _hovering = false;

  // 搜索
  bool _searchOpen = false;
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'terminal-search');
  bool _searchCase = false;
  bool _searchRegex = false;
  bool _searchWord = false;
  bool _searchMiss = false;

  double _bellFlash = 0;
  AppState? _app;

  TerminalSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    session.addListener(_onFrame);
    session.bells.addListener(_onBell);
    _restartBlink();
  }

  void _onBell() {
    if (_app?.terminal['bell'] == 'visual') flashBell();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    if (_app != app) {
      _app?.searchRequest.removeListener(_onSearchRequest);
      _app?.paneLocators.remove(session);
      app.searchRequest.addListener(_onSearchRequest);
      app.paneLocators[session] = _globalRect;
      _app = app;
    }
    _syncFocus();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != session) {
      _app?.paneLocators.remove(oldWidget.session);
      _app?.paneLocators[session] = _globalRect;
      oldWidget.session.removeListener(_onFrame);
      oldWidget.session.bells.removeListener(_onBell);
      session.addListener(_onFrame);
      session.bells.addListener(_onBell);
    }
    _syncFocus();
  }

  void _syncFocus() {
    if (widget.active && !_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active && !_focus.hasFocus && !_searchOpen) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _blink?.cancel();
    _input?.close();
    _app?.searchRequest.removeListener(_onSearchRequest);
    if (_app?.paneLocators[session] == _globalRect) _app?.paneLocators.remove(session);
    session.removeListener(_onFrame);
    session.bells.removeListener(_onBell);
    _focus.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _cache.clear();
    super.dispose();
  }

  Rect? _globalRect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _onSearchRequest() {
    if (!widget.active) return;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
      _searchText.selection = TextSelection(baseOffset: 0, extentOffset: _searchText.text.length);
    });
  }

  void _onFrame() {
    if (_focus.hasFocus) _updateImeRect();
    if (session.exited && mounted) setState(() {});
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _attachInput();
      if (!widget.active) AppScope.read(context).focusPane(widget.tab, session);
    } else {
      _input?.close();
      _input = null;
      _composing = '';
    }
    _restartBlink();
    setState(() {});
  }

  void _restartBlink() {
    _blink?.cancel();
    _cursorOn = true;
    final app = _app;
    if (app != null && app.terminal['cursorBlink'] != true) return;
    _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
      if (!mounted || !_focus.hasFocus) return;
      setState(() => _cursorOn = !_cursorOn);
    });
  }

  // ---------- 文本输入 / 输入法 ----------

  void _attachInput() {
    if (_input != null && _input!.attached) return;
    _input = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        enableInteractiveSelection: false,
        // 增量模式：每个增量自带变更前的文本，提交内容不依赖本地副本，
        // 重置输入状态时就不会因为和平台的状态不同步而重复发送字符
        enableDeltaModel: true,
      ),
    );
    _editing = TextEditingValue.empty;
    _input!.setEditingState(_editing);
    _input!.show();
    _updateImeRect();
  }

  void _updateImeRect() {
    final input = _input;
    final frame = session.frame;
    final box = context.findRenderObject() as RenderBox?;
    if (input == null || !input.attached || frame == null || box == null || !box.hasSize) return;
    final metrics = AppScope.read(context).metrics;
    final padding = _padding;
    input.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
    final caret = Rect.fromLTWH(
      padding + frame.cursorCol * metrics.cellWidth,
      padding + frame.cursorRow * metrics.cellHeight,
      metrics.cellWidth,
      metrics.cellHeight,
    );
    input.setCaretRect(caret);
    input.setComposingRect(caret);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _editing;

  @override
  AutofillScope? get currentAutofillScope => null;

  bool _wasComposing = false;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    var composing = '';
    final commit = <int>[];
    for (final delta in deltas) {
      final next = delta.apply(TextEditingValue(text: delta.oldText));
      if (delta.composing.isValid && !delta.composing.isCollapsed) {
        composing = delta.composing.textInside(next.text);
        _wasComposing = true;
        continue;
      }
      composing = '';
      switch (delta) {
        case TextEditingDeltaInsertion():
          commit.addAll(utf8.encode(delta.textInserted));
        case TextEditingDeltaReplacement():
          // 不在组合输入中的替换（如长按选重音字母）改的是已经发出去的字符，先退格删掉
          if (!_wasComposing) {
            final replaced = delta.replacedRange.textInside(delta.oldText).runes.length;
            commit.addAll(List.filled(replaced, 0x7f));
          }
          commit.addAll(utf8.encode(delta.replacementText));
        default:
          break;
      }
      _wasComposing = false;
    }
    setState(() => _composing = composing);
    if (commit.isNotEmpty) _sendBytes(commit);
    if (composing.isEmpty) {
      _editing = TextEditingValue.empty;
      _input?.setEditingState(_editing);
    }
  }

  void _sendBytes(List<int> bytes) {
    final app = AppScope.read(context);
    _restartBlink();
    for (final target in app.inputTargets()) {
      termInput(id: target.id, data: bytes);
    }
  }

  /// 非增量模式的平台（和测试里的 enterText）走这里
  @override
  void updateEditingValue(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _editing = value;
      setState(() => _composing = composing.textInside(value.text));
      return;
    }
    final text = value.text;
    _composing = '';
    if (text.isNotEmpty) _sendText(text);
    _editing = TextEditingValue.empty;
    _input?.setEditingState(_editing);
    setState(() {});
  }

  void _sendText(String text) {
    final app = AppScope.read(context);
    _restartBlink();
    for (final target in app.inputTargets()) {
      termKey(id: target.id, key: '', text: text, mods: 0, altIsMeta: false);
    }
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {
    _input = null;
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  // 以下来自 TextInputClient 的默认实现：用增量模式混入时需要显式给出
  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}

  // ---------- 键盘 ----------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_composing.isNotEmpty) return KeyEventResult.ignored;
    final app = AppScope.read(context);

    if (!session.started) return KeyEventResult.ignored;
    if (session.exited) {
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        _restart();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        app.closePane(widget.tab, session);
        return KeyEventResult.handled;
      }
    }

    final action = app.actionFor(event);
    if (action != null) {
      // 绑定了快捷键的组合一律吞掉（例如没有选区时的 ⌘C），否则会落到系统产生提示音
      app.runAction(action);
      return KeyEventResult.handled;
    }

    final mods = currentMods();
    final altIsMeta = app.terminal['altIsMeta'] == true || !Platform.isMacOS;
    final special = _specialKeys[event.logicalKey];
    String? key;
    var text = '';
    if (special != null) {
      key = special;
    } else if (mods & _mods.meta != 0) {
      return KeyEventResult.ignored;
    } else if (mods & _mods.ctrl != 0) {
      key = _controlBase(event);
    } else if (mods & _mods.alt != 0 && altIsMeta) {
      final label = event.logicalKey.keyLabel;
      key = label.length == 1 ? label.toLowerCase() : null;
      text = event.character ?? '';
    }
    if (key == null) return KeyEventResult.ignored;

    var handled = false;
    for (final target in app.inputTargets()) {
      handled = termKey(id: target.id, key: key, text: text, mods: mods, altIsMeta: altIsMeta) || handled;
    }
    if (handled) _restartBlink();
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _restart() {
    session.restart();
    setState(() {});
  }

  // ---------- 尺寸 ----------

  double get _padding => ((_app?.terminal['padding'] as num?) ?? 8).toDouble();

  void _layout(Size size, TerminalMetrics metrics) {
    if (size == _lastSize && _termSize != null && session.started) return;
    _lastSize = size;
    final padding = _padding;
    final cols = ((size.width - padding * 2) / metrics.cellWidth).floor().clamp(2, 1000);
    final rows = ((size.height - padding * 2) / metrics.cellHeight).floor().clamp(1, 1000);
    final termSize = TermSize(
      cols: cols,
      rows: rows,
      cellWidth: metrics.cellWidth.round(),
      cellHeight: metrics.cellHeight.round(),
    );
    final previous = _termSize;
    _termSize = termSize;
    if (!session.started) {
      session.start(termSize);
      return;
    }
    if (previous == null || previous.cols != cols || previous.rows != rows) {
      session.resize(termSize);
    }
  }

  // ---------- 鼠标 ----------

  ({int col, int row, bool right}) _cellAt(Offset position) {
    final metrics = AppScope.read(context).metrics;
    final frame = session.frame;
    final x = (position.dx - _padding) / metrics.cellWidth;
    final y = (position.dy - _padding) / metrics.cellHeight;
    final maxCol = (frame?.cols ?? 1) - 1;
    final maxRow = (frame?.rows ?? 1) - 1;
    return (col: x.floor().clamp(0, maxCol), row: y.floor().clamp(0, maxRow), right: x - x.floor() > 0.5);
  }

  int _buttonOf(PointerEvent event) {
    if (event.buttons & kSecondaryMouseButton != 0) return 2;
    if (event.buttons & kMiddleMouseButton != 0) return 1;
    return 0;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!session.started) return;
    _focus.requestFocus();
    final app = AppScope.read(context);
    final cell = _cellAt(event.localPosition);
    final mods = currentMods();
    final button = _buttonOf(event);
    _pressedButton = button;

    final frame = session.frame;
    if (frame != null && frame.mouseReporting && mods & _mods.shift == 0) {
      _reporting = termMouse(id: session.id, action: 0, button: button, col: cell.col, row: cell.row, mods: mods);
      if (_reporting) return;
    }

    if (button == 2) {
      _onRightClick(event.position, app);
      return;
    }
    if (button == 1) {
      if (app.terminal['pasteOnMiddleClick'] == true) app.pasteClipboard();
      return;
    }

    if (mods & (Platform.isMacOS ? _mods.meta : _mods.ctrl) != 0 && _openLinkAt(cell.col, cell.row)) return;

    final now = DateTime.now();
    final near = (event.localPosition - _lastClickPosition).distance < 6;
    _clickCount = now.difference(_lastClick) < const Duration(milliseconds: 400) && near ? _clickCount % 3 + 1 : 1;
    _lastClick = now;
    _lastClickPosition = event.localPosition;

    if (mods & _mods.shift != 0 && _clickCount == 1 && termSelectionText(id: session.id) != null) {
      termSelectUpdate(id: session.id, col: cell.col, row: cell.row, rightHalf: cell.right);
    } else {
      final kind = mods & _mods.alt != 0 ? 3 : _clickCount - 1;
      termSelectStart(id: session.id, col: cell.col, row: cell.row, rightHalf: cell.right, kind: kind);
      if (_clickCount > 1) termSelectUpdate(id: session.id, col: cell.col, row: cell.row, rightHalf: cell.right);
    }
    _selecting = true;
    session.refresh();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!session.started) return;
    final cell = _cellAt(event.localPosition);
    if (_reporting) {
      termMouse(id: session.id, action: 2, button: _pressedButton, col: cell.col, row: cell.row, mods: currentMods());
      return;
    }
    if (_selecting) {
      termSelectUpdate(id: session.id, col: cell.col, row: cell.row, rightHalf: cell.right);
      // 拖出上下边缘时滚动回看
      final box = context.size;
      if (box != null) {
        if (event.localPosition.dy < 0) termScroll(id: session.id, lines: 1, col: cell.col, row: 0);
        if (event.localPosition.dy > box.height) termScroll(id: session.id, lines: -1, col: cell.col, row: cell.row);
      }
      session.refresh();
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    final frame = session.frame;
    if (!session.started || frame == null || !frame.mouseReporting) return;
    final cell = _cellAt(event.localPosition);
    termMouse(id: session.id, action: 2, button: 3, col: cell.col, row: cell.row, mods: currentMods());
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!session.started) return;
    final cell = _cellAt(event.localPosition);
    if (_reporting) {
      termMouse(id: session.id, action: 1, button: _pressedButton, col: cell.col, row: cell.row, mods: currentMods());
      _reporting = false;
      return;
    }
    if (_selecting) {
      _selecting = false;
      final app = AppScope.read(context);
      if (app.terminal['copyOnSelect'] == true) {
        final text = termSelectionText(id: session.id);
        if (text != null) Clipboard.setData(ClipboardData(text: text));
      }
    }
  }

  void _scrollBy(double dy, Offset position) {
    if (!session.started) return;
    final metrics = AppScope.read(context).metrics;
    _scrollRemainder += -dy / metrics.cellHeight;
    final lines = _scrollRemainder.truncate();
    if (lines == 0) return;
    _scrollRemainder -= lines;
    final cell = _cellAt(position);
    termScroll(id: session.id, lines: lines, col: cell.col, row: cell.row);
    session.refresh();
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) _scrollBy(event.scrollDelta.dy, event.localPosition);
  }

  bool _openLinkAt(int col, int row) {
    final text = _lineWithColumns(row);
    if (text == null) return false;
    for (final match in _urlPattern.allMatches(text.text)) {
      final start = text.columns[match.start];
      final end = text.columns[match.end - 1];
      if (col >= start && col <= end) {
        openExternal(match.group(0)!.replaceAll(RegExp(r'[.,;:!?)\]]+$'), ''));
        return true;
      }
    }
    return false;
  }

  /// 由帧重建一行文本，并记录每个字符所在的列（宽字符占两列时文本下标与列号不一致）
  ({String text, List<int> columns})? _lineWithColumns(int row) {
    final frame = session.frame;
    if (frame == null || row >= frame.lines.length) return null;
    final buffer = StringBuffer();
    final columns = <int>[];
    for (final run in frame.lines[row].runs) {
      if (run.width == run.text.length) {
        for (var i = 0; i < run.text.length; i++) {
          buffer.write(run.text[i]);
          columns.add(run.col + i);
        }
      } else {
        for (final unit in run.text.codeUnits) {
          buffer.writeCharCode(unit);
          columns.add(run.col);
        }
      }
    }
    return (text: buffer.toString(), columns: columns);
  }

  Future<void> _onRightClick(Offset globalPosition, AppState app) async {
    final mode = app.terminal['rightClick'] as String? ?? 'menu';
    final selection = termSelectionText(id: session.id);
    if (mode == 'paste') {
      app.pasteClipboard();
      return;
    }
    if (mode == 'clipboard') {
      if (selection != null) {
        Clipboard.setData(ClipboardData(text: selection));
        termSelectClear(id: session.id);
        session.refresh();
      } else {
        app.pasteClipboard();
      }
      return;
    }
    final colors = AppTheme.of(context);
    String shortcut(String action) {
      final keys = app.hotkeysFor(action);
      return keys.isEmpty ? '' : keys.first.display();
    }

    PopupMenuItem<String> item(String value, String label, {bool enabled = true}) => PopupMenuItem(
          value: value,
          enabled: enabled,
          height: 30,
          child: Row(children: [
            Expanded(child: Text(tr(label), style: TextStyle(fontSize: 13, color: enabled ? colors.text : colors.textDim))),
            Text(shortcut(value), style: TextStyle(fontSize: 12, color: colors.textDim)),
          ]),
        );
    final remote = session.profileType != 'local';
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPosition.dx, globalPosition.dy, globalPosition.dx, globalPosition.dy),
      items: [
        item('copy', '复制', enabled: selection != null),
        item('paste', '粘贴'),
        item('select-all', '全选'),
        item('clear', '清屏'),
        const PopupMenuDivider(height: 8),
        item('split-right', '向右拆分'),
        item('split-bottom', '向下拆分'),
        item('split-left', '向左拆分'),
        item('split-top', '向上拆分'),
        const PopupMenuDivider(height: 8),
        item('search', '搜索'),
        item('duplicate-tab', '复制标签页'),
        item(remote ? 'reconnect-tab' : 'restart-tab', remote ? '重新连接' : '重启会话'),
        item('close-pane', '关闭窗格'),
      ],
    );
    if (chosen == null || !mounted) return;
    app.focusPane(widget.tab, session);
    app.runAction(chosen);
  }

  // ---------- 搜索 ----------

  String _searchPattern() {
    var pattern = _searchText.text;
    if (!_searchRegex) pattern = RegExp.escape(pattern);
    if (_searchWord) pattern = '\\b$pattern\\b';
    if (!_searchCase) pattern = '(?i)$pattern';
    return pattern;
  }

  void _search({required bool backwards}) {
    if (!session.started) return;
    if (_searchText.text.isEmpty) {
      termSearchClear(id: session.id);
      session.refresh();
      setState(() => _searchMiss = false);
      return;
    }
    try {
      final found = termSearch(id: session.id, pattern: _searchPattern(), backwards: backwards);
      setState(() => _searchMiss = !found);
    } catch (_) {
      setState(() => _searchMiss = true);
    }
    session.refresh();
  }

  void _closeSearch() {
    if (session.started) termSearchClear(id: session.id);
    session.refresh();
    setState(() => _searchOpen = false);
    _focus.requestFocus();
  }

  Widget _searchBar(AppColors colors) {
    Widget toggle(String label, bool value, String tip, VoidCallback onTap) => Tooltip(
          message: tr(tip),
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 26,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: value ? colors.accent.withValues(alpha: 0.25) : null,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(label, style: TextStyle(fontSize: 12, color: value ? colors.text : colors.textDim, fontFamily: 'Menlo')),
            ),
          ),
        );
    return Material(
      color: colors.surfaceRaised,
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: colors.border), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 200,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
                const SingleActivator(LogicalKeyboardKey.enter): () => _search(backwards: true),
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _search(backwards: false),
              },
              child: TextField(
                controller: _searchText,
                focusNode: _searchFocus,
                style: TextStyle(fontSize: 13, color: _searchMiss ? colors.danger : colors.text),
                decoration: InputDecoration(hintText: tr('搜索'), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                onChanged: (_) => _search(backwards: true),
              ),
            ),
          ),
          const SizedBox(width: 4),
          toggle('Aa', _searchCase, '区分大小写', () {
            setState(() => _searchCase = !_searchCase);
            _search(backwards: true);
          }),
          toggle('.*', _searchRegex, '正则表达式', () {
            setState(() => _searchRegex = !_searchRegex);
            _search(backwards: true);
          }),
          toggle('\\b', _searchWord, '全词匹配', () {
            setState(() => _searchWord = !_searchWord);
            _search(backwards: true);
          }),
          IconButton(
            tooltip: tr('上一个 (Enter)'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_up, color: colors.text),
            onPressed: () => _search(backwards: true),
          ),
          IconButton(
            tooltip: tr('下一个 (Shift+Enter)'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.keyboard_arrow_down, color: colors.text),
            onPressed: () => _search(backwards: false),
          ),
          IconButton(
            tooltip: tr('关闭 (Esc)'),
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, color: colors.textDim),
            onPressed: _closeSearch,
          ),
        ]),
      ),
    );
  }

  // ---------- 滚动条 ----------

  Widget _scrollbar(TermFrame frame, double height) {
    final total = frame.historySize + frame.rows;
    if (frame.historySize == 0 || total == 0) return const SizedBox.shrink();
    final visible = _hovering || frame.displayOffset > 0;
    final thumbHeight = (frame.rows / total * height).clamp(24.0, height);
    final top = (frame.historySize - frame.displayOffset) / frame.historySize * (height - thumbHeight);
    void dragTo(double dy) {
      final ratio = ((dy - thumbHeight / 2) / (height - thumbHeight)).clamp(0.0, 1.0);
      final offset = ((1 - ratio) * frame.historySize).round();
      termScrollOffset(id: session.id, offset: offset);
      session.refresh();
    }

    return Positioned(
      right: 1,
      top: 0,
      bottom: 0,
      width: 8,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) => dragTo(details.localPosition.dy),
          onTapDown: (details) => dragTo(details.localPosition.dy),
          child: Stack(children: [
            Positioned(
              top: top,
              left: 1,
              right: 1,
              height: thumbHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(color: rgb(frame.foreground).withValues(alpha: 0.3), borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final metrics = app.metrics;
    final frame = session.frame;
    final background = frame != null ? rgb(frame.background) : const Color(0xff171717);
    final foreground = frame != null ? rgb(frame.foreground) : const Color(0xffcacaca);
    final opacity = ((app.appearance['opacity'] as num?) ?? 1).toDouble();

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _layout(size, metrics);
      });
      return Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          onHover: _onPointerHover,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerSignal: _onSignal,
            onPointerPanZoomUpdate: (event) => _scrollBy(-event.panDelta.dy, event.localPosition),
            child: Container(
              color: background.withValues(alpha: opacity),
              child: Stack(children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: TerminalPainter(
                      session: session,
                      metrics: metrics,
                      cache: _cache,
                      padding: _padding,
                      cursorOn: _cursorOn,
                      focused: _focus.hasFocus,
                      composing: _composing,
                      selectionColor: foreground.withValues(alpha: 0.28),
                      matchColor: const Color(0x99f9a825),
                    ),
                  ),
                ),
                if (frame != null) _scrollbar(frame, size.height),
                if (_bellFlash > 0) Positioned.fill(child: IgnorePointer(child: ColoredBox(color: Colors.white.withValues(alpha: _bellFlash)))),
                if (session.exited) _exitBar(colors),
                if (_searchOpen) Positioned(top: 8, right: 16, child: _searchBar(colors)),
              ]),
            ),
          ),
        ),
      );
    });
  }

  Widget _exitBar(AppColors colors) {
    final remote = session.profileType != 'local';
    final reason = session.exitReason.isEmpty ? tr('会话已结束') : session.exitReason.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: colors.surfaceRaised.withValues(alpha: 0.95),
        child: Row(children: [
          Icon(Icons.info_outline, size: 16, color: colors.textDim),
          const SizedBox(width: 8),
          Expanded(child: Text(reason, style: TextStyle(color: colors.text, fontSize: 13), overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: _restart, child: Text(tr(remote ? '重新连接 (Enter)' : '重新启动 (Enter)'))),
          TextButton(
            onPressed: () => AppScope.read(context).closePane(widget.tab, session),
            child: Text(tr('关闭 (Esc)'), style: TextStyle(color: colors.textDim)),
          ),
        ]),
      ),
    );
  }

  void flashBell() {
    setState(() => _bellFlash = 0.15);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _bellFlash = 0);
    });
  }
}
