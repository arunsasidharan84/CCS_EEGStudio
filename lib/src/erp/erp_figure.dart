// lib/src/erp/erp_figure.dart
//
// The two figures of compute_mmn_erp.py, drawn with the same matplotlib
// conventions (DejaVu Sans, tick locator/formatter, tight_layout-style
// margins) as the TopoStats figure:
//
//   ErpWaveformFigure  – erp_waveforms_<el>.png: one panel per session,
//                        condition A/B mean ± SEM, window shading, cluster
//                        bars and window statistics box (9 × 3.2·n in, 150 dpi)
//   ErpEffectFigure    – effect_size_summary_<el>.png: within-session Cohen's d
//                        with bootstrap CI, and mismatch per session with
//                        between-session d (7.5 × 10 in, 150 dpi)
//
// Both paint at any dpi (interactive view and PNG/PDF export use the same code).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../topostats/mpl_text.dart';
import '../topostats/mpl_ticker.dart';
import 'erp_engine.dart';

const _black = Color(0xFF000000);
const _blue = Color(0xFF1F77B4);
const _red = Color(0xFFD62728);
const _barBlue = Color(0xFF4C72B0);
const _barRed = Color(0xFFC44E52);
const _grey = Color(0xFF808080);
const _monoFamily = 'Menlo';
const _monoFallback = [
  'DejaVu Sans Mono',
  'Courier New',
  'Courier',
  'monospace',
];

/// Removes a parenthetical suffix: "Standard (S51)" -> "Standard".
String shortConditionName(String s) =>
    s.replaceAll(RegExp(r'\s*\(.*\)\s*$'), '').trim();

/// Session names for the bar charts. The script strips "Pilot_Tukdam_"; in
/// general the alphabetic tokens that every file shares right after the
/// index prefix (the study name) are dropped.
List<String> shortSessionNames(List<String> labels) {
  if (labels.length < 2) return labels;
  final toks = [for (final l in labels) l.split('_')];
  final minLen = toks.map((t) => t.length).reduce(math.min);
  final drop = <int>{};
  for (var k = 1; k < minLen - 1; k++) {
    final t = toks.first[k];
    if (!RegExp(r'^[A-Za-z]+$').hasMatch(t)) break;
    if (toks.every((x) => x[k] == t)) {
      drop.add(k);
    } else {
      break;
    }
  }
  if (drop.isEmpty) return labels;
  return [
    for (final t in toks)
      [
        for (var k = 0; k < t.length; k++)
          if (!drop.contains(k)) t[k],
      ].join('_'),
  ];
}

String _msWindow(ErpSettings s) =>
    '${(s.winStart * 1000).toStringAsFixed(0)}–${(s.winEnd * 1000).toStringAsFixed(0)} ms';

/// Draws text in the monospace font (script: family="monospace").
Rect _monoText(
  Canvas? canvas,
  String text,
  Offset anchor,
  double sizePx, {
  HAlign ha = HAlign.left,
  VAlign va = VAlign.baseline,
  Color color = _black,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: _monoFamily,
        fontFamilyFallback: _monoFallback,
        fontSize: sizePx,
        color: color,
        height: 1.2,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final w = tp.width, h = tp.height;
  final x = switch (ha) {
    HAlign.left => anchor.dx,
    HAlign.center => anchor.dx - w / 2,
    HAlign.right => anchor.dx - w,
  };
  final y = switch (va) {
    VAlign.top => anchor.dy,
    VAlign.bottom => anchor.dy - h,
    VAlign.center || VAlign.centerBaseline => anchor.dy - h / 2,
    VAlign.baseline =>
      anchor.dy - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic),
  };
  if (canvas != null) tp.paint(canvas, Offset(x, y));
  return Rect.fromLTWH(x, y, w, h);
}

/// matplotlib bbox=dict(boxstyle="round", fc="white", ec="0.7", alpha=0.85)
void _textBox(Canvas canvas, Rect textRect, double fontPx, double pt) {
  final pad = 0.3 * fontPx;
  final r = textRect.inflate(pad);
  final rr = RRect.fromRectAndRadius(r, Radius.circular(pad));
  canvas.drawRRect(
    rr,
    Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85),
  );
  canvas.drawRRect(
    rr,
    Paint()
      ..color = const Color(0xFFB3B3B3).withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 * pt,
  );
}

