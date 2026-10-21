import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../i18n.dart';
import '../../src/rust/api/ai.dart' as ai;
import '../../theme.dart';
import 'widgets.dart';

class AiPage extends StatefulWidget {
  const AiPage({super.key});

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _systemPrompt;
  late final TextEditingController _presetName;
  late final TextEditingController _presetPrompt;
  late final List<Map<String, String>> _presets;
  String _activePreset = '';
  bool _busy = false;
  bool? _hasApiKey;
  String? _error;
  bool _saved = false;
  bool _dirty = false;

  Map<String, dynamic> _aiConfig(AppState app) =>
      (app.config['ai'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    final config = _aiConfig(app);
    _baseUrl = TextEditingController(text: config['baseUrl'] as String? ?? '');
    _model = TextEditingController(text: config['model'] as String? ?? '');
    _apiKey = TextEditingController();
    _systemPrompt = TextEditingController(
      text: config['systemPrompt'] as String? ?? '',
    );
    _presets = _readPresets(config['promptPresets']);
    final configuredPreset = config['activePreset'] as String? ?? '';
    _activePreset = _presets.any((preset) => preset['id'] == configuredPreset)
        ? configuredPreset
        : _presets.first['id']!;
    final active = _selectedPreset;
    _presetName = TextEditingController(text: active['name']);
    _presetPrompt = TextEditingController(text: active['prompt']);
    _refreshStatus();
  }

  List<Map<String, String>> _readPresets(dynamic raw) {
    dynamic source = raw;
    if (source is! List || source.isEmpty) {
      source = jsonDecode(ai.aiPresetsDefaults()) as List;
    }
    final presets = [
      for (final entry in source)
        if (entry is Map)
          <String, String>{
            'id': entry['id']?.toString() ?? '',
            'name': entry['name']?.toString() ?? '',
            'prompt': entry['prompt']?.toString() ?? '',
          },
    ].where((preset) => preset['id']!.isNotEmpty).toList();
    if (presets.isNotEmpty) return presets;
    return [
      {'id': 'general', 'name': '通用', 'prompt': ''},
    ];
  }

  Map<String, String> get _selectedPreset =>
      _presets.firstWhere((preset) => preset['id'] == _activePreset);

  void _markDirty() {
    setState(() {
      _dirty = true;
      _saved = false;
      _error = null;
    });
  }

  void _capturePresetEdits() {
    _selectedPreset['name'] = _presetName.text;
    _selectedPreset['prompt'] = _presetPrompt.text;
  }

  void _selectPreset(String id) {
    if (id == _activePreset) return;
    _capturePresetEdits();
    final next = _presets.firstWhere((preset) => preset['id'] == id);
    setState(() {
      _activePreset = id;
      _presetName.text = next['name']!;
      _presetPrompt.text = next['prompt']!;
      _dirty = true;
      _saved = false;
      _error = null;
    });
  }

  void _addPreset() {
    _capturePresetEdits();
    final preset = {
      'id': 'custom-${DateTime.now().microsecondsSinceEpoch}',
      'name': '新预设',
      'prompt': '',
    };
    setState(() {
      _presets.add(preset);
      _activePreset = preset['id']!;
      _presetName.text = preset['name']!;
      _presetPrompt.clear();
      _dirty = true;
      _saved = false;
      _error = null;
    });
  }

  void _deletePreset() {
    if (_presets.length <= 1) return;
    final index = _presets.indexWhere(
      (preset) => preset['id'] == _activePreset,
    );
    _presets.removeAt(index);
    final next = _presets.first;
    setState(() {
      _activePreset = next['id']!;
      _presetName.text = next['name']!;
      _presetPrompt.text = next['prompt']!;
      _dirty = true;
      _saved = false;
      _error = null;
    });
  }

  Future<void> _refreshStatus() async {
    try {
      final hasKey = ai.aiStatus();
      if (mounted) setState(() => _hasApiKey = hasKey);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _saved = false;
    });
    try {
      final app = AppScope.read(context);
      await app.updateConfig((config) {
        final values =
            config['ai'] as Map<String, dynamic>? ?? <String, dynamic>{};
        values['baseUrl'] = _baseUrl.text.trim();
        values['model'] = _model.text.trim();
        _capturePresetEdits();
        values['systemPrompt'] = _systemPrompt.text;
        values['promptPresets'] = [
          for (final preset in _presets) Map<String, String>.from(preset),
        ];
        values['activePreset'] = _activePreset;
        config['ai'] = values;
      });

      final key = _apiKey.text.trim();
      if (key.isNotEmpty) {
        await ai.aiSetApiKey(value: _apiKey.text);
        _apiKey.clear();
      }
      await _refreshStatus();
      if (mounted) {
        setState(() {
          _saved = true;
          _dirty = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteApiKey() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _saved = false;
    });
    try {
      await ai.aiSetApiKey(value: '');
      _apiKey.clear();
      await _refreshStatus();
      if (mounted) setState(() => _saved = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _systemPrompt.dispose();
    _presetName.dispose();
    _presetPrompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final config = _aiConfig(app);
    final position = config['panelPosition'] as String? ?? 'right';

    Widget field({
      required String label,
      required String help,
      required TextEditingController controller,
      required bool compact,
      required ValueChanged<String> onChanged,
      required String key,
      String? hint,
      bool secret = false,
    }) {
      final input = SizedBox(
        width: compact ? double.infinity : 300,
        child: TextField(
          key: ValueKey<String>(key),
          controller: controller,
          enabled: !_busy,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
          onChanged: onChanged,
          style: TextStyle(fontSize: 13, color: colors.text),
          decoration: InputDecoration(hintText: hint == null ? null : tr(hint)),
        ),
      );
      if (compact) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(label),
                style: TextStyle(fontSize: 13, color: colors.text),
              ),
              Text(
                tr(help),
                style: TextStyle(fontSize: 11.5, color: colors.textDim),
              ),
              const SizedBox(height: 6),
              input,
            ],
          ),
        );
      }
      return SettingRow(label: label, help: help, control: input);
    }

