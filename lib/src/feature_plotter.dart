// lib/src/feature_plotter.dart
//
// Pure-Dart EEG feature plot generator.
//
// Produces per-feature PNG figures combining:
//   • Top panel  — temporal line plots per recording segment (smoothed, with
//                  shaded ±SEM band), with sub-panels width-proportional to
//                  recording duration.
//   • Bottom row — N topoplot headmaps at equally-spaced time windows, each
//                  showing the spatial distribution of the feature averaged
//                  over a time window across all recordings that overlap it.
//
// Rendering is entirely via dart:ui (Canvas / PictureRecorder) — no Python,
// no external packages required.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

// ── Public API ─────────────────────────────────────────────────────────────

class PlotOptions {
  const PlotOptions({
    this.nTopoWindows = 10,
    this.smoothingWindow = 25,
    this.epochSizeSeconds = 2.0,
    this.features = const [],
    this.montagePath,
  });

  /// Number of equally-spaced topoplot time windows.
  final int nTopoWindows;

  /// Rolling-mean window (in epochs) for line-plot smoothing.
  final int smoothingWindow;

  /// Duration of one epoch in seconds (used to convert epoch index → minutes).
  final double epochSizeSeconds;

  /// Feature column names to plot. Empty → plot all discovered features.
  final List<String> features;

  /// Optional path to a custom montage file (.loc / .ced / .xyz / .csv).
  /// When null, standard 10-10 positions are used with graceful fallback.
  final String? montagePath;
}

