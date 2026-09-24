import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../hotkeys.dart';
import '../theme.dart';
import 'profile_icons.dart';
import '../i18n.dart';

class SelectorItem {
  SelectorItem({required this.title, this.description = '', this.icon, this.group = '', this.trailing = '', required this.onSelect, this.onEdit});

  final String title;
  final String description;
  final IconData? icon;
  final String group;
  final String trailing;
  final VoidCallback onSelect;
  final VoidCallback? onEdit;
}

/// 顶部弹出的选择列表：输入筛选，方向键移动，回车确认
class SelectorDialog extends StatefulWidget {
  const SelectorDialog({super.key, required this.hint, required this.build, this.footer});

  final String hint;
  final List<SelectorItem> Function(String query) build;
  final Widget? footer;

  @override
  State<SelectorDialog> createState() => _SelectorDialogState();
}

class _SelectorDialogState extends State<SelectorDialog> {
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta + count) % count);
    final offset = _selected * 44.0;
    if (_scroll.hasClients) {
      if (offset < _scroll.offset) _scroll.jumpTo(offset);
      if (offset + 44 > _scroll.offset + _scroll.position.viewportDimension) {
        _scroll.jumpTo(offset + 44 - _scroll.position.viewportDimension);
      }
    }
  }

  void _choose(SelectorItem item) {
    Navigator.of(context).pop();
    item.onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final items = widget.build(_query.text);
    if (_selected >= items.length) _selected = items.isEmpty ? 0 : items.length - 1;

    final rows = <Widget>[];
    var lastGroup = '';
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item.group != lastGroup && item.group.isNotEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(item.group, style: TextStyle(fontSize: 11, color: colors.textDim, fontWeight: FontWeight.w600)),
        ));
      }
      lastGroup = item.group;
      final selected = index == _selected;
      rows.add(MouseRegion(
        onHover: (_) {
          if (_selected != index) setState(() => _selected = index);
        },
        child: GestureDetector(
          onTap: () => _choose(item),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            color: selected ? colors.accent.withValues(alpha: 0.18) : Colors.transparent,
            child: Row(children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 16, color: colors.textDim),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: colors.text)),
                  if (item.description.isNotEmpty)
                    Text(item.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: colors.textDim)),
                ]),
              ),
              if (item.trailing.isNotEmpty) Text(item.trailing, style: TextStyle(fontSize: 12, color: colors.textDim)),
              if (item.onEdit != null && selected)
                IconButton(
                  tooltip: tr('编辑'),
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.settings_outlined, color: colors.textDim),
                  onPressed: () {
                    Navigator.of(context).pop();
                    item.onEdit!();
                  },
                ),
            ]),
          ),
        ),
      ));
    }

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Material(
          color: colors.surfaceRaised,
          elevation: 12,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 600,
            constraints: const BoxConstraints(maxHeight: 520),
            decoration: BoxDecoration(border: Border.all(color: colors.border), borderRadius: BorderRadius.circular(8)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, items.length),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, items.length),
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      if (items.isNotEmpty) _choose(items[_selected]);
                    },
                    const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
                  },
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    decoration: InputDecoration(hintText: tr(widget.hint), prefixIcon: Icon(Icons.search, size: 18, color: colors.textDim)),
                    onChanged: (_) => setState(() => _selected = 0),
                  ),
                ),
              ),
              Flexible(
                child: items.isEmpty
                    ? Padding(padding: const EdgeInsets.all(20), child: Text(tr('没有匹配项'), style: TextStyle(color: colors.textDim)))
                    : ListView(controller: _scroll, shrinkWrap: true, padding: const EdgeInsets.only(bottom: 8), children: rows),
              ),
              if (widget.footer != null) ...[Divider(height: 1, color: colors.border), widget.footer!],
            ]),
          ),
        ),
      ),
    );
  }
}

bool _matches(String query, List<String> fields) {
  if (query.isEmpty) return true;
  final lower = query.toLowerCase();
  return fields.any((field) => field.toLowerCase().contains(lower));
}

