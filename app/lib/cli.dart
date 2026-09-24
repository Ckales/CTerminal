/// 命令行参数，支持以下子命令：
/// - `CTerminal open 目录`：在该目录打开默认配置
/// - `CTerminal run 命令 [参数…]`：在新标签页运行命令
/// - `CTerminal profile 配置名`：按名称打开配置
/// - `CTerminal quickConnect user@host[:port]`
/// - `CTerminal settings [页面]`：打开设置（页面如 appearance、profiles）
sealed class CliRequest {
  static CliRequest? parse(List<String> raw) {
    // 从 Xcode / Finder 启动时系统会附带 `-NSxxx 值`、`-psn_xxx` 之类参数
    final args = <String>[];
    for (var index = 0; index < raw.length; index++) {
      final arg = raw[index];
      if (arg.startsWith('-psn_')) continue;
      if (arg.startsWith('-NS') || arg.startsWith('-Apple')) {
        if (index + 1 < raw.length && !raw[index + 1].startsWith('-')) index++;
        continue;
      }
      args.add(arg);
    }
    if (args.isEmpty) return null;
    final rest = args.sublist(1);
    switch (args.first) {
      case 'open':
        return rest.isEmpty ? null : OpenDirectory(rest.first);
      case 'run':
        return rest.isEmpty ? null : RunCommand(rest.first, rest.sublist(1));
      case 'profile':
        return rest.isEmpty ? null : OpenProfile(rest.join(' '));
      case 'quickConnect':
        return rest.isEmpty ? null : QuickConnect(rest.last);
      case 'settings':
        return OpenSettings(rest.isEmpty ? 'application' : rest.first);
    }
    // 直接传一个目录（例如把文件夹拖到程序坞图标上）
    return OpenDirectory(args.first);
  }
}

class OpenDirectory extends CliRequest {
  OpenDirectory(this.path);
  final String path;
}

class RunCommand extends CliRequest {
  RunCommand(this.command, this.args);
  final String command;
  final List<String> args;
}

class OpenProfile extends CliRequest {
  OpenProfile(this.name);
  final String name;
}

class OpenSettings extends CliRequest {
  OpenSettings(this.page);
  final String page;
}

class QuickConnect extends CliRequest {
  QuickConnect(this.target);
  final String target;
}