abstract class ErpFigure {
  double get widthIn;
  double get heightIn;
  void paint(Canvas canvas, double dpi);

  Future<ui.Image> toImage({double dpi = 150}) async {
    final w = (widthIn * dpi).round(), h = (heightIn * dpi).round();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    paint(canvas, dpi);
    final pic = rec.endRecording();
    try {
      return await pic.toImage(w, h);
    } finally {
      pic.dispose();
    }
  }

  Future<Uint8List> toPng({double dpi = 150}) async {
    final img = await toImage(dpi: dpi);
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      return bd!.buffer.asUint8List();
    } finally {
      img.dispose();
    }
  }
}

/// Location of the pointer on a waveform panel.
class ErpHit {
  const ErpHit(this.panel, this.sample, this.time);
  final int panel, sample;
  final double time;
}

// ═══════════════════════════════════════════════════════════════════════
//  Waveform figure
// ═══════════════════════════════════════════════════════════════════════

class ErpWaveformFigure extends ErpFigure {
  ErpWaveformFigure(this.an, {this.showClusterAlpha = 0.05}) {
    final rs = an.results;
    final n = math.max(1, rs.length);
    widthIn = 9;
    heightIn = 3.2 * n;
    // global y-limits (mean ± SEM of both conditions, 10 % padding)
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final r in rs) {
      for (var k = 0; k < r.times.length; k++) {
        for (final v in [
          r.aMean[k] + r.aSem[k],
          r.aMean[k] - r.aSem[k],
          r.bMean[k] + r.bSem[k],
          r.bMean[k] - r.bSem[k],
        ]) {
          if (v.isNaN) continue;
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
      }
    }
    if (!lo.isFinite) {
      lo = -1;
      hi = 1;
    }
    final pad = 0.1 * (hi - lo);
    yLim = (lo - pad, hi + pad);
    var t0 = double.infinity, t1 = double.negativeInfinity;
    for (final r in rs) {
      t0 = math.min(t0, r.times.first);
      t1 = math.max(t1, r.times.last);
    }
    if (!t0.isFinite) {
      t0 = -0.5;
      t1 = 1.2;
    }
    // axes.xmargin = 0.05, but the window span also counts as data
    final s = an.settings;
    final d0 = math.min(t0, s.winStart), d1 = math.max(t1, s.winEnd);
    final m = 0.05 * (d1 - d0);
    xLim = (d0 - m, d1 + m);
  }

  final ErpAnalysis an;
  final double showClusterAlpha;
  @override
  late final double widthIn, heightIn;
  late final (double, double) yLim, xLim;

  /// Panel rectangles in inches (computed in [layout]).
  List<Rect> panelsIn = const [];

  // tight_layout(rect=[0, 0, 1, 0.94]) margins measured on the script's
  // output (10 pt fonts): bottom 0.583 in, gap 0.393 in, top 0.06·H + 0.811 in
  void layout() {
    final n = math.max(1, an.results.length);
    const bottom = 0.583, gap = 0.393;
    final top = 0.06 * heightIn + 0.811;
    // left: pad + ylabel + labelpad + widest y tick label + tick
    final axHIn = (heightIn - top - bottom - (n - 1) * gap) / n;
    final yt = AxisTicks.compute(
      MaxNLocator.auto(yTickSpace(axHIn * 72, 10)),
      yLim.$1,
      yLim.$2,
    );
    var maxW = 0.0;
    for (final l in yt.labels) {
      maxW = math.max(maxW, measureMplText(l, Offset.zero, 10).width);
    }
    final leftPt = 10.8 + 9.68 + 4 + maxW + 7;
    final left = leftPt / 72, right = 12.7 / 72;
    panelsIn = [
      for (var i = 0; i < n; i++)
        Rect.fromLTWH(
          left,
          top + i * (axHIn + gap),
          widthIn - left - right,
          axHIn,
        ),
    ];
  }

  double xOf(Rect ax, double t) =>
      ax.left + (t - xLim.$1) / (xLim.$2 - xLim.$1) * ax.width;
  double yOf(Rect ax, double v) =>
      ax.bottom - (v - yLim.$1) / (yLim.$2 - yLim.$1) * ax.height;

  Rect panelPx(int i, double dpi) {
    if (panelsIn.isEmpty) layout();
    final r = panelsIn[i];
    return Rect.fromLTRB(
      r.left * dpi,
      r.top * dpi,
      r.right * dpi,
      r.bottom * dpi,
    );
  }

