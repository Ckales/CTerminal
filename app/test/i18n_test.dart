// 英文界面完整性：lib/ 里每一处中文界面文字都要有英文翻译。
// 新增界面文字忘了加翻译时这里会失败，并列出缺的句子。
import 'dart:io';

import 'package:cterminal/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

final _literal = RegExp(r"'((?:[^'\\\n]|\\.)*[一-鿿](?:[^'\\\n]|\\.)*)'");

/// 不是界面文字：日志、语言选项本身、按序号生成的动作名
bool _skip(String line, String text) =>
    line.contains('debugPrint') || text == '简体中文' || RegExp(r'^切换到标签页 \d$').hasMatch(text);

void main() {
  test('所有中文界面文字都有英文翻译', () {
    setLanguage('en');
    final missing = <String>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path;
      if (!path.endsWith('.dart') || path.contains('/src/rust/') || path.endsWith('i18n.dart')) continue;
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.startsWith('//')) continue;
        for (final match in _literal.allMatches(line)) {
          final text = match.group(1)!.replaceAll(r'\n', '\n').replaceAll(r'\$', r'$');
          if (_skip(line, text)) continue;
          if (tr(text) == text) missing.add('$path: $text');
        }
      }
    }
    setLanguage('zh');
    expect(missing, isEmpty, reason: '缺少英文翻译：\n${missing.join('\n')}');
  });

  test('占位符替换', () {
    setLanguage('en');
    expect(tr('还有 {count} 个会话正在运行，退出后会全部结束。', {'count': 2}), 'There are 2 running sessions. Quitting will end all of them.');
    setLanguage('zh');
    expect(tr('还有 {count} 个会话正在运行，退出后会全部结束。', {'count': 2}), '还有 2 个会话正在运行，退出后会全部结束。');
  });
}
