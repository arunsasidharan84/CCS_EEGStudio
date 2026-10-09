// lib/src/report/feature_report.dart
//
// Per-recording "Feature Report" PDF (replaces the hand-written dark-theme
// PDF in extraction_service.dart, which rendered pale text on white, lumped
// every column into "OTHER", reported 0 EEG channels in batch mode and drew
// a 30-s, 16-channel waveform strip too dense to read).
//
// Pages (A4, light theme, vector text via package:pdf):
//   1. Summary     – recording facts, preprocessing steps + parameters,
//                    feature families found in the CSV.
//   2. Signal      – 10-s snapshot of the cleaned EEG, every channel on its
//                    own labelled row with a common µV scale bar and 1-s
//                    grid; the raw signal is overlaid in grey when available.
//   3. Topography  – channel-mean scalp maps (MNE-style interpolation) of the
//                    band-power / aperiodic / nonlinear features.
//   4. Time course – per-feature mean across channels over the recording
//                    (smoothed like the TopoStats figure) with an IQR band.
//   5. Statistics  – per-feature summary table grouped by family
//                    (mean, SD, median, 5th/95th pct, % missing).
//
// Figures are rasterised with the app's own painters (Flutter canvas) at
// 200 dpi and embedded as images; all text and tables stay vector.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models.dart';
import '../topostats/mpl_text.dart';
import '../topostats/topo_interp.dart';
import '../topostats/topo_paint.dart';
import '../topostats/topostats_engine.dart';

// ── Palette (light, print friendly) ──────────────────────────────────────
const _ink = PdfColor.fromInt(0xFF111827);
const _muted = PdfColor.fromInt(0xFF4B5563);
const _faint = PdfColor.fromInt(0xFFE5E7EB);
const _zebra = PdfColor.fromInt(0xFFF3F4F6);
const _accent = PdfColor.fromInt(0xFF1D4ED8);
const _ok = PdfColor.fromInt(0xFF15803D);

const Map<String, String> _familyTitles = {
  'psd': 'Relative band power (Welch PSD)',
  'fooof': 'FOOOF periodic / aperiodic',
  'irasa': 'IRASA oscillatory / fractal',
  'nonlinear': 'Nonlinear dynamics',
  'acw': 'Autocorrelation window',
  'conn': 'Functional connectivity',
  'other': 'Other',
};

/// Family of a feature column, from the engine's naming convention.
String featureFamily(String h) {
  final l = h.toLowerCase();
  if (l.startsWith('conn_')) return 'conn';
  if (l.endsWith('_psd')) return 'psd';
  if (l.endsWith('_fooof')) return 'fooof';
  if (l.endsWith('_irasa')) return 'irasa';
  if (l.endsWith('_nonlinear')) return 'nonlinear';
  if (l == 'acw' || l.startsWith('acw')) return 'acw';
  return 'other';
}

String _prettyFeature(String h) => h
    .replaceAll(RegExp(r'_(PSD|FOOOF|Irasa|nonlinear)$'), '')
    .replaceAll('_', ' ');

class _FeatureSummary {
  _FeatureSummary(this.name);
  final String name;
  double mean = double.nan, sd = double.nan, median = double.nan;
  double p5 = double.nan, p95 = double.nan, missingPct = 0;
  Float64List chanMean = Float64List(0);
  Float64List timeMean = Float64List(0);
  Float64List timeQ1 = Float64List(0);
  Float64List timeQ3 = Float64List(0);
  Float64List tMin = Float64List(0);
}

double _quantile(List<double> sorted, double q) {
  if (sorted.isEmpty) return double.nan;
  final pos = (sorted.length - 1) * q;
  final lo = pos.floor(), hi = pos.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
}