  ErpHit? hitTest(Offset p, double dpi) {
    if (panelsIn.isEmpty) layout();
    for (var i = 0; i < an.results.length; i++) {
      final ax = panelPx(i, dpi);
      if (!ax.contains(p)) continue;
      final t = xLim.$1 + (p.dx - ax.left) / ax.width * (xLim.$2 - xLim.$1);
      final times = an.results[i].times;
      var best = 0;
      for (var k = 1; k < times.length; k++) {
        if ((times[k] - t).abs() < (times[best] - t).abs()) best = k;
      }
      return ErpHit(i, best, times[best]);
    }
    return null;
  }

  @override
  void paint(Canvas canvas, double dpi) {
    layout();
    final pt = dpi / 72;
    final s = an.settings;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthIn * dpi, heightIn * dpi),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final aShort = shortConditionName(s.condA.name),
        bShort = shortConditionName(s.condB.name);
    // suptitle (fontsize 11, y = 0.98, va top)
    drawMplText(
      canvas,
      '${s.componentName} ERPs at electrode ${s.electrode} — $aShort vs $bShort '
      '(mean ± SEM)\nBlack bar = significant cluster (permutation test, p<${_fmtAlpha(showClusterAlpha)})',
      Offset(widthIn * dpi / 2, 0.02 * heightIn * dpi),
      11 * pt,
      ha: HAlign.center,
      va: VAlign.top,
      multiAlign: HAlign.center,
    );

