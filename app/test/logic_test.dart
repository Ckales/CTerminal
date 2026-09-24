import 'package:cterminal/cli.dart';
import 'package:cterminal/hotkeys.dart';
import 'package:cterminal/pane_tree.dart';
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
