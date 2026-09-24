// SFTP 面板：用假的 Rust API（flutter_rust_bridge 的 initMock）模拟远端目录，
// 验证列表、进入目录、下载进度、拖放上传这些界面行为。
import 'dart:async';

import 'package:cterminal/app_state.dart';
import 'package:cterminal/src/rust/api/sftp.dart';
import 'package:cterminal/src/rust/frb_generated.dart';
import 'package:cterminal/terminal/terminal_session.dart';
import 'package:cterminal/theme.dart';
import 'package:cterminal/ui/sftp_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SftpFileEntry entry(String name, {bool dir = false, int size = 0}) =>
    SftpFileEntry(name: name, isDir: dir, isLink: false, size: size, modified: 1700000000, permissions: dir ? 0x1ed : 0x1a4);

class FakeApi extends Fake implements RustLibApi {
  final listed = <String>[];
  final uploads = <(String, String)>[];
  final downloads = <(String, String)>[];
  final download = StreamController<SftpProgress>();

  @override
  Future<int> crateApiSftpSftpOpen({required int termId}) async => 7;

  @override
  Future<String> crateApiSftpSftpHome({required int id}) async => '/home/me';

  @override
  Future<List<SftpFileEntry>> crateApiSftpSftpList({required int id, required String path}) async {
    listed.add(path);
    if (path == '/home/me') return [entry('logs', dir: true), entry('app.tar.gz', size: 2048)];
    return [entry('today.log', size: 10)];
  }

  @override
  String crateApiSftpDownloadsDir() => '/nonexistent-downloads';

  @override
  Stream<SftpProgress> crateApiSftpSftpDownload({required int id, required String remote, required String local}) {
    downloads.add((remote, local));
    return download.stream;
  }

  @override
  Stream<SftpProgress> crateApiSftpSftpUpload({required int id, required String local, required String remote}) {
    uploads.add((local, remote));
    return Stream.value(const SftpProgress(done: 5, total: 5, finished: true, error: ''));
  }

  @override
  Future<void> crateApiSftpSftpClose({required int id}) async {}

  @override
  String crateApiSettingsColorSchemes() => '[]';
}

void main() {
  late FakeApi api;

  setUpAll(() {
    api = FakeApi();
    RustLib.initMock(api: api);
  });

  testWidgets('列表、进入目录、下载进度、拖放上传', (tester) async {
    // 面板只用到 AppState 的拖放登记，给最小配置即可
    final app = AppState(config: {'hotkeys': <String, dynamic>{}});
    final session = TerminalSession(profile: {'id': 's', 'name': 'web', 'type': 'ssh', 'options': <String, dynamic>{}});
    await tester.binding.setSurfaceSize(const Size(600, 500));
    await tester.pumpWidget(AppScope(
      state: app,
      child: AppTheme(
        colors: AppColors.dark,
        child: MaterialApp(
          theme: materialTheme(AppColors.dark),
          home: Scaffold(body: SftpPanel(session: session, onClose: () {})),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('logs'), findsOneWidget);
    expect(find.text('app.tar.gz'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('rwxr-xr-x'), findsOneWidget);

    // 双击文件 → 下载到“下载”文件夹，进度实时显示
    await tester.tap(find.text('app.tar.gz'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('app.tar.gz'));
    await tester.pumpAndSettle();
    expect(api.downloads.single, ('/home/me/app.tar.gz', '/nonexistent-downloads/app.tar.gz'));
    api.download.add(const SftpProgress(done: 1024, total: 2048, finished: false, error: ''));
    await tester.pump();
    await tester.pump();
    final progress = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).last);
    expect(progress.value, 0.5);
    api.download.add(const SftpProgress(done: 0, total: 0, finished: true, error: ''));
    await tester.pump();
    await tester.pump();
    expect(find.text('在访达中显示'), findsOneWidget);

    // 拖到面板上的文件上传到当前目录
    app.dropFiles(['/tmp/report.pdf'], const Offset(300, 250));
    await tester.pumpAndSettle();
    expect(api.uploads.single, ('/tmp/report.pdf', '/home/me/report.pdf'));

    // 双击目录进入，上一级返回
    await tester.tap(find.text('logs'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('logs'));
    await tester.pumpAndSettle();
    expect(find.text('today.log'), findsOneWidget);
    await tester.tap(find.byTooltip('上一级'));
    await tester.pumpAndSettle();
    // 上传完成后会刷新一次当前目录
    expect(api.listed, ['/home/me', '/home/me', '/home/me/logs', '/home/me']);
  });
}
