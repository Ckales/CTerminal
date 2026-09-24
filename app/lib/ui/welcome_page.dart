import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import 'settings/widgets.dart';
import '../i18n.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.tab});

  final WelcomeTab tab;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final colors = AppTheme.of(context);
    return Container(
      color: colors.surface,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 620,
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 48), children: [
          Text(tr('欢迎使用 CTerminal'), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: colors.text)),
          const SizedBox(height: 8),
          Text(tr('先调几个常用设置，其余的随时可以在设置里改。'), style: TextStyle(fontSize: 13, color: colors.textDim)),
          const SizedBox(height: 28),
          const ConfigDropdown(path: 'appearance.theme', label: '主题', options: {'dark': '深色', 'light': '浅色', 'system': '跟随系统'}),
          const ConfigDropdown(path: 'appearance.tabsLocation', label: '标签栏位置', options: {'top': '顶部', 'bottom': '底部', 'left': '左侧', 'right': '右侧'}),
          const ConfigNumber(path: 'terminal.fontSize', label: '字号', min: 6, max: 72, integer: false),
          const ConfigSwitch(path: 'application.restoreTabs', label: '启动时恢复标签页'),
          const ConfigSwitch(path: 'terminal.copyOnSelect', label: '选中即复制'),
          const SizedBox(height: 28),
          Row(children: [
            FilledButton(
              onPressed: () async {
                await app.updateConfig((config) => config['application']['enableWelcomeTab'] = false);
                app.closeTab(tab);
              },
              child: Text(tr('开始使用')),
            ),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: () => app.openSettings(), child: Text(tr('打开全部设置'))),
          ]),
        ]),
      ),
    );
  }
}
