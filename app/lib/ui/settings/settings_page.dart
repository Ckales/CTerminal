import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../src/rust/api/settings.dart' as rust;
import '../../src/rust/api/update.dart' as update;
import '../../terminal/terminal_view.dart' show openExternal;
import '../../theme.dart';
import '../../update_check.dart';
import '../../version.dart';
import '../selector.dart';
import 'color_schemes_page.dart';
import 'highlight_page.dart';
import 'hotkeys_page.dart';
import 'profiles_page.dart';
import 'vault_page.dart';
import 'widgets.dart';
import '../../i18n.dart';

const _pages = <(String, String, IconData)>[
  ('application', '应用', Icons.apps_outlined),
  ('appearance', '外观', Icons.palette_outlined),
  ('colorScheme', '配色方案', Icons.format_color_fill_outlined),
  ('highlight', '关键字高亮', Icons.highlight_outlined),
  ('terminal', '终端', Icons.terminal),
  ('profiles', '配置和连接', Icons.dns_outlined),
  ('hotkeys', '快捷键', Icons.keyboard_outlined),
  ('ssh', 'SSH', Icons.vpn_key_outlined),
  ('vault', '凭据', Icons.lock_outline),
  ('configFile', '配置文件', Icons.description_outlined),
  ('about', '关于', Icons.info_outline),
];

/// 设置以标签页打开，可以和终端并排切换对照
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.tab});

  final SettingsTab tab;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final page = tab.page.split(':').first;
    final argument = tab.page.contains(':') ? tab.page.substring(tab.page.indexOf(':') + 1) : '';

    return Container(
      color: colors.surface,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 200,
          decoration: BoxDecoration(color: colors.chrome, border: Border(right: BorderSide(color: colors.border))),
          child: ListView(padding: const EdgeInsets.symmetric(vertical: 12), children: [
            for (final (id, name, icon) in _pages)
              _NavItem(
                name: name,
                icon: icon,
                selected: page == id,
                onTap: () {
                  tab.page = id;
                  app.openSettings(id);
                },
              ),
          ]),
        ),
        Expanded(
          child: switch (page) {
            'appearance' => _scroll(const _AppearancePage()),
            'colorScheme' => const ColorSchemesPage(),
            'highlight' => const HighlightPage(),
            'terminal' => _scroll(const _TerminalPage()),
            'profiles' => ProfilesPage(editId: argument, key: ValueKey('profiles:$argument')),
            'hotkeys' => const HotkeysPage(),
            'ssh' => _scroll(const _SshPage()),
            'vault' => const VaultPage(),
            'configFile' => const _ConfigFilePage(),
            'about' => _scroll(const _AboutPage()),
            _ => _scroll(const _ApplicationPage()),
          },
        ),
      ]),
    );
  }

  Widget _scroll(Widget child) => ListView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), children: [child]);
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.name, required this.icon, required this.selected, required this.onTap});

  final String name;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? colors.tabActive : null,
          border: Border(left: BorderSide(color: selected ? colors.accent : Colors.transparent, width: 2)),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: selected ? colors.text : colors.textDim),
          const SizedBox(width: 10),
          Text(tr(name), style: TextStyle(fontSize: 13, color: selected ? colors.text : colors.textDim)),
        ]),
      ),
    );
  }
}

class _ApplicationPage extends StatelessWidget {
  const _ApplicationPage();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final profiles = {for (final profile in app.profiles) profile['id'] as String: profile['name'] as String};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsSection(title: '启动', children: [
        const ConfigSwitch(path: 'application.restoreTabs', label: '启动时恢复标签页', help: '重新打开上次退出时的标签页和分屏布局'),
        const ConfigSwitch(path: 'application.enableWelcomeTab', label: '显示欢迎页'),
        ConfigDropdown(
          path: 'application.defaultProfile',
          label: '默认配置',
          help: '新建标签页时使用',
          options: {'': '系统默认 shell', ...profiles},
        ),
      ]),
      const SettingsSection(title: '行为', children: [
        ConfigDropdown(path: 'application.language', label: '语言', options: {'system': '跟随系统', 'zh-CN': '简体中文', 'en': 'English'}),
        ConfigSwitch(path: 'application.confirmOnClose', label: '退出时确认', help: '有会话在运行时关闭窗口会先询问'),
        ConfigSwitch(path: 'application.checkForUpdates', label: '自动检查更新', help: '启动时检查 GitHub 上的新版本，每天最多一次'),
      ]),
    ]);
  }
}