_FeatureSummary _summarise(
  String name,
  List<int> epochs,
  Float64List m,
  int nCh,
  double epochSec,
  int smooth,
) {
  final s = _FeatureSummary(name);
  final nE = epochs.length;
  final all = <double>[];
  var missing = 0;
  final cs = Float64List(nCh), cc = Float64List(nCh);
  final tm = Float64List(nE), q1 = Float64List(nE), q3 = Float64List(nE);
  for (var r = 0; r < nE; r++) {
    final row = <double>[];
    for (var c = 0; c < nCh; c++) {
      final v = m[r * nCh + c];
      if (v.isFinite) {
        all.add(v);
        row.add(v);
        cs[c] += v;
        cc[c] += 1;
      } else {
        missing++;
      }
    }
    row.sort();
    tm[r] = row.isEmpty ? double.nan : row.reduce((a, b) => a + b) / row.length;
    q1[r] = _quantile(row, 0.25);
    q3[r] = _quantile(row, 0.75);
  }
  s.missingPct = nE * nCh == 0 ? 0 : 100.0 * missing / (nE * nCh);
  if (all.isNotEmpty) {
    final mu = all.reduce((a, b) => a + b) / all.length;
    var ss = 0.0;
    for (final v in all) {
      ss += (v - mu) * (v - mu);
    }
    all.sort();
    s.mean = mu;
    s.sd = all.length > 1 ? math.sqrt(ss / (all.length - 1)) : 0;
    s.median = _quantile(all, 0.5);
    s.p5 = _quantile(all, 0.05);
    s.p95 = _quantile(all, 0.95);
  }
  s.chanMean = Float64List.fromList([
    for (var c = 0; c < nCh; c++) cc[c] > 0 ? cs[c] / cc[c] : double.nan,
  ]);
  s.timeMean = rollingCenterMean(tm, smooth);
  s.timeQ1 = rollingCenterMean(q1, smooth);
  s.timeQ3 = rollingCenterMean(q3, smooth);
  s.tMin = Float64List.fromList([for (final e in epochs) e * epochSec / 60.0]);
  return s;
}

String _fmt(double v) {
  if (v.isNaN) return '–';
  final a = v.abs();
  if (a != 0 && (a >= 1e4 || a < 1e-3)) return v.toStringAsExponential(2);
  if (a >= 100) return v.toStringAsFixed(1);
  if (a >= 1) return v.toStringAsFixed(3);
  return v.toStringAsFixed(4);
}

// ── Raster helpers (Flutter canvas → PNG) ────────────────────────────────

Future<Uint8List> _render(
  double wIn,
  double hIn,
  double dpi,
  void Function(Canvas c, double ppi) draw,
) async {
  final w = (wIn * dpi).round(), h = (hIn * dpi).round();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  c.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  draw(c, dpi);
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  pic.dispose();
  return bd!.buffer.asUint8List();
}

/// Robust raw-derived scale shared by both signal panels.
double signalComparisonSpan(
  EegRecording reference,
  List<String> channels,
  double startSeconds,
) {
  final spans = <double>[];
  for (final label in channels) {
    final index = reference.labels.indexOf(label);
    if (index < 0) continue;
    final values = reference.preview[index];
    final start = (startSeconds * reference.sampleRate).round().clamp(
      0,
      values.length,
    );
    final end = math.min(
      values.length,
      start + (10 * reference.sampleRate).round(),
    );
    if (end <= start) continue;
    final segment = values.sublist(start, end).map((v) => v.toDouble()).toList()
      ..sort();
    spans.add(_quantile(segment, 0.95) - _quantile(segment, 0.05));
  }
  spans.sort();
  return math.max(
    _quantile(spans, 0.5).isFinite ? _quantile(spans, 0.5) : 1.0,
    1e-9,
  );
}

