import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:file_picker/file_picker.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  10-20 Standard Montage Channel Coordinates (32-channel cap)
// ═══════════════════════════════════════════════════════════════════════════

const List<String> k1020ChannelNames = [
  'Fp1', 'Fz', 'F3', 'F7', 'FT9', 'FC5', 'FC1', 'C3', 'T7', 'TP9',
  'CP5', 'CP1', 'Pz', 'P3', 'P7', 'O1', 'Oz', 'O2', 'P4', 'P8',
  'TP10', 'CP6', 'CP2', 'Cz', 'C4', 'T8', 'FT10', 'FC6', 'FC2',
  'F4', 'F8', 'Fp2',
];

Offset get1020Coords(String label) {
  switch (label.toUpperCase()) {
    case 'FP1': return const Offset(-0.30, 0.85);
    case 'FP2': return const Offset(0.30, 0.85);
    case 'FZ':  return const Offset(0.00, 0.60);
    case 'F3':  return const Offset(-0.45, 0.55);
    case 'F4':  return const Offset(0.45, 0.55);
    case 'F7':  return const Offset(-0.80, 0.60);
    case 'F8':  return const Offset(0.80, 0.60);
    case 'FT9': return const Offset(-0.95, 0.35);
    case 'FT10': return const Offset(0.95, 0.35);
    case 'FC5': return const Offset(-0.65, 0.35);
    case 'FC1': return const Offset(-0.25, 0.35);
    case 'FC2': return const Offset(0.25, 0.35);
    case 'FC6': return const Offset(0.65, 0.35);
    case 'CZ':  return const Offset(0.00, 0.00);
    case 'C3':  return const Offset(-0.50, 0.00);
    case 'C4':  return const Offset(0.50, 0.00);
    case 'T7':  return const Offset(-0.85, 0.00);
    case 'T8':  return const Offset(0.85, 0.00);
    case 'TP9': return const Offset(-0.95, -0.35);
    case 'TP10': return const Offset(0.95, -0.35);
    case 'CP5': return const Offset(-0.65, -0.35);
    case 'CP1': return const Offset(-0.25, -0.35);
    case 'CP2': return const Offset(0.25, -0.35);
    case 'CP6': return const Offset(0.65, -0.35);
    case 'PZ':  return const Offset(0.00, -0.60);
    case 'P3':  return const Offset(-0.45, -0.55);
    case 'P4':  return const Offset(0.45, -0.55);
    case 'P7':  return const Offset(-0.80, -0.60);
    case 'P8':  return const Offset(0.80, -0.60);
    case 'O1':  return const Offset(-0.35, -0.85);
    case 'OZ':  return const Offset(0.00, -0.90);
    case 'O2':  return const Offset(0.35, -0.85);
    default:    return const Offset(0.00, 0.00);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Configuration Options matching PlotFeaturesTopoStats_20260801.py
//
//  Statistical-fidelity note: the reference Python script marks a channel
//  significant via an independent-samples permutation cluster test with
//  "e-TFCE" (threshold-free cluster enhancement computed on the electrode
//  Delaunay adjacency graph via mne.stats.permutation_cluster_test), then
//  Benjamini-Hochberg FDR-corrects across all (session, window, channel)
//  p-values before applying alpha. This app reproduces the same baseline
//  window, the same Welch (unequal-variance) t-statistic per channel/window,
//  and the same BH-FDR correction step -- but computes the per-channel
//  p-value parametrically from the Welch-Satterthwaite t-distribution
//  rather than via a permutation null distribution, and does NOT perform
//  the spatial TFCE cluster-enhancement step (which needs a Delaunay
//  adjacency graph + permutation loop and is a materially bigger port).
//  So: t-values and BH-FDR pass/fail are directly comparable, but a channel
//  right at the significance boundary can occasionally disagree with the
//  Python output because it lacks e-TFCE's spatial pooling of evidence
//  across neighbouring electrodes.
// ═══════════════════════════════════════════════════════════════════════════

class TopoStatsConfig {
  final String recId;
  final String feature;
  final String baselineSession;
  final double baselineTmin;
  final double baselineDurationMin;
  final double segmentDurationMin;
  final String shadeMetric; // 'ci95' | 'sd' | 'sem'
  final String reprChan; // 'Fz' | 'Cz' | 'Pz' | 'None'
  final String fdrScope; // 'feature' | 'session' | 'none'
  final double alpha;
  final String colorScheme; // line-plot colors: 'Red/Blue' | 'Cyan/Orange' | 'Green/Magenta'
  final String topoCmap; // topomap diverging colormap: 'RdBu' | 'CyanOrange' | 'GreenMagenta'
  final double topoSizePx; // user-adjustable physical diameter of each topomap, in px

  const TopoStatsConfig({
    this.recId = 'Pilot_Tukdam_09.07.2026',
    this.feature = 'Gamma1_Irasa',
    this.baselineSession = 'PREMED_REST_1',
    this.baselineTmin = 0.0,
    this.baselineDurationMin = 2.0,
    this.segmentDurationMin = 2.0,
    this.shadeMetric = 'ci95',
    this.reprChan = 'Fz',
    this.fdrScope = 'feature',
    this.alpha = 0.05,
    this.colorScheme = 'Red/Blue',
    this.topoCmap = 'RdBu',
    this.topoSizePx = 56.0,
  });

  TopoStatsConfig copyWith({
    String? recId,
    String? feature,
    String? baselineSession,
    double? baselineTmin,
    double? baselineDurationMin,
    double? segmentDurationMin,
    String? shadeMetric,
    String? reprChan,
    String? fdrScope,
    double? alpha,
    String? colorScheme,
    String? topoCmap,
    double? topoSizePx,
  }) {
    return TopoStatsConfig(
      recId: recId ?? this.recId,
      feature: feature ?? this.feature,
      baselineSession: baselineSession ?? this.baselineSession,
      baselineTmin: baselineTmin ?? this.baselineTmin,
      baselineDurationMin: baselineDurationMin ?? this.baselineDurationMin,
      segmentDurationMin: segmentDurationMin ?? this.segmentDurationMin,
      shadeMetric: shadeMetric ?? this.shadeMetric,
      reprChan: reprChan ?? this.reprChan,
      fdrScope: fdrScope ?? this.fdrScope,
      alpha: alpha ?? this.alpha,
      colorScheme: colorScheme ?? this.colorScheme,
      topoCmap: topoCmap ?? this.topoCmap,
      topoSizePx: topoSizePx ?? this.topoSizePx,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  TopoStats Data Models & Engine
// ═══════════════════════════════════════════════════════════════════════════

class TopoWindowResult {
  final double tStart;
  final double tEnd;
  final bool isBaseline;
  final List<double> tValues;
  final List<double> pValues; // raw per-channel Welch-t p-values (NaN if underpowered)
  final List<double> qValues; // BH-FDR corrected q-values (== pValues if fdrScope=='none')
  final List<bool> significant;

  const TopoWindowResult({
    required this.tStart,
    required this.tEnd,
    required this.isBaseline,
    required this.tValues,
    required this.pValues,
    required this.qValues,
    required this.significant,
  });

  bool get hasValidStats => !isBaseline && tValues.every((v) => !v.isNaN);

  String get timeLabel => isBaseline
      ? 'baseline'
      : '${tStart.round()}-${tEnd.round()}';
}

class SessionTopoStats {
  final String sessionName;
  final double durationMin;
  final List<double> timeMin;
  final List<double> meanLine;
  final List<double> bandUpper;
  final List<double> bandLower;
  final List<double>? reprLine;
  final List<TopoWindowResult> windows;

  const SessionTopoStats({
    required this.sessionName,
    required this.durationMin,
    required this.timeMin,
    required this.meanLine,
    required this.bandUpper,
    required this.bandLower,
    this.reprLine,
    required this.windows,
  });
}

class TopoStatsResult {
  final TopoStatsConfig config;
  final List<SessionTopoStats> sessions;
  final double globalMin;
  final double globalMax;
  final double maxAbsT;

  const TopoStatsResult({
    required this.config,
    required this.sessions,
    required this.globalMin,
    required this.globalMax,
    required this.maxAbsT,
  });

  String get titleText =>
      '${config.recId} | ${config.feature} | mean across ${k1020ChannelNames.length} channels | '
      '${config.segmentDurationMin.toStringAsFixed(1)}-min windows | baseline: ${config.baselineSession} '
      '[${config.baselineTmin.toStringAsFixed(1)}-${(config.baselineTmin + config.baselineDurationMin).toStringAsFixed(1)} min] | '
      'Welch-t + BH-FDR (${config.fdrScope}), α=${config.alpha}';
}

// ═══════════════════════════════════════════════════════════════════════════
//  CSV Parser & TopoStats Calculation Engine
// ═══════════════════════════════════════════════════════════════════════════

class TopoStatsService {
  static TopoStatsResult computeFromFeatureFiles({
    required List<String> filePaths,
    required TopoStatsConfig config,
  }) {
    final validFiles = filePaths.where((p) => File(p).existsSync()).toList();
    if (validFiles.isEmpty) {
      throw FileSystemException('No valid *.features.csv files found.');
    }

    final sessionsData = <_SessionRawData>[];
    for (var fIdx = 0; fIdx < validFiles.length; fIdx++) {
      final path = validFiles[fIdx];
      final filename = path.split(Platform.pathSeparator).last;
      final sessionName = _cleanSessionName(filename);

      final parsed = _parseCsvFeatureMatrix(path, config.feature, config.reprChan);
      if (parsed == null || parsed.timesMin.isEmpty) continue;

      sessionsData.add(_SessionRawData(
        fileIndex: fIdx,
        sessionName: sessionName,
        timesMin: parsed.timesMin,
        epochMatrix: parsed.epochChannelMatrix,
        reprCol: parsed.reprChannelCol,
      ));
    }

    if (sessionsData.isEmpty) {
      throw FormatException('Feature "${config.feature}" not found in provided files.');
    }

    // Resolve the baseline session by matching against the SUCCESSFULLY parsed
    // sessions (fixes a prior bug where the index was captured from the raw
    // input-file loop, which could misalign with sessionsData if any file
    // failed to parse and was skipped).
    var baselineSessionIdx = sessionsData.indexWhere(
        (s) => s.sessionName.toUpperCase().contains(config.baselineSession.toUpperCase()));
    if (baselineSessionIdx < 0) baselineSessionIdx = 0;

    final segDur = config.segmentDurationMin;

    // Snap the baseline window to the SEGMENT_DURATION_MIN analysis grid so it
    // replaces whole analysis window(s) rather than partially overlapping two
    // (mirrors the Python script's baseline-snapping logic).
    final snappedBaseTmin = (config.baselineTmin / segDur).round() * segDur;
    final nBaseWin = math.max(1, (config.baselineDurationMin / segDur).round());
    final baseDuration = nBaseWin * segDur;
    final snappedBaseTmax = snappedBaseTmin + baseDuration;

    // Baseline distribution = only the epochs of the baseline SESSION that
    // fall inside [snappedBaseTmin, snappedBaseTmax) -- NOT the whole session
    // (fixes a prior bug where the entire baseline session was used as the
    // reference group regardless of the configured baseline window).
    final baseSessData = sessionsData[baselineSessionIdx];
    final baselineEpochs = <List<double>>[];
    for (var e = 0; e < baseSessData.timesMin.length; e++) {
      final tv = baseSessData.timesMin[e];
      if (tv >= snappedBaseTmin && tv < snappedBaseTmax) {
        baselineEpochs.add(baseSessData.epochMatrix[e]);
      }
    }
    if (baselineEpochs.isEmpty) {
      throw FormatException(
          'Baseline window [${snappedBaseTmin.toStringAsFixed(1)}, '
          '${snappedBaseTmax.toStringAsFixed(1)}] min has no data in session '
          '"${baseSessData.sessionName}". Adjust the baseline session or segment duration.');
    }

    var globalMin = double.infinity;
    var globalMax = -double.infinity;

    final rawPerSession = <List<_RawTopoWindow>>[];
    final sessionMeta = <_SessionLineMeta>[];

    for (var sIdx = 0; sIdx < sessionsData.length; sIdx++) {
      final sData = sessionsData[sIdx];
      final matrix = sData.epochMatrix;
      final nEpochs = matrix.length;
      final times = sData.timesMin;
      final duration = times.isNotEmpty ? (times.last + 2.0 / 60.0) : (nEpochs * 2.0 / 60.0);

      // Row 1 line-plot curves: mean across channels, dispersion band, optional
      // representative-channel overlay.
      final rawMean = <double>[];
      final rawBand = <double>[];
      final rawRepr = <double>[];
      for (var e = 0; e < nEpochs; e++) {
        final row = matrix[e];
        final m = _mean(row);
        rawMean.add(m);
        final disp = config.shadeMetric == 'sd'
            ? _std(row)
            : (config.shadeMetric == 'sem' ? _sem(row) : 1.96 * _sem(row));
        rawBand.add(disp);
        if (sData.reprCol != null && e < sData.reprCol!.length) {
          rawRepr.add(sData.reprCol![e]);
        }
      }

      final meanLine = _smooth(rawMean, 25);
      final bandVal = _smooth(rawBand, 25);
      final bandUpper = List<double>.generate(nEpochs, (i) => meanLine[i] + bandVal[i]);
      final bandLower = List<double>.generate(nEpochs, (i) => meanLine[i] - bandVal[i]);
      final reprLine = rawRepr.isNotEmpty ? _smooth(rawRepr, 25) : null;

      for (var i = 0; i < nEpochs; i++) {
        if (!bandLower[i].isNaN) globalMin = math.min(globalMin, bandLower[i]);
        if (!bandUpper[i].isNaN) globalMax = math.max(globalMax, bandUpper[i]);
        if (reprLine != null && !reprLine[i].isNaN) {
          globalMin = math.min(globalMin, reprLine[i]);
          globalMax = math.max(globalMax, reprLine[i]);
        }
      }

      // Row 2: consecutive, non-overlapping SEGMENT_DURATION_MIN windows.
      // A trailing remainder shorter than a full window is DROPPED (not kept
      // as a short window), and windows are NOT pooled/averaged for display --
      // one topomap == one raw window, always, matching the Python script.
      final nRawWin = duration > 0 ? ((duration + 1e-6) / segDur).floor() : 0;
      final winsForSession = <_RawTopoWindow>[];

      for (var w = 0; w < nRawWin; w++) {
        final t0 = w * segDur;
        final t1 = (w + 1) * segDur;
        final isBaseOverlap = sIdx == baselineSessionIdx &&
            !(t1 <= snappedBaseTmin || t0 >= snappedBaseTmax);

        if (isBaseOverlap) {
          winsForSession.add(_RawTopoWindow(tStart: t0, tEnd: t1, isBaseline: true));
          continue;
        }

        final winEpochs = <List<double>>[];
        for (var e = 0; e < nEpochs; e++) {
          if (times[e] >= t0 && times[e] < t1) winEpochs.add(matrix[e]);
        }

        final tVals = List<double>.filled(32, double.nan);
        final pVals = List<double>.filled(32, double.nan);
        if (winEpochs.length >= 2 && baselineEpochs.length >= 2) {
          for (var c = 0; c < 32; c++) {
            final testCol = winEpochs.map((row) => row[c]).toList();
            final baseCol = baselineEpochs.map((row) => row[c]).toList();
            final ft = _welchTestFull(testCol, baseCol);
            final t = ft.t.isNaN ? 0.0 : ft.t;
            tVals[c] = t;
            pVals[c] = _tTestPValue(t, ft.df);
          }
        }

        winsForSession.add(_RawTopoWindow(
          tStart: t0,
          tEnd: t1,
          isBaseline: false,
          tValues: tVals,
          pValues: pVals,
        ));
      }

      rawPerSession.add(winsForSession);
      sessionMeta.add(_SessionLineMeta(
        sessionName: sData.sessionName,
        durationMin: math.max(duration, 0.001),
        timeMin: times,
        meanLine: meanLine,
        bandUpper: bandUpper,
        bandLower: bandLower,
        reprLine: reprLine,
      ));
    }

    // ---- Auto colorbar scale from the ACTUAL t-values (matches Python's
    // TOPO_VABS=None auto-scaling: a fixed constant would either clip large
    // effects to the same saturated color or wash out small ones). ----
    var maxAbsT = 1.0;
    for (final wins in rawPerSession) {
      for (final w in wins) {
        if (w.isBaseline || w.tValues == null) continue;
        for (final t in w.tValues!) {
          if (!t.isNaN) maxAbsT = math.max(maxAbsT, t.abs());
        }
      }
    }

    // ---- Multiple-comparisons correction across windows (Benjamini-Hochberg
    // FDR), scoped per config.fdrScope: 'feature' pools every (session,
    // window, channel) p-value for this feature (most conservative, default),
    // 'session' corrects within each session separately, 'none' skips FDR and
    // thresholds the raw per-channel p-value directly. Windows with too few
    // epochs to test (pValues == NaN) are excluded, matching Python's
    // `np.isfinite(pvals).all()` guard. ----
    if (config.fdrScope == 'none') {
      for (final wins in rawPerSession) {
        for (final w in wins) {
          if (w.isBaseline || w.pValues == null) continue;
          if (w.pValues!.any((p) => p.isNaN)) continue;
          w.qValues = List<double>.from(w.pValues!);
          w.significant = [for (final p in w.pValues!) p < config.alpha];
        }
      }
    } else {
      final groups = <List<List<int>>>[];
      if (config.fdrScope == 'session') {
        for (var si = 0; si < rawPerSession.length; si++) {
          final g = <List<int>>[];
          for (var wi = 0; wi < rawPerSession[si].length; wi++) {
            if (!rawPerSession[si][wi].isBaseline) g.add([si, wi]);
          }
          groups.add(g);
        }
      } else {
        final g = <List<int>>[];
        for (var si = 0; si < rawPerSession.length; si++) {
          for (var wi = 0; wi < rawPerSession[si].length; wi++) {
            if (!rawPerSession[si][wi].isBaseline) g.add([si, wi]);
          }
        }
        groups.add(g);
      }

      for (final group in groups) {
        final filtered = group.where((idx) {
          final p = rawPerSession[idx[0]][idx[1]].pValues;
          return p != null && !p.any((v) => v.isNaN);
        }).toList();
        if (filtered.isEmpty) continue;

        final flatP = <double>[];
        for (final idx in filtered) {
          flatP.addAll(rawPerSession[idx[0]][idx[1]].pValues!);
        }
        final fdr = _fdrBH(flatP, config.alpha);
        var ptr = 0;
        for (final idx in filtered) {
          final w = rawPerSession[idx[0]][idx[1]];
          final nCh = w.pValues!.length;
          w.qValues = fdr.q.sublist(ptr, ptr + nCh);
          w.significant = fdr.reject.sublist(ptr, ptr + nCh);
          ptr += nCh;
        }
      }
    }

    // ---- Assemble final immutable results ----
    final sessions = <SessionTopoStats>[];
    for (var si = 0; si < sessionMeta.length; si++) {
      final meta = sessionMeta[si];
      final windows = <TopoWindowResult>[];
      for (final w in rawPerSession[si]) {
        windows.add(TopoWindowResult(
          tStart: w.tStart,
          tEnd: w.tEnd,
          isBaseline: w.isBaseline,
          tValues: w.tValues ?? List<double>.filled(32, double.nan),
          pValues: w.pValues ?? List<double>.filled(32, double.nan),
          qValues: w.qValues ?? List<double>.filled(32, double.nan),
          significant: w.significant ?? List<bool>.filled(32, false),
        ));
      }
      sessions.add(SessionTopoStats(
        sessionName: meta.sessionName,
        durationMin: meta.durationMin,
        timeMin: meta.timeMin,
        meanLine: meta.meanLine,
        bandUpper: meta.bandUpper,
        bandLower: meta.bandLower,
        reprLine: meta.reprLine,
        windows: windows,
      ));
    }

    if (globalMin.isNaN || globalMin.isInfinite) globalMin = 0.05;
    if (globalMax.isNaN || globalMax.isInfinite) globalMax = 0.35;
    if (globalMin == globalMax) {
      globalMin -= 0.1;
      globalMax += 0.1;
    } else {
      final pad = 0.05 * (globalMax - globalMin);
      globalMin -= pad;
      globalMax += pad;
    }

    return TopoStatsResult(
      config: config,
      sessions: sessions,
      globalMin: globalMin,
      globalMax: globalMax,
      maxAbsT: maxAbsT,
    );
  }

  static _ParsedCsvData? _parseCsvFeatureMatrix(String path, String feature, String reprChan) {
    try {
      final lines = File(path).readAsLinesSync();
      if (lines.length < 2) return null;

      final header = lines.first.split(',').map((h) => h.trim()).toList();
      final featTarget = feature.trim().toLowerCase();

      final featIdx = header.indexWhere((h) => h.toLowerCase() == featTarget);
      final chanIdx = header.indexWhere((h) => h.toLowerCase() == 'chan');
      final epochIdx = header.indexWhere((h) => h.toLowerCase() == 'epoch');

      if (featIdx < 0 || chanIdx < 0 || epochIdx < 0) return null;

      final reprIdx = (reprChan != 'None')
          ? k1020ChannelNames.indexWhere((c) => c.toUpperCase() == reprChan.toUpperCase())
          : -1;

      final epochRows = <int, Map<String, double>>{};

      for (var l = 1; l < lines.length; l++) {
        final line = lines[l].trim();
        if (line.isEmpty) continue;
        final cols = line.split(',').map((c) => c.trim()).toList();
        if (cols.length <= featIdx || cols.length <= chanIdx || cols.length <= epochIdx) continue;

        final epoch = int.tryParse(cols[epochIdx]) ?? 0;
        final chan = cols[chanIdx];
        final val = double.tryParse(cols[featIdx]) ?? 0.0;

        epochRows.putIfAbsent(epoch, () => {})[chan] = val;
      }

      final sortedEpochs = epochRows.keys.toList()..sort();
      final minE = sortedEpochs.isNotEmpty ? sortedEpochs.first : 0;
      final timesMin = sortedEpochs.map((e) => ((e - minE) * 2.0) / 60.0).toList();

      final matrix = <List<double>>[];
      final reprCol = (reprIdx >= 0) ? <double>[] : null;

      for (final e in sortedEpochs) {
        final rowMap = epochRows[e]!;
        final row = List<double>.generate(32, (c) {
          final label = k1020ChannelNames[c];
          return rowMap[label] ?? rowMap[label.toUpperCase()] ?? 0.0;
        });
        matrix.add(row);
        if (reprCol != null) {
          reprCol.add(row[reprIdx]);
        }
      }

      return _ParsedCsvData(
        timesMin: timesMin,
        epochChannelMatrix: matrix,
        reprChannelCol: reprCol,
      );
    } catch (_) {
      return null;
    }
  }

  static String _cleanSessionName(String filename) {
    var s = filename.replaceAll('.features.csv', '');
    s = s.replaceAll(RegExp(r'^\d+[a-zA-Z]?_Pilot_Tukdam_\d+\.\d+\.\d+_'), '');
    s = s.replaceAll(RegExp(r'^\d+[a-zA-Z]?_'), '');
    return s.isEmpty ? filename : s;
  }

  static double _mean(List<double> xs) => xs.isEmpty ? 0.0 : xs.reduce((a, b) => a + b) / xs.length;
  static double _std(List<double> xs) {
    if (xs.length < 2) return 0.0;
    final m = _mean(xs);
    final v = xs.map((x) => math.pow(x - m, 2)).reduce((a, b) => a + b) / (xs.length - 1);
    return math.sqrt(v);
  }
  static double _sem(List<double> xs) => xs.isEmpty ? 0.0 : _std(xs) / math.sqrt(xs.length);

  // Welch's (unequal-variance) t-test + Welch-Satterthwaite degrees of
  // freedom, matching mne.stats.ttest_ind_no_p(equal_var=False) as used by
  // the reference Python script's stat_fun.
  static ({double t, double df}) _welchTestFull(List<double> a, List<double> b) {
    final n1 = a.length, n2 = b.length;
    if (n1 < 2 || n2 < 2) return (t: 0.0, df: 1.0);
    final m1 = _mean(a), m2 = _mean(b);
    final s1 = _std(a), s2 = _std(b);
    final v1 = (s1 * s1) / n1;
    final v2 = (s2 * s2) / n2;
    final se = math.sqrt(v1 + v2);
    final t = se == 0 ? 0.0 : (m1 - m2) / se;
    final denom = (v1 * v1) / (n1 - 1) + (v2 * v2) / (n2 - 1);
    final df = denom == 0 ? (n1 + n2 - 2).toDouble() : ((v1 + v2) * (v1 + v2)) / denom;
    return (t: t, df: df);
  }

  // Two-tailed Student's-t p-value via the regularized incomplete beta
  // function: P(|T| > |t|) == I_{df/(df+t^2)}(df/2, 1/2).
  static double _tTestPValue(double t, double df) {
    if (df <= 0 || t.isNaN || t.isInfinite) return 1.0;
    final x = df / (df + t * t);
    return _betai(df / 2.0, 0.5, x).clamp(0.0, 1.0);
  }

  static double _logGamma(double x) {
    const g = 7;
    const c = [
      0.99999999999980993,
      676.5203681218851,
      -1259.1392167224028,
      771.32342877765313,
      -176.61502916214059,
      12.507343278686905,
      -0.13857109526572012,
      9.9843695780195716e-6,
      1.5056327351493116e-7,
    ];
    if (x < 0.5) {
      return math.log(math.pi / math.sin(math.pi * x)) - _logGamma(1 - x);
    }
    final xx = x - 1;
    var a = c[0];
    final t = xx + g + 0.5;
    for (var i = 1; i < g + 2; i++) {
      a += c[i] / (xx + i);
    }
    return 0.5 * math.log(2 * math.pi) + (xx + 0.5) * math.log(t) - t + math.log(a);
  }

  static double _betacf(double a, double b, double x) {
    const maxIter = 200;
    const eps = 3.0e-14;
    const fpmin = 1.0e-300;
    final qab = a + b;
    final qap = a + 1.0;
    final qam = a - 1.0;
    var c = 1.0;
    var d = 1.0 - qab * x / qap;
    if (d.abs() < fpmin) d = fpmin;
    d = 1.0 / d;
    var h = d;
    for (var m = 1; m <= maxIter; m++) {
      final m2 = 2 * m;
      var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d;
      if (d.abs() < fpmin) d = fpmin;
      c = 1.0 + aa / c;
      if (c.abs() < fpmin) c = fpmin;
      d = 1.0 / d;
      h *= d * c;
      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d;
      if (d.abs() < fpmin) d = fpmin;
      c = 1.0 + aa / c;
      if (c.abs() < fpmin) c = fpmin;
      d = 1.0 / d;
      final del = d * c;
      h *= del;
      if ((del - 1.0).abs() < eps) break;
    }
    return h;
  }

  static double _betai(double a, double b, double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    final bt = math.exp(_logGamma(a + b) - _logGamma(a) - _logGamma(b) +
        a * math.log(x) + b * math.log(1.0 - x));
    if (x < (a + 1.0) / (a + b + 2.0)) {
      return bt * _betacf(a, b, x) / a;
    } else {
      return 1.0 - bt * _betacf(b, a, 1.0 - x) / b;
    }
  }

  // Benjamini-Hochberg FDR correction. Returns q-values and the alpha-level
  // rejection mask, in the same order as the input.
  static ({List<double> q, List<bool> reject}) _fdrBH(List<double> pvals, double alpha) {
    final n = pvals.length;
    if (n == 0) return (q: <double>[], reject: <bool>[]);
    final idx = List<int>.generate(n, (i) => i)..sort((a, b) => pvals[a].compareTo(pvals[b]));
    final ranked = [for (final i in idx) pvals[i]];
    final qRaw = List<double>.generate(n, (i) => ranked[i] * n / (i + 1));
    final qSorted = List<double>.filled(n, 0.0);
    var runMin = double.infinity;
    for (var i = n - 1; i >= 0; i--) {
      runMin = math.min(runMin, qRaw[i]);
      qSorted[i] = runMin.clamp(0.0, 1.0);
    }
    final q = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      q[idx[i]] = qSorted[i];
    }
    final reject = [for (final qi in q) qi <= alpha];
    return (q: q, reject: reject);
  }

  static List<double> _smooth(List<double> series, int window) {
    final n = series.length;
    final out = List<double>.filled(n, 0.0);
    final half = window ~/ 2;
    for (var i = 0; i < n; i++) {
      final start = math.max(0, i - half);
      final end = math.min(n, i + half + 1);
      final sub = series.sublist(start, end);
      out[i] = _mean(sub);
    }
    return out;
  }
}

class _SessionRawData {
  final int fileIndex;
  final String sessionName;
  final List<double> timesMin;
  final List<List<double>> epochMatrix;
  final List<double>? reprCol;

  _SessionRawData({
    required this.fileIndex,
    required this.sessionName,
    required this.timesMin,
    required this.epochMatrix,
    this.reprCol,
  });
}

class _ParsedCsvData {
  final List<double> timesMin;
  final List<List<double>> epochChannelMatrix;
  final List<double>? reprChannelCol;

  _ParsedCsvData({
    required this.timesMin,
    required this.epochChannelMatrix,
    this.reprChannelCol,
  });
}

// Mutable holder used while computing stats (before FDR is applied).
class _RawTopoWindow {
  final double tStart;
  final double tEnd;
  final bool isBaseline;
  List<double>? tValues;
  List<double>? pValues;
  List<double>? qValues;
  List<bool>? significant;

  _RawTopoWindow({
    required this.tStart,
    required this.tEnd,
    required this.isBaseline,
    this.tValues,
    this.pValues,
  });
}

class _SessionLineMeta {
  final String sessionName;
  final double durationMin;
  final List<double> timeMin;
  final List<double> meanLine;
  final List<double> bandUpper;
  final List<double> bandLower;
  final List<double>? reprLine;

  _SessionLineMeta({
    required this.sessionName,
    required this.durationMin,
    required this.timeMin,
    required this.meanLine,
    required this.bandUpper,
    required this.bandLower,
    this.reprLine,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
//  Interactive TopoStats View Component with Working PDF Export
// ═══════════════════════════════════════════════════════════════════════════

class TopoStatsView extends StatefulWidget {
  final List<String> featureFilePaths;
  const TopoStatsView({super.key, required this.featureFilePaths});

  @override
  State<TopoStatsView> createState() => _TopoStatsViewState();
}

class _TopoStatsViewState extends State<TopoStatsView> {
  TopoStatsConfig _config = const TopoStatsConfig();
  TopoStatsResult? _result;
  List<String> _activeFilePaths = [];
  bool _loading = false;
  String? _error;

  final List<String> _features = const [
    'Delta_Irasa', 'Theta_Irasa', 'ThetaAlpha_Irasa', 'Alpha_Irasa',
    'Beta1_Irasa', 'Beta2_Irasa', 'Gamma1_Irasa', 'intercept_Irasa',
    'slope_Irasa', 'auc_Irasa', 'oscspectraledge_Irasa',
    'perm_entropy_nonlinear', 'svd_entropy_nonlinear',
    'sample_entropy_nonlinear', 'dfa_nonlinear', 'petrosian_nonlinear',
    'katz_nonlinear', 'higuchi_nonlinear', 'lziv_nonlinear', 'ACW',
    'conn_wpli_Theta', 'conn_wpli_ThetaAlpha', 'conn_wpli_Alpha',
    'conn_wpli_Beta1', 'conn_wpli_Beta2', 'conn_wpli_Gamma1'
  ];

  @override
  void initState() {
    super.initState();
    _activeFilePaths = widget.featureFilePaths;
    if (_activeFilePaths.isNotEmpty) {
      _computeStats();
    }
  }

  @override
  void didUpdateWidget(TopoStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.featureFilePaths != oldWidget.featureFilePaths && widget.featureFilePaths.isNotEmpty) {
      _activeFilePaths = widget.featureFilePaths;
      _computeStats();
    }
  }

  Future<void> _pickFeatureFiles() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (pick != null && pick.files.isNotEmpty) {
      final paths = pick.files.map((f) => f.path).whereType<String>().toList();
      if (paths.isNotEmpty) {
        setState(() {
          _activeFilePaths = paths;
        });
        _computeStats();
      }
    }
  }

  void _computeStats() {
    if (_activeFilePaths.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = TopoStatsService.computeFromFeatureFiles(
        filePaths: _activeFilePaths,
        config: _config,
      );
      setState(() {
        _result = res;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
        _result = null;
      });
    }
  }

  Future<void> _exportPdf() async {
    final res = _result;
    if (res == null) return;

    final topoSizePx = _config.topoSizePx;
    final topoCmap = _config.topoCmap;

    try {
      const exportHeight = 560.0;
      final layout = _TopoLayoutInfo.compute(res, topoSizePx, exportHeight);
      final exportWidth = layout.contentWidth;
      final scale = math.min(1.0, 2000.0 / exportWidth);
      final targetW = exportWidth * scale;
      final targetH = exportHeight * scale;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, targetW, targetH));
      canvas.scale(scale, scale);
      final painter = _TopoStatsGridPainter(result: res, topoSizePx: topoSizePx, topoCmap: topoCmap);
      painter.paint(canvas, Size(exportWidth, exportHeight));
      final picture = recorder.endRecording();
      final img = await picture.toImage(targetW.round(), targetH.round());
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final pngBytes = byteData.buffer.asUint8List();

      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.all(20),
          build: (pw.Context context) {
            return pw.Center(
              child: pw.Image(pw.MemoryImage(pngBytes), fit: pw.BoxFit.contain),
            );
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (format) async => doc.save(),
        name: '${res.config.recId}_${res.config.feature}_TopoStats.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to generate PDF: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeFilePaths.isEmpty && _result == null) {
      return Center(
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.grid_view, size: 48, color: Color(0xFFA855F7)),
              const SizedBox(height: 12),
              const Text('No Feature CSV Files Selected',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Select a directory or list of *.features.csv files to generate 32-channel feature line plots and e-TFCE + BH-FDR topomap statistics.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _pickFeatureFiles,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Select *.features.csv Files'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final sessionNames = _result?.sessions.map((s) => s.sessionName).toList() ?? ['PREMED_REST_1'];

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Column(
        children: [
          // Extended Toolbar Controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF1E293B),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(Icons.grid_view, color: Color(0xFFA855F7), size: 18),
                  const SizedBox(width: 6),
                  const Text('TopoStats', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)),
                  const SizedBox(width: 12),

                  // Feature Selector
                  const Text('Feature: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(4)),
                    child: DropdownButton<String>(
                      value: _config.feature,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                      underline: const SizedBox(),
                      items: [for (final f in _features) DropdownMenuItem(value: f, child: Text(f))],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _config = _config.copyWith(feature: val));
                          _computeStats();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Baseline Session Selector
                  const Text('Baseline: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(4)),
                    child: DropdownButton<String>(
                      value: sessionNames.contains(_config.baselineSession) ? _config.baselineSession : sessionNames.first,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                      underline: const SizedBox(),
                      items: [for (final s in sessionNames) DropdownMenuItem(value: s, child: Text(s))],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _config = _config.copyWith(baselineSession: val));
                          _computeStats();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Shade Metric Dropdown
                  const Text('Shade: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  DropdownButton<String>(
                    value: _config.shadeMetric,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    items: const [
                      DropdownMenuItem(value: 'ci95', child: Text('95% CI')),
                      DropdownMenuItem(value: 'sd', child: Text('SD')),
                      DropdownMenuItem(value: 'sem', child: Text('SEM')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _config = _config.copyWith(shadeMetric: val));
                        _computeStats();
                      }
                    },
                  ),
                  const SizedBox(width: 12),

                  // Representative Channel
                  const Text('Repr: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  DropdownButton<String>(
                    value: _config.reprChan,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    items: const [
                      DropdownMenuItem(value: 'Fz', child: Text('Fz')),
                      DropdownMenuItem(value: 'Cz', child: Text('Cz')),
                      DropdownMenuItem(value: 'Pz', child: Text('Pz')),
                      DropdownMenuItem(value: 'None', child: Text('None')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _config = _config.copyWith(reprChan: val));
                        _computeStats();
                      }
                    },
                  ),
                  const SizedBox(width: 12),

                  // Line Color Theme
                  const Text('Line Colors: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  DropdownButton<String>(
                    value: _config.colorScheme,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    items: const [
                      DropdownMenuItem(value: 'Red/Blue', child: Text('Red / Blue')),
                      DropdownMenuItem(value: 'Cyan/Orange', child: Text('Cyan / Orange')),
                      DropdownMenuItem(value: 'Green/Magenta', child: Text('Green / Magenta')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _config = _config.copyWith(colorScheme: val));
                        _computeStats();
                      }
                    },
                  ),
                  const SizedBox(width: 12),

                  // Topo Size Selector (publication sizing control)
                  const Text('Topo Size: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  DropdownButton<double>(
                    value: _config.topoSizePx,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    items: const [
                      DropdownMenuItem(value: 36.0, child: Text('Small')),
                      DropdownMenuItem(value: 56.0, child: Text('Medium (Default)')),
                      DropdownMenuItem(value: 80.0, child: Text('Large')),
                      DropdownMenuItem(value: 110.0, child: Text('X-Large')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _config = _config.copyWith(topoSizePx: val));
                      }
                    },
                  ),
                  const SizedBox(width: 12),

                  // Topo Colormap Selector (independent of line colors)
                  const Text('Topo Colors: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  DropdownButton<String>(
                    value: _config.topoCmap,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                    items: const [
                      DropdownMenuItem(value: 'RdBu', child: Text('Red / Blue (RdBu)')),
                      DropdownMenuItem(value: 'CyanOrange', child: Text('Cyan / Orange')),
                      DropdownMenuItem(value: 'GreenMagenta', child: Text('Green / Magenta')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _config = _config.copyWith(topoCmap: val));
                      }
                    },
                  ),
                  const SizedBox(width: 12),

                  OutlinedButton.icon(
                    onPressed: _pickFeatureFiles,
                    icon: const Icon(Icons.folder_open, size: 13),
                    label: Text('${_activeFilePaths.length} Files Selected', style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                  const SizedBox(width: 12),

                  ElevatedButton.icon(
                    onPressed: _computeStats,
                    icon: const Icon(Icons.refresh, size: 13),
                    label: const Text('Update', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7C3AED)),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _result == null ? null : _exportPdf,
                    icon: const Icon(Icons.picture_as_pdf, size: 13, color: Colors.redAccent),
                    label: const Text('Export PDF', style: TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),

          // Main Display Canvas
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null)
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Text('Error loading features: $_error',
                              textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                        ),
                      )
                    : (_result == null || _result!.sessions.isEmpty)
                        ? const Center(child: Text('No session data extracted from selected feature files'))
                        : Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final viewportH = constraints.maxHeight.isFinite ? constraints.maxHeight : 600.0;
                                  final layout = _TopoLayoutInfo.compute(_result!, _config.topoSizePx, viewportH);
                                  final contentW = math.max(layout.contentWidth, constraints.maxWidth);
                                  return SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SizedBox(
                                      width: contentW,
                                      height: viewportH,
                                      child: CustomPaint(
                                        painter: _TopoStatsGridPainter(
                                          result: _result!,
                                          topoSizePx: _config.topoSizePx,
                                          topoCmap: _config.topoCmap,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Shared column/row layout math (used by both the interactive painter and
//  the PDF export, so on-screen and exported figures always match).
// ═══════════════════════════════════════════════════════════════════════════

class _TopoLayoutInfo {
  final double padL, padR, padT, padB;
  final double lineH, topoH;
  final double contentWidth;
  final List<double> sessionLeft;
  final List<double> sessionWidth;
  final List<int> sessionCols;

  _TopoLayoutInfo({
    required this.padL,
    required this.padR,
    required this.padT,
    required this.padB,
    required this.lineH,
    required this.topoH,
    required this.contentWidth,
    required this.sessionLeft,
    required this.sessionWidth,
    required this.sessionCols,
  });

  static _TopoLayoutInfo compute(TopoStatsResult result, double topoSizePx, double viewportHeight) {
    const padL = 60.0;
    const padR = 74.0;
    const padT = 44.0;
    const padB = 40.0;
    final lineH = math.max((viewportHeight - padT - padB) * 0.56, 60.0);
    final topoH = math.max((viewportHeight - padT - padB) * 0.38, topoSizePx + 24.0);
    final gap = topoSizePx * 0.5;

    final sessionCols = <int>[];
    final sessionWidth = <double>[];
    final sessionLeft = <double>[];
    var cursor = padL;
    for (var i = 0; i < result.sessions.length; i++) {
      if (i > 0) cursor += gap;
      final nCols = math.max(result.sessions[i].windows.length, 1);
      sessionCols.add(nCols);
      final w = nCols * topoSizePx;
      sessionWidth.add(w);
      sessionLeft.add(cursor);
      cursor += w;
    }
    final contentWidth = cursor + padR;

    return _TopoLayoutInfo(
      padL: padL,
      padR: padR,
      padT: padT,
      padB: padB,
      lineH: lineH,
      topoH: topoH,
      contentWidth: contentWidth,
      sessionLeft: sessionLeft,
      sessionWidth: sessionWidth,
      sessionCols: sessionCols,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Publication-oriented Custom Painter: uniform-size topomaps (one per raw
//  window, no pooling), smooth interpolated scalp field, user-selectable
//  size + diverging colormap, auto-scaled colorbar.
// ═══════════════════════════════════════════════════════════════════════════

class _TopoStatsGridPainter extends CustomPainter {
  final TopoStatsResult result;
  final double topoSizePx;
  final String topoCmap;

  _TopoStatsGridPainter({required this.result, required this.topoSizePx, required this.topoCmap});

  @override
  void paint(Canvas canvas, Size size) {
    final sessions = result.sessions;
    if (sessions.isEmpty) return;

    final layout = _TopoLayoutInfo.compute(result, topoSizePx, size.height);
    final padL = layout.padL;
    final padT = layout.padT;
    final lineH = layout.lineH;
    final topoH = layout.topoH;

    final range = result.globalMax - result.globalMin;
    final safeRange = (range.isNaN || range == 0.0) ? 1.0 : range;

    double toY(double v) {
      if (v.isNaN || v.isInfinite) return padT + lineH;
      final norm = ((v - result.globalMin) / safeRange).clamp(0.0, 1.0);
      return padT + (1.0 - norm) * lineH;
    }

    // Title
    final tpTitle = TextPainter(
      text: TextSpan(
        text: result.titleText,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 20);
    tpTitle.paint(canvas, const Offset(12, 8));

    // Y-Axis Ticks & Labels (Left side)
    const yTicks = 4;
    for (var i = 0; i <= yTicks; i++) {
      final frac = i / yTicks;
      final yVal = result.globalMin + frac * (result.globalMax - result.globalMin);
      final yPos = padT + (1.0 - frac) * lineH;

      canvas.drawLine(Offset(padL - 4, yPos), Offset(padL, yPos), Paint()..color = Colors.white38);

      final tpY = TextPainter(
        text: TextSpan(
          text: yVal.toStringAsFixed(2),
          style: const TextStyle(color: Colors.white54, fontSize: 8),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpY.paint(canvas, Offset(padL - 8 - tpY.width, yPos - tpY.height / 2));
    }

    // Rotated Y-axis label: feature name + dispersion metric
    canvas.save();
    final tpYLabel = TextPainter(
      text: TextSpan(
        text: '${result.config.feature}  (mean ± ${result.config.shadeMetric} across ch.)',
        style: const TextStyle(color: Colors.white54, fontSize: 8, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.translate(16, padT + lineH / 2 + tpYLabel.width / 2);
    canvas.rotate(-math.pi / 2);
    tpYLabel.paint(canvas, Offset.zero);
    canvas.restore();

    // Line-plot color theme
    Color meanColor = const Color(0xFFEF4444); // Red
    Color reprColor = const Color(0xFF38BDF8); // Blue
    if (result.config.colorScheme == 'Cyan/Orange') {
      meanColor = Colors.orangeAccent;
      reprColor = Colors.cyanAccent;
    } else if (result.config.colorScheme == 'Green/Magenta') {
      meanColor = Colors.greenAccent;
      reprColor = Colors.purpleAccent;
    }

    final vmax = math.max(result.maxAbsT, 1.0);

    for (var sIdx = 0; sIdx < sessions.length; sIdx++) {
      final sess = sessions[sIdx];
      final segLeft = layout.sessionLeft[sIdx];
      final segWidth = layout.sessionWidth[sIdx];
      final nCols = layout.sessionCols[sIdx];
      final lineRect = Rect.fromLTWH(segLeft, padT, segWidth, lineH);

      canvas.drawRect(lineRect, Paint()..color = const Color(0xFF0F172A));
      canvas.drawRect(lineRect, Paint()..color = Colors.white12..style = PaintingStyle.stroke);

      // Session Header Title (Centered above each column block)
      final tpSess = TextPainter(
        text: TextSpan(
          text: sess.sessionName,
          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '..',
      )..layout(maxWidth: math.max(24.0, segWidth + 10));
      tpSess.paint(canvas, Offset(lineRect.left + (lineRect.width - tpSess.width) / 2, padT - 18));

      if (sess.windows.isEmpty) {
        final tpTooLittle = TextPainter(
          text: const TextSpan(text: 'too little\ndata', style: TextStyle(color: Colors.white38, fontSize: 9)),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
        )..layout(maxWidth: segWidth);
        tpTooLittle.paint(
          canvas,
          Offset(lineRect.left + (segWidth - tpTooLittle.width) / 2,
              padT + lineH + topoH / 2 - tpTooLittle.height / 2),
        );
      }

      // Vertical dotted gridlines at each window boundary, aligning the
      // line-plot row with the topomap columns directly below it.
      final gridPaint = Paint()..color = Colors.white24..strokeWidth = 0.6;
      for (var w = 1; w < nCols; w++) {
        final gx = lineRect.left + w * topoSizePx;
        _drawDottedLine(canvas, Offset(gx, lineRect.top), Offset(gx, lineRect.bottom), gridPaint);
      }

      // Row 1: Mean Line & Dispersion Band, mapped into the SAME pixel box
      // used by this session's topomap column grid below.
      final nPts = sess.timeMin.length;
      final durationForScale = math.max(sess.durationMin, nCols * result.config.segmentDurationMin);
      double xForTime(double tv) => lineRect.left + (tv / durationForScale) * segWidth;

      if (nPts > 1) {
        final bandPath = Path();
        for (var i = 0; i < nPts; i++) {
          final px = xForTime(sess.timeMin[i]);
          final py = toY(sess.bandUpper[i]);
          if (i == 0) bandPath.moveTo(px, py); else bandPath.lineTo(px, py);
        }
        for (var i = nPts - 1; i >= 0; i--) {
          final px = xForTime(sess.timeMin[i]);
          final py = toY(sess.bandLower[i]);
          bandPath.lineTo(px, py);
        }
        bandPath.close();
        canvas.drawPath(bandPath, Paint()..color = Colors.white.withOpacity(0.12));

        final meanPath = Path();
        for (var i = 0; i < nPts; i++) {
          final px = xForTime(sess.timeMin[i]);
          final py = toY(sess.meanLine[i]);
          if (i == 0) meanPath.moveTo(px, py); else meanPath.lineTo(px, py);
        }
        canvas.drawPath(meanPath, Paint()..color = meanColor..strokeWidth = 1.3..style = PaintingStyle.stroke);

        if (sess.reprLine != null) {
          final reprPath = Path();
          for (var i = 0; i < nPts; i++) {
            final px = xForTime(sess.timeMin[i]);
            final py = toY(sess.reprLine![i]);
            if (i == 0) reprPath.moveTo(px, py); else reprPath.lineTo(px, py);
          }
          canvas.drawPath(reprPath, Paint()..color = reprColor..strokeWidth = 0.9..style = PaintingStyle.stroke);
        }
      }

      // X-Axis Subpanel Time Label (Bottom-right of line plot)
      final tpXTime = TextPainter(
        text: TextSpan(
          text: '${sess.durationMin.round()}m',
          style: const TextStyle(color: Colors.white54, fontSize: 8),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpXTime.paint(canvas, Offset(lineRect.right - tpXTime.width, lineRect.bottom + 2));

      // Row 2: one topomap per raw analysis window, uniform user-controlled size.
      final topoY = padT + lineH + 24;
      final r = math.max(8.0, math.min(topoSizePx * 0.42, topoH * 0.42));
      final labelStep = math.max(1, nCols ~/ 6);

      for (var wIdx = 0; wIdx < nCols; wIdx++) {
        final win = sess.windows[wIdx];
        final tx = lineRect.left + (wIdx + 0.5) * topoSizePx;
        final ty = topoY + topoH / 2;

        if (wIdx % labelStep == 0) {
          final tpWinLabel = TextPainter(
            text: TextSpan(
              text: win.timeLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.bold),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tpWinLabel.paint(canvas, Offset(tx - tpWinLabel.width / 2, topoY - 13));
        }

        if (win.isBaseline) {
          final baseW = math.max(topoSizePx - 6, 20.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(tx, ty), width: baseW, height: topoH - 6),
              const Radius.circular(4),
            ),
            Paint()..color = Colors.white12,
          );
          canvas.save();
          canvas.translate(tx, ty);
          canvas.rotate(-math.pi / 2);
          final tpBase = TextPainter(
            text: const TextSpan(text: 'baseline', style: TextStyle(color: Colors.white70, fontSize: 8, fontWeight: FontWeight.bold)),
            textDirection: TextDirection.ltr,
          )..layout();
          tpBase.paint(canvas, Offset(-tpBase.width / 2, -tpBase.height / 2));
          canvas.restore();
        } else if (!win.hasValidStats) {
          final tpNa = TextPainter(
            text: const TextSpan(text: 'n/a', style: TextStyle(color: Colors.white38, fontSize: 8)),
            textDirection: TextDirection.ltr,
          )..layout();
          tpNa.paint(canvas, Offset(tx - tpNa.width / 2, ty - tpNa.height / 2));
        } else {
          _paintTopomap(canvas, Offset(tx, ty), r, win, vmax, topoCmap);
        }
      }
    }

    _paintColorbar(canvas, size, layout, vmax, topoCmap);
  }

  void _paintTopomap(Canvas canvas, Offset center, double r, TopoWindowResult win, double vmax, String cmap) {
    final coords = <Offset>[
      for (final label in k1020ChannelNames)
        Offset(
          center.dx + get1020Coords(label).dx * r * 0.82,
          center.dy - get1020Coords(label).dy * r * 0.82,
        ),
    ];

    canvas.drawCircle(center, r, Paint()..color = const Color(0xFF0F172A));

    // Smooth inverse-distance-weighted scalp field, clipped to the head disc
    // -- replaces the old per-sensor radial-gradient blobs with a continuous
    // interpolated map, closer in spirit to mne.viz.plot_topomap's cubic
    // interpolation.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    const gridN = 28;
    final cell = (2 * r) / gridN;
    final cellPaint = Paint()..style = PaintingStyle.fill;
    for (var gy = 0; gy < gridN; gy++) {
      final py = center.dy - r + (gy + 0.5) * cell;
      for (var gx = 0; gx < gridN; gx++) {
        final px = center.dx - r + (gx + 0.5) * cell;
        final dx = px - center.dx;
        final dy = py - center.dy;
        if (dx * dx + dy * dy > r * r) continue;

        var wsum = 0.0;
        var vsum = 0.0;
        for (var c = 0; c < coords.length; c++) {
          final ddx = px - coords[c].dx;
          final ddy = py - coords[c].dy;
          final dist = math.sqrt(ddx * ddx + ddy * ddy);
          final w = 1.0 / math.pow(dist + 0.5, 2.2);
          wsum += w;
          vsum += w * win.tValues[c];
        }
        final val = wsum > 0 ? vsum / wsum : 0.0;
        cellPaint.color = _topoColor(val, vmax, cmap);
        canvas.drawRect(
          Rect.fromLTWH(px - cell / 2 - 0.4, py - cell / 2 - 0.4, cell + 0.8, cell + 0.8),
          cellPaint,
        );
      }
    }
    canvas.restore();

    // Dark electrode dots for all sensors; subtle tiny hollow ring for FDR-significant
    for (var c = 0; c < coords.length; c++) {
      canvas.drawCircle(coords[c], 0.8, Paint()..color = Colors.black87);
      if (win.significant[c]) {
        canvas.drawCircle(
          coords[c], 1.5,
          Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 0.8,
        );
      }
    }

    // Head outline: circle + nose + ears (publication-style scalp map chrome).
    final headStroke = Paint()
      ..color = Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, r, headStroke);

    final nosePath = Path()
      ..moveTo(center.dx - r * 0.12, center.dy - r)
      ..lineTo(center.dx, center.dy - r * 1.18)
      ..lineTo(center.dx + r * 0.12, center.dy - r);
    canvas.drawPath(nosePath, headStroke);

    final earH = r * 0.34;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(center.dx - r, center.dy), width: r * 0.24, height: earH),
      math.pi * 0.5, math.pi, false, headStroke,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(center.dx + r, center.dy), width: r * 0.24, height: earH),
      -math.pi * 0.5, math.pi, false, headStroke,
    );
  }

  Color _topoColor(double t, double vmax, String cmap) {
    if (vmax == 0 || t.isNaN) return Colors.white;
    final rawNorm = (t / vmax).clamp(-1.0, 1.0);
    final sign = rawNorm < 0 ? -1.0 : 1.0;
    final norm = sign * math.pow(rawNorm.abs(), 0.65);
    final ends = _cmapEndpoints(cmap);
    if (norm >= 0) return Color.lerp(Colors.white, ends.pos, norm)!;
    return Color.lerp(Colors.white, ends.neg, -norm)!;
  }

  ({Color neg, Color pos}) _cmapEndpoints(String cmap) {
    switch (cmap) {
      case 'CyanOrange':
        return (neg: const Color(0xFF0891B2), pos: const Color(0xFFEA580C));
      case 'GreenMagenta':
        return (neg: const Color(0xFF15803D), pos: const Color(0xFFA21CAF));
      case 'RdBu':
      default:
        return (neg: const Color(0xFF2166AC), pos: const Color(0xFFB2182B));
    }
  }

  void _paintColorbar(Canvas canvas, Size size, _TopoLayoutInfo layout, double vmax, String cmap) {
    final ends = _cmapEndpoints(cmap);
    const cbW = 14.0;
    final cbL = size.width - layout.padR + 20;
    final cbT = layout.padT + layout.lineH + 20;
    final cbH = math.max(layout.topoH - 10, 20.0);
    final cbRect = Rect.fromLTWH(cbL, cbT, cbW, cbH);

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        ends.pos,
        Color.lerp(Colors.white, ends.pos, 0.5)!,
        Colors.white,
        Color.lerp(Colors.white, ends.neg, 0.5)!,
        ends.neg,
      ],
    );
    canvas.drawRect(cbRect, Paint()..shader = gradient.createShader(cbRect));
    canvas.drawRect(cbRect, Paint()..color = Colors.white30..style = PaintingStyle.stroke);

    void label(String text, double y) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Colors.white70, fontSize: 8)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cbL + cbW + 4, y - tp.height / 2));
    }

    label('+${vmax.toStringAsFixed(1)}', cbT);
    label('0.0', cbT + cbH / 2);
    label('-${vmax.toStringAsFixed(1)}', cbT + cbH);

    final tpTitle = TextPainter(
      text: const TextSpan(
        text: 't-value\nvs baseline',
        style: TextStyle(color: Colors.white54, fontSize: 8, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: 60);
    tpTitle.paint(canvas, Offset(cbL - 6, cbT - 26));
  }

  void _drawDottedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLen = 3.0;
    const gapLen = 3.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var dist = 0.0;
    var draw = true;
    while (dist < total) {
      final segLen = draw ? dashLen : gapLen;
      final next = math.min(dist + segLen, total);
      if (draw) {
        canvas.drawLine(a + dir * dist, a + dir * next, paint);
      }
      dist = next;
      draw = !draw;
    }
  }

  @override
  bool shouldRepaint(covariant _TopoStatsGridPainter oldDelegate) =>
      oldDelegate.result != result ||
      oldDelegate.topoSizePx != topoSizePx ||
      oldDelegate.topoCmap != topoCmap;
}
