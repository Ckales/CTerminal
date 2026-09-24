import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../i18n.dart';
import '../terminal/terminal_view.dart' show openExternal;
import '../theme.dart';
import '../update_check.dart';

/// 标签栏右侧的更新提示：有新版本时才出现，点击打开发布页
class UpdateButton extends StatefulWidget {
  const UpdateButton({super.key, required this.height});

  final double height;

  @override
  State<UpdateButton> createState() => _UpdateButtonState();
}

class _UpdateButtonState extends State<UpdateButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return ValueListenableBuilder(
      valueListenable: UpdateCheck.available,
      builder: (context, update, _) {
        if (update == null) return const SizedBox.shrink();
        return Tooltip(
          message: tr('新版本 {version} 已发布，点击打开发布页', {'version': update.latest}),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: () => openExternal(update.url),
              child: Container(
                height: widget.height,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: _hover ? colors.tabHover : Colors.transparent,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.arrow_down_circle, size: 14, color: colors.accent),
                  const SizedBox(width: 4),
                  Text(update.latest, style: TextStyle(fontSize: 12, color: colors.accent)),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}
