import 'package:flutter/material.dart';

/// 界面配色（终端内容的颜色来自配色方案，不在这里）
class AppColors {
  const AppColors({
    required this.chrome,
    required this.tabActive,
    required this.tabHover,
    required this.surface,
    required this.surfaceRaised,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.danger,
    required this.isDark,
  });

  /// 标题栏 / 标签栏底色
  final Color chrome;
  final Color tabActive;
  final Color tabHover;
  /// 设置页等内容区底色
  final Color surface;
  /// 弹层、输入框
  final Color surfaceRaised;
  final Color border;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color danger;
  final bool isDark;

  static const dark = AppColors(
    chrome: Color(0xff121212),
    tabActive: Color(0xff1e1e1e),
    tabHover: Color(0xff191919),
    surface: Color(0xff1a1a1a),
    surfaceRaised: Color(0xff262626),
    border: Color(0xff2e2e2e),
    text: Color(0xffd4d4d4),
    textDim: Color(0xff8a8a8a),
    accent: Color(0xff4c8dff),
    danger: Color(0xffff615a),
    isDark: true,
  );

  static const light = AppColors(
    chrome: Color(0xffe6e6e6),
    tabActive: Color(0xfffafafa),
    tabHover: Color(0xffefefef),
    surface: Color(0xfff6f6f6),
    surfaceRaised: Color(0xffffffff),
    border: Color(0xffd6d6d6),
    text: Color(0xff1f1f1f),
    textDim: Color(0xff6e6e6e),
    accent: Color(0xff2f6fe0),
    danger: Color(0xffd93b33),
    isDark: false,
  );
}

class AppTheme extends InheritedWidget {
  const AppTheme({super.key, required this.colors, required super.child});

  final AppColors colors;

  static AppColors of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppTheme>()!.colors;

  @override
  bool updateShouldNotify(AppTheme oldWidget) => oldWidget.colors != colors;
}

ThemeData materialTheme(AppColors colors) {
  final base = colors.isDark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    colorScheme: base.colorScheme.copyWith(primary: colors.accent, secondary: colors.accent, surface: colors.surfaceRaised),
    textTheme: base.textTheme.apply(bodyColor: colors.text, displayColor: colors.text),
    dividerColor: colors.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: colors.tabHover,
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(color: colors.surfaceRaised, borderRadius: BorderRadius.circular(4), border: Border.all(color: colors.border)),
      textStyle: TextStyle(color: colors.text, fontSize: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: colors.surfaceRaised,
      // 与按钮、下拉框同高（30）
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      border: OutlineInputBorder(borderSide: BorderSide(color: colors.border), borderRadius: BorderRadius.circular(4)),
      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: colors.border), borderRadius: BorderRadius.circular(4)),
      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: colors.accent), borderRadius: BorderRadius.circular(4)),
      hintStyle: TextStyle(color: colors.textDim),
      prefixIconColor: colors.textDim,
      prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 0),
    ),
    filledButtonTheme: FilledButtonThemeData(style: _buttonStyle(colors).merge(FilledButton.styleFrom(backgroundColor: colors.accent, foregroundColor: Colors.white))),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _buttonStyle(colors).merge(OutlinedButton.styleFrom(foregroundColor: colors.text, side: BorderSide(color: colors.border))),
    ),
    textButtonTheme: TextButtonThemeData(style: _buttonStyle(colors).merge(TextButton.styleFrom(foregroundColor: colors.text))),
    switchTheme: SwitchThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      thumbColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? Colors.white : colors.textDim),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? colors.accent : colors.border),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceRaised,
      textStyle: TextStyle(color: colors.text, fontSize: 13),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: colors.border)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colors.border)),
    ),
  );
}

/// 桌面尺寸的按钮：高 30、小圆角，替代 Material 默认的 40 高胶囊形
ButtonStyle _buttonStyle(AppColors colors) => ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // 不用 compact 密度：它会再从 30 里减掉 8
      visualDensity: VisualDensity.standard,
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      iconSize: const WidgetStatePropertyAll(15),
    );

/// 标签彩标可选色
const tabColors = <String>['#ff615a', '#f9a825', '#ebd99c', '#b1e969', '#82fff7', '#5da9f6', '#e86aff', '#9e9e9e'];

Color? parseHexColor(String? value) {
  if (value == null || value.length != 7 || !value.startsWith('#')) return null;
  final parsed = int.tryParse(value.substring(1), radix: 16);
  if (parsed == null) return null;
  return Color(0xff000000 | parsed);
}