/// 10-s multichannel snapshot, one labelled row per channel.
Future<Uint8List?> _signalImage(
  EegRecording clean,
  EegRecording? raw,
  List<String> channels,
  double wIn,
  double hIn, {
  double? sharedSpan,
  double startSeconds = 30,
}) async {
  if (clean.preview.isEmpty || clean.sampleRate <= 0) return null;
  final fs = clean.sampleRate;
  final n = clean.preview.first.length;
  if (n < fs) return null;
  const segSec = 10.0;
  final segN = math.min(n, (segSec * fs).round());
  final start = (startSeconds * fs).round().clamp(0, n - segN);
  final idx = <int>[];
  for (final ch in channels) {
    final i = clean.labels.indexOf(ch);
    if (i >= 0) idx.add(i);
  }
  if (idx.isEmpty) {
    for (var i = 0; i < clean.labels.length; i++) {
      idx.add(i);
    }
  }
  // Common robust scale: median of per-channel (p95 - p5).
  final spans = <double>[];
  for (final i in idx) {
    final seg =
        clean.preview[i]
            .sublist(start, start + segN)
            .map((v) => v.toDouble())
            .toList()
          ..sort();
    spans.add(_quantile(seg, 0.95) - _quantile(seg, 0.05));
  }
  spans.sort();
  final span = math.max(sharedSpan ?? _quantile(spans, 0.5), 1e-9);
  // Scale bar: a round number close to span/2.
  final bar = _niceNumber(span / 2);
  final rawIdx = <int, int>{};
  if (raw != null) {
    for (final i in idx) {
      final j = raw.labels.indexOf(clean.labels[i]);
      if (j >= 0) rawIdx[i] = j;
    }
  }
  final t0 = start / fs;

  return _render(wIn, hIn, 200, (c, ppi) {
    final pt = ppi / 72;
    final left = 0.55 * ppi, right = wIn * ppi - 0.75 * ppi;
    final top = 0.1 * ppi, bottom = hIn * ppi - 0.35 * ppi;
    final rowH = (bottom - top) / idx.length;
    final gain =
        rowH * 0.9 / span; // px per µV: typical trace fills ~90% of its row
    double x(double s) => left + (s / segN) * (right - left);
    // 1-s grid
    final grid = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..strokeWidth = 0.6 * pt;
    for (var sec = 0; sec <= segSec; sec++) {
      final gx = x(sec * fs);
      c.drawLine(Offset(gx, top), Offset(gx, bottom), grid);
      drawMplText(
        c,
        (t0 + sec).toStringAsFixed(0),
        Offset(gx, bottom + 3 * pt),
        7 * pt,
        ha: HAlign.center,
        va: VAlign.top,
        color: const Color(0xFF4B5563),
      );
    }
    drawMplText(
      c,
      'Time (s)',
      Offset((left + right) / 2, bottom + 14 * pt),
      7.5 * pt,
      ha: HAlign.center,
      va: VAlign.top,
      color: const Color(0xFF4B5563),
    );
    for (var r = 0; r < idx.length; r++) {
      drawMplText(
        c,
        clean.labels[idx[r]],
        Offset(left - 5 * pt, top + (r + 0.5) * rowH),
        6.5 * pt,
        ha: HAlign.right,
        va: VAlign.centerBaseline,
        color: const Color(0xFF111827),
      );
    }
    c.save();
    c.clipRect(Rect.fromLTRB(left, top, right, bottom));
    for (var r = 0; r < idx.length; r++) {
      final i = idx[r];
      final cy = top + (r + 0.5) * rowH;
      c.save();
      c.clipRect(
        Rect.fromLTRB(left, top + r * rowH, right, top + (r + 1) * rowH),
      );
      void trace(Float32List d, int from, double rate, Paint p) {
        final path = Path();
        final segLen = (segSec * rate).round();
        var mean = 0.0;
        var cnt = 0;
        for (var s = 0; s < segLen && from + s < d.length; s++) {
          mean += d[from + s];
          cnt++;
        }
        if (cnt == 0) return;
        mean /= cnt;
        final step = math.max(1, (segLen / ((right - left) * 1.5)).floor());
        for (var s = 0; s < cnt; s += step) {
          final px = left + (s / segLen) * (right - left);
          final py = cy - (d[from + s] - mean) * gain;
          if (s == 0) {
            path.moveTo(px, py);
          } else {
            path.lineTo(px, py);
          }
        }
        c.drawPath(path, p);
      }

      final j = rawIdx[i];
      if (raw != null && j != null) {
        final rs = (t0 * raw.sampleRate).round();
        trace(
          raw.preview[j],
          rs,
          raw.sampleRate,
          Paint()
            ..color = const Color(0xFFB0B7C3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5 * pt,
        );
      }
      trace(
        clean.preview[i],
        start,
        fs,
        Paint()
          ..color = const Color(0xFF1E3A8A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.55 * pt,
      );
      c.restore();
    }
    c.restore();
    // scale bar
    final bx = right + 14 * pt;
    final by = bottom;
    final bl = bar * gain;
    final sb = Paint()
      ..color = const Color(0xFFDC2626)
      ..strokeWidth = 1.2 * pt;
    c.drawLine(Offset(bx, by), Offset(bx, by - bl), sb);
    drawMplText(
      c,
      '${_fmtBar(bar)} µV',
      Offset(bx + 4 * pt, by - bl / 2),
      7 * pt,
      va: VAlign.centerBaseline,
      color: const Color(0xFFDC2626),
    );
  });
}

double _niceNumber(double x) {
  if (!(x > 0)) return 1;
  final e = (math.log(x) / math.ln10).floor();
  final f = x / math.pow(10, e);
  final nf = f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10));
  return nf * math.pow(10, e).toDouble();
}

