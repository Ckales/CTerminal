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
  bool _busy = false;
  bool? _hasApiKey;
  String? _error;
  bool _saved = false;

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
    _refreshStatus();
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
        config['ai'] = values;
      });

      final key = _apiKey.text.trim();
      if (key.isNotEmpty) {
        await ai.aiSetApiKey(value: _apiKey.text);
        _apiKey.clear();
      }
      await _refreshStatus();
      if (mounted) setState(() => _saved = true);
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
      String? hint,
      bool secret = false,
    }) {
      final input = SizedBox(
        width: compact ? double.infinity : 300,
        child: TextField(
          controller: controller,
          enabled: !_busy,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 900.0;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 20 : 32,
            24,
            compact ? 20 : 32,
            32,
          ),
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsSection(
                    title: 'AI 助手',
                    description: '支持 Chat Completions 兼容服务。填写服务商提供的地址、模型和密钥。',
                    children: [
                      compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                        : (value) => app.updateConfig((config) {
                                            final values =
                                                config['ai']
                                                    as Map<String, dynamic>? ??
                                                <String, dynamic>{};
                                            values['panelPosition'] = value;
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
                                      : (value) => app.updateConfig((config) {
                                          final values =
                                              config['ai']
                                                  as Map<String, dynamic>? ??
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
                        hint: 'https://api.example.com/v1',
                        compact: compact,
                      ),
                      field(
                        label: '模型',
                        help: '要使用的模型名称',
                        controller: _model,
                        hint: '模型名称',
                        compact: compact,
                      ),
                      field(
                        label: 'API Key',
                        help: '密钥安全保存在系统凭据存储中，不会写入配置文件',
                        controller: _apiKey,
                        secret: true,
                        hint: '留空表示保留已保存的密钥',
                        compact: compact,
                      ),
                      compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
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
                      if (_saved)
                        Text(
                          tr('已保存'),
                          style: TextStyle(fontSize: 12, color: colors.accent),
                        ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        tr('操作失败：{error}', {'error': _error!}),
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
