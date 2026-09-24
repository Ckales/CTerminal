import 'package:flutter/foundation.dart';

import 'src/rust/api/update.dart' as rust;

/// 新版本检查的界面状态。版本比较、每天最多一次等规则都在 Rust 侧（cterm_core::update）
abstract final class UpdateCheck {
  /// 有新版本时非空，标签栏据此显示更新按钮
  static final ValueNotifier<rust.UpdateInfo?> available = ValueNotifier(null);

  /// 启动后后台检查一次；失败静默
  static Future<void> onStartup() async {
    final found = await rust.updateCheckDaily();
    if (found != null) available.value = found;
  }

  /// “关于”页的立即检查；失败时抛出错误文字
  static Future<rust.UpdateInfo> checkNow() async {
    final result = await rust.updateCheckNow();
    available.value = result.newer ? result : null;
    return result;
  }
}