String _fmtBar(double v) =>
    v >= 1 ? v.toStringAsFixed(0) : v.toStringAsPrecision(1);

/// Grid of channel-mean topomaps (own colour scale each).
Future<Uint8List?> _topoImage(
  List<_FeatureSummary> feats,
  List<String> channels,
  double wIn,
) async {
  final keep = <int>[];
  for (var c = 0; c < channels.length; c++) {
    if (isStandard1020Channel(channels[c])) keep.add(c);
  }
  if (keep.length < 4 || feats.isEmpty) return null;
  final chs = [for (final c in keep) channels[c]];
  final interp = TopoInterpolator.forChannels(chs);
  const cols = 3;
  final rows = (feats.length / cols).ceil();
  final cellW = wIn / cols;
  final cellH = cellW * 0.98;
  final hIn = rows * cellH;
  return _render(wIn, hIn, 200, (c, ppi) {
    final pt = ppi / 72;
    for (var k = 0; k < feats.length; k++) {
      final f = feats[k];
      final r = k ~/ cols, col = k % cols;
      final cell = Rect.fromLTWH(
        col * cellW * ppi,
        r * cellH * ppi,
        cellW * ppi,
        cellH * ppi,
      );
      final vals = [for (final c in keep) f.chanMean[c]];
      final fin = vals.where((v) => v.isFinite).toList()..sort();
      if (fin.isEmpty) continue;
      final lo = fin.first, hi = fin.last;
      drawMplText(
        c,
        _prettyFeature(f.name),
        Offset(cell.center.dx, cell.top + 4 * pt),
        8.5 * pt,
        ha: HAlign.center,
        va: VAlign.top,
        color: const Color(0xFF111827),
      );
      final map = Rect.fromLTWH(
        cell.left + 4 * pt,
        cell.top + 18 * pt,
        cell.width - 46 * pt,
        cell.height - 24 * pt,
      );
      paintTopomap(
        c,
        map,
        interp,
        vals,
        vmin: lo,
        vmax: hi,
        outlineWidth: 0.9 * pt,
      );
      final cb = Rect.fromLTWH(
        map.right + 4 * pt,
        map.top + map.height * 0.15,
        5 * pt,
        map.height * 0.7,
      );
      paintColorbar(c, cb);
      drawMplText(
        c,
        _fmt(hi),
        Offset(cb.right + 2 * pt, cb.top),
        6 * pt,
        va: VAlign.centerBaseline,
        color: const Color(0xFF4B5563),
      );
      drawMplText(
        c,
        _fmt(lo),
        Offset(cb.right + 2 * pt, cb.bottom),
        6 * pt,
        va: VAlign.centerBaseline,
        color: const Color(0xFF4B5563),
      );
    }
  });
}

