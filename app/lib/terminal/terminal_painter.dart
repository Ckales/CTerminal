import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../src/rust/api/terminal.dart';
import 'terminal_session.dart';

// 与 cterm-core frame.rs 的 RUN_* 一致
const runBold = 1;
const runItalic = 1 << 1;
const runUnderline = 1 << 2;
const runStrike = 1 << 3;
const runSelected = 1 << 4;
const runMatch = 1 << 5;
const runUndercurl = 1 << 6;
const runDefaultBg = 1 << 7;

Color rgb(int value) => Color(0xff000000 | value);

List<String> monospaceFallback() {
  if (Platform.isMacOS) return const ['Menlo', 'SF Mono', 'PingFang SC', 'Apple Color Emoji', 'Apple Symbols'];
  if (Platform.isWindows) return const ['Consolas', 'Cascadia Mono', 'Microsoft YaHei', 'Segoe UI Emoji', 'Segoe UI Symbol'];
  return const ['DejaVu Sans Mono', 'Noto Sans Mono CJK SC', 'Noto Color Emoji'];
}

/// 字体度量：格宽取 100 个字符的平均宽度，避免单字符测量的舍入误差
class TerminalMetrics {
  TerminalMetrics({required this.fontFamily, required this.fontSize, required this.lineHeight, this.ligatures = false}) {
    final painter = TextPainter(
      text: TextSpan(text: 'W' * 100, style: baseStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    cellWidth = painter.width / 100;
    final natural = painter.height;
    cellHeight = (fontSize * lineHeight).ceilToDouble().clamp(natural, double.infinity).toDouble();
    painter.dispose();
  }

  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  /// 连字不改变字宽（等宽连字字体的连字字形宽度就是 N 个格子），只影响段落排版，
  /// 放在这里是为了切换时 ParagraphCache 整体失效
  final bool ligatures;
  late final double cellWidth;
  late final double cellHeight;

  TextStyle baseStyle() => TextStyle(fontFamily: fontFamily, fontFamilyFallback: monospaceFallback(), fontSize: fontSize, height: 1.0);

  bool sameAs(TerminalMetrics other) =>
      other.fontFamily == fontFamily && other.fontSize == fontSize && other.lineHeight == lineHeight && other.ligatures == ligatures;
}

class TextPiece {
  TextPiece(this.x, this.width, this.paragraph, this.centered);
  final double x;
  final double width;
  final ui.Paragraph paragraph;
  final bool centered;
}

class CachedLine {
  CachedLine(this.pieces, this.boxes);
  final List<TextPiece> pieces;
  /// 自绘的制表符 / 方块字符：(列, 字符, 颜色)
  final List<(int, int, int)> boxes;
}

/// 按行内容哈希缓存排好版的段落，内容不变的行不再排版
class ParagraphCache {
  final Map<int, CachedLine> _lines = {};
  TerminalMetrics? _metrics;

  void _ensure(TerminalMetrics metrics) {
    if (_metrics == null || !_metrics!.sameAs(metrics)) {
      clear();
      _metrics = metrics;
    }
    if (_lines.length > 3000) clear();
  }

  void clear() {
    for (final line in _lines.values) {
      for (final piece in line.pieces) {
        piece.paragraph.dispose();
      }
    }
    _lines.clear();
  }

  /// [cursorCol]：开连字时光标所在行传入光标列，该格单独成段，不会和相邻字符连成一个字形
  CachedLine line(TermLine line, TerminalMetrics metrics, {int? cursorCol}) {
    _ensure(metrics);
    final key = cursorCol == null ? line.hash : Object.hash(line.hash, cursorCol);
    return _lines.putIfAbsent(key, () => _build(line, metrics, cursorCol));
  }

  CachedLine _build(TermLine line, TerminalMetrics metrics, int? cursorCol) {
    final pieces = <TextPiece>[];
    final boxes = <(int, int, int)>[];
    final cw = metrics.cellWidth;
    for (final run in line.runs) {
      final text = run.text;
      final decorated = run.flags & (runUnderline | runStrike | runUndercurl) != 0;
      if (text.trim().isEmpty && !decorated) continue;
      if (run.text.runes.length == 1 && isBoxDrawing(run.text.runes.first) && run.flags & runSelected == 0) {
        boxes.add((run.col, run.text.runes.first, run.fg));
        continue;
      }
      final ascii = run.width == text.length;
      // 只有 ASCII 段会多字符并段（见 frame.rs），也只有它们会出现连字
      if (ascii && cursorCol != null && cursorCol >= run.col && cursorCol < run.col + run.width) {
        final at = cursorCol - run.col;
        for (final (start, end) in [(0, at), (at, at + 1), (at + 1, text.length)]) {
          if (start == end) continue;
          final part = text.substring(start, end);
          if (part.trim().isEmpty && !decorated) continue;
          pieces.add(TextPiece((run.col + start) * cw, part.length * cw, buildParagraph(part, run.fg, run.flags, metrics), false));
        }
        continue;
      }
      final paragraph = buildParagraph(text, run.fg, run.flags, metrics);
      pieces.add(TextPiece(run.col * cw, run.width * cw, paragraph, !ascii));
    }
    return CachedLine(pieces, boxes);
  }
}

/// 开：连字 + 上下文替换；关：两者都显式禁用（有些字体默认开 calt，如 JetBrains Mono 的 -> 就靠它）
const _ligaturesOn = [ui.FontFeature.enable('liga'), ui.FontFeature.enable('calt')];
const _ligaturesOff = [ui.FontFeature.disable('liga'), ui.FontFeature.disable('calt')];

ui.Paragraph buildParagraph(String text, int fg, int flags, TerminalMetrics metrics) {
  final color = rgb(fg);
  final decorations = <TextDecoration>[
    if (flags & (runUnderline | runUndercurl) != 0) TextDecoration.underline,
    if (flags & runStrike != 0) TextDecoration.lineThrough,
  ];
  final style = ui.TextStyle(
    color: color,
    fontFamily: metrics.fontFamily,
    fontFamilyFallback: monospaceFallback(),
    fontSize: metrics.fontSize,
    fontWeight: flags & runBold != 0 ? FontWeight.bold : FontWeight.normal,
    fontStyle: flags & runItalic != 0 ? FontStyle.italic : FontStyle.normal,
    decoration: TextDecoration.combine(decorations),
    decorationColor: color,
    decorationStyle: flags & runUndercurl != 0 ? TextDecorationStyle.wavy : TextDecorationStyle.solid,
    fontFeatures: metrics.ligatures ? _ligaturesOn : _ligaturesOff,
  );
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(maxLines: 1, textDirection: TextDirection.ltr))
    ..pushStyle(style)
    ..addText(text);
  final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
  return paragraph;
}

/// U+2500-257F 制表符、U+2580-259F 方块：字体里这些字形常常不贴边，TUI 边框会断开，所以自己画
bool isBoxDrawing(int rune) => (rune >= 0x2500 && rune <= 0x257f) || (rune >= 0x2580 && rune <= 0x259f);

/// 线段粗细：上 右 下 左；0 无 1 细 2 粗 3 双线
const _boxLines = <int, List<int>>{
  0x2500: [0, 1, 0, 1], 0x2501: [0, 2, 0, 2], 0x2502: [1, 0, 1, 0], 0x2503: [2, 0, 2, 0],
  0x250c: [0, 1, 1, 0], 0x250d: [0, 2, 1, 0], 0x250e: [0, 1, 2, 0], 0x250f: [0, 2, 2, 0],
  0x2510: [0, 0, 1, 1], 0x2511: [0, 0, 1, 2], 0x2512: [0, 0, 2, 1], 0x2513: [0, 0, 2, 2],
  0x2514: [1, 1, 0, 0], 0x2515: [1, 2, 0, 0], 0x2516: [2, 1, 0, 0], 0x2517: [2, 2, 0, 0],
  0x2518: [1, 0, 0, 1], 0x2519: [1, 0, 0, 2], 0x251a: [2, 0, 0, 1], 0x251b: [2, 0, 0, 2],
  0x251c: [1, 1, 1, 0], 0x251d: [1, 2, 1, 0], 0x2520: [2, 1, 2, 0], 0x2523: [2, 2, 2, 0],
  0x2524: [1, 0, 1, 1], 0x2525: [1, 0, 1, 2], 0x2528: [2, 0, 2, 1], 0x252b: [2, 0, 2, 2],
  0x252c: [0, 1, 1, 1], 0x252f: [0, 2, 1, 2], 0x2530: [0, 1, 2, 1], 0x2533: [0, 2, 2, 2],
  0x2534: [1, 1, 0, 1], 0x2537: [1, 2, 0, 2], 0x2538: [2, 1, 0, 1], 0x253b: [2, 2, 0, 2],
  0x253c: [1, 1, 1, 1], 0x253f: [1, 2, 1, 2], 0x2542: [2, 1, 2, 1], 0x254b: [2, 2, 2, 2],
  0x2550: [0, 3, 0, 3], 0x2551: [3, 0, 3, 0],
  0x2552: [0, 3, 1, 0], 0x2553: [0, 1, 3, 0], 0x2554: [0, 3, 3, 0],
  0x2555: [0, 0, 1, 3], 0x2556: [0, 0, 3, 1], 0x2557: [0, 0, 3, 3],
  0x2558: [1, 3, 0, 0], 0x2559: [3, 1, 0, 0], 0x255a: [3, 3, 0, 0],
  0x255b: [1, 0, 0, 3], 0x255c: [3, 0, 0, 1], 0x255d: [3, 0, 0, 3],
  0x255e: [1, 3, 1, 0], 0x255f: [3, 1, 3, 0], 0x2560: [3, 3, 3, 0],
  0x2561: [1, 0, 1, 3], 0x2562: [3, 0, 3, 1], 0x2563: [3, 0, 3, 3],
  0x2564: [0, 3, 1, 3], 0x2565: [0, 1, 3, 1], 0x2566: [0, 3, 3, 3],
  0x2567: [1, 3, 0, 3], 0x2568: [3, 1, 0, 1], 0x2569: [3, 3, 0, 3],
  0x256a: [1, 3, 1, 3], 0x256b: [3, 1, 3, 1], 0x256c: [3, 3, 3, 3],
  // 圆角按直角画
  0x256d: [0, 1, 1, 0], 0x256e: [0, 0, 1, 1], 0x256f: [1, 0, 0, 1], 0x2570: [1, 1, 0, 0],
  0x2574: [0, 0, 0, 1], 0x2575: [1, 0, 0, 0], 0x2576: [0, 1, 0, 0], 0x2577: [0, 0, 1, 0],
  0x2578: [0, 0, 0, 2], 0x2579: [2, 0, 0, 0], 0x257a: [0, 2, 0, 0], 0x257b: [0, 0, 2, 0],
  0x257c: [0, 2, 0, 1], 0x257d: [1, 0, 2, 0], 0x257e: [0, 1, 0, 2], 0x257f: [2, 0, 1, 0],
};

/// 画不了的字符返回 false，交回字体渲染
bool paintBox(Canvas canvas, int rune, Rect cell, Color color) {
  // 不抗锯齿：相邻格子的线段要严丝合缝地接上，抗锯齿会在接缝处留下浅色竖纹
  final paint = Paint()
    ..color = color
    ..isAntiAlias = false;
  if (rune >= 0x2580) {
    final w = cell.width, h = cell.height, l = cell.left, t = cell.top;
    Rect? rect;
    switch (rune) {
      case 0x2580:
        rect = Rect.fromLTWH(l, t, w, h / 2);
      case 0x2588:
        rect = cell;
      case 0x258c:
        rect = Rect.fromLTWH(l, t, w / 2, h);
      case 0x2590:
        rect = Rect.fromLTWH(l + w / 2, t, w / 2, h);
      case 0x2591:
      case 0x2592:
      case 0x2593:
        final alpha = rune == 0x2591 ? 0.25 : (rune == 0x2592 ? 0.5 : 0.75);
        canvas.drawRect(cell, Paint()
          ..color = color.withValues(alpha: alpha)
          ..isAntiAlias = false);
        return true;
      case 0x2594:
        rect = Rect.fromLTWH(l, t, w, h / 8);
      case 0x2595:
        rect = Rect.fromLTWH(l + w * 7 / 8, t, w / 8, h);
      default:
        if (rune >= 0x2581 && rune <= 0x2587) {
          // 下 1/8 .. 7/8
          final part = (rune - 0x2580) / 8;
          rect = Rect.fromLTWH(l, t + h * (1 - part), w, h * part);
        } else if (rune >= 0x2589 && rune <= 0x258f) {
          // 左 7/8 .. 1/8
          final part = (0x2590 - rune) / 8;
          rect = Rect.fromLTWH(l, t, w * part, h);
        }
    }
    if (rect == null) return false;
    canvas.drawRect(rect, paint);
    return true;
  }
  final lines = _boxLines[rune];
  if (lines == null) return false;
  final thin = (cell.width / 8).clamp(1.0, 2.0).roundToDouble();
  final cx = (cell.left + cell.width / 2).floorToDouble();
  final cy = (cell.top + cell.height / 2).floorToDouble();
  void segment(int weight, bool vertical, double from, double to) {
    if (weight == 0) return;
    final size = weight == 2 ? thin * 2 : thin;
    if (weight == 3) {
      final gap = thin;
      for (final offset in [-gap - thin, gap]) {
        canvas.drawRect(
          vertical ? Rect.fromLTRB(cx + offset, from, cx + offset + thin, to) : Rect.fromLTRB(from, cy + offset, to, cy + offset + thin),
          paint,
        );
      }
      return;
    }
    canvas.drawRect(
      vertical ? Rect.fromLTRB(cx - size / 2, from, cx + size / 2, to) : Rect.fromLTRB(from, cy - size / 2, to, cy + size / 2),
      paint,
    );
  }

  // 线段越过中心半个（最粗的）线宽，拐角正好接上又不冒头
  final heaviest = lines.reduce((a, b) => a > b ? a : b);
  final pad = heaviest == 2 ? thin : (heaviest == 3 ? thin * 1.5 : thin / 2);
  segment(lines[0], true, cell.top, cy + pad);
  segment(lines[2], true, cy - pad, cell.bottom);
  segment(lines[3], false, cell.left, cx + pad);
  segment(lines[1], false, cx - pad, cell.right);
  return true;
}

/// 格子边界取整：格宽是小数（如 8.4px），不取整时相邻格子之间会出现缝
Rect snappedCell(int col, int width, double y, double cw, double ch) =>
    Rect.fromLTRB((col * cw).roundToDouble(), y.roundToDouble(), ((col + width) * cw).roundToDouble(), (y + ch).roundToDouble());

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.session,
    required this.metrics,
    required this.cache,
    required this.padding,
    required this.cursorOn,
    required this.focused,
    required this.composing,
    required this.selectionColor,
    required this.matchColor,
  }) : super(repaint: session);

  /// 每次重绘都读最新帧：repaint 监听 session，painter 本身不会重建
  final TerminalSession session;
  final TerminalMetrics metrics;
  final ParagraphCache cache;
  final double padding;
  final bool cursorOn;
  final bool focused;
  final String composing;
  final Color selectionColor;
  final Color matchColor;

  static Paint _fill(Color color) => Paint()
    ..color = color
    ..isAntiAlias = false;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = session.frame;
    if (frame == null) return;
    final cw = metrics.cellWidth;
    final ch = metrics.cellHeight;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(padding, padding);

    for (var row = 0; row < frame.lines.length; row++) {
      final line = frame.lines[row];
      final y = row * ch;
      for (final run in line.runs) {
        final rect = snappedCell(run.col, run.width, y, cw, ch);
        if (run.flags & runDefaultBg == 0) {
          canvas.drawRect(rect, _fill(rgb(run.bg)));
        }
        if (run.flags & runMatch != 0) {
          canvas.drawRect(rect, _fill(matchColor));
        } else if (run.flags & runSelected != 0) {
          canvas.drawRect(rect, _fill(selectionColor));
        }
      }
      final splitCursor = metrics.ligatures && row == frame.cursorRow && frame.cursorVisible && frame.displayOffset == 0;
      final painted = cache.line(line, metrics, cursorCol: splitCursor ? frame.cursorCol : null);
      for (final piece in painted.pieces) {
        final paragraph = piece.paragraph;
        final dy = y + (ch - paragraph.height) / 2;
        var dx = piece.x;
        if (piece.centered && paragraph.maxIntrinsicWidth < piece.width) {
          dx += (piece.width - paragraph.maxIntrinsicWidth) / 2;
        }
        canvas.drawParagraph(paragraph, Offset(dx, dy));
      }
      for (final (col, rune, fg) in painted.boxes) {
        final cell = snappedCell(col, 1, y, cw, ch);
        if (!paintBox(canvas, rune, cell, rgb(fg))) {
          final paragraph = buildParagraph(String.fromCharCode(rune), fg, 0, metrics);
          canvas.drawParagraph(paragraph, Offset(cell.left, y + (ch - paragraph.height) / 2));
          paragraph.dispose();
        }
      }
    }

    _paintCursor(canvas, frame, cw, ch);
    canvas.restore();
  }

  TermRun? _runAt(TermFrame frame, int row, int col) {
    if (row >= frame.lines.length) return null;
    for (final run in frame.lines[row].runs) {
      if (col >= run.col && col < run.col + run.width) return run;
    }
    return null;
  }

  void _paintCursor(Canvas canvas, TermFrame frame, double cw, double ch) {
    if (!frame.cursorVisible || frame.displayOffset != 0) {
      return;
    }
    final run = _runAt(frame, frame.cursorRow, frame.cursorCol);
    final cellWidth = run != null && run.width == 2 ? 2 * cw : cw;
    final rect = Rect.fromLTWH(frame.cursorCol * cw, frame.cursorRow * ch, cellWidth, ch);
    final cursorColor = rgb(frame.cursorColor);

    if (composing.isNotEmpty) {
      final paragraph = buildParagraph(composing, frame.foreground, runUnderline, metrics);
      final box = Rect.fromLTWH(rect.left, rect.top, paragraph.maxIntrinsicWidth, ch);
      canvas.drawRect(box, Paint()..color = rgb(frame.background));
      canvas.drawParagraph(paragraph, Offset(rect.left, rect.top + (ch - paragraph.height) / 2));
      paragraph.dispose();
      return;
    }
    if (!focused) {
      canvas.drawRect(rect.deflate(0.5), Paint()
        ..color = cursorColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
      return;
    }
    if (!cursorOn) return;
    switch (frame.cursorShape) {
      case 1:
        canvas.drawRect(Rect.fromLTWH(rect.left, rect.bottom - 2, rect.width, 2), Paint()..color = cursorColor);
      case 2:
        canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, 2, rect.height), Paint()..color = cursorColor);
      case 3:
        canvas.drawRect(rect.deflate(0.5), Paint()
          ..color = cursorColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
      default:
        canvas.drawRect(rect, Paint()..color = cursorColor);
        if (run != null && run.text.trim().isNotEmpty) {
          // 块光标下的字符用背景色重画，保持可读
          final text = run.width == run.text.length ? run.text[frame.cursorCol - run.col] : run.text;
          final paragraph = buildParagraph(text, frame.background, run.flags & (runBold | runItalic), metrics);
          final dx = rect.left + (rect.width - paragraph.maxIntrinsicWidth).clamp(0, double.infinity) / 2;
          canvas.drawParagraph(paragraph, Offset(run.width == run.text.length ? rect.left : dx, rect.top + (ch - paragraph.height) / 2));
          paragraph.dispose();
        }
    }
  }

  @override
  bool shouldRepaint(TerminalPainter oldDelegate) =>
      oldDelegate.session != session ||
      oldDelegate.cursorOn != cursorOn ||
      oldDelegate.focused != focused ||
      oldDelegate.composing != composing ||
      !oldDelegate.metrics.sameAs(metrics) ||
      oldDelegate.padding != padding;
}
