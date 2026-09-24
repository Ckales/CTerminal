import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../src/rust/api/settings.dart' as rust;
import '../../theme.dart';
import '../profile_icons.dart';
import '../selector.dart';
import 'widgets.dart';
import '../../i18n.dart';

String _newId() {
  final random = Random();
  return List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join();
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) => jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Map<String, dynamic> _blankProfile(String type) {
  final options = switch (type) {
    'ssh' => {'host': '', 'port': 22, 'user': '', 'auth': 'auto'},
    'telnet' => {'host': '', 'port': 23},
    'serial' => {'port': '', 'baudrate': 115200},
    _ => {'command': '', 'args': <String>[]},
  };
  final names = {'ssh': '新 SSH 连接', 'telnet': '新 Telnet 连接', 'serial': '新串口连接', 'local': '新本地终端'};
  return {'id': _newId(), 'name': tr(names[type]!), 'type': type, 'options': options, 'group': '', 'icon': '', 'color': '', 'behaviorOnSessionEnd': 'auto'};
}

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key, this.editId = ''});

  /// 从选择器的“编辑”进来时直接打开该配置
  final String editId;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  Map<String, dynamic>? _editing;
  bool _isNew = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    if (widget.editId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final app = AppScope.read(context);
        final found = app.profiles.where((profile) => profile['id'] == widget.editId).firstOrNull;
        if (found != null) setState(() => _editing = _deepCopy(found));
      });
    }
  }

  Future<void> _create() async {
    final colors = AppTheme.of(context);
    final type = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr('新建配置'), style: TextStyle(fontSize: 15, color: colors.text)),
        children: [
          for (final (type, name, icon) in [
            ('ssh', 'SSH 连接', Icons.dns_outlined),
            ('local', '本地终端', Icons.terminal),
            ('telnet', 'Telnet 连接', Icons.lan_outlined),
            ('serial', '串口', Icons.usb),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(type),
              child: Row(children: [Icon(icon, size: 18, color: colors.textDim), const SizedBox(width: 12), Text(tr(name))]),
            ),
        ],
      ),
    );
    if (type == null) return;
    setState(() {
      _editing = _blankProfile(type);
      _isNew = true;
    });
  }

  Future<void> _save(Map<String, dynamic> profile) async {
    final app = AppScope.read(context);
    profile.remove('isBuiltin');
    await app.updateConfig((config) {
      final profiles = config['profiles'] as List;
      final index = profiles.indexWhere((existing) => (existing as Map)['id'] == profile['id']);
      if (index >= 0) {
        profiles[index] = profile;
      } else {
        profiles.add(profile);
      }
    });
    setState(() {
      _editing = null;
      _isNew = false;
    });
  }

  Future<void> _delete(Map<String, dynamic> profile) async {
    final app = AppScope.read(context);
    final ok = await showConfirm(context, title: '删除配置？', message: tr('将删除「{name}」，同时清除钥匙串里保存的密码。', {'name': profile['name']}), confirm: '删除', danger: true);
    if (!ok) return;
    await rust.secretDelete(kind: 'password', profileId: profile['id'] as String);
    await app.updateConfig((config) {
      (config['profiles'] as List).removeWhere((existing) => (existing as Map)['id'] == profile['id']);
    });
    setState(() => _editing = null);
  }

  void _duplicate(Map<String, dynamic> profile) {
    final copy = _deepCopy(profile);
    copy['id'] = _newId();
    copy['name'] = tr('{name} 副本', {'name': profile['name']});
    copy.remove('isBuiltin');
    if (copy['group'] == 'ssh-config') copy['group'] = '';
    setState(() {
      _editing = copy;
      _isNew = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    if (editing != null) {
      return ProfileEditor(
        key: ValueKey(editing['id']),
        profile: editing,
        isNew: _isNew,
        onSave: _save,
        onCancel: () => setState(() {
          _editing = null;
          _isNew = false;
        }),
        onDelete: _isNew ? null : () => _delete(editing),
      );
    }
    return _list(context);
  }

  Widget _list(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final profile in app.profiles) {
      final text = '${profile['name']} ${profileDescription(profile)}'.toLowerCase();
      if (_filter.isNotEmpty && !text.contains(_filter.toLowerCase())) continue;
      grouped.putIfAbsent(groupName(app, profile), () => []).add(profile);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        Text(tr('配置和连接'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        SizedBox(
          width: 220,
          child: TextField(
            style: TextStyle(fontSize: 13, color: colors.text),
            decoration: InputDecoration(hintText: tr('筛选'), prefixIcon: Icon(Icons.search, size: 16)),
            onChanged: (value) => setState(() => _filter = value),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add, size: 16), label: Text(tr('新建'))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => _manageGroups(context), child: Text(tr('管理分组'))),
      ]),
      const SizedBox(height: 16),
      for (final entry in grouped.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(entry.key, style: TextStyle(fontSize: 12, color: colors.textDim, fontWeight: FontWeight.w600)),
        ),
        for (final profile in entry.value) _profileRow(context, app, colors, profile),
      ],
    ]);
  }

  Widget _profileRow(BuildContext context, AppState app, AppColors colors, Map<String, dynamic> profile) {
    final builtin = profile['isBuiltin'] == true;
    final color = parseHexColor(profile['color'] as String?);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: colors.surfaceRaised, borderRadius: BorderRadius.circular(4), border: Border.all(color: colors.border)),
      // ListTile 的悬停 / 水波纹画在最近的 Material 上，不包一层会被上面的背景色盖住
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          leading: Icon(profileIcon(profile), size: 18, color: color ?? colors.textDim),
          title: Text(profile['name'] as String, style: TextStyle(fontSize: 13, color: colors.text)),
          subtitle: Text(profileDescription(profile), style: TextStyle(fontSize: 11.5, color: colors.textDim)),
          onTap: builtin ? null : () => setState(() => _editing = _deepCopy(profile)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: tr('在新标签页打开'), iconSize: 16, icon: const Icon(Icons.play_arrow_outlined), onPressed: () => app.newTab(profile: profile)),
            IconButton(tooltip: tr(builtin ? '复制为新配置后可编辑' : '复制'), iconSize: 16, icon: const Icon(Icons.copy_outlined), onPressed: () => _duplicate(profile)),
            if (!builtin) IconButton(tooltip: tr('编辑'), iconSize: 16, icon: const Icon(Icons.edit_outlined), onPressed: () => setState(() => _editing = _deepCopy(profile))),
          ]),
        ),
      ),
    );
  }

  Future<void> _manageGroups(BuildContext context) async {
    final app = AppScope.read(context);
    final colors = AppTheme.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
        final groups = List<Map<String, dynamic>>.from((app.config['groups'] as List).map((group) => Map<String, dynamic>.from(group as Map)));
        return AlertDialog(
          title: Text(tr('分组'), style: TextStyle(fontSize: 15, color: colors.text)),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (groups.isEmpty) Text(tr('还没有分组'), style: TextStyle(color: colors.textDim)),
              for (final group in groups)
                ListTile(
                  dense: true,
                  title: Text(group['name'] as String),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      iconSize: 16,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final name = await showTextPrompt(dialogContext, title: '重命名分组', initial: group['name'] as String);
                        if (name == null || name.trim().isEmpty) return;
                        await app.updateConfig((config) {
                          for (final entry in config['groups'] as List) {
                            if ((entry as Map)['id'] == group['id']) entry['name'] = name.trim();
                          }
                        });
                        setDialogState(() {});
                      },
                    ),
                    IconButton(
                      iconSize: 16,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await app.updateConfig((config) {
                          (config['groups'] as List).removeWhere((entry) => (entry as Map)['id'] == group['id']);
                          for (final profile in config['profiles'] as List) {
                            if ((profile as Map)['group'] == group['id']) profile['group'] = '';
                          }
                        });
                        setDialogState(() {});
                      },
                    ),
                  ]),
                ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final name = await showTextPrompt(dialogContext, title: '新建分组');
                if (name == null || name.trim().isEmpty) return;
                await app.updateConfig((config) => (config['groups'] as List).add({'id': _newId(), 'name': name.trim(), 'collapsed': false}));
                setDialogState(() {});
              },
              child: Text(tr('新建分组')),
            ),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('完成'))),
          ],
        );
      }),
    );
  }
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.profile, required this.isNew, required this.onSave, required this.onCancel, this.onDelete});

  final Map<String, dynamic> profile;
  final bool isNew;
  final Future<void> Function(Map<String, dynamic> profile) onSave;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final Map<String, dynamic> _profile = _deepCopy(widget.profile);
  Map<String, dynamic> get _options => _profile['options'] as Map<String, dynamic>;
  String get _type => _profile['type'] as String;
  bool? _passwordSaved;
  List<String> _serialPorts = [];

  @override
  void initState() {
    super.initState();
    if (_type == 'ssh') _refreshPassword();
    if (_type == 'serial') rust.serialPorts().then((ports) => setState(() => _serialPorts = ports));
  }

  Future<void> _refreshPassword() async {
    final saved = await rust.secretExists(kind: 'password', profileId: _profile['id'] as String);
    if (mounted) setState(() => _passwordSaved = saved);
  }

  void _set(String key, dynamic value) => setState(() => _profile[key] = value);
  void _setOption(String key, dynamic value) => setState(() => _options[key] = value);

  Widget _text(String label, String key, {String? hint, bool number = false, String? help, double width = 320, bool option = true}) {
    final source = option ? _options : _profile;
    final value = source[key];
    return SettingRow(
      label: label,
      help: help,
      control: CommitTextField(
        width: width,
        hint: hint,
        number: number,
        value: value?.toString() ?? '',
        onCommit: (text) {
          final parsed = number ? int.tryParse(text) : text;
          if (number && parsed == null) return;
          option ? _setOption(key, parsed) : _set(key, parsed);
        },
      ),
    );
  }

  /// numeric：选项是数字（波特率等），存回配置时要转成整数，否则 Rust 反序列化会失败
  Widget _dropdown(String label, String key, Map<String, String> options, {bool option = true, String? help, bool numeric = false}) {
    final source = option ? _options : _profile;
    return SettingRow(
      label: label,
      help: help,
      control: SizedBox(
        width: 320,
        child: ChoiceDropdown(
          value: source[key]?.toString() ?? '',
          options: options,
          onChanged: (value) {
            final stored = numeric ? int.parse(value) : value;
            option ? _setOption(key, stored) : _set(key, stored);
          },
        ),
      ),
    );
  }

  Widget _switch(String label, String key, {String? help}) => SettingRow(
        label: label,
        help: help,
        control: CompactSwitch(value: _options[key] == true, onChanged: (value) => _setOption(key, value)),
      );

  /// 每行一项的列表字段（参数、私钥、环境变量）
  Widget _lines(String label, String key, {String? help, String? hint, bool pairs = false}) {
    final raw = (_options[key] as List?) ?? [];
    final text = pairs ? raw.map((pair) => '${(pair as List)[0]}=${pair[1]}').join('\n') : raw.join('\n');
    return SettingRow(
      label: label,
      help: help,
      control: CommitTextField(
        width: 320,
        maxLines: 3,
        hint: hint,
        value: text,
        onCommit: (value) {
          final lines = value.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
          if (pairs) {
            _setOption(key, [
              for (final line in lines)
                if (line.contains('=')) [line.substring(0, line.indexOf('=')), line.substring(line.indexOf('=') + 1)],
            ]);
          } else {
            _setOption(key, lines);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final groups = {'': '未分组', for (final group in (app.config['groups'] as List)) (group as Map)['id'] as String: group['name'] as String};
    final typeNames = {'local': '本地终端', 'ssh': 'SSH', 'telnet': 'Telnet', 'serial': '串口'};

    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back, size: 18), onPressed: widget.onCancel, tooltip: tr('返回')),
        Text(widget.isNew ? tr('新建{type}配置', {'type': tr(typeNames[_type]!)}) : tr('编辑配置'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const Spacer(),
        if (widget.onDelete != null)
          TextButton(onPressed: widget.onDelete, child: Text(tr('删除'), style: TextStyle(color: colors.danger))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: widget.onCancel, child: Text(tr('取消'))),
        const SizedBox(width: 8),
        FilledButton(onPressed: () => widget.onSave(_profile), child: Text(tr('保存'))),
      ]),
      const SizedBox(height: 16),
      SettingsSection(title: '常规', children: [
        _text('名称', 'name', option: false),
        _dropdown('分组', 'group', groups, option: false),
        SettingRow(
          label: '图标',
          control: Wrap(spacing: 4, children: [
            for (final entry in {'': profileIcon({'type': _type}), ...profileIconChoices}.entries)
              InkWell(
                onTap: () => _set('icon', entry.key),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    border: Border.all(color: _profile['icon'] == entry.key ? colors.accent : Colors.transparent),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(entry.value, size: 16, color: colors.textDim),
                ),
              ),
          ]),
        ),
        SettingRow(
          label: '颜色',
          help: '标签页顶部的彩标',
          control: Wrap(spacing: 6, children: [
            for (final color in ['', ...tabColors])
              GestureDetector(
                onTap: () => _set('color', color),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: parseHexColor(color),
                    shape: BoxShape.circle,
                    border: Border.all(color: _profile['color'] == color ? colors.text : colors.border, width: 1.5),
                  ),
                  child: color.isEmpty ? Icon(Icons.block, size: 12, color: colors.textDim) : null,
                ),
              ),
          ]),
        ),
        _dropdown('会话结束时', 'behaviorOnSessionEnd', {
          'auto': '正常退出时关闭，出错时保留',
          'keep': '保留标签页',
          'reconnect': '自动重新连接',
          'close': '关闭标签页',
        }, option: false),
        SettingRow(
          label: '禁用动态标题',
          help: '标签页始终显示配置名，不跟随程序设置的标题',
          control: CompactSwitch(value: _profile['disableDynamicTitle'] == true, onChanged: (value) => _set('disableDynamicTitle', value)),
        ),
      ]),
      ...switch (_type) {
        'ssh' => _sshSections(app, colors),
        'telnet' => [
            SettingsSection(title: '连接', children: [_text('主机', 'host'), _text('端口', 'port', number: true, width: 100)]),
          ],
        'serial' => _serialSections(),
        _ => [
            SettingsSection(title: '命令', children: [
              _text('程序', 'command', hint: '/bin/zsh', help: '可执行文件的完整路径'),
              _lines('参数', 'args', help: '每行一个', hint: '-l'),
              _text('工作目录', 'cwd', hint: '留空 = 用户主目录'),
              _lines('环境变量', 'env', help: '每行一个 KEY=VALUE', pairs: true),
            ]),
          ],
      },
    ]);
  }

  List<Widget> _sshSections(AppState app, AppColors colors) {
    final jumpHosts = {
      '': '不使用',
      for (final profile in app.profiles)
        if (profile['type'] == 'ssh' && profile['id'] != _profile['id']) profile['id'] as String: profile['name'] as String,
    };
    final forwards = List<Map<String, dynamic>>.from(((_options['forwardedPorts'] as List?) ?? []).map((item) => Map<String, dynamic>.from(item as Map)));
    final scripts = List<Map<String, dynamic>>.from(((_options['loginScripts'] as List?) ?? []).map((item) => Map<String, dynamic>.from(item as Map)));

    return [
      SettingsSection(title: '连接', children: [
        _text('主机', 'host', hint: 'example.com'),
        _text('端口', 'port', number: true, width: 100),
        _text('用户名', 'user', hint: '留空则连接时询问'),
        _dropdown('跳板机', 'jumpHost', jumpHosts),
        _text('代理命令', 'proxyCommand', hint: 'ssh -W %h:%p bastion.example.com', help: 'ProxyCommand：经由此命令的输入输出连接，%h 主机、%p 端口、%r 用户；设置了跳板机时以跳板机为准'),
      ]),
      SettingsSection(title: '认证', children: [
        _dropdown('方式', 'auth', {
          'auto': '自动（agent → 私钥 → 键盘交互 → 密码）',
          'password': '密码',
          'publicKey': '私钥',
          'agent': 'ssh-agent',
          'keyboardInteractive': '键盘交互',
        }),
        _lines('私钥文件', 'privateKeys', help: '每行一个路径；留空时自动尝试 ~/.ssh/id_ed25519 等', hint: '~/.ssh/id_ed25519'),
        SettingRow(
          label: '密码',
          help: _passwordSaved == true ? '已保存在系统钥匙串' : '不保存时连接时询问；密码只写入系统钥匙串，不进配置文件',
          control: Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton(
              onPressed: () async {
                final value = await _askPassword(context);
                if (value == null) return;
                await rust.secretSet(kind: 'password', profileId: _profile['id'] as String, value: value);
                _refreshPassword();
              },
              child: Text(tr(_passwordSaved == true ? '修改密码' : '保存密码')),
            ),
            if (_passwordSaved == true) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await rust.secretDelete(kind: 'password', profileId: _profile['id'] as String);
                  _refreshPassword();
                },
                child: Text(tr('清除'), style: TextStyle(color: colors.danger)),
              ),
            ],
          ]),
        ),
        _switch('转发 ssh-agent', 'agentForward', help: '只对信任的服务器开启'),
      ]),
      SettingsSection(title: '端口转发', description: '本地：把本机端口转发到远端可访问的地址；远程：把服务器端口转发回本机；动态：本机 SOCKS5 代理', children: [
        for (var index = 0; index < forwards.length; index++) _forwardRow(forwards, index, colors),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              forwards.add({'type': 'local', 'host': '127.0.0.1', 'port': 8080, 'targetAddress': '127.0.0.1', 'targetPort': 80, 'description': ''});
              _setOption('forwardedPorts', forwards);
            },
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('添加转发')),
          ),
        ),
      ]),
      SettingsSection(title: '登录脚本', description: '连接后等待出现指定文本再发送命令；等待文本留空则立即发送', children: [
        for (var index = 0; index < scripts.length; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(
                child: CommitTextField(
                  width: null,
                  hint: '等待文本，如 \$ ',
                  value: scripts[index]['expect'] as String? ?? '',
                  onCommit: (value) {
                    scripts[index]['expect'] = value;
                    _setOption('loginScripts', scripts);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: CommitTextField(
                  width: null,
                  hint: '发送的命令',
                  value: scripts[index]['send'] as String? ?? '',
                  onCommit: (value) {
                    scripts[index]['send'] = value;
                    _setOption('loginScripts', scripts);
                  },
                ),
              ),
              IconButton(
                iconSize: 16,
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  scripts.removeAt(index);
                  _setOption('loginScripts', scripts);
                },
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              scripts.add({'expect': '', 'send': ''});
              _setOption('loginScripts', scripts);
            },
            icon: const Icon(Icons.add, size: 16),
            label: Text(tr('添加一步')),
          ),
        ),
      ]),
      SettingsSection(title: '高级', children: [
        _text('保活间隔（秒）', 'keepaliveInterval', number: true, width: 100, help: '0 = 不发送'),
        _text('保活失败次数上限', 'keepaliveCountMax', number: true, width: 100),
        _text('连接超时（秒）', 'readyTimeout', number: true, width: 100),
      ]),
    ];
  }

  Widget _forwardRow(List<Map<String, dynamic>> forwards, int index, AppColors colors) {
    final forward = forwards[index];
    void update(String key, dynamic value) {
      forward[key] = value;
      _setOption('forwardedPorts', forwards);
    }

    final isDynamic = forward['type'] == 'dynamic';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(
          width: 100,
          child: ChoiceDropdown(value: forward['type'] as String? ?? 'local', options: const {'local': '本地', 'remote': '远程', 'dynamic': '动态'}, onChanged: (value) => update('type', value)),
        ),
        const SizedBox(width: 6),
        CommitTextField(width: 120, hint: '监听地址', value: forward['host'] as String? ?? '', onCommit: (value) => update('host', value)),
        const SizedBox(width: 6),
        CommitTextField(width: 70, number: true, hint: '端口', value: '${forward['port'] ?? ''}', onCommit: (value) => update('port', int.tryParse(value) ?? 0)),
        if (!isDynamic) ...[
          Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 14, color: colors.textDim)),
          CommitTextField(width: 120, hint: '目标地址', value: forward['targetAddress'] as String? ?? '', onCommit: (value) => update('targetAddress', value)),
          const SizedBox(width: 6),
          CommitTextField(width: 70, number: true, hint: '端口', value: '${forward['targetPort'] ?? ''}', onCommit: (value) => update('targetPort', int.tryParse(value) ?? 0)),
        ],
        IconButton(
          iconSize: 16,
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            forwards.removeAt(index);
            _setOption('forwardedPorts', forwards);
          },
        ),
      ]),
    );
  }

  List<Widget> _serialSections() {
    final ports = {for (final port in _serialPorts) port: port};
    return [
      SettingsSection(title: '串口', children: [
        if (ports.isEmpty) _text('端口', 'port', hint: Platform.isWindows ? 'COM3' : '/dev/cu.usbserial-0001') else _dropdown('端口', 'port', ports),
        _dropdown('波特率', 'baudrate', {for (final rate in [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]) '$rate': '$rate'}, numeric: true),
        _dropdown('数据位', 'databits', const {'5': '5', '6': '6', '7': '7', '8': '8'}, numeric: true),
        _dropdown('停止位', 'stopbits', const {'1': '1', '2': '2'}, numeric: true),
        _dropdown('校验', 'parity', const {'none': '无', 'odd': '奇校验', 'even': '偶校验'}),
        _dropdown('流控', 'flowcontrol', const {'none': '无', 'software': '软件 (XON/XOFF)', 'hardware': '硬件 (RTS/CTS)'}),
        _dropdown('回车发送', 'outputNewlines', const {'cr': 'CR', 'lf': 'LF', 'crlf': 'CRLF'}),
        _switch('本地回显', 'localEcho'),
      ]),
    ];
  }

  Future<String?> _askPassword(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('保存密码'), style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(hintText: tr('密码')),
            onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(tr('取消'))),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(controller.text), child: Text(tr('保存到钥匙串'))),
        ],
      ),
    );
  }
}
