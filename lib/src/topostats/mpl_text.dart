// lib/src/topostats/mpl_text.dart
//
// matplotlib-compatible text placement (Text._get_layout) on a Flutter
// canvas, using the bundled DejaVu Sans (matplotlib's default font) so the
// labels look the same as in the reference PNGs.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

const String kMplFontFamily = 'DejaVuSans';

/// DejaVu Sans metrics (units/em) of "l" ascent and "p" descent, which is
/// what matplotlib measures as the line box of every text ("lp").
const double _lpAscent = 1556 / 2048;
const double _lpDescent = 426 / 2048;
const double _lineSpacing = 1.2;

enum HAlign { left, center, right }

enum VAlign { top, center, baseline, bottom, centerBaseline }

/// Measured multi-line text block (unrotated frame, y down, px).
class MplTextBlock {
  MplTextBlock._(
    this.painters,
    this.width,
    this.height,
    this.baselines,
    this.lineX,
    this.ascent,
    this.descent,
  );

  factory MplTextBlock(String text, double sizePx, Color color, HAlign malign) {
    final lines = text.split('\n');
    final a = _lpAscent * sizePx;
    final d = _lpDescent * sizePx;
    final painters = <TextPainter>[];
    for (final l in lines) {
      painters.add(
        TextPainter(
          text: TextSpan(
            text: l,
            style: TextStyle(
              fontFamily: kMplFontFamily,
              fontSize: sizePx,
              color: color,
              height: 1.0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
    }
    final widths = [for (final p in painters) p.width];
    final w = widths.isEmpty ? 0.0 : widths.reduce(math.max);
    final baselines = <double>[];
    var y = 0.0;
    for (var i = 0; i < lines.length; i++) {
      if (i == 0) {
        y = a;
      } else {
        y += d + a * _lineSpacing;
      }
      baselines.add(y);
    }
    final h = (baselines.isEmpty ? 0.0 : baselines.last) + d;
    final lineX = [
      for (final wi in widths)
        switch (malign) {
          HAlign.left => 0.0,
          HAlign.center => w / 2 - wi / 2,
          HAlign.right => w - wi,
        },
    ];
    return MplTextBlock._(painters, w, h, baselines, lineX, a, d);
  }

  final List<TextPainter> painters;
  final double width, height;
  final List<double> baselines;
  final List<double> lineX;
  final double ascent, descent;

  /// matplotlib's `baseline` value of the last line (distance top->baseline
  /// for single-line text).
  double get _mplBaseline {
    if (baselines.isEmpty) return 0;
    if (baselines.length == 1) return ascent;
    return ascent + baselines[baselines.length - 2] + descent;
  }

  void _paintAt(Canvas canvas, double left, double top) {
    for (var i = 0; i < painters.length; i++) {
      final p = painters[i];
      final bl = p.computeDistanceToActualBaseline(ui.TextBaseline.alphabetic);
      p.paint(canvas, Offset(left + lineX[i], top + baselines[i] - bl));
    }
  }
}

/// Draws [text] like matplotlib's Text(x, y, ha, va, rotation).
/// Returns the text's bounding box on the canvas (axis-aligned, px).
Rect drawMplText(
  Canvas canvas,
  String text,
  Offset anchor,
  double sizePx, {
  HAlign ha = HAlign.left,
  VAlign va = VAlign.baseline,
  double rotationDeg = 0,
  bool rotationModeAnchor = false,
  Color color = const Color(0xFF000000),
  HAlign? multiAlign,
}) {
  final b = MplTextBlock(text, sizePx, color, multiAlign ?? ha);
  return drawMplTextBlock(
    canvas,
    b,
    anchor,
    ha: ha,
    va: va,
    rotationDeg: rotationDeg,
    rotationModeAnchor: rotationModeAnchor,
  );
}

/// Bounding box a text would occupy (without drawing it).
Rect measureMplText(
  String text,
  Offset anchor,
  double sizePx, {
  HAlign ha = HAlign.left,
  VAlign va = VAlign.baseline,
  double rotationDeg = 0,
  bool rotationModeAnchor = false,
}) {
  final b = MplTextBlock(text, sizePx, const Color(0xFF000000), ha);
  return drawMplTextBlock(
    null,
    b,
    anchor,
    ha: ha,
    va: va,
    rotationDeg: rotationDeg,
    rotationModeAnchor: rotationModeAnchor,
  );
}

Rect drawMplTextBlock(
  Canvas? canvas,
  MplTextBlock b,
  Offset anchor, {
  HAlign ha = HAlign.left,
  VAlign va = VAlign.baseline,
  double rotationDeg = 0,
  bool rotationModeAnchor = false,
}) {
  // Work in matplotlib's y-up text frame: block spans x [0, w], y [-h, 0].
  final w = b.width, h = b.height;
  final baseline = b._mplBaseline;
  final th = rotationDeg * math.pi / 180;
  final c = math.cos(th), s = math.sin(th);
  (double, double) rot(double x, double y) => (x * c - y * s, x * s + y * c);

  final corners = [rot(0, -h), rot(0, 0), rot(w, 0), rot(w, -h)];
  final xmin = corners.map((p) => p.$1).reduce(math.min);
  final xmax = corners.map((p) => p.$1).reduce(math.max);
  final ymin = corners.map((p) => p.$2).reduce(math.min);
  final ymax = corners.map((p) => p.$2).reduce(math.max);

  double ox, oy;
  if (!rotationModeAnchor) {
    ox = switch (ha) {
      HAlign.center => (xmin + xmax) / 2,
      HAlign.right => xmax,
      HAlign.left => xmin,
    };
    oy = switch (va) {
      VAlign.center => (ymin + ymax) / 2,
      VAlign.top => ymax,
      VAlign.baseline => ymin + b.descent,
      VAlign.centerBaseline => ymin + (ymax - ymin) - baseline / 2,
      VAlign.bottom => ymin,
    };
  } else {
    final x0 = ha == HAlign.center ? w / 2 : (ha == HAlign.right ? w : 0.0);
    final y0 = switch (va) {
      VAlign.center => -h / 2,
      VAlign.top => 0.0,
      VAlign.baseline => 0.0 - baseline,
      VAlign.centerBaseline => 0.0 - baseline / 2,
      VAlign.bottom => -h,
    };
    final r = rot(x0, y0);
    ox = r.$1;
    oy = r.$2;
  }
  // Text origin (block top-left in the text frame) relative to anchor, in
  // screen coordinates (y down).
  final bboxLeft = anchor.dx + (xmin - ox);
  final bboxTop = anchor.dy - (ymax - oy);
  final bbox = Rect.fromLTWH(bboxLeft, bboxTop, xmax - xmin, ymax - ymin);
  if (canvas != null) {
    canvas.save();
    canvas.translate(anchor.dx - ox, anchor.dy + oy);
    canvas.rotate(-th);
    // The frame origin is the block's top-left corner.
    b._paintAt(canvas, 0, 0);
    canvas.restore();
  }
  return bbox;
}
