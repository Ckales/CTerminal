import 'package:flutter/material.dart';

const profileIconChoices = <String, IconData>{
  'terminal': Icons.terminal,
  'server': Icons.dns_outlined,
  'cloud': Icons.cloud_outlined,
  'database': Icons.storage_outlined,
  'desktop': Icons.desktop_windows_outlined,
  'linux': Icons.computer_outlined,
  'git': Icons.merge_type,
  'powershell': Icons.keyboard_double_arrow_right,
  'cmd': Icons.chevron_right,
  'serial': Icons.usb,
  'network': Icons.lan_outlined,
  'bolt': Icons.bolt_outlined,
  'star': Icons.star_outline,
  'lock': Icons.lock_outline,
  'home': Icons.home_outlined,
  'code': Icons.code,
};

IconData profileIcon(Map<String, dynamic> profile) {
  final named = profileIconChoices[profile['icon']];
  if (named != null) return named;
  switch (profile['type']) {
    case 'ssh':
      return Icons.dns_outlined;
    case 'telnet':
      return Icons.lan_outlined;
    case 'serial':
      return Icons.usb;
    default:
      return Icons.terminal;
  }
}

/// 选择器里的一行说明：ssh 显示 user@host:port，本地显示命令
String profileDescription(Map<String, dynamic> profile) {
  final options = (profile['options'] as Map?) ?? {};
  switch (profile['type']) {
    case 'ssh':
      final user = options['user'] as String? ?? '';
      final port = options['port'] ?? 22;
      final host = options['host'] as String? ?? '';
      return '${user.isEmpty ? '' : '$user@'}$host${port == 22 ? '' : ':$port'}';
    case 'telnet':
      return 'telnet ${options['host']}:${options['port']}';
    case 'serial':
      return '${options['port']} @ ${options['baudrate']}';
    default:
      final args = (options['args'] as List?)?.join(' ') ?? '';
      return '${options['command'] ?? ''} $args'.trim();
  }
}

/// 解析快速连接：[user@]host[:port]，或 telnet://host[:port]
Map<String, dynamic>? parseQuickConnect(String input) {
  var text = input.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  var type = 'ssh';
  if (text.startsWith('telnet://')) {
    type = 'telnet';
    text = text.substring('telnet://'.length);
  } else if (text.startsWith('ssh://')) {
    text = text.substring('ssh://'.length);
  } else if (!text.contains('@') && !text.contains('.') && !text.contains(':')) {
    // 纯单词更可能是在筛选 profile，不当成主机名
    return null;
  }
  var user = '';
  final at = text.lastIndexOf('@');
  if (at >= 0) {
    user = text.substring(0, at);
    text = text.substring(at + 1);
  }
  var port = type == 'ssh' ? 22 : 23;
  // IPv6 需要写成 [addr]:port
  final bracket = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(text);
  String host;
  if (bracket != null) {
    host = bracket.group(1)!;
    if (bracket.group(2) != null) port = int.parse(bracket.group(2)!);
  } else {
    final parts = text.split(':');
    if (parts.length > 2) return null;
    host = parts.first;
    if (parts.length == 2) {
      final parsed = int.tryParse(parts[1]);
      if (parsed == null || parsed <= 0 || parsed > 65535) return null;
      port = parsed;
    }
  }
  if (host.isEmpty || !RegExp(r'^[A-Za-z0-9._:\-]+$').hasMatch(host)) return null;
  final name = type == 'ssh' ? '${user.isEmpty ? '' : '$user@'}$host${port == 22 ? '' : ':$port'}' : '$host:$port';
  return {
    'id': 'quick:$type:$name',
    'name': name,
    'type': type,
    'options': type == 'ssh' ? {'host': host, 'port': port, 'user': user} : {'host': host, 'port': port},
  };
}
