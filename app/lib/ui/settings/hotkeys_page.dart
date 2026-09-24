import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../hotkeys.dart';
import '../../src/rust/api/settings.dart' as rust;
import '../../theme.dart';
import '../../i18n.dart';

class HotkeysPage extends StatefulWidget {
  const HotkeysPage({super.key});

  @override
  State<HotkeysPage> createState() => _HotkeysPageState();
}

class _HotkeysPageState extends State<HotkeysPage> {
  String _filter = '';

  Map<String, dynamic> _defaults() => (jsonDecode(rust.configDefaults()) as Map<String, dynamic>)['hotkeys'] as Map<String, dynamic>;

  /// 动作显示名；配置快捷键（`profile:<id>`）显示配置名
  String _label(AppState app, String action) {
    if (!action.startsWith(profileHotkeyPrefix)) return actionName(action);
    final id = action.substring(profileHotkeyPrefix.length);
    final profile = app.profiles.where((profile) => profile['id'] == id).firstOrNull;
    return tr('打开配置「{name}」', {'name': profile == null ? id : profile['name']});
  }

  Future<void> _record(String action) async {
    final app = AppScope.read(context);
    final hotkey = await showDialog<Hotkey>(context: context, builder: (_) => const _RecordDialog());
    if (hotkey == null) return;
    final formatted = hotkey.format();
    // 同一组合只能属于一个动作：先从别的动作上摘掉
    final conflict = app.config['hotkeys'].entries.where((entry) {
      if (entry.key == action) return false;
      return (entry.value as List).any((key) => Hotkey.parse(key as String) == hotkey);
    }).map((entry) => entry.key as String).toList();
    await app.updateConfig((config) {
      final hotkeys = config['hotkeys'] as Map<String, dynamic>;
      for (final other in conflict) {
        (hotkeys[other] as List).removeWhere((key) => Hotkey.parse(key as String) == hotkey);
      }
      final keys = List<String>.from((hotkeys[action] as List?) ?? []);
      if (!keys.contains(formatted)) keys.add(formatted);
      hotkeys[action] = keys;
    });
    if (conflict.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('{key} 已从「{actions}」上移除', {'key': hotkey.display(), 'actions': conflict.map((action) => _label(app, action)).join(tr('、'))})),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final hotkeys = app.config['hotkeys'] as Map<String, dynamic>;
    bool matches(String action, String name) {
      if (_filter.isEmpty) return true;
      final keys = app.hotkeysFor(action).map((key) => key.display()).join(' ');
      return '$name ${_label(app, action)} $action $keys'.toLowerCase().contains(_filter.toLowerCase());
    }

    final actions = hotkeyActionNames.entries.where((entry) => matches(entry.key, entry.value)).toList();
    final profileActions = <String>[];
    for (final profile in app.profiles) {
      final action = '$profileHotkeyPrefix${profile['id']}';
      if (matches(action, profile['name'] as String)) profileActions.add(action);
    }

    Widget row(String action) => Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_label(app, action), style: TextStyle(fontSize: 13, color: colors.text)),
                Text(action, style: TextStyle(fontSize: 11, color: colors.textDim)),
              ]),
            ),
            Wrap(spacing: 6, children: [
              for (final key in (hotkeys[action] as List? ?? []))
                InputChip(
                  label: Text(Hotkey.parse(key as String)?.display() ?? key, style: TextStyle(fontSize: 12, color: colors.text)),
                  backgroundColor: colors.surfaceRaised,
                  side: BorderSide(color: colors.border),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => app.updateConfig((config) => (config['hotkeys'][action] as List).remove(key)),
                ),
            ]),
            IconButton(tooltip: tr('添加快捷键'), iconSize: 16, icon: const Icon(Icons.add), onPressed: () => _record(action)),
            IconButton(
              tooltip: tr('恢复默认'),
              iconSize: 16,
              icon: const Icon(Icons.restart_alt),
              onPressed: () => app.updateConfig((config) => config['hotkeys'][action] = _defaults()[action] ?? []),
            ),
          ]),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        Text(tr('快捷键'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        SizedBox(
          width: 240,
          child: TextField(
            style: TextStyle(fontSize: 13, color: colors.text),
            decoration: InputDecoration(hintText: tr('搜索动作或按键'), prefixIcon: Icon(Icons.search, size: 16)),
            onChanged: (value) => setState(() => _filter = value),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () => app.updateConfig((config) => config['hotkeys'] = _defaults()),
          child: Text(tr('全部恢复默认')),
        ),
      ]),
      const SizedBox(height: 12),
      for (final entry in actions) row(entry.key),
      if (profileActions.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text(tr('配置'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(height: 4),
        Text(tr('给配置绑定快捷键，按下即用该配置新建标签页'), style: TextStyle(fontSize: 12, color: colors.textDim)),
        const SizedBox(height: 4),
        for (final action in profileActions) row(action),
      ],
    ]);
  }
}

class _RecordDialog extends StatefulWidget {
  const _RecordDialog();

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AlertDialog(
      title: Text(tr('按下新的快捷键'), style: TextStyle(fontSize: 15)),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.handled;
          if (event.logicalKey == LogicalKeyboardKey.escape && !HardwareKeyboard.instance.isShiftPressed) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          final hotkey = hotkeyFromEvent(event);
          if (hotkey != null) Navigator.of(context).pop(hotkey);
          return KeyEventResult.handled;
        },
        child: SizedBox(
          width: 300,
          height: 60,
          child: Center(child: Text(tr('等待按键…（Esc 取消）'), style: TextStyle(color: colors.textDim))),
        ),
      ),
    );
  }
}
