import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme.dart';
import '../../i18n.dart';

/// 设置页里的一组设置
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.children, this.description});

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr(title), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        if (description != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr(description!), style: TextStyle(fontSize: 12, color: colors.textDim)),
          ),
        const SizedBox(height: 8),
        ...children,
      ]),
    );
  }
}

class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.label, this.help, required this.control});

  final String label;
  final String? help;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(label), style: TextStyle(fontSize: 13, color: colors.text)),
            if (help != null) Text(tr(help!), style: TextStyle(fontSize: 11.5, color: colors.textDim)),
          ]),
        ),
        const SizedBox(width: 16),
        control,
      ]),
    );
  }
}

dynamic readPath(Map<String, dynamic> config, String path) {
  dynamic value = config;
  for (final part in path.split('.')) {
    if (value is! Map) return null;
    value = value[part];
  }
  return value;
}

void writePath(Map<String, dynamic> config, String path, dynamic value) {
  final parts = path.split('.');
  Map target = config;
  for (final part in parts.sublist(0, parts.length - 1)) {
    target = target[part] as Map;
  }
  target[parts.last] = value;
}

class ConfigSwitch extends StatelessWidget {
  const ConfigSwitch({super.key, required this.path, required this.label, this.help});

  final String path;
  final String label;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SettingRow(
      label: label,
      help: help,
      control: Switch(
        value: readPath(app.config, path) == true,
        onChanged: (value) => app.updateConfig((config) => writePath(config, path, value)),
      ),
    );
  }
}

class ConfigDropdown extends StatelessWidget {
  const ConfigDropdown({super.key, required this.path, required this.label, required this.options, this.help, this.width = 220});

  final String path;
  final String label;
  final String? help;
  final Map<String, String> options;
  final double width;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SettingRow(
      label: label,
      help: help,
      control: SizedBox(
        width: width,
        child: ChoiceDropdown(
          value: readPath(app.config, path)?.toString() ?? '',
          options: options,
          onChanged: (value) => app.updateConfig((config) => writePath(config, path, value)),
        ),
      ),
    );
  }
}

class ChoiceDropdown extends StatelessWidget {
  const ChoiceDropdown({super.key, required this.value, required this.options, required this.onChanged});

  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final entries = Map.of(options);
    // 配置里是选项之外的值（手改过配置文件）时如实显示，不偷偷替换
    if (!entries.containsKey(value)) entries[value] = value.isEmpty ? tr('（未设置）') : value;
    return DropdownButtonFormField<String>(
      // 值在外部变化时（重置、重新加载配置）要重建，否则表单字段会保留旧状态
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      isDense: true,
      dropdownColor: colors.surfaceRaised,
      style: TextStyle(fontSize: 13, color: colors.text),
      items: [
        for (final entry in entries.entries)
          DropdownMenuItem(value: entry.key, child: Text(tr(entry.value), overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

/// 失焦或回车时才提交，避免每敲一个字就写一次配置
class CommitTextField extends StatefulWidget {
  const CommitTextField({super.key, required this.value, required this.onCommit, this.hint, this.width = 220, this.number = false, this.obscure = false, this.maxLines = 1});

  final String value;
  final ValueChanged<String> onCommit;
  final String? hint;
  final double? width;
  final bool number;
  final bool obscure;
  final int maxLines;

  @override
  State<CommitTextField> createState() => _CommitTextFieldState();
}

class _CommitTextFieldState extends State<CommitTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(CommitTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && widget.value != _controller.text) _controller.text = widget.value;
  }

  void _commit() {
    if (_controller.text != widget.value) widget.onCommit(_controller.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      obscureText: widget.obscure,
      maxLines: widget.maxLines,
      keyboardType: widget.number ? TextInputType.number : null,
      style: TextStyle(fontSize: 13, color: colors.text),
      decoration: InputDecoration(hintText: widget.hint == null ? null : tr(widget.hint!)),
      onSubmitted: (_) => _commit(),
    );
    return widget.width == null ? field : SizedBox(width: widget.width, child: field);
  }
}

class ConfigText extends StatelessWidget {
  const ConfigText({super.key, required this.path, required this.label, this.help, this.hint, this.width = 220});

  final String path;
  final String label;
  final String? help;
  final String? hint;
  final double width;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SettingRow(
      label: label,
      help: help,
      control: CommitTextField(
        width: width,
        hint: hint,
        value: readPath(app.config, path)?.toString() ?? '',
        onCommit: (value) => app.updateConfig((config) => writePath(config, path, value)),
      ),
    );
  }
}

class ConfigNumber extends StatelessWidget {
  const ConfigNumber({super.key, required this.path, required this.label, this.help, this.min, this.max, this.integer = true});

  final String path;
  final String label;
  final String? help;
  final num? min;
  final num? max;
  final bool integer;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final value = readPath(app.config, path) as num? ?? 0;
    return SettingRow(
      label: label,
      help: help,
      control: CommitTextField(
        width: 100,
        number: true,
        value: integer ? value.toInt().toString() : value.toString(),
        onCommit: (text) {
          final num? input = integer ? int.tryParse(text) : double.tryParse(text);
          if (input == null) return;
          var parsed = input;
          if (min != null && parsed < min!) parsed = min!;
          if (max != null && parsed > max!) parsed = max!;
          app.updateConfig((config) => writePath(config, path, parsed));
        },
      ),
    );
  }
}

class ConfigSlider extends StatefulWidget {
  const ConfigSlider({super.key, required this.path, required this.label, required this.min, required this.max, this.divisions, this.format});

  final String path;
  final String label;
  final double min;
  final double max;
  final int? divisions;
  final String Function(double value)? format;

  @override
  State<ConfigSlider> createState() => _ConfigSliderState();
}

class _ConfigSliderState extends State<ConfigSlider> {
  /// 拖动中的值；松手才写配置
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final stored = ((readPath(app.config, widget.path) as num?) ?? widget.min).toDouble().clamp(widget.min, widget.max);
    final value = _dragging ?? stored;
    return SettingRow(
      label: widget.label,
      control: SizedBox(
        width: 260,
        child: Row(children: [
          Expanded(
            child: Slider(
              value: value,
              min: widget.min,
              max: widget.max,
              divisions: widget.divisions,
              onChanged: (next) => setState(() => _dragging = next),
              onChangeEnd: (next) {
                setState(() => _dragging = null);
                app.updateConfig((config) => writePath(config, widget.path, double.parse(next.toStringAsFixed(2))));
              },
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(widget.format?.call(value) ?? value.toStringAsFixed(2), style: TextStyle(fontSize: 12, color: colors.textDim)),
          ),
        ]),
      ),
    );
  }
}
