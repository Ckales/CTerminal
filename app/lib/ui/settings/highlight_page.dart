import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../src/rust/api/settings.dart' as rust;
import '../../theme.dart';
import 'widgets.dart';
import '../../i18n.dart';

const _colorNames = ['黑', '红', '绿', '黄', '蓝', '品红', '青', '白'];

String _colorName(int index) => index < 8 ? tr(_colorNames[index]) : tr('亮{color}', {'color': tr(_colorNames[index % 8])});

/// 关键字高亮规则：正则 + 调色板颜色，靠前的优先
class HighlightPage extends StatelessWidget {
  const HighlightPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final rules = app.config['highlightRules'] as List;
    // 当前方案找不到时内核用第一套内置配色，这里跟着一致
    final schemeName = app.terminal['colorScheme'];
    final scheme = app.colorSchemes.firstWhere((entry) => entry['name'] == schemeName, orElse: () => app.colorSchemes.first);
    final palette = [for (final color in scheme['colors'] as List) parseHexColor(color as String) ?? Colors.black];

    void edit(void Function(List rules) change) => app.updateConfig((config) => change(config['highlightRules'] as List));

    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        Text(tr('关键字高亮'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: () => edit((rules) => rules.add({'pattern': '', 'ignoreCase': true, 'foreground': 1, 'background': null, 'bold': false, 'enabled': true})),
          icon: const Icon(Icons.add, size: 16),
          label: Text(tr('添加规则')),
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text(
          tr('按正则给程序没有上色的文字换颜色，颜色取自当前配色方案。靠前的规则优先；vim 等全屏程序里不生效。'),
          style: TextStyle(fontSize: 12, color: colors.textDim),
        ),
      ),
      for (var index = 0; index < rules.length; index++)
        _RuleRow(
          rule: rules[index] as Map<String, dynamic>,
          palette: palette,
          first: index == 0,
          last: index == rules.length - 1,
          onChanged: (key, value) => edit((rules) => rules[index][key] = value),
          onMove: (offset) => edit((rules) => rules.insert(index + offset, rules.removeAt(index))),
          onDelete: () => edit((rules) => rules.removeAt(index)),
        ),
    ]);
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.palette,
    required this.first,
    required this.last,
    required this.onChanged,
    required this.onMove,
    required this.onDelete,
  });

  final Map<String, dynamic> rule;
  final List<Color> palette;
  final bool first;
  final bool last;
  final void Function(String key, Object? value) onChanged;
  final ValueChanged<int> onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final pattern = rule['pattern'] as String;
    final error = rust.highlightPatternError(pattern: pattern);
    final foreground = rule['foreground'] as int?;
    final background = rule['background'] as int?;

    Widget colorPicker(String key, int? value) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: value == null ? null : palette[value], border: Border.all(color: colors.border)),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 96,
            child: ChoiceDropdown(
              value: value?.toString() ?? '',
              options: {'': '不改', for (var index = 0; index < 16; index++) '$index': _colorName(index)},
              onChanged: (text) => onChanged(key, text.isEmpty ? null : int.parse(text)),
            ),
          ),
        ]);

    Widget toggle(String label, String tooltip, String key, {FontWeight? weight}) {
      final on = rule[key] == true;
      return Tooltip(
        message: tr(tooltip),
        child: InkWell(
          onTap: () => onChanged(key, !on),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? colors.accent.withValues(alpha: 0.18) : null,
              border: Border.all(color: on ? colors.accent : colors.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: weight, color: on ? colors.text : colors.textDim)),
          ),
        ),
      );
    }

    Widget action(IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
          icon: Icon(icon, size: 16),
          tooltip: tr(tooltip),
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
        );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CompactSwitch(value: rule['enabled'] == true, onChanged: (value) => onChanged('enabled', value)),
          const SizedBox(width: 12),
          Expanded(child: CommitTextField(value: pattern, width: null, hint: '正则表达式', onCommit: (value) => onChanged('pattern', value))),
          const SizedBox(width: 8),
          toggle('Aa', '忽略大小写', 'ignoreCase'),
          const SizedBox(width: 4),
          toggle('B', '粗体', 'bold', weight: FontWeight.bold),
          const SizedBox(width: 12),
          Text(tr('前景'), style: TextStyle(fontSize: 12, color: colors.textDim)),
          const SizedBox(width: 6),
          colorPicker('foreground', foreground),
          const SizedBox(width: 12),
          Text(tr('背景'), style: TextStyle(fontSize: 12, color: colors.textDim)),
          const SizedBox(width: 6),
          colorPicker('background', background),
          const SizedBox(width: 8),
          action(Icons.arrow_upward, '上移', first ? null : () => onMove(-1)),
          action(Icons.arrow_downward, '下移', last ? null : () => onMove(1)),
          action(Icons.delete_outline, '删除', onDelete),
        ]),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 46, top: 4),
            child: Text(tr('正则有误，此规则不生效：{error}', {'error': error}), style: TextStyle(fontSize: 11.5, color: colors.danger)),
          ),
      ]),
    );
  }
}