    for (var i = 0; i < an.results.length; i++) {
      _paintPanel(canvas, i, dpi, pt, isLast: i == an.results.length - 1);
    }
    if (an.results.isNotEmpty) _paintLegend(canvas, panelPx(0, dpi), pt);
  }

  String _fmtAlpha(double a) => a.toString().replaceFirst(RegExp(r'0+$'), '');

  void _paintPanel(
    Canvas canvas,
    int i,
    double dpi,
    double pt, {
    required bool isLast,
  }) {
    final r = an.results[i];
    final s = an.settings;
    final ax = panelPx(i, dpi);
    canvas.save();
    canvas.clipRect(ax);
    // MMN window
    canvas.drawRect(
      Rect.fromLTRB(xOf(ax, s.winStart), ax.top, xOf(ax, s.winEnd), ax.bottom),
      Paint()..color = _grey.withValues(alpha: 0.15),
    );
    final thin = Paint()
      ..color = _black
      ..strokeWidth = 0.6 * pt
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(ax.left, yOf(ax, 0)),
      Offset(ax.right, yOf(ax, 0)),
      thin,
    );
    _dashedV(
      canvas,
      xOf(ax, 0),
      ax.top,
      ax.bottom,
      thin,
      3.7 * 0.6 * pt,
      1.6 * 0.6 * pt,
    );

    void band(Float64List m, Float64List e, Color c) {
      final p = Path();
      for (var k = 0; k < r.times.length; k++) {
        final o = Offset(xOf(ax, r.times[k]), yOf(ax, m[k] + e[k]));
        k == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      for (var k = r.times.length - 1; k >= 0; k--) {
        p.lineTo(xOf(ax, r.times[k]), yOf(ax, m[k] - e[k]));
      }
      p.close();
      canvas.drawPath(p, Paint()..color = c.withValues(alpha: 0.25));
    }

    void line(Float64List m, Color c) {
      final p = Path();
      for (var k = 0; k < r.times.length; k++) {
        final o = Offset(xOf(ax, r.times[k]), yOf(ax, m[k]));
        k == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        p,
        Paint()
          ..color = c
          ..strokeWidth = 1.6 * pt
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.square,
      );
    }

    // same z-order as the script: A line, A band, B line, B band
    line(r.aMean, _blue);
    band(r.aMean, r.aSem, _blue);
    line(r.bMean, _red);
    band(r.bMean, r.bSem, _red);

    // significant clusters: thick black bar near the bottom
    final barY = yOf(ax, yLim.$1 + 0.03 * (yLim.$2 - yLim.$1));
    for (final c in r.clusters) {
      if (c.pValue <= showClusterAlpha) {
        final t0 = r.times[c.startIdx],
            t1 = r.times[math.min(c.endIdx, r.times.length - 1)];
        canvas.drawLine(
          Offset(xOf(ax, t0), barY),
          Offset(xOf(ax, t1), barY),
          Paint()
            ..color = _black
            ..strokeWidth = 4 * pt
            ..strokeCap = StrokeCap.butt,
        );
      }
    }
    canvas.restore();

    // spines
    canvas.drawRect(
      ax,
      Paint()
        ..color = _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 * pt,
    );
    final tick = Paint()
      ..color = _black
      ..strokeWidth = 0.8 * pt;
    final xt = AxisTicks.compute(
      MaxNLocator.auto(xTickSpace(ax.width / pt, 10)),
      xLim.$1,
      xLim.$2,
    );
    var labelsBottom = ax.bottom;
    for (var k = 0; k < xt.locs.length; k++) {
      final x = xOf(ax, xt.locs[k]);
      canvas.drawLine(
        Offset(x, ax.bottom),
        Offset(x, ax.bottom + 3.5 * pt),
        tick,
      );
      if (isLast) {
        final bb = drawMplText(
          canvas,
          xt.labels[k],
          Offset(x, ax.bottom + 7 * pt),
          10 * pt,
          ha: HAlign.center,
          va: VAlign.top,
        );
        labelsBottom = math.max(labelsBottom, bb.bottom);
      }
    }
    if (isLast) {
      drawMplText(
        canvas,
        'Time (s)',
        Offset(ax.center.dx, labelsBottom + 4 * pt),
        10 * pt,
        ha: HAlign.center,
        va: VAlign.top,
      );
    }
    final yt = AxisTicks.compute(
      MaxNLocator.auto(yTickSpace(ax.height / pt, 10)),
      yLim.$1,
      yLim.$2,
    );
    var labelsLeft = ax.left - 3.5 * pt;
    for (var k = 0; k < yt.locs.length; k++) {
      final y = yOf(ax, yt.locs[k]);
      canvas.drawLine(Offset(ax.left - 3.5 * pt, y), Offset(ax.left, y), tick);
      final bb = drawMplText(
        canvas,
        yt.labels[k],
        Offset(ax.left - 7 * pt, y),
        10 * pt,
        ha: HAlign.right,
        va: VAlign.centerBaseline,
      );
      labelsLeft = math.min(labelsLeft, bb.left);
    }
    drawMplText(
      canvas,
      'Amplitude (µV)',
      Offset(labelsLeft - 4 * pt, ax.center.dy),
      10 * pt,
      ha: HAlign.center,
      va: VAlign.bottom,
      rotationDeg: 90,
      rotationModeAnchor: true,
    );
    // title(loc="left", fontsize=10)
    drawMplText(
      canvas,
      '${r.fileLabel}   (n_std=${r.nA}, n_dev=${r.nB})',
      Offset(ax.left, ax.top - 6 * pt),
      10 * pt,
      ha: HAlign.left,
      va: VAlign.baseline,
    );
    // window statistics box, bottom right
    final txt =
        '${s.componentName} window ${_msWindow(s)}:  '
        't(${r.dfWindow.toStringAsFixed(0)})=${r.tWindow.toStringAsFixed(2)}, '
        'p=${r.pWindow.toStringAsFixed(4)}, d=${r.dWindow.toStringAsFixed(2)}';
    final anchor = Offset(
      ax.left + 0.99 * ax.width,
      ax.bottom - 0.03 * ax.height,
    );
    final bb = _monoText(
      null,
      txt,
      anchor,
      8 * pt,
      ha: HAlign.right,
      va: VAlign.bottom,
    );
    final pad = 0.3 * 8 * pt;
    final shifted = bb.shift(Offset(-pad, -pad));
    _textBox(canvas, shifted, 8 * pt, pt);
    _monoText(
      canvas,
      txt,
      anchor.translate(-pad, -pad),
      8 * pt,
      ha: HAlign.right,
      va: VAlign.bottom,
    );
  }

  void _paintLegend(Canvas canvas, Rect ax, double pt) {
    final s = an.settings;
    final entries = <(String, Color, bool)>[
      ('${s.componentName} window', _grey.withValues(alpha: 0.15), true),
      (s.condA.name, _blue, false),
      (s.condB.name, _red, false),
    ];
    const fs = 8.0;
    final fsPx = fs * pt;
    final handleLen = 2.0 * fsPx,
        handleGap = 0.8 * fsPx,
        rowGap = 0.5 * fsPx,
        border = 0.4 * fsPx;
    var textW = 0.0;
    for (final e in entries) {
      textW = math.max(textW, measureMplText(e.$1, Offset.zero, fsPx).width);
    }
    final rowH = fsPx * 0.97;
    final w = border * 2 + handleLen + handleGap + textW;
    final h =
        border * 2 + entries.length * rowH + (entries.length - 1) * rowGap;
    final pad = 0.5 * fsPx;
    final box = Rect.fromLTWH(ax.right - pad - w, ax.top + pad, w, h);
    final rr = RRect.fromRectAndRadius(box, Radius.circular(0.2 * fsPx));
    canvas.drawRRect(
      rr,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.9),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..color = const Color(0xFFCCCCCC).withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 * pt,
    );
    for (var i = 0; i < entries.length; i++) {
      final (label, c, patch) = entries[i];
      final cy = box.top + border + i * (rowH + rowGap) + rowH / 2;
      final hx = box.left + border;
      if (patch) {
        canvas.drawRect(
          Rect.fromLTWH(hx, cy - 0.35 * fsPx, handleLen, 0.7 * fsPx),
          Paint()..color = c,
        );
        canvas.drawRect(
          Rect.fromLTWH(hx, cy - 0.35 * fsPx, handleLen, 0.7 * fsPx),
          Paint()
            ..color = _grey.withValues(alpha: 0.15)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 * pt,
        );
      } else {
        canvas.drawLine(
          Offset(hx, cy),
          Offset(hx + handleLen, cy),
          Paint()
            ..color = c
            ..strokeWidth = 1.6 * pt,
        );
      }
      drawMplText(
        canvas,
        label,
        Offset(hx + handleLen + handleGap, cy),
        fsPx,
        ha: HAlign.left,
        va: VAlign.centerBaseline,
      );
    }
  }

  void _dashedV(
    Canvas c,
    double x,
    double y0,
    double y1,
    Paint p,
    double dash,
    double gap,
  ) {
    var y = y0;
    while (y < y1) {
      final e = math.min(y + dash, y1);
      c.drawLine(Offset(x, y), Offset(x, e), p);
      y = e + gap;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  Effect-size figure
// ═══════════════════════════════════════════════════════════════════════

class ErpEffectFigure extends ErpFigure {
  ErpEffectFigure(this.an);

  final ErpAnalysis an;
  @override
  double get widthIn => 7.5;
  @override
  double get heightIn => 10;

  late List<String> _names;
  late Rect _axA, _axB; // pt
  late (double, double) _xLim, _yLimA, _yLimB;

  static const double _pad = 10.8; // tight_layout pad (1.08 × 10 pt)

  (double, double) _barLimits(
    List<double> v,
    List<double> lo,
    List<double> hi,
  ) {
    var a = 0.0, b = 0.0;
    for (var i = 0; i < v.length; i++) {
      a = math.min(a, math.min(v[i], lo[i]));
      b = math.max(b, math.max(v[i], hi[i]));
    }
    if (a == b) b = a + 1;
    final m = 0.2 * (b - a);
    return (a - m, b + m);
  }

  void _layout() {
    final rs = an.results;
    final n = rs.length;
    _names = shortSessionNames([for (final r in rs) r.fileLabel]);
    final span = (n - 1) + 0.8;
    _xLim = (-0.4 - 0.1 * span, n - 1 + 0.4 + 0.1 * span);
    _yLimA = _barLimits(
      [for (final r in rs) r.dWindow],
      [for (final r in rs) r.dBootLo],
      [for (final r in rs) r.dBootHi],
    );
    _yLimB = _barLimits(
      [for (final r in rs) r.mismatchMean],
      [for (final r in rs) r.mismatchLo],
      [for (final r in rs) r.mismatchHi],
    );

    const wPt = 7.5 * 72, hPt = 10 * 72;
    // rotated tick labels (fontsize 8, rotation 20, ha right)
    final rot = [
      for (final l in _names)
        measureMplText(
          l,
          Offset.zero,
          8,
          ha: HAlign.right,
          va: VAlign.top,
          rotationDeg: 20,
        ),
    ];
    final rotH = rot.isEmpty ? 0.0 : rot.map((b) => b.height).reduce(math.max);
    final titleH = measureMplText('A\nB', Offset.zero, 9).height;
    final top = _pad + titleH + 6;
    final between = rotH + 7 + _pad + titleH + 6;
    final bottom = _pad + rotH + 7;
    final axH = (hPt - top - between - bottom) / 2;

    double yDecor((double, double) lim) {
      final yt = AxisTicks.compute(
        MaxNLocator.auto(yTickSpace(axH, 10)),
        lim.$1,
        lim.$2,
      );
      var mw = 0.0;
      for (final l in yt.labels) {
        mw = math.max(mw, measureMplText(l, Offset.zero, 10).width);
      }
      return 9.68 + 4 + mw + 7;
    }

    final yDec = math.max(yDecor(_yLimA), yDecor(_yLimB));
    var left = _pad + yDec;
    var right = _pad;
    for (var it = 0; it < 8; it++) {
      final axW = wPt - left - right;
      var need = _pad;
      for (var i = 0; i < n; i++) {
        final x = left + (i - _xLim.$1) / (_xLim.$2 - _xLim.$1) * axW;
        need = math.max(need, _pad - (x - rot[i].width) + left);
      }
      final nl = math.max(_pad + yDec, need);
      if ((nl - left).abs() < 0.01) break;
      left = nl;
    }
    _axA = Rect.fromLTWH(left, top, wPt - left - right, axH);
    _axB = Rect.fromLTWH(left, top + axH + between, wPt - left - right, axH);
  }

  @override
  void paint(Canvas canvas, double dpi) {
    _layout();
    final pt = dpi / 72;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthIn * dpi, heightIn * dpi),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final rs = an.results;
    final s = an.settings;
    Rect px(Rect r) =>
        Rect.fromLTRB(r.left * pt, r.top * pt, r.right * pt, r.bottom * pt);

    // Panel A: within-session Cohen's d
    final axA = px(_axA);
    _bars(
      canvas,
      axA,
      pt,
      _yLimA,
      [for (final r in rs) r.dWindow],
      [for (final r in rs) r.dBootLo],
      [for (final r in rs) r.dBootHi],
      _barBlue,
    );
    double yOfA(double v) =>
        axA.bottom - (v - _yLimA.$1) / (_yLimA.$2 - _yLimA.$1) * axA.height;
    double xOfA(double v) =>
        axA.left + (v - _xLim.$1) / (_xLim.$2 - _xLim.$1) * axA.width;
    for (var i = 0; i < rs.length; i++) {
      final d = rs[i].dWindow;
      final up = rs[i].dBootHi - d, dn = d - rs[i].dBootLo;
      final sg = d == 0 ? 1.0 : d.sign;
      final y = d + (d >= 0 ? up : -dn) + 0.05 * sg;
      drawMplText(
        canvas,
        rs[i].pWindow < s.alpha ? '*' : 'ns',
        Offset(xOfA(i.toDouble()), yOfA(y)),
        10 * pt,
        ha: HAlign.center,
        va: VAlign.baseline,
      );
    }
    _decor(
      canvas,
      axA,
      pt,
      _yLimA,
      "Cohen's d (${shortConditionName(s.condA.name)} vs "
          "${shortConditionName(s.condB.name)})",
      'Within-session effect size\n${s.componentName} window ${_msWindow(s)} '
          '(error bars = bootstrap 95% CI)',
    );

    // Panel B: mismatch magnitude per session
    final axB = px(_axB);
    _bars(
      canvas,
      axB,
      pt,
      _yLimB,
      [for (final r in rs) r.mismatchMean],
      [for (final r in rs) r.mismatchLo],
      [for (final r in rs) r.mismatchHi],
      _barRed,
    );
    _decor(
      canvas,
      axB,
      pt,
      _yLimB,
      'Mismatch magnitude, ${shortConditionName(s.condB.name)} − '
          '${shortConditionName(s.condA.name)} (µV)',
      'Between-session comparison\n(mismatch magnitude, bootstrap 95% CI)',
    );
    if (an.between.isNotEmpty) {
      final txt = [
        for (final b in an.between)
          '${_names[b.i]} vs ${_names[b.j]}: d=${b.d.toStringAsFixed(2)}',
      ].join('\n');
      final anchor = Offset(
        axB.left + 0.02 * axB.width,
        axB.bottom - 0.02 * axB.height,
      );
      final pad = 0.3 * 7 * pt;
      final bb = _monoText(
        null,
        txt,
        anchor,
        7 * pt,
        ha: HAlign.left,
        va: VAlign.bottom,
      );
      _textBox(canvas, bb.shift(Offset(pad, -pad)), 7 * pt, pt);
      _monoText(
        canvas,
        txt,
        anchor.translate(pad, -pad),
        7 * pt,
        ha: HAlign.left,
        va: VAlign.bottom,
      );
    }
  }

  void _bars(
    Canvas canvas,
    Rect ax,
    double pt,
    (double, double) yl,
    List<double> v,
    List<double> lo,
    List<double> hi,
    Color c,
  ) {
    double xOf(double x) =>
        ax.left + (x - _xLim.$1) / (_xLim.$2 - _xLim.$1) * ax.width;
    double yOf(double y) =>
        ax.bottom - (y - yl.$1) / (yl.$2 - yl.$1) * ax.height;
    canvas.save();
    canvas.clipRect(ax);
    for (var i = 0; i < v.length; i++) {
      canvas.drawRect(
        Rect.fromLTRB(
          xOf(i - 0.4),
          yOf(math.max(0, v[i])),
          xOf(i + 0.4),
          yOf(math.min(0, v[i])),
        ),
        Paint()..color = c.withValues(alpha: 0.85),
      );
    }
    canvas.drawLine(
      Offset(ax.left, yOf(0)),
      Offset(ax.right, yOf(0)),
      Paint()
        ..color = _black
        ..strokeWidth = 0.8 * pt,
    );
    final e = Paint()
      ..color = _black
      ..strokeWidth = 1.5 * pt;
    for (var i = 0; i < v.length; i++) {
      final x = xOf(i.toDouble());
      canvas.drawLine(Offset(x, yOf(lo[i])), Offset(x, yOf(hi[i])), e);
      for (final y in [lo[i], hi[i]]) {
        canvas.drawLine(
          Offset(x - 5 * pt, yOf(y)),
          Offset(x + 5 * pt, yOf(y)),
          e,
        );
      }
    }
    canvas.restore();
  }

  void _decor(
    Canvas canvas,
    Rect ax,
    double pt,
    (double, double) yl,
    String ylabel,
    String title,
  ) {
    double xOf(double x) =>
        ax.left + (x - _xLim.$1) / (_xLim.$2 - _xLim.$1) * ax.width;
    double yOf(double y) =>
        ax.bottom - (y - yl.$1) / (yl.$2 - yl.$1) * ax.height;
    canvas.drawRect(
      ax,
      Paint()
        ..color = _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 * pt,
    );
    final tick = Paint()
      ..color = _black
      ..strokeWidth = 0.8 * pt;
    for (var i = 0; i < _names.length; i++) {
      final x = xOf(i.toDouble());
      canvas.drawLine(
        Offset(x, ax.bottom),
        Offset(x, ax.bottom + 3.5 * pt),
        tick,
      );
      drawMplText(
        canvas,
        _names[i],
        Offset(x, ax.bottom + 7 * pt),
        8 * pt,
        ha: HAlign.right,
        va: VAlign.top,
        rotationDeg: 20,
      );
    }
    final yt = AxisTicks.compute(
      MaxNLocator.auto(yTickSpace(ax.height / pt, 10)),
      yl.$1,
      yl.$2,
    );
    var labelsLeft = ax.left - 3.5 * pt;
    for (var k = 0; k < yt.locs.length; k++) {
      final y = yOf(yt.locs[k]);
      canvas.drawLine(Offset(ax.left - 3.5 * pt, y), Offset(ax.left, y), tick);
      final bb = drawMplText(
        canvas,
        yt.labels[k],
        Offset(ax.left - 7 * pt, y),
        10 * pt,
        ha: HAlign.right,
        va: VAlign.centerBaseline,
      );
      labelsLeft = math.min(labelsLeft, bb.left);
    }
    drawMplText(
      canvas,
      ylabel,
      Offset(labelsLeft - 4 * pt, ax.center.dy),
      10 * pt,
      ha: HAlign.center,
      va: VAlign.bottom,
      rotationDeg: 90,
      rotationModeAnchor: true,
    );
    drawMplText(
      canvas,
      title,
      Offset(ax.center.dx, ax.top - 6 * pt),
      9 * pt,
      ha: HAlign.center,
      va: VAlign.baseline,
      multiAlign: HAlign.center,
    );
  }
}