/// Generates one PNG per feature, saved into [outputDir].
/// Returns a list of saved file paths.
Future<List<String>> generateFeaturePlots({
  required List<String> csvPaths,
  required String outputDir,
  required PlotOptions options,
  void Function(double progress, String message)? onProgress,
}) async {
  final saved = <String>[];

  // 1. Parse all CSV files.
  onProgress?.call(0.0, 'Reading CSV files…');
  final datasets = <_Dataset>[];
  for (final p in csvPaths) {
    try {
      datasets.add(_CsvReader.read(p, options.epochSizeSeconds));
    } catch (e) {
      onProgress?.call(0.0, '⚠ Skipped $p: $e');
    }
  }
  if (datasets.isEmpty) {
    onProgress?.call(1.0, '✗ No valid CSV files.');
    return saved;
  }

  // 2. Determine feature list.
  final Set<String> allFeatures = {};
  for (final ds in datasets) {
    allFeatures.addAll(ds.features.keys);
  }
  final featureList = options.features.isNotEmpty
      ? options.features.where(allFeatures.contains).toList()
      : allFeatures.toList()
    ..sort();

  // 3. Load montage.
  final montage = Montage.build(options.montagePath);

  // 4. Render one plot per feature.
  final dir = Directory(outputDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  for (var fi = 0; fi < featureList.length; fi++) {
    final feature = featureList[fi];
    onProgress?.call(fi / featureList.length, 'Plotting $feature…');

    try {
      final bytes = await _renderFeaturePlot(
        feature: feature,
        datasets: datasets,
        montage: montage,
        options: options,
      );
      final outPath = '$outputDir/${_safeFilename(feature)}.png';
      await File(outPath).writeAsBytes(bytes);
      saved.add(outPath);
    } catch (e) {
      onProgress?.call(fi / featureList.length, '⚠ Error plotting $feature: $e');
    }
  }

  onProgress?.call(1.0, '✓ Done — ${saved.length} plots saved.');
  return saved;
}

// ── Internal data model ────────────────────────────────────────────────────

class _Dataset {
  _Dataset({
    required this.name,
    required this.features,
    required this.maxTimeMin,
  });

  /// Display name (filename without extension).
  final String name;

  /// Map: feature column → Map<channel, List<(timeMin, value)>>
  final Map<String, Map<String, List<_Sample>>> features;

  final double maxTimeMin;
}

class _Sample {
  const _Sample(this.timeMin, this.value);
  final double timeMin;
  final double value;
}

// ── CSV Reader ─────────────────────────────────────────────────────────────

class _CsvReader {
  static _Dataset read(String path, double epochSizeSeconds) {
    final lines = File(path).readAsLinesSync();
    if (lines.length < 2) throw const FormatException('Empty CSV');

    // Parse header.
    final headers = _splitCsv(lines[0]);
    final chanIdx = headers.indexOf('Chan');
    final epochIdx = headers.indexOf('Epoch');
    if (chanIdx < 0 || epochIdx < 0) {
      throw const FormatException('CSV missing Chan or Epoch columns');
    }

    // Build feature index (everything that's not Chan/Epoch/Segment/Time).
    final skipCols = {'Chan', 'Epoch', 'Segment', 'Time', 'File', 'Recording'};
    final featureCols = <String, int>{};
    for (var i = 0; i < headers.length; i++) {
      if (!skipCols.contains(headers[i])) {
        featureCols[headers[i]] = i;
      }
    }

    // Map: feature → chan → samples.
    final Map<String, Map<String, List<_Sample>>> data = {};
    for (final f in featureCols.keys) {
      data[f] = {};
    }

    double maxTime = 0.0;
    final conversionFactor = epochSizeSeconds / 60.0; // epochs → minutes

    for (var li = 1; li < lines.length; li++) {
      final row = _splitCsv(lines[li]);
      if (row.length <= chanIdx || row.length <= epochIdx) continue;

      final chan = row[chanIdx].trim();
      final epochRaw = double.tryParse(row[epochIdx]);
      if (epochRaw == null) continue;
      final timeMin = epochRaw * conversionFactor;
      if (timeMin > maxTime) maxTime = timeMin;

      for (final entry in featureCols.entries) {
        final col = entry.key;
        final idx = entry.value;
        if (idx >= row.length) continue;
        final val = double.tryParse(row[idx]);
        if (val == null || val.isNaN || val.isInfinite) continue;
        data[col]!.putIfAbsent(chan, () => []).add(_Sample(timeMin, val));
      }
    }

    // Derive dataset display name.
    final name = File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.features\.csv$'), '');

    return _Dataset(name: name, features: data, maxTimeMin: maxTime);
  }

  static List<String> _splitCsv(String line) {
    // Simple CSV split respecting quoted fields.
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuote = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuote = !inQuote;
      } else if (c == ',' && !inQuote) {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    result.add(buf.toString());
    return result;
  }
}

// ── Montage ────────────────────────────────────────────────────────────────
//
// Electrode positions are stored as normalised (x, y) offsets in a unit circle
// where (0.5, 0.5) is the centre (Cz). x increases rightward, y increases
// downward (screen coords).  These are projected onto the head circle in the
// TopoRenderer.

class Montage {
  Montage._(this._positions);

  final Map<String, ui.Offset> _positions;

  ui.Offset? operator [](String label) => _positions[label];

  Iterable<String> get channels => _positions.keys;

  /// Build a montage: tries to load [montagePath] first, then falls back to
  /// the built-in standard 10-10 table.
  static Montage build(String? montagePath) {
    final positions = <String, ui.Offset>{};

    // Start with the built-in table.
    positions.addAll(_standard1010);

    // Overlay any custom file.
    if (montagePath != null) {
      try {
        final custom = _loadMontageFile(montagePath);
        positions.addAll(custom);
      } catch (_) {
        // Custom file failed — silently fall back to built-in.
      }
    }

    return Montage._(positions);
  }

  static Map<String, ui.Offset> _loadMontageFile(String path) {
    final ext = path.toLowerCase().split('.').last;
    final lines = File(path).readAsLinesSync();
    final result = <String, ui.Offset>{};

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('%')) continue;

      List<String> parts;
      if (ext == 'csv') {
        parts = line.split(',');
      } else {
        // .loc / .ced / .xyz — whitespace delimited
        parts = line.split(RegExp(r'\s+'));
      }
      if (parts.length < 3) continue;

      String label = '';
      double? theta, phi; // spherical, degrees

      if (ext == 'loc' || ext == 'ced') {
        // Format: index theta phi label
        if (parts.length >= 4) {
          theta = double.tryParse(parts[1]);
          phi = double.tryParse(parts[2]);
          label = parts[3];
        }
      } else if (ext == 'xyz') {
        // Format: label x y z  (Cartesian)
        label = parts[0];
        final x = double.tryParse(parts[1]);
        final y = double.tryParse(parts[2]);
        // Ignore z — project to 2-D
        if (x != null && y != null) {
          // Normalise to [0..1] assuming head radius ~1
          result[label] = ui.Offset(x * 0.5 + 0.5, -y * 0.5 + 0.5);
        }
        continue;
      } else {
        // CSV: label, x_norm, y_norm  (already in [0..1])
        label = parts[0];
        final x = double.tryParse(parts[1]);
        final y = double.tryParse(parts[2]);
        if (x != null && y != null) {
          result[label] = ui.Offset(x, y);
        }
        continue;
      }

      if (theta == null || phi == null || label.isEmpty) continue;
      // Convert spherical → 2-D using standard EEG projection.
      final r = math.sin(phi * math.pi / 180.0);
      final nx = r * math.cos(theta * math.pi / 180.0);
      final ny = r * math.sin(theta * math.pi / 180.0);
      result[label] = ui.Offset(nx * 0.5 + 0.5, -ny * 0.5 + 0.5);
    }

    return result;
  }

  // Standard 10-10 positions (x, y) normalised to [0..1] within head circle.
  // Origin (0.5, 0.5) = centre = Cz. x = right, y = up.
  static const Map<String, ui.Offset> _standard1010 = {
    // Midline
    'Fpz': ui.Offset(0.500, 0.115),
    'Fz':  ui.Offset(0.500, 0.270),
    'FCz': ui.Offset(0.500, 0.370),
    'Cz':  ui.Offset(0.500, 0.500),
    'CPz': ui.Offset(0.500, 0.630),
    'Pz':  ui.Offset(0.500, 0.730),
    'POz': ui.Offset(0.500, 0.830),
    'Oz':  ui.Offset(0.500, 0.885),

    // Fp row
    'Fp1': ui.Offset(0.385, 0.125),
    'Fp2': ui.Offset(0.615, 0.125),

    // AF row
    'AF7': ui.Offset(0.270, 0.175),
    'AF3': ui.Offset(0.390, 0.195),
    'AF4': ui.Offset(0.610, 0.195),
    'AF8': ui.Offset(0.730, 0.175),

    // F row
    'F7':  ui.Offset(0.175, 0.260),
    'F5':  ui.Offset(0.275, 0.258),
    'F3':  ui.Offset(0.378, 0.255),
    'F1':  ui.Offset(0.440, 0.255),
    'F2':  ui.Offset(0.560, 0.255),
    'F4':  ui.Offset(0.622, 0.255),
    'F6':  ui.Offset(0.725, 0.258),
    'F8':  ui.Offset(0.825, 0.260),

    // FT / FC row
    'FT7': ui.Offset(0.140, 0.355),
    'FT8': ui.Offset(0.860, 0.355),
    'FC5': ui.Offset(0.240, 0.355),
    'FC3': ui.Offset(0.360, 0.360),
    'FC1': ui.Offset(0.440, 0.365),
    'FC2': ui.Offset(0.560, 0.365),
    'FC4': ui.Offset(0.640, 0.360),
    'FC6': ui.Offset(0.760, 0.355),

    // T / C row
    'T7':  ui.Offset(0.105, 0.500),
    'T8':  ui.Offset(0.895, 0.500),
    'C5':  ui.Offset(0.205, 0.500),
    'C3':  ui.Offset(0.320, 0.500),
    'C1':  ui.Offset(0.430, 0.500),
    'C2':  ui.Offset(0.570, 0.500),
    'C4':  ui.Offset(0.680, 0.500),
    'C6':  ui.Offset(0.795, 0.500),

    // Inferior Temporal
    'FT9': ui.Offset(0.050, 0.355),
    'FT10': ui.Offset(0.950, 0.355),
    'TP9': ui.Offset(0.050, 0.645),
    'TP10': ui.Offset(0.950, 0.645),
    // CP row
    'CP5': ui.Offset(0.235, 0.640),
    'CP3': ui.Offset(0.355, 0.638),
    'CP1': ui.Offset(0.440, 0.636),
    'CP2': ui.Offset(0.560, 0.636),
    'CP4': ui.Offset(0.645, 0.638),
    'CP6': ui.Offset(0.765, 0.640),
    'TP7': ui.Offset(0.132, 0.632),
    'TP8': ui.Offset(0.868, 0.632),

    // P row
    'P7':  ui.Offset(0.170, 0.740),
    'P5':  ui.Offset(0.268, 0.745),
    'P3':  ui.Offset(0.373, 0.745),
    'P1':  ui.Offset(0.445, 0.745),
    'P2':  ui.Offset(0.555, 0.745),
    'P4':  ui.Offset(0.627, 0.745),
    'P6':  ui.Offset(0.732, 0.745),
    'P8':  ui.Offset(0.830, 0.740),

    // PO row
    'PO7': ui.Offset(0.225, 0.835),
    'PO3': ui.Offset(0.370, 0.838),
    'PO4': ui.Offset(0.630, 0.838),
    'PO8': ui.Offset(0.775, 0.835),

    // O row
    'O1':  ui.Offset(0.365, 0.880),
    'O2':  ui.Offset(0.635, 0.880),

    // Iz
    'Iz':  ui.Offset(0.500, 0.955),

    // Common aliases
    'T3':  ui.Offset(0.105, 0.500),
    'T4':  ui.Offset(0.895, 0.500),
    'T5':  ui.Offset(0.170, 0.740),
    'T6':  ui.Offset(0.830, 0.740),
    'A1':  ui.Offset(0.060, 0.530),
    'A2':  ui.Offset(0.940, 0.530),
    'Nasion': ui.Offset(0.500, 0.050),
    'Inion':  ui.Offset(0.500, 0.970),
  };
}