/// Small multiples: mean across channels over time with IQR band.
Future<Uint8List?> _timeImage(List<_FeatureSummary> feats, double wIn) async {
  if (feats.isEmpty) return null;
  const cols = 2;
  final rows = (feats.length / cols).ceil();
  final cellW = wIn / cols;
  const cellH = 1.6;
  return _render(wIn, rows * cellH, 200, (c, ppi) {
    final pt = ppi / 72;
    for (var k = 0; k < feats.length; k++) {
      final f = feats[k];
      final r = k ~/ cols, col = k % cols;
      final cell = Rect.fromLTWH(
        col * cellW * ppi,
        r * cellH * ppi,
        cellW * ppi,
        cellH * ppi,
      );
      final ax = Rect.fromLTRB(
        cell.left + 34 * pt,
        cell.top + 16 * pt,
        cell.right - 8 * pt,
        cell.bottom - 20 * pt,
      );
      drawMplText(
        c,
        _prettyFeature(f.name),
        Offset(ax.left, cell.top + 3 * pt),
        8 * pt,
        va: VAlign.top,
        color: const Color(0xFF111827),
      );
      final n = f.tMin.length;
      if (n < 2) continue;
      var lo = double.infinity, hi = -double.infinity;
      for (var i = 0; i < n; i++) {
        for (final v in [f.timeQ1[i], f.timeQ3[i], f.timeMean[i]]) {
          if (v.isFinite) {
            lo = math.min(lo, v);
            hi = math.max(hi, v);
          }
        }
      }
      if (!lo.isFinite) continue;
      if (hi == lo) {
        hi += 1;
        lo -= 1;
      }
      final pad = (hi - lo) * 0.06;
      lo -= pad;
      hi += pad;
      final t0 = f.tMin.first, t1 = f.tMin.last;
      double x(double t) =>
          ax.left + (t - t0) / math.max(t1 - t0, 1e-9) * ax.width;
      double y(double v) => ax.bottom - (v - lo) / (hi - lo) * ax.height;
      c.drawRect(ax, Paint()..color = const Color(0xFFF9FAFB));
      final band = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        if (!f.timeQ3[i].isFinite) continue;
        final p = Offset(x(f.tMin[i]), y(f.timeQ3[i]));
        if (started) {
          band.lineTo(p.dx, p.dy);
        } else {
          band.moveTo(p.dx, p.dy);
        }
        started = true;
      }
      for (var i = n - 1; i >= 0; i--) {
        if (!f.timeQ1[i].isFinite) continue;
        band.lineTo(x(f.tMin[i]), y(f.timeQ1[i]));
      }
      band.close();
      c.drawPath(band, Paint()..color = const Color(0x3360A5FA));
      final line = Path();
      started = false;
      for (var i = 0; i < n; i++) {
        final v = f.timeMean[i];
        if (!v.isFinite) {
          started = false;
          continue;
        }
        final p = Offset(x(f.tMin[i]), y(v));
        if (started) {
          line.lineTo(p.dx, p.dy);
        } else {
          line.moveTo(p.dx, p.dy);
        }
        started = true;
      }
      c.drawPath(
        line,
        Paint()
          ..color = const Color(0xFF1D4ED8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0 * pt,
      );
      c.drawRect(
        ax,
        Paint()
          ..color = const Color(0xFF9CA3AF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5 * pt,
      );
      for (final v in [hi - pad, lo + pad]) {
        drawMplText(
          c,
          _fmt(v),
          Offset(ax.left - 3 * pt, y(v)),
          6 * pt,
          ha: HAlign.right,
          va: VAlign.center,
          color: const Color(0xFF4B5563),
        );
      }
      drawMplText(
        c,
        t0.toStringAsFixed(0),
        Offset(ax.left, ax.bottom + 2 * pt),
        6 * pt,
        va: VAlign.top,
        color: const Color(0xFF4B5563),
      );
      drawMplText(
        c,
        '${t1.toStringAsFixed(0)} min',
        Offset(ax.right, ax.bottom + 2 * pt),
        6 * pt,
        ha: HAlign.right,
        va: VAlign.top,
        color: const Color(0xFF4B5563),
      );
    }
  });
}

// ── PDF assembly ─────────────────────────────────────────────────────────

Future<pw.ThemeData> _theme() async {
  try {
    final data = await rootBundle.load('assets/fonts/DejaVuSans.ttf');
    final f = pw.Font.ttf(data);
    return pw.ThemeData.withFont(base: f, bold: f);
  } catch (_) {
    return pw.ThemeData.base();
  }
}

pw.Widget _h1(String t) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 6),
  child: pw.Text(
    t,
    style: pw.TextStyle(
      fontSize: 15,
      color: _ink,
      fontWeight: pw.FontWeight.bold,
    ),
  ),
);

pw.Widget _note(String t) =>
    pw.Text(t, style: const pw.TextStyle(fontSize: 8.5, color: _muted));

pw.Widget _kv(List<(String, String)> rows) => pw.Table(
  columnWidths: const {0: pw.FixedColumnWidth(150), 1: pw.FlexColumnWidth()},
  children: [
    for (var i = 0; i < rows.length; i++)
      pw.TableRow(
        decoration: pw.BoxDecoration(
          color: i.isEven ? _zebra : PdfColors.white,
        ),
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 3.5,
            ),
            child: pw.Text(
              rows[i].$1,
              style: const pw.TextStyle(fontSize: 9, color: _muted),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 6,
              vertical: 3.5,
            ),
            child: pw.Text(
              rows[i].$2,
              style: const pw.TextStyle(fontSize: 9, color: _ink),
            ),
          ),
        ],
      ),
  ],
);

