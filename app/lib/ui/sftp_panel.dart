import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../src/rust/api/sftp.dart' as rust;
import '../terminal/terminal_session.dart';
import '../theme.dart';
import 'selector.dart';
import '../i18n.dart';

String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatPermissions(int mode) {
  const letters = 'rwxrwxrwx';
  final buffer = StringBuffer();
  for (var bit = 0; bit < 9; bit++) {
    buffer.write(mode & (1 << (8 - bit)) != 0 ? letters[bit] : '-');
  }
  return buffer.toString();
}

String formatTime(int seconds) {
  if (seconds == 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

String remoteJoin(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

String remoteParent(String path) {
  final trimmed = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final index = trimmed.lastIndexOf('/');
  return index <= 0 ? '/' : trimmed.substring(0, index);
}

/// 本地已有同名文件时加序号：a.txt → a (1).txt
String uniqueLocalPath(String dir, String name) {
  var candidate = '$dir${Platform.pathSeparator}$name';
  if (!File(candidate).existsSync()) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var index = 1;; index++) {
    candidate = '$dir${Platform.pathSeparator}$stem ($index)$ext';
    if (!File(candidate).existsSync()) return candidate;
  }
}

class _Transfer {
  _Transfer({required this.name, required this.upload, required this.localPath});
  final String name;
  final bool upload;
  final String localPath;
  int done = 0;
  int total = 0;
  bool finished = false;
  String error = '';
}

class SftpPanel extends StatefulWidget {
  const SftpPanel({super.key, required this.session, required this.onClose});

  final TerminalSession session;
  final VoidCallback onClose;

  @override
  State<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends State<SftpPanel> {
  int? _sftp;
  String _path = '';
  List<rust.SftpFileEntry> _entries = [];
  bool _loading = true;
  String _error = '';
  final TextEditingController _pathField = TextEditingController();
  final List<_Transfer> _transfers = [];
  int? _selected;
  AppState? _app;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (_app != app) {
      _app?.dropTargets.remove(this);
      app.dropTargets[this] = (_globalRect, _uploadAll);
      _app = app;
    }
  }

  @override
  void dispose() {
    _app?.dropTargets.remove(this);
    final id = _sftp;
    if (id != null) rust.sftpClose(id: id);
    _pathField.dispose();
    super.dispose();
  }

  Rect? _globalRect() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final id = await rust.sftpOpen(termId: widget.session.id);
      _sftp = id;
      final home = await rust.sftpHome(id: id);
      await _open(home);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _open(String path) async {
    final id = _sftp;
    if (id == null) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final entries = await rust.sftpList(id: id, path: path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _pathField.text = path;
        _entries = entries;
        _selected = null;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function(int id) action) async {
    final id = _sftp;
    if (id == null) return;
    try {
      await action(id);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return;
    }
    await _open(_path);
  }

  void _track(_Transfer transfer, Stream<rust.SftpProgress> stream) {
    setState(() => _transfers.insert(0, transfer));
    stream.listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          if (progress.finished) {
            transfer.finished = true;
            transfer.error = progress.error;
          } else {
            transfer.done = progress.done;
            transfer.total = progress.total;
          }
        });
        if (progress.finished && transfer.upload) _open(_path);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            transfer.finished = true;
            transfer.error = '$error';
          });
        }
      },
    );
  }

  void _download(rust.SftpFileEntry entry) {
    final id = _sftp;
    if (id == null) return;
    final local = uniqueLocalPath(rust.downloadsDir(), entry.name);
    final transfer = _Transfer(name: entry.name, upload: false, localPath: local)..total = entry.size;
    _track(transfer, rust.sftpDownload(id: id, remote: remoteJoin(_path, entry.name), local: local));
  }

  /// 拖到面板上的本地文件 / 文件夹上传到当前目录
  void _uploadAll(List<String> paths) {
    final id = _sftp;
    if (id == null) return;
    for (final path in paths) {
      final name = path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).last;
      final transfer = _Transfer(name: name, upload: true, localPath: path);
      _track(transfer, rust.sftpUpload(id: id, local: path, remote: remoteJoin(_path, name)));
    }
  }

  Future<void> _entryMenu(rust.SftpFileEntry entry, Offset position) async {
    final colors = AppTheme.of(context);
    PopupMenuItem<String> item(String value, String label, {bool danger = false}) => PopupMenuItem(
          value: value,
          height: 30,
          child: Text(tr(label), style: TextStyle(fontSize: 13, color: danger ? colors.danger : colors.text)),
        );
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        if (entry.isDir) item('open', '打开') else item('download', '下载到“下载”文件夹'),
        item('rename', '重命名'),
        item('copy', '复制路径'),
        const PopupMenuDivider(height: 8),
        item('delete', '删除', danger: true),
      ],
    );
    if (!mounted || chosen == null) return;
    final full = remoteJoin(_path, entry.name);
    switch (chosen) {
      case 'open':
        _open(full);
      case 'download':
        _download(entry);
      case 'copy':
        Clipboard.setData(ClipboardData(text: full));
      case 'rename':
        final name = await showTextPrompt(context, title: '重命名', initial: entry.name);
        if (name == null || name.trim().isEmpty || name == entry.name) return;
        await _run((id) => rust.sftpRename(id: id, from: full, to: remoteJoin(_path, name.trim())));
      case 'delete':
        final ok = await showConfirm(
          context,
          title: tr('删除{kind}？', {'kind': tr(entry.isDir ? '文件夹' : '文件')}),
          message: tr(entry.isDir ? '「{name}」及其中的全部内容会被删除，无法恢复。' : '「{name}」会被删除，无法恢复。', {'name': entry.name}),
          confirm: '删除',
          danger: true,
        );
        if (!ok) return;
        await _run((id) => rust.sftpRemove(id: id, path: full, isDir: entry.isDir && !entry.isLink));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    Widget tool(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tr(tip),
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, color: colors.textDim),
          onPressed: onTap,
        );

    return Material(
      color: colors.surface,
      elevation: 8,
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.border))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            color: colors.chrome,
            child: Row(children: [
              const SizedBox(width: 4),
              Text('SFTP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.text)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _pathField,
                  style: TextStyle(fontSize: 12, color: colors.text, fontFamily: 'Menlo'),
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                  onSubmitted: (value) => _open(value.trim().isEmpty ? '/' : value.trim()),
                ),
              ),
              tool(Icons.arrow_upward, '上一级', _path == '/' || _path.isEmpty ? null : () => _open(remoteParent(_path))),
              tool(Icons.refresh, '刷新', () => _sftp == null ? _connect() : _open(_path)),
              tool(Icons.create_new_folder_outlined, '新建文件夹', _sftp == null
                  ? null
                  : () async {
                      final name = await showTextPrompt(context, title: '新建文件夹');
                      if (name == null || name.trim().isEmpty) return;
                      await _run((id) => rust.sftpMkdir(id: id, path: remoteJoin(_path, name.trim())));
                    }),
              tool(Icons.close, '关闭', widget.onClose),
            ]),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              color: colors.danger.withValues(alpha: 0.12),
              child: Row(children: [
                Expanded(child: Text(_error, style: TextStyle(fontSize: 12, color: colors.danger))),
                TextButton(onPressed: _sftp == null ? _connect : () => _open(_path), child: Text(tr('重试'))),
              ]),
            ),
          Expanded(
            child: _entries.isEmpty && !_loading
                ? Center(child: Text(_error.isEmpty ? tr('空文件夹\n拖入文件即可上传') : '', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: colors.textDim)))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemExtent: 30,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      final selected = _selected == index;
                      return GestureDetector(
                        onTap: () => setState(() => _selected = index),
                        onDoubleTap: () => entry.isDir ? _open(remoteJoin(_path, entry.name)) : _download(entry),
                        onSecondaryTapUp: (details) {
                          setState(() => _selected = index);
                          _entryMenu(entry, details.globalPosition);
                        },
                        child: Container(
                          color: selected ? colors.accent.withValues(alpha: 0.18) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(children: [
                            Icon(
                              entry.isDir ? Icons.folder_outlined : (entry.isLink ? Icons.link : Icons.insert_drive_file_outlined),
                              size: 15,
                              color: entry.isDir ? colors.accent : colors.textDim,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(entry.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: colors.text))),
                            SizedBox(
                              width: 64,
                              child: Text(entry.isDir ? '' : formatSize(entry.size), textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: colors.textDim)),
                            ),
                            const SizedBox(width: 10),
                            Text(formatTime(entry.modified), style: TextStyle(fontSize: 11, color: colors.textDim)),
                            const SizedBox(width: 10),
                            Text(formatPermissions(entry.permissions), style: TextStyle(fontSize: 11, color: colors.textDim, fontFamily: 'Menlo')),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
          if (_transfers.isNotEmpty) _transferList(colors),
        ]),
      ),
    );
  }

  Widget _transferList(AppColors colors) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.border))),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 4), children: [
        for (final transfer in _transfers)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(children: [
              Icon(transfer.upload ? Icons.upload : Icons.download, size: 14, color: colors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(transfer.name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: colors.text)),
                  const SizedBox(height: 3),
                  if (transfer.error.isNotEmpty)
                    Text(transfer.error, style: TextStyle(fontSize: 11, color: colors.danger))
                  else
                    LinearProgressIndicator(
                      minHeight: 3,
                      value: transfer.finished ? 1 : (transfer.total > 0 ? transfer.done / transfer.total : null),
                    ),
                ]),
              ),
              const SizedBox(width: 8),
              if (transfer.finished && transfer.error.isEmpty && !transfer.upload)
                TextButton(
                  onPressed: () => Platform.isMacOS
                      ? Process.run('open', ['-R', transfer.localPath])
                      : Process.run('explorer', ['/select,', transfer.localPath]),
                  child: Text(tr(Platform.isMacOS ? '在访达中显示' : '在资源管理器中显示'), style: const TextStyle(fontSize: 11)),
                )
              else
                Text(
                  transfer.finished ? tr(transfer.error.isEmpty ? '完成' : '失败') : formatSize(transfer.done),
                  style: TextStyle(fontSize: 11, color: colors.textDim),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// SSH 窗格右上角的 SFTP 按钮
class SftpButton extends StatelessWidget {
  const SftpButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Tooltip(
      message: tr('打开 SFTP 文件面板'),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: colors.surfaceRaised.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: colors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_open_outlined, size: 13, color: colors.textDim),
            const SizedBox(width: 4),
            Text('SFTP', style: TextStyle(fontSize: 11, color: colors.textDim)),
          ]),
        ),
      ),
    );
  }
}