// ── Rolling mean smoothing ──────────────────────────────────────────────────

List<double> _rollMean(List<double> y, int window) {
  if (y.isEmpty || window <= 1) return List.from(y);
  final half = window ~/ 2;
  final result = <double>[];
  for (var i = 0; i < y.length; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(y.length - 1, i + half);
    double sum = 0;
    for (var j = lo; j <= hi; j++) {
      sum += y[j];
    }
    result.add(sum / (hi - lo + 1));
  }
  return result;
}

// ── Colour palette (Jet-like) ──────────────────────────────────────────────

ui.Color _jetColor(double t) {
  t = t.clamp(0.0, 1.0);
  double r = (1.5 - (abs(t - 0.75)) * 4).clamp(0.0, 1.0);
  double g = (1.5 - (abs(t - 0.50)) * 4).clamp(0.0, 1.0);
  double b = (1.5 - (abs(t - 0.25)) * 4).clamp(0.0, 1.0);
  return ui.Color.fromARGB(255, (r * 255).toInt(), (g * 255).toInt(), (b * 255).toInt());
}

double abs(double x) => x < 0 ? -x : x;

// ── Topoplot renderer ───────────────────────────────────────────────────────

void _renderTopo({
  required ui.Canvas canvas,
  required ui.Rect rect,
  required Map<String, double> chanValues,
  required Montage montage,
  required double globalMin,
  required double globalMax,
  required Map<String, ui.Offset> unknownPositions,
  String? timeLabel,
}) {
  final double r = rect.width / 2.2;
  final double cx = rect.left + rect.width / 2;
  final double cy = rect.top + rect.height / 2.2; // Shift up slightly

  final safeRange = (globalMax - globalMin).abs();
  final range = safeRange < 1e-12 ? 1.0 : safeRange;

  // Draw background circle
  canvas.drawCircle(
    ui.Offset(cx, cy),
    r,
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );

  // Combine montage + unknown for this plot
  final Map<String, ui.Offset> allPos = {};
  for (final ch in montage.channels) {
    final pos = montage[ch];
    if (pos != null) allPos[ch] = pos;
  }
  unknownPositions.forEach((ch, pos) => allPos[ch] = pos);

  if (chanValues.isEmpty) {
    _drawHeadOutline(canvas, cx, cy, r);
    return;
  }

  // IDW Interpolation
  final int grid = 80;
  final double step = (2 * r) / grid;
  final double rSq = r * r;
  final paint = ui.Paint()..style = ui.PaintingStyle.fill;

  for (var iy = 0; iy < grid; iy++) {
    final double py = cy - r + iy * step + step / 2;
    for (var ix = 0; ix < grid; ix++) {
      final double px = cx - r + ix * step + step / 2;
      final double dx = px - cx;
      final double dy = py - cy;
      if (dx * dx + dy * dy > rSq) continue;

      // Gaussian kernel: smooth spatial interpolation, no font/IDW artifacts
      double wSum = 0.0;
      double vSum = 0.0;
      const double sigma2 = 0.04; // controls spatial blur (~0.2 * headRadius units)

      for (final entry in chanValues.entries) {
        final pos = allPos[entry.key];
        if (pos == null) continue;

        final double ex = cx - r + pos.dx * 2 * r;
        final double ey = cy - r + pos.dy * 2 * r;
        final double edx = px - ex;
        final double edy = py - ey;
        final double dSq = (edx * edx + edy * edy) / (r * r); // normalise

        final double w = math.exp(-dSq / sigma2);
        wSum += w;
        vSum += entry.value * w;
      }

      final interp = wSum > 1e-9 ? vSum / wSum : globalMin;
      final t = (interp - globalMin) / range;
      paint.color = _jetColor(t);

      canvas.drawRect(
          ui.Rect.fromLTWH(px - step / 2 - 0.5, py - step / 2 - 0.5, step + 1, step + 1),
          paint);
    }
  }

  _drawHeadOutline(canvas, cx, cy, r);

  final dotPaint = ui.Paint()
    ..color = const ui.Color(0xFFFFFFFF)
    ..style = ui.PaintingStyle.fill;
  final dotBorderPaint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;

  for (final entry in chanValues.entries) {
    final pos = allPos[entry.key];
    if (pos == null) continue;
    final double ex = cx - r + pos.dx * 2 * r;
    final double ey = cy - r + pos.dy * 2 * r;
    final dotOffset = ui.Offset(ex, ey);
    canvas.drawCircle(dotOffset, 2.5, dotPaint);
    canvas.drawCircle(dotOffset, 2.5, dotBorderPaint);
  }

  if (timeLabel != null) {
    _drawTopoLabel(canvas, rect, timeLabel);
  }
}