/// Writes the report for one recording's feature CSV.
Future<void> writeFeatureReport({
  required String outputPath,
  required String csvPath,
  required EegRecording recording,
  EegRecording? raw,
  PreprocessingOptions? prep,
  ExtractionOptions? options,
  double epochSeconds = 2.0,
  List<String> excludedChannels = const [],
}) async {
  // The engine respects saved epoch boundaries even when the extraction UI
  // requests a different duration. Report the duration actually used.
  if (recording.isEpoched) epochSeconds = recording.epochDurationSeconds;
  if (raw != null &&
      (recording.epochTmin != null ||
          (raw.durationSeconds - recording.durationSeconds).abs() > 2))
    raw = null;
  final channels = detectChannels(csvPath);
  final allCols = numericFeatureColumns(
    csvPath,
  ).where((h) => !kTopoMetaColumns.contains(h)).toList();
  final parsed = parseFeatureCsv(csvPath, allCols, channels);
  final nCh = channels.length;
  final summaries = <String, _FeatureSummary>{};
  var nEpochs = 0;
  for (final f in allCols) {
    final ep = parsed.epochs[f];
    final m = parsed.values[f];
    if (ep == null || m == null || ep.isEmpty) continue;
    nEpochs = math.max(nEpochs, ep.length);
    summaries[f] = _summarise(f, ep, m, nCh, epochSeconds, 25);
  }
  final byFamily = <String, List<_FeatureSummary>>{};
  for (final s in summaries.values) {
    byFamily.putIfAbsent(featureFamily(s.name), () => []).add(s);
  }

  // Features shown as maps / time courses: the script's reference list
  // (band power, aperiodic, nonlinear, ACW) in its order, else first 16.
  var key = [
    for (final f in kReferenceFeatureList)
      if (summaries.containsKey(f)) summaries[f]!,
  ];
  if (key.isEmpty) key = summaries.values.take(16).toList();
  key = key.where((s) => featureFamily(s.name) != 'conn').toList();

  const pageW = 595.28 - 72; // A4 minus margins (pt)
  final topos = <Uint8List>[];
  for (var i = 0; i < key.length; i += 9) {
    final img = await _topoImage(
      key.sublist(i, math.min(i + 9, key.length)),
      channels,
      pageW / 72,
    );
    if (img != null) topos.add(img);
  }
  final times = <Uint8List>[];
  for (var i = 0; i < key.length; i += 8) {
    final img = await _timeImage(
      key.sublist(i, math.min(i + 8, key.length)),
      pageW / 72,
    );
    if (img != null) times.add(img);
  }
  final signalPages = <(Uint8List?, Uint8List?, List<String>)>[];
  const signalWidth = (842 - 84) / 72;
  final compare = raw != null;
  final snapshotStart = math.max(
    0.0,
    math.min(30.0, recording.durationSeconds - 10),
  );
  for (var i = 0; i < channels.length; i += 7) {
    final group = channels.sublist(i, math.min(i + 7, channels.length));
    final span = signalComparisonSpan(raw ?? recording, group, snapshotStart);
    final cleanImage = await _signalImage(
      recording,
      null,
      group,
      compare ? signalWidth / 2 : signalWidth,
      (595.28 - 140) / 72,
      sharedSpan: span,
      startSeconds: snapshotStart,
    );
    final rawImage = raw == null
        ? null
        : await _signalImage(
            raw,
            null,
            group,
            signalWidth / 2,
            (595.28 - 140) / 72,
            sharedSpan: span,
            startSeconds: snapshotStart,
          );
    signalPages.add((rawImage, cleanImage, group));
  }

  final theme = await _theme();
  final doc = pw.Document(
    title: 'CCS EEG feature report',
    creator: 'CCS EEG Studio',
    theme: theme,
  );
  final name = _base(recording.path);
  final stamp = DateTime.now().toLocal().toString().substring(0, 16);

  pw.Widget header(pw.Context ctx) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 10),
    padding: const pw.EdgeInsets.only(bottom: 4),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _accent, width: 1.2)),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'CCS EEG Studio · Feature report',
          style: pw.TextStyle(
            fontSize: 9,
            color: _accent,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.Text(name, style: const pw.TextStyle(fontSize: 8, color: _muted)),
      ],
    ),
  );
  pw.Widget footer(pw.Context ctx) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      pw.Text(
        'Generated $stamp',
        style: const pw.TextStyle(fontSize: 7.5, color: _muted),
      ),
      pw.Text(
        'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 7.5, color: _muted),
      ),
    ],
  );

  final eegCh = nCh;
  final dur = recording.sampleRate > 0
      ? recording.sampleCount / recording.sampleRate
      : 0.0;
  final p = prep;
  final pipeline = <(String, bool, String)>[
    if (p != null) ...[
      (
        'Band-pass filter',
        p.filter,
        p.filter ? '${p.lowHz}–${p.highHz} Hz' : '',
      ),
      (
        'Notch filter',
        p.filter && p.notchHz > 0,
        p.filter && p.notchHz > 0 ? '${p.notchHz} Hz' : '',
      ),
      (
        'Downsample',
        p.downsample,
        p.downsample ? '${p.downsampleFreq.toStringAsFixed(0)} Hz' : '',
      ),
      ('Bad-channel detection', p.badchannel, ''),
      (
        'GEDAI denoising',
        p.gedai,
        p.gedai
            ? 'threshold ${p.gedaiThreshold}, ${p.gedaiEpochSeconds} s epochs'
            : '',
      ),
      (
        'Bad-channel interpolation',
        p.interpolate,
        p.interpolate ? 'spherical spline' : '',
      ),
      (
        'Source localisation',
        p.sourceLocalization,
        p.sourceLocalization ? 'eLORETA' : '',
      ),
    ],
    ('Feature extraction reference', options?.removeNonEeg ?? true, 'common average, EEG channels only'),
  ];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: 36,
        marginRight: 36,
        marginTop: 30,
        marginBottom: 30,
      ),
      header: header,
      footer: footer,
      build: (ctx) => [
        pw.Text(
          name.replaceAll(
            RegExp(r'\.(ccseeg\.json|set|edf|vhdr|fif|mat)$'),
            '',
          ),
          style: pw.TextStyle(
            fontSize: 18,
            color: _ink,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 2),
        _note('Feature CSV: ${_base(csvPath)}'),
        pw.SizedBox(height: 12),
        pw.Row(
          children: [
            for (final (k, v) in [
              ('EEG channels', '$eegCh'),
              ('Epochs', '$nEpochs × ${pyFloat(epochSeconds)} s'),
              ('Duration', '${(dur / 60).toStringAsFixed(1)} min'),
              ('Sample rate', '${recording.sampleRate.toStringAsFixed(0)} Hz'),
            ])
              pw.Expanded(
                child: pw.Container(
                  margin: const pw.EdgeInsets.only(right: 8),
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    color: _zebra,
                    border: pw.Border.all(color: _faint),
                    borderRadius: pw.BorderRadius.circular(4),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        k.toUpperCase(),
                        style: const pw.TextStyle(fontSize: 7, color: _muted),
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(
                        v,
                        style: pw.TextStyle(
                          fontSize: 14,
                          color: _ink,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        pw.SizedBox(height: 16),
        _h1('Preprocessing'),
        pw.Table(
          columnWidths: const {
            0: pw.FixedColumnWidth(170),
            1: pw.FixedColumnWidth(60),
            2: pw.FlexColumnWidth(),
          },
          children: [
            for (var i = 0; i < pipeline.length; i++)
              pw.TableRow(
                decoration: pw.BoxDecoration(
                  color: i.isEven ? _zebra : PdfColors.white,
                ),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3.5,
                    ),
                    child: pw.Text(
                      pipeline[i].$1,
                      style: const pw.TextStyle(fontSize: 9, color: _ink),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3.5,
                    ),
                    child: pw.Text(
                      pipeline[i].$2 ? 'yes' : 'no',
                      style: pw.TextStyle(
                        fontSize: 9,
                        color: pipeline[i].$2 ? _ok : _muted,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3.5,
                    ),
                    child: pw.Text(
                      pipeline[i].$3,
                      style: const pw.TextStyle(fontSize: 9, color: _muted),
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (excludedChannels.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          _note('Excluded non-EEG channels: ${excludedChannels.join(', ')}'),
        ],
        pw.SizedBox(height: 16),
        _h1('Features in this file'),
        _kv([
          for (final fam in _familyTitles.keys)
            if (byFamily[fam] != null)
              (
                _familyTitles[fam]!,
                '${byFamily[fam]!.length} features - detailed statistics follow',
              ),
        ]),
        pw.SizedBox(height: 16),
        _h1('Channels'),
        _note(channels.join('  ')),
      ],
    ),
  );

  for (final (rawImage, cleanImage, group) in signalPages) {
    if (cleanImage == null) continue;
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.landscape.copyWith(
          marginLeft: 36,
          marginRight: 36,
          marginTop: 30,
          marginBottom: 30,
        ),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            header(ctx),
            _h1(
              rawImage == null
                  ? 'Signal snapshot'
                  : 'Raw and cleaned signal comparison',
            ),
            _note(
              '${snapshotStart.toStringAsFixed(0)}-${(snapshotStart + 10).toStringAsFixed(0)} s '
              '| ${group.join(', ')} | Shared amplitude scale; traces are centred and clipped within each row.',
            ),
            if (rawImage != null)
              _note(
                'Raw input includes artifacts and may use a different reference. '
                'This is a visual comparison of the full pipeline, not GEDAI alone.',
              ),
            pw.SizedBox(height: 8),
            pw.Row(
              children: [
                if (rawImage != null) ...[
                  pw.Expanded(
                    child: pw.Text(
                      'RAW INPUT',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: _muted,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 12),
                ],
                pw.Expanded(
                  child: pw.Text(
                    'CLEANED OUTPUT',
                    style: pw.TextStyle(
                      fontSize: 10,
                      color: _accent,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            pw.Expanded(
              child: pw.Row(
                children: [
                  if (rawImage != null) ...[
                    pw.Expanded(
                      child: pw.Image(
                        pw.MemoryImage(rawImage),
                        fit: pw.BoxFit.contain,
                      ),
                    ),
                    pw.SizedBox(width: 12),
                  ],
                  pw.Expanded(
                    child: pw.Image(
                      pw.MemoryImage(cleanImage),
                      fit: pw.BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
            footer(ctx),
          ],
        ),
      ),
    );
  }

  final a4 = PdfPageFormat.a4.copyWith(
    marginLeft: 36,
    marginRight: 36,
    marginTop: 30,
    marginBottom: 30,
  );
  for (var i = 0; i < topos.length; i++) {
    doc.addPage(
      pw.MultiPage(
        pageFormat: a4,
        header: header,
        footer: footer,
        build: (ctx) => [
          _h1(i == 0 ? 'Scalp topography' : 'Scalp topography (continued)'),
          _note(
            'Mean over all epochs per channel. Each map has its own colour scale (viridis, min to max).',
          ),
          pw.SizedBox(height: 8),
          pw.Image(pw.MemoryImage(topos[i]), width: pageW),
        ],
      ),
    );
  }
  for (var i = 0; i < times.length; i++) {
    doc.addPage(
      pw.MultiPage(
        pageFormat: a4,
        header: header,
        footer: footer,
        build: (ctx) => [
          _h1(i == 0 ? 'Time course' : 'Time course (continued)'),
          _note(
            'Mean across channels per epoch, smoothed over 25 epochs; shaded band = channel inter-quartile range.',
          ),
          pw.SizedBox(height: 8),
          pw.Image(pw.MemoryImage(times[i]), width: pageW),
        ],
      ),
    );
  }

  // Statistics tables
  doc.addPage(
    pw.MultiPage(
      pageFormat: a4,
      header: header,
      footer: footer,
      build: (ctx) => [
        _h1('Feature statistics'),
        _note(
          'Across all epochs and channels. p5 / p95 = 5th / 95th percentile.',
        ),
        for (final fam in _familyTitles.keys)
          if (byFamily[fam] != null) ...[
            pw.SizedBox(height: 10),
            pw.Text(
              _familyTitles[fam]!,
              style: pw.TextStyle(
                fontSize: 10.5,
                color: _accent,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 3),
            pw.TableHelper.fromTextArray(
              headers: [
                'Feature',
                'Mean',
                'SD',
                'Median',
                'p5',
                'p95',
                'Missing',
              ],
              data: [
                for (final s in byFamily[fam]!)
                  [
                    s.name,
                    _fmt(s.mean),
                    _fmt(s.sd),
                    _fmt(s.median),
                    _fmt(s.p5),
                    _fmt(s.p95),
                    '${s.missingPct.toStringAsFixed(1)}%',
                  ],
              ],
              headerStyle: pw.TextStyle(
                fontSize: 8.5,
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
              ),
              headerDecoration: const pw.BoxDecoration(color: _accent),
              cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
              oddRowDecoration: const pw.BoxDecoration(color: _zebra),
              cellAlignments: {
                0: pw.Alignment.centerLeft,
                for (var i = 1; i < 7; i++) i: pw.Alignment.centerRight,
              },
              columnWidths: {0: const pw.FlexColumnWidth(2.4)},
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 3,
              ),
              border: null,
            ),
          ],
      ],
    ),
  );

  await File(outputPath).writeAsBytes(await doc.save());
}

String _base(String p) => p.split(RegExp(r'[\\/]')).last;
