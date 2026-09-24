import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'cli.dart';
import 'src/rust/api/settings.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'ui/app_shell.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  String? configError;
  Map<String, dynamic> config;
  try {
    config = jsonDecode(await rust.configLoad()) as Map<String, dynamic>;
  } catch (error) {
    // 配置文件损坏：用默认值运行，但不覆盖用户的文件，界面上提示
    configError = '$error';
    config = jsonDecode(rust.configDefaults()) as Map<String, dynamic>;
  }
  final app = AppState(config: config);
  await app.reloadProfiles();
  runApp(CTerminalApp(state: app, configError: configError, cli: CliRequest.parse(args)));
}