void _drawHeadOutline(ui.Canvas canvas, double cx, double cy, double r) {
  final linePaint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;

  canvas.drawCircle(ui.Offset(cx, cy), r, linePaint);

  final nosePath = ui.Path()
    ..moveTo(cx - r * 0.1, cy - r)
    ..lineTo(cx, cy - r * 1.15)
    ..lineTo(cx + r * 0.1, cy - r);
  canvas.drawPath(nosePath, linePaint);

  final earPaint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;
  canvas.drawArc(
    ui.Rect.fromCircle(center: ui.Offset(cx - r - 2, cy), radius: r * 0.15),
    math.pi / 2,
    math.pi,
    false,
    earPaint,
  );
  canvas.drawArc(
    ui.Rect.fromCircle(center: ui.Offset(cx + r + 2, cy), radius: r * 0.15),
    -math.pi / 2,
    math.pi,
    false,
    earPaint,
  );
}

void _drawTopoLabel(ui.Canvas canvas, ui.Rect rect, String label) {
  _drawText(canvas, label, ui.Offset(rect.left + rect.width / 2 - label.length * 4.5, rect.bottom - 16),
      color: const ui.Color(0xFF000000), scale: 0.9);
}

// ── Line plot renderer ──────────────────────────────────────────────────────

void _renderLinePlot({
  required ui.Canvas canvas,
  required ui.Rect rect,
  required List<double> xData,
  required List<double> yMean,
  required List<double> yStd,
  required double globalMin,
  required double globalMax,
  required double xMax,
  required String segName,
  bool drawYAxis = true,
}) {
  if (xData.isEmpty || yMean.isEmpty) return;
  final plotRect = rect;

  final yRange = (globalMax - globalMin).abs();
  final safeY = yRange < 1e-12 ? 1.0 : yRange;

  double toX(double t) => plotRect.left + (t / xMax) * plotRect.width;
  double toY(double v) =>
      plotRect.bottom - ((v - globalMin) / safeY) * plotRect.height;

  // Shaded error band
  if (xData.length > 1 && yStd.isNotEmpty) {
    final path = ui.Path();
    bool started = false;
    for (var i = 0; i < xData.length; i++) {
      final px = toX(xData[i]);
      final py = toY(yMean[i] + yStd[i]);
      if (!started) {
        path.moveTo(px, py);
        started = true;
      } else {
        path.lineTo(px, py);
      }
    }
    for (var i = xData.length - 1; i >= 0; i--) {
      final px = toX(xData[i]);
      final py = toY(yMean[i] - yStd[i]);
      path.lineTo(px, py);
    }
    path.close();

    final bandPaint = ui.Paint()..color = const ui.Color(0x331F77B4);
    canvas.drawPath(path, bandPaint);
  }

  // Line
  if (xData.length > 1) {
    final linePaint = ui.Paint()
      ..color = const ui.Color(0xFF1F77B4)
      ..strokeWidth = 2.0
      ..style = ui.PaintingStyle.stroke
      ..strokeJoin = ui.StrokeJoin.round;

    final path = ui.Path();
    bool started = false;
    for (var i = 0; i < xData.length; i++) {
      final px = toX(xData[i]);
      final py = toY(yMean[i]);
      if (!started) {
        path.moveTo(px, py);
        started = true;
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(path, linePaint);
  }

  // Bounding box
  final borderPaint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;
  canvas.drawRect(plotRect, borderPaint);

  // Ticks
  final tickPaint = ui.Paint()
    ..color = const ui.Color(0xFF000000)
    ..strokeWidth = 1.0;

  if (drawYAxis) {
    for (var i = 0; i <= 4; i++) {
      final val = globalMin + (yRange / 4) * (4 - i);
      final y = plotRect.top + (plotRect.height / 4) * i;
      canvas.drawLine(ui.Offset(plotRect.left, y), ui.Offset(plotRect.left - 6, y), tickPaint);
      _drawSmallText(
          canvas,
          val.toStringAsFixed(2),
          ui.Offset(plotRect.left - 110, y - 8),
          width: 100,
          fontSize: 14.0,
          align: ui.TextAlign.right);
    }
    
    // Draw rotated label
    canvas.save();
    canvas.translate(plotRect.left - 90, plotRect.top + plotRect.height / 2 + 100);
    canvas.rotate(-1.57079632679); // -pi/2
    _drawSmallText(canvas, 'Average PSD', const ui.Offset(0, 0), width: 200, fontSize: 16.0, align: ui.TextAlign.center);
    canvas.restore();
  } else {
    for (var i = 0; i <= 4; i++) {
      final y = plotRect.top + (plotRect.height / 4) * i;
      canvas.drawLine(ui.Offset(plotRect.left, y), ui.Offset(plotRect.left + 4, y), tickPaint);
    }
  }

  // X ticks
  for (var t = 0; t <= xMax; t += 5) {
    if (t == 0) continue;
    final tx = toX(t.toDouble());
    if (tx > plotRect.right) break;
    canvas.drawLine(ui.Offset(tx, plotRect.bottom), ui.Offset(tx, plotRect.bottom + 6), tickPaint);
    _drawSmallText(canvas, t.toString(), ui.Offset(tx - 40, plotRect.bottom + 10), width: 80, fontSize: 14.0, align: ui.TextAlign.center);
  }
  canvas.drawLine(ui.Offset(plotRect.left, plotRect.bottom), ui.Offset(plotRect.left, plotRect.bottom + 6), tickPaint);
  _drawSmallText(canvas, '0', ui.Offset(plotRect.left - 40, plotRect.bottom + 10), width: 80, fontSize: 14.0, align: ui.TextAlign.center);

  // Segment title
  _drawSmallText(canvas, segName, ui.Offset(plotRect.left, plotRect.top - 25), width: plotRect.width, align: ui.TextAlign.center, fontSize: 16.0, fontWeight: ui.FontWeight.w600);
}

void _drawSmallText(
  ui.Canvas canvas,
  String text,
  ui.Offset offset, {
  double width = 60,
  ui.Color color = const ui.Color(0xFF000000),
  double fontSize = 10.0,
  ui.FontWeight fontWeight = ui.FontWeight.normal,
  ui.TextAlign align = ui.TextAlign.left,
}) {
  // Estimate text pixel width for alignment
  final double charW = fontSize * 0.65;
  final double totalW = text.length * charW;
  double startX = offset.dx;
  if (align == ui.TextAlign.center) startX = offset.dx + (width - totalW) / 2;
  if (align == ui.TextAlign.right) startX = offset.dx + width - totalW;
  _drawText(canvas, text, ui.Offset(startX, offset.dy), color: color, scale: fontSize / 12.0);
}

// ── Path-based text renderer (no font dependency) ─────────────────────────
//
// Draws ASCII text using a minimal stroke-based glyph set. Each glyph is
// 5 wide × 7 tall in local units, scaled by [scale], stroked with [color].

void _drawText(ui.Canvas canvas, String text, ui.Offset origin,
    {ui.Color color = const ui.Color(0xFF000000), double scale = 1.0}) {
  final paint = ui.Paint()
    ..color = color
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = scale * 1.1
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round;

  double cx = origin.dx;
  final double cy = origin.dy;
  const double cw = 6.0; // char cell width
  const double ch = 8.0; // char cell height

  for (final char in text.runes) {
    final segs = _glyphSegments(char);
    final path = ui.Path();
    for (final seg in segs) {
      path.moveTo(cx + seg[0] * cw * scale, cy + seg[1] * ch * scale);
      path.lineTo(cx + seg[2] * cw * scale, cy + seg[3] * ch * scale);
    }
    canvas.drawPath(path, paint);
    cx += (cw + 1.5) * scale;
  }
}

/// Returns list of line segments [x0,y0,x1,y1] in normalised glyph coords
/// (0..1 width, 0..1 height) for a given ASCII char code.
List<List<double>> _glyphSegments(int c) {
  // Segments defined as fractions of cell: x in [0,1], y in [0,1]
  // Top=0, Middle=0.5, Bottom=1
  // Segments: top, topLeft, topRight, mid, botLeft, botRight, bot, dot
  const t = 0.0, m = 0.45, b = 0.9;
  const l = 0.0, r = 0.85;
  // Segment templates: [x1,y1,x2,y2]
  const topSeg    = [l, t, r, t];
  const tLSeg     = [l, t, l, m];
  const tRSeg     = [r, t, r, m];
  const midSeg    = [l, m, r, m];
  const bLSeg     = [l, m, l, b];
  const bRSeg     = [r, m, r, b];
  const botSeg    = [l, b, r, b];
  const dotSeg    = [r, b, r, b]; // single dot at bottom-right
  const dashSeg   = [0.15, m, 0.7, m];

  switch (c) {
    case 48: return [topSeg, tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // 0
    case 49: return [tRSeg, bRSeg]; // 1
    case 50: return [topSeg, tRSeg, midSeg, bLSeg, botSeg]; // 2
    case 51: return [topSeg, tRSeg, midSeg, bRSeg, botSeg]; // 3
    case 52: return [tLSeg, tRSeg, midSeg, bRSeg]; // 4
    case 53: return [topSeg, tLSeg, midSeg, bRSeg, botSeg]; // 5
    case 54: return [topSeg, tLSeg, midSeg, bLSeg, bRSeg, botSeg]; // 6
    case 55: return [topSeg, tRSeg, bRSeg]; // 7
    case 56: return [topSeg, tLSeg, tRSeg, midSeg, bLSeg, bRSeg, botSeg]; // 8
    case 57: return [topSeg, tLSeg, tRSeg, midSeg, bRSeg, botSeg]; // 9
    case 45: return [dashSeg]; // -
    case 46: return [dotSeg]; // .
    case 65: return [topSeg, tLSeg, tRSeg, midSeg, bLSeg, bRSeg]; // A
    case 66: return [topSeg, tLSeg, midSeg, bLSeg, bRSeg, botSeg, tRSeg]; // B (approx)
    case 67: return [topSeg, tLSeg, bLSeg, botSeg]; // C
    case 68: return [topSeg, tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // D same as O
    case 69: return [topSeg, tLSeg, midSeg, bLSeg, botSeg]; // E
    case 70: return [topSeg, tLSeg, midSeg, bLSeg]; // F
    case 71: return [topSeg, tLSeg, bLSeg, bRSeg, botSeg]; // G
    case 72: return [tLSeg, tRSeg, midSeg, bLSeg, bRSeg]; // H
    case 73: return [tRSeg, bRSeg]; // I
    case 74: return [tRSeg, bRSeg, botSeg, bLSeg]; // J
    case 75: return [tLSeg, bLSeg, midSeg, tRSeg, bRSeg]; // K (approx)
    case 76: return [tLSeg, bLSeg, botSeg]; // L
    case 77: return [tLSeg, tRSeg, bLSeg, bRSeg, topSeg]; // M (approx)
    case 78: return [tLSeg, tRSeg, bLSeg, bRSeg, topSeg]; // N (approx)
    case 79: return [topSeg, tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // O
    case 80: return [topSeg, tLSeg, tRSeg, midSeg]; // P
    case 81: return [topSeg, tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // Q
    case 82: return [topSeg, tLSeg, tRSeg, midSeg, bLSeg]; // R
    case 83: return [topSeg, tLSeg, midSeg, bRSeg, botSeg]; // S = 5
    case 84: return [topSeg, tRSeg, bRSeg]; // T approx
    case 85: return [tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // U
    case 86: return [tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // V approx
    case 87: return [tLSeg, tRSeg, bLSeg, bRSeg, botSeg]; // W approx
    case 88: return [tLSeg, tRSeg, midSeg, bLSeg, bRSeg]; // X
    case 89: return [tLSeg, tRSeg, midSeg, bRSeg]; // Y
    case 90: return [topSeg, tRSeg, midSeg, bLSeg, botSeg]; // Z
    case 95: return [botSeg]; // _
    case 32: return []; // space
    default: return [midSeg]; // unknown → dash
  }
}

// ── Main plot compositor ───────────────────────────────────────────────────

Future<Uint8List> _renderFeaturePlot({
  required String feature,
  required List<_Dataset> datasets,
  required Montage montage,
  required PlotOptions options,
}) async {
  final nSeg = datasets.length;
  final segData = datasets.map((d) => d.features[feature] ?? {}).toList();

  // Find global percentiles for topoplot colourmap
  final allValues = <double>[];
  for (var si = 0; si < nSeg; si++) {
    for (final samples in segData[si].values) {
      for (final s in samples) {
        allValues.add(s.value);
      }
    }
  }
  allValues.sort();
  double topoGMin = 0.0;
  double topoGMax = 1.0;
  if (allValues.isNotEmpty) {
    topoGMin = allValues[(allValues.length * 0.02).floor()]; // 2nd percentile
    topoGMax = allValues[(allValues.length * 0.98).floor()]; // 98th percentile
  }
  if (topoGMin == topoGMax) {
    topoGMin -= 0.001;
    topoGMax += 0.001;
  }

  // Pre-calculate line plot data and limits
  final List<List<double>> segXData = [];
  final List<List<double>> segYMean = [];
  final List<List<double>> segYStd = [];
  double lineGMin = double.infinity;
  double lineGMax = double.negativeInfinity;

  for (var si = 0; si < nSeg; si++) {
    final Map<double, List<double>> byTime = {};
    for (final samples in segData[si].values) {
      for (final s in samples) {
        byTime.putIfAbsent(s.timeMin, () => []).add(s.value);
      }
    }
    
    final sortedT = byTime.keys.toList()..sort();
    final xRaw = sortedT;
    final yMeanRaw = <double>[];
    final yStdRaw = <double>[];
    for (final t in sortedT) {
      final vals = byTime[t]!;
      final double mean = vals.reduce((a, b) => a + b) / vals.length;
      yMeanRaw.add(mean);
      if (vals.length > 1) {
        final double variance = vals.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) / vals.length;
        yStdRaw.add(math.sqrt(variance));
      } else {
        yStdRaw.add(0.0);
      }
    }
    final yMeanSmooth = _rollMean(yMeanRaw, options.smoothingWindow);
    final yStdSmooth = _rollMean(yStdRaw, options.smoothingWindow);
    
    segXData.add(xRaw);
    segYMean.add(yMeanSmooth);
    segYStd.add(yStdSmooth);

    for (int i = 0; i < xRaw.length; i++) {
      final valMax = yMeanSmooth[i] + yStdSmooth[i];
      final valMin = yMeanSmooth[i] - yStdSmooth[i];
      if (valMax > lineGMax) lineGMax = valMax;
      if (valMin < lineGMin) lineGMin = valMin;
    }
  }

  if (lineGMin == double.infinity) {
    lineGMin = 0.0;
    lineGMax = 1.0;
  }
  // Add 10% padding to line plot limits
  final yRange = (lineGMax - lineGMin) == 0 ? 1.0 : (lineGMax - lineGMin);
  lineGMax += yRange * 0.1;
  lineGMin -= yRange * 0.1;


  // ── Layout constants ──────────────────────────────────────────────────────
  const double titleH = 80.0;
  const double lineH = 300.0;
  const double gapW = 20.0;
  const double topoH = 140.0;
  const double topoW = 140.0;
  const double colorBarW = 20.0;
  const double leftPad = 120.0;
  const double rightPad = 100.0;

  // Distribute nTopoWindows across segments
  List<int> toposPerSeg = List.filled(nSeg, 0);
  int targetTotal = datasets.length > options.nTopoWindows ? datasets.length : options.nTopoWindows;
  double totalTime = datasets.fold(0.0, (s, ds) => s + ds.maxTimeMin);
  int remaining = targetTotal - nSeg;
  for (int i = 0; i < nSeg; i++) {
    toposPerSeg[i] = 1 + (totalTime > 0 ? (remaining * (datasets[i].maxTimeMin / totalTime)).round() : 0);
  }
  // Adjust to exact targetTotal
  int currentSum = toposPerSeg.fold(0, (a, b) => a + b);
  while (currentSum != targetTotal) {
    if (currentSum < targetTotal) {
      int maxIdx = 0;
      for (int i = 1; i < nSeg; i++) {
        if (datasets[i].maxTimeMin > datasets[maxIdx].maxTimeMin) maxIdx = i;
      }
      toposPerSeg[maxIdx]++;
      currentSum++;
    } else {
      int maxIdx = -1;
      for (int i = 0; i < nSeg; i++) {
        if (toposPerSeg[i] > 1) {
          if (maxIdx == -1 || datasets[i].maxTimeMin > datasets[maxIdx].maxTimeMin) {
            maxIdx = i;
          }
        }
      }
      if (maxIdx != -1) {
        toposPerSeg[maxIdx]--;
        currentSum--;
      } else {
        break;
      }
    }
  }

  // Calculate segment widths
  final List<double> segWidths = [];
  for (int i = 0; i < nSeg; i++) {
    double w = datasets[i].maxTimeMin * 15.0; // Reduce pixels per minute for less elongated plot
    w = w < 140.0 ? 140.0 : w; // Min width 140
    double reqW = toposPerSeg[i] * topoW;
    segWidths.add(w < reqW ? reqW : w);
  }

  final double totalSegW = segWidths.fold(0.0, (a, b) => a + b);
  final double contentW = totalSegW + gapW * (nSeg - 1);
  final double figW = leftPad + contentW + rightPad;
  final double figH = titleH + lineH + 60 + topoH + 40;

  // ── Render ────────────────────────────────────────────────────────────────

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  // Background
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, figW, figH),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );

  // Title
  _drawSmallText(
    canvas, 
    feature, 
    const ui.Offset(0, 20), 
    width: figW, 
    color: const ui.Color(0xFF000000), 
    fontSize: 24, 
    fontWeight: ui.FontWeight.bold,
    align: ui.TextAlign.center
  );

  final Map<String, ui.Offset> unknownPositions = {};

  // Lines
  double xCursor = leftPad;
  for (var si = 0; si < nSeg; si++) {
    final w = segWidths[si];
    final segRect = ui.Rect.fromLTWH(xCursor, titleH, w, lineH);
    final maxT = datasets[si].maxTimeMin;

    _renderLinePlot(
      canvas: canvas,
      rect: segRect,
      xData: segXData[si],
      yMean: segYMean[si],
      yStd: segYStd[si],
      globalMin: lineGMin,
      globalMax: lineGMax,
      xMax: maxT < 0.1 ? 0.1 : maxT,
      segName: datasets[si].name,
      drawYAxis: si == 0,
    );

    // Render Topoplots for this segment
    final int k = toposPerSeg[si];
    final double topoActualW = w / k;
    final double tStep = (maxT < 0.1 ? 0.1 : maxT) / k;

    for (int j = 0; j < k; j++) {
      final tCenter = tStep * (j + 0.5);
      final tLo = tCenter - (tStep / 2);
      final tHi = tCenter + (tStep / 2);

      final chanAccum = <String, List<double>>{};
      for (final entry in segData[si].entries) {
        final chan = entry.key;
        for (final s in entry.value) {
          if (s.timeMin >= tLo && s.timeMin <= tHi) {
            chanAccum.putIfAbsent(chan, () => []).add(s.value);
          }
        }
      }
      final chanMeans = <String, double>{};
      for (final entry in chanAccum.entries) {
        chanMeans[entry.key] = entry.value.reduce((a, b) => a + b) / entry.value.length;
      }

      final topoRect = ui.Rect.fromLTWH(
        xCursor + j * topoActualW + (topoActualW - topoW) / 2,
        titleH + lineH + 50,
        topoW,
        topoH,
      );

      _renderTopo(
        canvas: canvas,
        rect: topoRect,
        chanValues: chanMeans,
        montage: montage,
        globalMin: topoGMin,
        globalMax: topoGMax,
        unknownPositions: unknownPositions,
        timeLabel: tCenter.toStringAsFixed(1),
      );
    }

    xCursor += w + gapW;
  }

  // Draw Colorbar
  final double barX = figW - rightPad + 20;
  final double barY = titleH + lineH + 50;
  final double barH = topoH;
  for (var py = 0; py < barH; py++) {
    final double t = 1.0 - py / barH;
    canvas.drawRect(
      ui.Rect.fromLTWH(barX, barY + py, colorBarW, 1.1),
      ui.Paint()..color = _jetColor(t),
    );
  }
  _drawSmallText(canvas, topoGMax.toStringAsFixed(2), ui.Offset(barX + colorBarW + 5, barY - 8), width: 60, fontSize: 14.0);
  _drawSmallText(canvas, topoGMin.toStringAsFixed(2), ui.Offset(barX + colorBarW + 5, barY + barH - 8), width: 60, fontSize: 14.0);

  // ── Finalise ──────────────────────────────────────────────────────────────

  final picture = recorder.endRecording();
  final img = await picture.toImage(figW.round(), figH.round());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  img.dispose();

  if (byteData == null) throw StateError('Failed to encode PNG');
  return byteData.buffer.asUint8List();
}

// ── Utilities ──────────────────────────────────────────────────────────────

String _safeFilename(String feature) =>
    feature.replaceAll(RegExp(r'[^\w\-.]'), '_') + '_' + DateTime.now().millisecondsSinceEpoch.toString();