String groupName(AppState app, Map<String, dynamic> profile) {
  final group = profile['group'] as String? ?? '';
  if (group == 'ssh-config') return '~/.ssh/config';
  if (profile['isBuiltin'] == true && profile['type'] == 'local') return tr('本地');
  if (group.isEmpty) return tr('未分组');
  for (final entry in (app.config['groups'] as List)) {
    final map = entry as Map;
    if (map['id'] == group) return map['name'] as String? ?? group;
  }
  return group;
}

Future<void> showProfileSelector(BuildContext context, {void Function(Map<String, dynamic> profile)? onPick}) async {
  final app = AppScope.read(context);
  await app.reloadProfiles();
  if (!context.mounted) return;
  void open(Map<String, dynamic> profile) {
    if (onPick != null) {
      onPick(profile);
    } else {
      app.newTab(profile: profile);
    }
  }

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (dialogContext) => SelectorDialog(
      hint: '筛选配置，或输入 user@host:port 快速连接',
      footer: TextButton.icon(
        onPressed: () {
          Navigator.of(dialogContext).pop();
          app.openSettings('profiles');
        },
        icon: const Icon(Icons.tune, size: 16),
        label: Text(tr('管理配置和连接')),
      ),
      build: (query) {
        final items = <SelectorItem>[];
        final quick = parseQuickConnect(query);
        if (quick != null) {
          items.add(SelectorItem(
            title: tr('快速连接 {target}', {'target': quick['name']}),
            description: quick['type'] == 'ssh' ? 'SSH' : 'Telnet',
            icon: quick['type'] == 'ssh' ? Icons.bolt_outlined : Icons.lan_outlined,
            onSelect: () => open(quick),
          ));
        }
        final recentIds = List<String>.from(app.config['recentProfiles'] as List);
        final byId = {for (final profile in app.profiles) profile['id'] as String: profile};
        if (query.isEmpty) {
          for (final id in recentIds) {
            final profile = byId[id];
            if (profile == null) continue;
            items.add(SelectorItem(
              title: profile['name'] as String,
              description: profileDescription(profile),
              icon: profileIcon(profile),
              group: tr('最近使用'),
              onSelect: () => open(profile),
            ));
          }
        }
        final grouped = <String, List<Map<String, dynamic>>>{};
        for (final profile in app.profiles) {
          final name = profile['name'] as String? ?? '';
          if (!_matches(query, [name, profileDescription(profile)])) continue;
          grouped.putIfAbsent(groupName(app, profile), () => []).add(profile);
        }
        grouped.forEach((group, profiles) {
          for (final profile in profiles) {
            final editable = profile['isBuiltin'] != true;
            items.add(SelectorItem(
              title: profile['name'] as String,
              description: profileDescription(profile),
              icon: profileIcon(profile),
              group: group,
              onSelect: () => open(profile),
              onEdit: editable ? () => app.openSettings('profiles:${profile['id']}') : null,
            ));
          }
        });
        return items;
      },
    ),
  );
}

Future<void> showCommandPalette(BuildContext context) async {
  final app = AppScope.read(context);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (dialogContext) => SelectorDialog(
      hint: '输入命令',
      build: (query) {
        final items = <SelectorItem>[];
        hotkeyActionNames.forEach((action, name) {
          if (!_matches(query, [name, actionName(action), action])) return;
          final keys = app.hotkeysFor(action);
          items.add(SelectorItem(
            title: actionName(action),
            description: action,
            trailing: keys.isEmpty ? '' : keys.first.display(),
            onSelect: () => app.runAction(action),
          ));
        });
        return items;
      },
    ),
  );
}

Future<String?> showTextPrompt(BuildContext context, {required String title, String initial = '', String hint = ''}) {
  final controller = TextEditingController(text: initial);
  final colors = AppTheme.of(context);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(title), style: TextStyle(fontSize: 15, color: colors.text)),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr(hint)),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('取消'))),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text), child: Text(tr('确定'))),
      ],
    ),
  );
}

Future<bool> showConfirm(BuildContext context, {required String title, required String message, String confirm = '确定', bool danger = false}) async {
  final colors = AppTheme.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(tr(title), style: TextStyle(fontSize: 15, color: colors.text)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 300),
        child: SingleChildScrollView(child: Text(tr(message), style: TextStyle(fontSize: 13, color: colors.textDim))),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(tr('取消'))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: colors.danger) : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(tr(confirm)),
        ),
      ],
    ),
  );
  return result ?? false;
}
