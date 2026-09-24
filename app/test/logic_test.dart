import 'package:cterminal/cli.dart';
import 'package:cterminal/hotkeys.dart';
import 'package:cterminal/pane_tree.dart';
import 'package:cterminal/src/rust/api/terminal.dart';
import 'package:cterminal/terminal/terminal_painter.dart';
import 'package:cterminal/ui/profile_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hotkey', () {
    test('解析快捷键格式', () {
      expect(Hotkey.parse('⌘-Shift-D'), const Hotkey(key: 'D', meta: true, shift: true));
      expect(Hotkey.parse('Ctrl-⌘-F'), const Hotkey(key: 'F', meta: true, ctrl: true));
      expect(Hotkey.parse('⌘--'), const Hotkey(key: '-', meta: true));
      expect(Hotkey.parse('⌘-⌥-Right'), const Hotkey(key: 'Right', meta: true, alt: true));
      expect(Hotkey.parse('Ctrl-Shift-Alt-1'), const Hotkey(key: '1', ctrl: true, shift: true, alt: true));
      expect(Hotkey.parse('Hyper-X'), isNull);
    });

    test('格式化后能解析回来', () {
      const hotkey = Hotkey(key: '-', meta: true, shift: true);
      expect(Hotkey.parse(hotkey.format()), hotkey);
    });
  });

  group('动作名', () {
    test('按序号生成的动作都有名字', () {
      expect(hotkeyActionNames.containsKey('tab-20'), isTrue);
      expect(hotkeyActionNames.containsKey('pane-nav-9'), isTrue);
      expect(actionName('tab-15'), '切换到标签页 15');
      expect(actionName('pane-nav-3'), '聚焦第 3 个窗格');
      expect(actionName('focus-all-tabs'), '同时输入到所有标签页');
    });
  });

  group('连字', () {
    TermLine line(String text) => TermLine(hash: 42, runs: [TermRun(col: 0, width: text.length, text: text, fg: 0xffffff, bg: 0, flags: 0)]);

    test('光标所在格单独成段，其余按格子定位', () {
      final metrics = TerminalMetrics(fontFamily: 'Menlo', fontSize: 14, lineHeight: 1.2, ligatures: true);
      final cache = ParagraphCache();
      final whole = cache.line(line('a->b'), metrics);
      expect(whole.pieces.length, 1);
      final split = cache.line(line('a->b'), metrics, cursorCol: 2);
      expect([for (final piece in split.pieces) piece.x], [0, 2 * metrics.cellWidth, 3 * metrics.cellWidth]);
      expect([for (final piece in split.pieces) piece.width], [2 * metrics.cellWidth, metrics.cellWidth, metrics.cellWidth]);
      final atStart = cache.line(line('a->b'), metrics, cursorCol: 0);
      expect([for (final piece in atStart.pieces) piece.x], [0, metrics.cellWidth]);
      cache.clear();
    });

    test('开关连字会让段落缓存失效', () {
      final off = TerminalMetrics(fontFamily: 'Menlo', fontSize: 14, lineHeight: 1.2);
      final on = TerminalMetrics(fontFamily: 'Menlo', fontSize: 14, lineHeight: 1.2, ligatures: true);
      expect(off.sameAs(on), isFalse);
      final cache = ParagraphCache();
      final first = cache.line(line('!='), off);
      expect(identical(cache.line(line('!='), off), first), isTrue);
      expect(identical(cache.line(line('!='), on), first), isFalse);
      cache.clear();
    });
  });

  group('PaneTree', () {
    test('同方向拆分并入父分支并平均分配', () {
      final tree = PaneTree('a');
      tree.split('a', 'b', SplitSide.right);
      tree.split('b', 'c', SplitSide.right);
      expect(tree.panes, ['a', 'b', 'c']);
      final root = tree.root as SplitNode<String>;
      expect(root.children.length, 3);
      expect(root.ratios.every((ratio) => (ratio - 1 / 3).abs() < 1e-9), isTrue);
    });

    test('不同方向拆分生成嵌套分支，删除后折叠', () {
      final tree = PaneTree('a');
      tree.split('a', 'b', SplitSide.right);
      tree.split('b', 'c', SplitSide.bottom);
      expect(tree.panes, ['a', 'b', 'c']);
      expect(tree.neighbor('a', SplitSide.right), 'b');
      expect(tree.neighbor('b', SplitSide.bottom), 'c');
      expect(tree.neighbor('c', SplitSide.top), 'b');
      expect(tree.neighbor('c', SplitSide.left), 'a');
      expect(tree.remove('c'), isFalse);
      expect(tree.panes, ['a', 'b']);
      expect((tree.root as SplitNode<String>).children.every((child) => child is LeafNode<String>), isTrue);
      expect(tree.remove('b'), isFalse);
      expect(tree.root, isA<LeafNode<String>>());
      expect(tree.remove('a'), isTrue);
    });

    test('向左拆分插在前面', () {
      final tree = PaneTree('a');
      tree.split('a', 'b', SplitSide.left);
      expect(tree.panes, ['b', 'a']);
    });

    test('调整比例有下限', () {
      final tree = PaneTree('a');
      tree.split('a', 'b', SplitSide.right);
      tree.resize('a', vertical: false, delta: 0.9);
      final root = tree.root as SplitNode<String>;
      expect(root.ratios[1], closeTo(0.05, 1e-9));
      expect(root.ratios[0] + root.ratios[1], closeTo(1, 1e-9));
    });
  });

  group('快速连接', () {
    test('user@host:port', () {
      final profile = parseQuickConnect('deploy@192.0.2.10:2222')!;
      expect(profile['type'], 'ssh');
      expect(profile['options'], {'host': '192.0.2.10', 'port': 2222, 'user': 'deploy'});
      expect(profile['name'], 'deploy@192.0.2.10:2222');
    });

    test('只有主机名、默认端口', () {
      expect(parseQuickConnect('example.com')!['options'], {'host': 'example.com', 'port': 22, 'user': ''});
    });

    test('telnet 与 IPv6', () {
      final telnet = parseQuickConnect('telnet://192.0.2.1')!;
      expect(telnet['type'], 'telnet');
      expect(telnet['options'], {'host': '192.0.2.1', 'port': 23});
      expect(parseQuickConnect('root@[2001:db8::1]:22')!['options']['host'], '2001:db8::1');
    });

    test('普通筛选词不当主机', () {
      expect(parseQuickConnect('zsh'), isNull);
      expect(parseQuickConnect('a b'), isNull);
      expect(parseQuickConnect('host:99999'), isNull);
    });
  });

  group('命令行', () {
    test('子命令与系统附加参数', () {
      expect(CliRequest.parse(['-NSDocumentRevisionsDebugMode', 'YES']), isNull);
      expect((CliRequest.parse(['-NSDocumentRevisionsDebugMode', 'YES', 'open', '/tmp']) as OpenDirectory).path, '/tmp');
      expect(CliRequest.parse(['-NSDocumentRevisionsDebugMode']), isNull);
      final run = CliRequest.parse(['run', 'htop', '-d', '5']) as RunCommand;
      expect(run.command, 'htop');
      expect(run.args, ['-d', '5']);
      expect((CliRequest.parse(['profile', 'my', 'server']) as OpenProfile).name, 'my server');
      expect((CliRequest.parse(['open', '/tmp']) as OpenDirectory).path, '/tmp');
      expect(CliRequest.parse(['run']), isNull);
    });
  });
}
