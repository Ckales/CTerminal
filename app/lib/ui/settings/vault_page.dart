import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../src/rust/api/settings.dart' as rust;
import '../../theme.dart';
import '../../i18n.dart';

/// 秘密交给系统钥匙串，配置文件里不出现任何秘密
class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  Map<String, bool> _saved = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final result = <String, bool>{};
    for (final profile in app.profiles.where((profile) => profile['type'] == 'ssh')) {
      final id = profile['id'] as String;
      result[id] = await rust.secretExists(kind: 'password', profileId: id);
    }
    if (mounted) {
      setState(() {
        _saved = result;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final store = Platform.isMacOS ? 'macOS 钥匙串（钥匙串访问 → 登录 → 搜索 “CTerminal”）' : 'Windows 凭据管理器（Windows 凭据 → “CTerminal”）';
    final ssh = app.profiles.where((profile) => profile['type'] == 'ssh').toList();
    return ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [
      Text(tr('凭据'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
      const SizedBox(height: 6),
      Text(tr('SSH 密码和私钥口令只保存在{store}。\n配置文件、日志、标签页恢复数据里都不会出现明文密码；界面层也读不到已保存的密码，只能覆盖或删除。', {'store': tr(store)}),
          style: TextStyle(fontSize: 12.5, color: colors.textDim, height: 1.6)),
      const SizedBox(height: 16),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      for (final profile in ssh)
        ListTile(
          dense: true,
          leading: Icon(Icons.key_outlined, size: 18, color: colors.textDim),
          title: Text(profile['name'] as String, style: TextStyle(fontSize: 13, color: colors.text)),
          subtitle: Text(tr(_saved[profile['id']] == true ? '已保存密码' : '未保存密码'), style: TextStyle(fontSize: 11.5, color: colors.textDim)),
          trailing: _saved[profile['id']] == true
              ? TextButton(
                  onPressed: () async {
                    await rust.secretDelete(kind: 'password', profileId: profile['id'] as String);
                    _load();
                  },
                  child: Text(tr('删除'), style: TextStyle(color: colors.danger)),
                )
              : null,
        ),
      if (ssh.isEmpty && !_loading) Text(tr('还没有 SSH 配置'), style: TextStyle(color: colors.textDim)),
    ]);
  }
}
