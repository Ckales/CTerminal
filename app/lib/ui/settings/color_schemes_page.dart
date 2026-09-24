import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../selector.dart';
import 'widgets.dart';
import '../../i18n.dart';

class ColorSchemesPage extends StatefulWidget {
  const ColorSchemesPage({super.key});

  @override
  State<ColorSchemesPage> createState() => _ColorSchemesPageState();
}

class _ColorSchemesPageState extends State<ColorSchemesPage> {
  Map<String, dynamic>? _editing;

  bool _isCustom(AppState app, String name) => (app.config['customColorSchemes'] as List).any((scheme) => (scheme as Map)['name'] == name);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final current = app.terminal['colorScheme'] as String;
    final editing = _editing;
    if (editing != null) return _editor(app, colors, editing);

    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        Text(tr('配色方案'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () {
            final base = app.colorSchemes.firstWhere((scheme) => scheme['name'] == current, orElse: () => app.colorSchemes.first);
            setState(() => _editing = {...base, 'name': tr('{name} 自定义', {'name': base['name']}), 'colors': List<String>.from(base['colors'] as List)});
          },
          icon: const Icon(Icons.add, size: 16),
          label: Text(tr('基于当前方案新建')),
        ),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final scheme in app.colorSchemes)
          _SchemePreview(
            scheme: scheme,
            selected: scheme['name'] == current,
            custom: _isCustom(app, scheme['name'] as String),
            onTap: () => app.updateConfig((config) => config['terminal']['colorScheme'] = scheme['name']),
            onEdit: () => setState(() => _editing = {...scheme, 'colors': List<String>.from(scheme['colors'] as List)}),
          ),
      ]),
    ]);
  }

  Widget _editor(AppState app, AppColors colors, Map<String, dynamic> scheme) {
    final originalName = _editing!['name'];
    Widget colorField(String label, String value, ValueChanged<String> onChanged) => SettingRow(
          label: label,
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 18, height: 18, decoration: BoxDecoration(color: parseHexColor(value), border: Border.all(color: colors.border))),
            const SizedBox(width: 8),
            CommitTextField(
              width: 110,
              value: value,
              onCommit: (text) {
                if (parseHexColor(text.trim()) == null) return;
                setState(() => onChanged(text.trim()));
              },
            ),
          ]),
        );
    const names = ['黑', '红', '绿', '黄', '蓝', '品红', '青', '白'];
    final palette = scheme['colors'] as List<String>;
    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, size: 18), onPressed: () => setState(() => _editing = null)),
        Text(tr('编辑配色方案'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        if (_isCustom(app, originalName as String))
          TextButton(
            onPressed: () async {
              final ok = await showConfirm(context, title: '删除配色方案？', message: tr('删除「{name}」', {'name': originalName}), confirm: '删除', danger: true);
              if (!ok) return;
              await app.updateConfig((config) => (config['customColorSchemes'] as List).removeWhere((entry) => (entry as Map)['name'] == originalName));
              setState(() => _editing = null);
            },
            child: Text(tr('删除'), style: TextStyle(color: colors.danger)),
          ),
        FilledButton(
          onPressed: () async {
            await app.updateConfig((config) {
              final list = config['customColorSchemes'] as List;
              list.removeWhere((entry) => (entry as Map)['name'] == scheme['name']);
              list.add(scheme);
              config['terminal']['colorScheme'] = scheme['name'];
            });
            setState(() => _editing = null);
          },
          child: Text(tr('保存并使用')),
        ),
      ]),
      const SizedBox(height: 12),
      SettingRow(
        label: '名称',
        control: CommitTextField(value: scheme['name'] as String, onCommit: (value) => setState(() => scheme['name'] = value.trim())),
      ),
      colorField('前景', scheme['foreground'] as String, (value) => scheme['foreground'] = value),
      colorField('背景', scheme['background'] as String, (value) => scheme['background'] = value),
      colorField('光标', scheme['cursor'] as String, (value) => scheme['cursor'] = value),
      for (var index = 0; index < 16; index++)
        colorField('${index < 8 ? tr(names[index]) : tr('亮{color}', {'color': tr(names[index % 8])})}（$index）', palette[index], (value) => palette[index] = value),
      const SizedBox(height: 16),
      _SchemePreview(scheme: scheme, selected: false, custom: false, onTap: () {}, onEdit: null, width: 420),
    ]);
  }
}

class _SchemePreview extends StatelessWidget {
  const _SchemePreview({required this.scheme, required this.selected, required this.custom, required this.onTap, required this.onEdit, this.width = 260});

  final Map<String, dynamic> scheme;
  final bool selected;
  final bool custom;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final palette = [for (final color in scheme['colors'] as List) parseHexColor(color as String) ?? Colors.black];
    final foreground = parseHexColor(scheme['foreground'] as String) ?? Colors.white;
    final background = parseHexColor(scheme['background'] as String) ?? Colors.black;
    const mono = TextStyle(fontFamily: 'Menlo', fontSize: 12, height: 1.4);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? colors.accent : colors.border, width: selected ? 2 : 1),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(scheme['name'] as String, style: mono.copyWith(color: foreground, fontWeight: FontWeight.bold))),
            if (custom) Text(tr('自定义'), style: mono.copyWith(color: palette[8], fontSize: 10)),
            if (onEdit != null)
              InkWell(onTap: onEdit, child: Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.edit_outlined, size: 14, color: palette[8]))),
          ]),
          const SizedBox(height: 4),
          Text.rich(TextSpan(style: mono.copyWith(color: foreground), children: [
            TextSpan(text: 'user@host', style: TextStyle(color: palette[2])),
            const TextSpan(text: ':'),
            TextSpan(text: '~/project', style: TextStyle(color: palette[4])),
            const TextSpan(text: ' \$ ls\n'),
            TextSpan(text: 'src  ', style: TextStyle(color: palette[12])),
            TextSpan(text: 'run.sh  ', style: TextStyle(color: palette[10])),
            TextSpan(text: 'error.log', style: TextStyle(color: palette[1])),
          ])),
          const SizedBox(height: 6),
          Row(children: [
            for (final color in palette) Expanded(child: Container(height: 8, color: color)),
          ]),
        ]),
      ),
    );
  }
}
