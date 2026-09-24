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
        content: Text(tr('{key} 已从「{actions}」上移除', {'key': hotkey.display(), 'actions': conflict.map(actionName).join(tr('、'))})),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final hotkeys = app.config['hotkeys'] as Map<String, dynamic>;
    final actions = hotkeyActionNames.entries.where((entry) {
      if (_filter.isEmpty) return true;
      final keys = app.hotkeysFor(entry.key).map((key) => key.display()).join(' ');
      return '${entry.value} ${actionName(entry.key)} ${entry.key} $keys'.toLowerCase().contains(_filter.toLowerCase());
    }).toList();

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
      for (final entry in actions)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(actionName(entry.key), style: TextStyle(fontSize: 13, color: colors.text)),
                Text(entry.key, style: TextStyle(fontSize: 11, color: colors.textDim)),
              ]),
            ),
            Wrap(spacing: 6, children: [
              for (final key in (hotkeys[entry.key] as List? ?? []))
                InputChip(
                  label: Text(Hotkey.parse(key as String)?.display() ?? key, style: TextStyle(fontSize: 12, color: colors.text)),
                  backgroundColor: colors.surfaceRaised,
                  side: BorderSide(color: colors.border),
                  visualDensity: VisualDensity.compact,
                  onDeleted: () => app.updateConfig((config) => (config['hotkeys'][entry.key] as List).remove(key)),
                ),
            ]),
            IconButton(tooltip: tr('添加快捷键'), iconSize: 16, icon: const Icon(Icons.add), onPressed: () => _record(entry.key)),
            IconButton(
              tooltip: tr('恢复默认'),
              iconSize: 16,
              icon: const Icon(Icons.restart_alt),
              onPressed: () => app.updateConfig((config) => config['hotkeys'][entry.key] = _defaults()[entry.key] ?? []),
            ),
          ]),
        ),
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