class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    final fonts = Platform.isMacOS
        ? {'Menlo': 'Menlo', 'SF Mono': 'SF Mono', 'Monaco': 'Monaco', 'Courier New': 'Courier New', 'JetBrains Mono': 'JetBrains Mono', 'Fira Code': 'Fira Code'}
        : {'Consolas': 'Consolas', 'Cascadia Mono': 'Cascadia Mono', 'Cascadia Code': 'Cascadia Code', 'Courier New': 'Courier New', 'JetBrains Mono': 'JetBrains Mono'};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SettingsSection(title: '窗口', children: [
        ConfigDropdown(path: 'appearance.theme', label: '主题', options: {'dark': '深色', 'light': '浅色', 'system': '跟随系统'}),
        ConfigDropdown(
          path: 'appearance.tabsLocation',
          label: '标签栏位置',
          options: {'top': '顶部', 'bottom': '底部', 'left': '左侧', 'right': '右侧'},
        ),
        ConfigSwitch(path: 'appearance.flexibleTabs', label: '标签页等宽铺满'),
        ConfigSwitch(path: 'appearance.showTabProfileIcon', label: '标签页显示配置图标'),
        ConfigSwitch(path: 'appearance.showTabCloseButton', label: '标签页显示关闭按钮'),
        ConfigSlider(path: 'appearance.opacity', label: '终端背景不透明度', min: 0.3, max: 1, divisions: 14),
        ConfigSlider(path: 'appearance.zoom', label: '界面缩放', min: 0.8, max: 1.5, divisions: 14),
      ]),
      SettingsSection(title: '字体', children: [
        SettingRow(
          label: '字体',
          help: '可以直接输入已安装的等宽字体名',
          control: SizedBox(
            width: 220,
            child: _FontField(options: fonts),
          ),
        ),
        const ConfigNumber(path: 'terminal.fontSize', label: '字号', min: 6, max: 72, integer: false),
        const ConfigSlider(path: 'terminal.lineHeight', label: '行高', min: 1, max: 2, divisions: 20),
        const ConfigSwitch(path: 'terminal.ligatures', label: '连字', help: '字体支持时（如 Fira Code、JetBrains Mono）把 -> != >= 等显示为一个字形'),
      ]),
      const SettingsSection(title: '光标', children: [
        ConfigDropdown(path: 'terminal.cursor', label: '光标形状', options: {'block': '方块', 'underline': '下划线', 'beam': '竖线'}),
        ConfigSwitch(path: 'terminal.cursorBlink', label: '光标闪烁'),
      ]),
    ]);
  }
}

class _FontField extends StatelessWidget {
  const _FontField({required this.options});

  final Map<String, String> options;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final current = app.terminal['font'] as String;
    return Row(children: [
      Expanded(
        child: CommitTextField(
          width: null,
          value: current,
          onCommit: (value) => app.updateConfig((config) => config['terminal']['font'] = value.trim()),
        ),
      ),
      PopupMenuButton<String>(
        tooltip: tr('常用字体'),
        icon: const Icon(Icons.arrow_drop_down, size: 18),
        itemBuilder: (context) => [for (final font in options.keys) PopupMenuItem(value: font, height: 30, child: Text(font, style: TextStyle(fontFamily: font, fontSize: 13)))],
        onSelected: (font) => app.updateConfig((config) => config['terminal']['font'] = font),
      ),
    ]);
  }
}

class _TerminalPage extends StatelessWidget {
  const _TerminalPage();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsSection(title: '键盘', children: [
        if (Platform.isMacOS) const ConfigSwitch(path: 'terminal.altIsMeta', label: '把 Option 键当作 Meta', help: '开启后 ⌥B / ⌥F 等发送 ESC 前缀序列，关闭时输入特殊字符'),
        const ConfigSwitch(path: 'terminal.scrollOnInput', label: '输入时滚动到底部'),
      ]),
      const SettingsSection(title: '鼠标与剪贴板', children: [
        ConfigSwitch(path: 'terminal.copyOnSelect', label: '选中即复制'),
        ConfigDropdown(
          path: 'terminal.rightClick',
          label: '右键',
          options: {'menu': '显示菜单', 'paste': '粘贴', 'clipboard': '有选区时复制，否则粘贴'},
        ),
        ConfigSwitch(path: 'terminal.pasteOnMiddleClick', label: '中键粘贴'),
        ConfigSwitch(path: 'terminal.warnOnMultilinePaste', label: '粘贴多行内容前确认'),
      ]),
      const SettingsSection(title: '显示', children: [
        ConfigNumber(path: 'terminal.scrollbackLines', label: '回滚行数', help: '新开的会话生效', min: 100, max: 1000000),
        ConfigSwitch(path: 'terminal.boldIsBright', label: '粗体使用亮色'),
        ConfigNumber(path: 'terminal.padding', label: '内边距', min: 0, max: 40, integer: false),
        ConfigDropdown(path: 'terminal.bell', label: '响铃', options: {'off': '关闭', 'visual': '闪烁', 'audible': '声音'}),
      ]),
    ]);
  }
}

class _SshPage extends StatelessWidget {
  const _SshPage();

  @override
  Widget build(BuildContext context) {
    return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsSection(title: '主机密钥', children: [
        ConfigSwitch(path: 'ssh.verifyHostKeys', label: '校验主机密钥', help: '首次连接时确认指纹，密钥变更时警告（强烈建议开启）'),
        ConfigText(path: 'ssh.knownHostsFile', label: 'known_hosts 文件', hint: '~/.ssh/known_hosts', width: 300),
      ]),
      SettingsSection(title: '认证', children: [
        ConfigSwitch(path: 'ssh.useAgent', label: '使用 ssh-agent', help: 'macOS / Linux 读取 SSH_AUTH_SOCK，Windows 使用 OpenSSH Agent'),
      ]),
    ]);
  }
}