    Widget multilineField({
      required String label,
      required String help,
      required TextEditingController controller,
      required bool compact,
      required ValueChanged<String> onChanged,
      required String key,
    }) {
      final input = SizedBox(
        width: compact ? double.infinity : 420,
        child: TextField(
          key: ValueKey<String>(key),
          controller: controller,
          enabled: !_busy,
          minLines: 4,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          style: TextStyle(fontSize: 13, color: colors.text),
          decoration: const InputDecoration(alignLabelWithHint: true),
          onChanged: onChanged,
        ),
      );
      if (compact) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(label),
                style: TextStyle(fontSize: 13, color: colors.text),
              ),
              Text(
                tr(help),
                style: TextStyle(fontSize: 11.5, color: colors.textDim),
              ),
              const SizedBox(height: 6),
              input,
            ],
          ),
        );
      }
      return SettingRow(label: label, help: help, control: input);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 900.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 20 : 32,
                  24,
                  compact ? 20 : 32,
                  24,
                ),
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SettingsSection(
                          title: 'AI 助手',
                          description:
                              '支持 Chat Completions 兼容服务。填写服务商提供的地址、模型和密钥。',
                          children: [
                            compact
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tr('面板位置'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colors.text,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ChoiceDropdown(
                                          value: position,
                                          options: const {
                                            'right': '右侧',
                                            'bottom': '底部',
                                          },
                                          onChanged: _busy
                                              ? (_) {}
                                              : (value) =>
                                                    app.updateConfig((config) {
                                                      final values =
                                                          config['ai']
                                                              as Map<
                                                                String,
                                                                dynamic
                                                              >? ??
                                                          <String, dynamic>{};
                                                      values['panelPosition'] =
                                                          value;
                                                      config['ai'] = values;
                                                    }),
                                        ),
                                      ),
                                    ],
                                  )
                                : SettingRow(
                                    label: '面板位置',
                                    control: SizedBox(
                                      width: 220,
                                      child: ChoiceDropdown(
                                        value: position,
                                        options: const {
                                          'right': '右侧',
                                          'bottom': '底部',
                                        },
                                        onChanged: _busy
                                            ? (_) {}
                                            : (value) => app.updateConfig((
                                                config,
                                              ) {
                                                final values =
                                                    config['ai']
                                                        as Map<
                                                          String,
                                                          dynamic
                                                        >? ??
                                                    <String, dynamic>{};
                                                values['panelPosition'] = value;
                                                config['ai'] = values;
                                              }),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                        SettingsSection(
                          title: '服务',
                          children: [
                            field(
                              label: 'Base URL',
                              help: 'AI 服务的 API 地址',
                              controller: _baseUrl,
                              key: 'ai-base-url',
                              onChanged: (_) => _markDirty(),
                              hint: 'https://api.example.com/v1',
                              compact: compact,
                            ),
                            field(
                              label: '模型',
                              help: '要使用的模型名称',
                              controller: _model,
                              key: 'ai-model',
                              onChanged: (_) => _markDirty(),
                              hint: '模型名称',
                              compact: compact,
                            ),
                            field(
                              label: 'API Key',
                              help: '密钥安全保存在系统凭据存储中，不会写入配置文件',
                              controller: _apiKey,
                              key: 'ai-api-key',
                              onChanged: (_) => _markDirty(),
                              secret: true,
                              hint: '留空表示保留已保存的密钥',
                              compact: compact,
                            ),
                            compact
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tr('密钥状态'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colors.text,
                                        ),
                                      ),
                                      Text(
                                        tr('只显示是否已设置，不会读取密钥内容'),
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: colors.textDim,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _hasApiKey == null
                                            ? tr('检查中…')
                                            : tr(_hasApiKey! ? '已设置' : '未设置'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: _hasApiKey == true
                                              ? colors.accent
                                              : colors.textDim,
                                        ),
                                      ),
                                    ],
                                  )
                                : SettingRow(
                                    label: '密钥状态',
                                    help: '只显示是否已设置，不会读取密钥内容',
                                    control: SizedBox(
                                      width: 300,
                                      child: Text(
                                        _hasApiKey == null
                                            ? tr('检查中…')
                                            : tr(_hasApiKey! ? '已设置' : '未设置'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: _hasApiKey == true
                                              ? colors.accent
                                              : colors.textDim,
                                        ),
                                      ),
                                    ),
                                  ),
                          ],
                        ),
                        SettingsSection(
                          title: '提示词预设',
                          description: '预设定义助手的基础行为，和你在对话框中输入的问题分开保存。',
                          children: [
                            compact
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        tr('默认使用预设'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: colors.text,
                                        ),
                                      ),
                                      Text(
                                        tr('新对话使用此预设作为基础系统指令'),
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: colors.textDim,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ChoiceDropdown(
                                          value: _activePreset,
                                          options: {
                                            for (final preset in _presets)
                                              preset['id']!:
                                                  preset['name']!.isEmpty
                                                  ? tr('未命名预设')
                                                  : preset['name']!,
                                          },
                                          onChanged: _busy
                                              ? (_) {}
                                              : _selectPreset,
                                        ),
                                      ),
                                    ],
                                  )
                                : SettingRow(
                                    label: '默认使用预设',
                                    help: '新对话使用此预设作为基础系统指令',
                                    control: SizedBox(
                                      width: 300,
                                      child: ChoiceDropdown(
                                        value: _activePreset,
                                        options: {
                                          for (final preset in _presets)
                                            preset['id']!:
                                                preset['name']!.isEmpty
                                                ? tr('未命名预设')
                                                : preset['name']!,
                                        },
                                        onChanged: _busy
                                            ? (_) {}
                                            : _selectPreset,
                                      ),
                                    ),
                                  ),
                            field(
                              label: '预设名称',
                              help: '用于识别和选择这个预设',
                              controller: _presetName,
                              key: 'ai-preset-name',
                              onChanged: (value) {
                                _selectedPreset['name'] = value;
                                _markDirty();
                              },
                              hint: '预设名称',
                              compact: compact,
                            ),
                            multilineField(
                              label: '预设内容',
                              help: '作为基础系统指令，描述助手的职责和回答方式。',
                              controller: _presetPrompt,
                              key: 'ai-preset-prompt',
                              compact: compact,
                              onChanged: (value) {
                                _selectedPreset['prompt'] = value;
                                _markDirty();
                              },
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _busy ? null : _addPreset,
                                  icon: const Icon(Icons.add, size: 16),
                                  label: Text(tr('新建预设')),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _busy || _presets.length <= 1
                                      ? null
                                      : _deletePreset,
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                  ),
                                  label: Text(tr('删除当前预设')),
                                ),
                              ],
                            ),
                          ],
                        ),
                        SettingsSection(
                          title: '自定义系统指令',
                          description: '这段指令用于补充助手行为，不会和对话中的问题混在一起。留空时只使用当前预设。',
                          children: [
                            multilineField(
                              label: '系统 prompt',
                              help: '保存后对后续请求生效；留空则采用上方预设内容。',
                              controller: _systemPrompt,
                              key: 'ai-system-prompt',
                              compact: compact,
                              onChanged: (_) => _markDirty(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: colors.surface,
              elevation: 2,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 20 : 32,
                  10,
                  compact ? 20 : 32,
                  12,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy ? null : _save,
                            icon: _busy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined, size: 16),
                            label: Text(tr('保存')),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy || _hasApiKey != true
                                ? null
                                : _deleteApiKey,
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: Text(tr('删除 API Key')),
                          ),
                          if (_dirty)
                            Text(
                              tr('未保存更改'),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textDim,
                              ),
                            )
                          else if (_saved)
                            Text(
                              tr('已保存'),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.accent,
                              ),
                            ),
                        ],
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            tr('操作失败：{error}', {'error': _error!}),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