class _ConfigFilePage extends StatefulWidget {
  const _ConfigFilePage();

  @override
  State<_ConfigFilePage> createState() => _ConfigFilePageState();
}

class _ConfigFilePageState extends State<_ConfigFilePage> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    final path = rust.configFilePath();
    final pretty = const JsonEncoder.withIndent('  ').convert(app.config);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('配置文件'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(height: 6),
        SelectableText(path, style: TextStyle(fontSize: 12, color: colors.textDim, fontFamily: 'Menlo')),
        const SizedBox(height: 4),
        Text(tr('密码、口令不会写进这个文件，它们保存在系统钥匙串里。'), style: TextStyle(fontSize: 12, color: colors.textDim)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          OutlinedButton(
            onPressed: () => Platform.isMacOS ? Process.run('open', ['-R', path]) : Process.run('explorer', ['/select,', path]),
            child: Text(tr(Platform.isMacOS ? '在访达中显示' : '在资源管理器中显示')),
          ),
          OutlinedButton(
            onPressed: () => Platform.isMacOS ? Process.run('open', ['-t', path]) : Process.run('notepad', [path]),
            child: Text(tr('用文本编辑器打开')),
          ),
          OutlinedButton(
            // 与 Rust 侧 log.rs 约定：配置目录/logs
            onPressed: () => Process.run(Platform.isMacOS ? 'open' : 'explorer', ['${File(path).parent.path}${Platform.pathSeparator}logs']),
            child: Text(tr('打开日志目录')),
          ),
          OutlinedButton(
            onPressed: () async {
              try {
                final loaded = await rust.configLoad();
                await app.replaceConfigJson(loaded);
                setState(() => _error = null);
              } catch (error) {
                setState(() => _error = '$error');
              }
            },
            child: Text(tr('重新加载')),
          ),
          OutlinedButton(
            onPressed: () async {
              final ok = await showConfirm(context, title: '恢复默认设置？', message: tr('所有设置会恢复默认值，已保存的配置（连接）会保留。'), danger: true, confirm: '恢复');
              if (!ok) return;
              final defaults = jsonDecode(rust.configDefaults()) as Map<String, dynamic>;
              defaults['profiles'] = app.config['profiles'];
              defaults['groups'] = app.config['groups'];
              defaults['customColorSchemes'] = app.config['customColorSchemes'];
              await app.replaceConfigJson(jsonEncode(defaults));
            },
            child: Text(tr('恢复默认设置')),
          ),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: colors.danger, fontSize: 12))),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: colors.surfaceRaised, border: Border.all(color: colors.border), borderRadius: BorderRadius.circular(4)),
            child: SingleChildScrollView(child: SelectableText(pretty, style: TextStyle(fontSize: 12, fontFamily: 'Menlo', color: colors.text))),
          ),
        ),
      ]),
    );
  }
}

class _AboutPage extends StatefulWidget {
  const _AboutPage();

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  bool _checking = false;
  update.UpdateInfo? _result;
  String? _error;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await UpdateCheck.checkNow();
      if (!mounted) return;
      setState(() => _result = result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    TextStyle dim = TextStyle(fontSize: 13, color: colors.textDim, height: 1.6);
    final result = _result;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('CTerminal', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: colors.text)),
      const SizedBox(height: 4),
      Text(tr('版本 {version}', {'version': update.appVersion()}), style: dim),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton(onPressed: _checking ? null : _check, child: Text(tr(_checking ? '正在检查…' : '检查更新'))),
        const SizedBox(width: 12),
        if (_error != null)
          Flexible(child: Text(_error!, style: TextStyle(fontSize: 12, color: colors.danger)))
        else if (result != null && result.newer)
          InkWell(
            onTap: () => openExternal(result.url),
            child: Text(tr('发现新版本 {version}，点击打开发布页', {'version': result.latest}), style: TextStyle(fontSize: 12, color: colors.accent)),
          )
        else if (result != null)
          Text(tr('已是最新版本'), style: TextStyle(fontSize: 12, color: colors.textDim)),
      ]),
      const SizedBox(height: 16),
      Text(tr('跨平台桌面终端。Flutter 绘制界面，Rust 负责终端内核与连接。'), style: dim),
      const SizedBox(height: 16),
      Text(tr('开源许可：MIT'), style: dim),
      Text(tr('终端内核 alacritty_terminal · SSH russh · PTY portable-pty · 串口 serialport · 钥匙串 keyring'), style: dim),
      const SizedBox(height: 16),
      TextButton.icon(
        onPressed: () => Process.run(Platform.isMacOS ? 'open' : 'explorer', [projectUrl]),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: const Text(projectUrl),
      ),
    ]);
  }
}
