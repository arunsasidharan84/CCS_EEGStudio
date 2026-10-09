// lib/src/topostats/topostats_engine.dart
//
// Data + statistics pipeline of PlotFeaturesTopoStats_20260801.py, ported
// to pure Dart (no dart:ui, so it can run in a background isolate).
//
// Every step mirrors the reference script:
//   * file discovery `*_{rec_ID}_*.features.csv`, sorted by path
//   * clean_segment_name(): strip `^\d+[a-zA-Z]?_{rec_ID}_` and suffix
//   * feature_matrix(): pd.to_numeric(errors='coerce') + pivot_table(mean)
//     (all-NaN epochs dropped, missing channels -> NaN), sorted by Epoch,
//     t = Epoch * epoch_size / 60  (NOT re-based to 0)
//   * nanmean / nanstd(ddof=1) / SEM / 95% CI across channels
//   * pandas rolling(window, center=True, min_periods=1).mean()
//   * equal-length windows from t = 0, trailing remainder dropped
//   * baseline window snapped to the analysis grid
//   * e-TFCE permutation test per window (see etfce.dart)
//   * BH-FDR over 'feature' | 'session' | 'none'
//   * colour limit = max |t_obs| (auto, >= 1) unless fixed

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'etfce.dart';
import 'mne_constants.dart';
import 'topo_interp.dart' show buildChannelAdjacency;

export 'etfce.dart' show TfceFormula;

/// The feature list of the reference script (plotted in this order by
/// "export all").
const List<String> kReferenceFeatureList = [
  'Delta_Irasa',
  'Theta_Irasa',
  'ThetaAlpha_Irasa',
  'Alpha_Irasa',
  'Beta1_Irasa',
  'Beta2_Irasa',
  'Gamma1_Irasa',
  'intercept_Irasa',
  'slope_Irasa',
  'auc_Irasa',
  'oscspectraledge_Irasa',
  'perm_entropy_nonlinear',
  'svd_entropy_nonlinear',
  'sample_entropy_nonlinear',
  'dfa_nonlinear',
  'petrosian_nonlinear',
  'katz_nonlinear',
  'higuchi_nonlinear',
  'lziv_nonlinear',
  'ACW',
  'conn_wpli_Theta',
  'conn_wpli_ThetaAlpha',
  'conn_wpli_Alpha',
  'conn_wpli_Beta1',
  'conn_wpli_Beta2',
  'conn_wpli_Gamma1',
];

/// Metadata columns that are never features.
const Set<String> kTopoMetaColumns = {
  'Chan',
  'Epoch',
  'epoch_label',
  'filename',
  'subjid',
  'sessn',
  'condn',
  'bin_idx',
  'bin_start_s',
  'bin_end_s',
  'mode',
};

/// User settings -- names and defaults follow the script's USER SETTINGS.
class TopoStatsSettings {
  const TopoStatsSettings({
    this.recId = '',
    this.feature = 'Gamma1_Irasa',
    this.epochSize = 2.0,
    this.windowSize = 25,
    this.channels = kDefault32Channels,
    this.reprChan = 'Fz',
    this.shadeMetric = 'ci95',
    this.segmentDurationMin = 2.0,
    this.targetTopoWidthIn = 0.5,
    this.sessionGapFrac = 0.5,
    this.sigMarkerSize = 1.6,
    this.sigMarkerEdgeWidth = 0.45,
    this.baselineSession = 'EO_EC_AT_VP',
    this.baselineTmin = 0.0,
    this.baselineDurationMin = 2.0,
    this.nPermutations = 500,
    this.tfceStart = 0.0,
    this.tfceStep = 0.2,
    this.randomSeed = 42,
    this.tfceFormula = TfceFormula.legacy,
    this.fdrScope = 'feature',
    this.alpha = 0.05,
    this.topoCmap = 'RdBu_r',
    this.topoVabs,
    this.topoValue = TopoValue.tfce,
    this.dpi = 200,
  });

  final String recId;
  final String feature;
  final double epochSize;
  final int windowSize;
  final List<String> channels;
  final String? reprChan; // null => none
  final String shadeMetric; // sd | sem | ci95
  final double segmentDurationMin;
  final double targetTopoWidthIn;
  final double sessionGapFrac;
  final double sigMarkerSize;
  final double sigMarkerEdgeWidth;
  final String baselineSession;
  final double baselineTmin;
  final double baselineDurationMin;
  final int nPermutations;
  final double tfceStart;
  final double tfceStep;
  final int randomSeed;
  final TfceFormula tfceFormula;
  final String fdrScope; // feature | session | none
  final double alpha;
  final String topoCmap;
  final double? topoVabs;
  final TopoValue topoValue;
  final int dpi;

  TopoStatsSettings copyWith({
    String? recId,
    String? feature,
    double? epochSize,
    int? windowSize,
    List<String>? channels,
    Object? reprChan = _keep,
    String? shadeMetric,
    double? segmentDurationMin,
    double? targetTopoWidthIn,
    double? sessionGapFrac,
    String? baselineSession,
    double? baselineTmin,
    double? baselineDurationMin,
    int? nPermutations,
    double? tfceStart,
    double? tfceStep,
    int? randomSeed,
    TfceFormula? tfceFormula,
    String? fdrScope,
    double? alpha,
    String? topoCmap,
    Object? topoVabs = _keep,
    TopoValue? topoValue,
    int? dpi,
  }) {
    return TopoStatsSettings(
      recId: recId ?? this.recId,
      feature: feature ?? this.feature,
      epochSize: epochSize ?? this.epochSize,
      windowSize: windowSize ?? this.windowSize,
      channels: channels ?? this.channels,
      reprChan: identical(reprChan, _keep)
          ? this.reprChan
          : reprChan as String?,
      shadeMetric: shadeMetric ?? this.shadeMetric,
      segmentDurationMin: segmentDurationMin ?? this.segmentDurationMin,
      targetTopoWidthIn: targetTopoWidthIn ?? this.targetTopoWidthIn,
      sessionGapFrac: sessionGapFrac ?? this.sessionGapFrac,
      sigMarkerSize: sigMarkerSize,
      sigMarkerEdgeWidth: sigMarkerEdgeWidth,
      baselineSession: baselineSession ?? this.baselineSession,
      baselineTmin: baselineTmin ?? this.baselineTmin,
      baselineDurationMin: baselineDurationMin ?? this.baselineDurationMin,
      nPermutations: nPermutations ?? this.nPermutations,
      tfceStart: tfceStart ?? this.tfceStart,
      tfceStep: tfceStep ?? this.tfceStep,
      randomSeed: randomSeed ?? this.randomSeed,
      tfceFormula: tfceFormula ?? this.tfceFormula,
      fdrScope: fdrScope ?? this.fdrScope,
      alpha: alpha ?? this.alpha,
      topoCmap: topoCmap ?? this.topoCmap,
      topoVabs: identical(topoVabs, _keep)
          ? this.topoVabs
          : topoVabs as double?,
      topoValue: topoValue ?? this.topoValue,
      dpi: dpi ?? this.dpi,
    );
  }

  /// Stats-relevant fingerprint (used to cache results).
  String statsKey(List<String> files) => [
    files.join('|'),
    recId,
    feature,
    epochSize,
    windowSize,
    channels.join(','),
    reprChan,
    shadeMetric,
    segmentDurationMin,
    baselineSession,
    baselineTmin,
    baselineDurationMin,
    nPermutations,
    tfceStart,
    tfceStep,
    randomSeed,
    tfceFormula.name,
    fdrScope,
    alpha,
  ].join('#');
}

const Object _keep = Object();

/// What the topomaps are coloured by.
enum TopoValue {
  /// The value the reference script plots: MNE's returned t_obs, which for
  /// a TFCE threshold is the signed TFCE-enhanced statistic.
  tfce,

  /// Raw Welch t (not what the script shows; offered for inspection).
  rawT,
}

// ─────────────────────────────────────────────────────────────────────────
//  Results
// ─────────────────────────────────────────────────────────────────────────

class TopoWindow {
  TopoWindow({
    required this.tStart,
    required this.tEnd,
    required this.isBaseline,
    this.tObs,
    this.rawT,
    this.pValues,
    this.nTest = 0,
  });

  final double tStart;
  final double tEnd;
  final bool isBaseline;
  final Float64List? tObs; // null => n/a (too few epochs)
  final Float64List? rawT;
  final Float64List? pValues;
  Float64List? qValues;
  List<bool>? significant;
  final int nTest;

  bool get hasStats =>
      !isBaseline && tObs != null && tObs!.every((v) => v.isFinite);

  Map<String, Object?> toJson() => {
    't_start': tStart,
    't_end': tEnd,
    'is_baseline': isBaseline,
    if (tObs != null) 't_obs': tObs,
    if (rawT != null) 't_raw': rawT,
    if (pValues != null) 'p': pValues,
    if (qValues != null) 'q': qValues,
    if (significant != null) 'sig': significant,
  };
}

class TopoSession {
  TopoSession({
    required this.name,
    required this.path,
    required this.tMin,
    required this.mean,
    required this.band,
    required this.repr,
    required this.windows,
    required this.matrix,
  });

  final String name;
  final String path;
  final Float64List tMin;
  final Float64List mean; // smoothed
  final Float64List band; // smoothed dispersion
  final Float64List? repr; // smoothed representative channel
  final List<TopoWindow> windows;

  /// Raw (epochs x channels) matrix, row-major. Kept for tooltips/export.
  final Float64List matrix;

  /// Line-plot x-limit (max time, >= 0.5 min).
  double get durationMin {
    if (tMin.isEmpty) return 1.0;
    var m = tMin.first;
    for (final t in tMin) {
      if (t > m) m = t;
    }
    return math.max(m, 0.5);
  }
}

class TopoStatsResult {
  TopoStatsResult({
    required this.settings,
    required this.sessions,
    required this.baselineIndex,
    required this.baselineTmin,
    required this.baselineTmax,
    required this.yMin,
    required this.yMax,
    required this.vmax,
    required this.log,
  });

  final TopoStatsSettings settings;
  final List<TopoSession> sessions;
  final int baselineIndex;
  final double baselineTmin;
  final double baselineTmax;
  final double yMin;
  final double yMax;
  final double vmax;
  final List<String> log;

  String get baselineName => sessions[baselineIndex].name;

  /// Same statistics, different display settings (colour source, colormap,
  /// fixed limit, topomap size, dpi). Recomputes the colour limit.
  TopoStatsResult withDisplay(TopoStatsSettings display) {
    final s = settings.copyWith(
      topoValue: display.topoValue,
      topoCmap: display.topoCmap,
      topoVabs: display.topoVabs,
      targetTopoWidthIn: display.targetTopoWidthIn,
      dpi: display.dpi,
    );
    return TopoStatsResult(
      settings: s,
      sessions: sessions,
      baselineIndex: baselineIndex,
      baselineTmin: baselineTmin,
      baselineTmax: baselineTmax,
      yMin: yMin,
      yMax: yMax,
      vmax: autoVmax(sessions, s),
      log: log,
    );
  }

  int get totalWindows => sessions.fold(0, (a, s) => a + s.windows.length);

  /// fig.suptitle(...) text, character for character.
  String get suptitle {
    final s = settings;
    return '${s.recId} | ${s.feature} | mean across ${s.channels.length} channels | '
        '${pyFloat(s.segmentDurationMin)}-min windows | baseline: $baselineName '
        '[${pyFloat(baselineTmin)}-${pyFloat(baselineTmax)} min] | '
        'e-TFCE + BH-FDR (${s.fdrScope}), n_perm=${s.nPermutations}, '
        'α=${pyFloat(s.alpha)}';
  }

  String get outputFileName =>
      '${settings.recId}_${settings.feature}_meanChan_TopoStats';

  /// Tidy per-(session, window, channel) stats table.
  String toCsv() {
    final b = StringBuffer(
      'session,t_start_min,t_end_min,is_baseline,channel,t_obs,t_raw,p,q,significant\n',
    );
    for (final s in sessions) {
      for (final w in s.windows) {
        for (var c = 0; c < settings.channels.length; c++) {
          String f(Float64List? v) =>
              v == null || v[c].isNaN ? '' : v[c].toString();
          b.writeln(
            [
              s.name,
              w.tStart,
              w.tEnd,
              w.isBaseline,
              settings.channels[c],
              f(w.tObs),
              f(w.rawT),
              f(w.pValues),
              f(w.qValues),
              w.significant == null ? '' : w.significant![c],
            ].join(','),
          );
        }
      }
    }
    return b.toString();
  }
}

/// Python `str(float)` for the values that appear in the title.
String pyFloat(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e16) return '${v.toInt()}.0';
  return v.toString();
}

// ─────────────────────────────────────────────────────────────────────────
//  File discovery / naming
// ─────────────────────────────────────────────────────────────────────────

/// Keeps the baseline attached to a selected session after selection changes.
TopoStatsSettings settingsForSessions(
  TopoStatsSettings settings,
  List<String> names,
) {
  if (names.isEmpty ||
      names.any((name) => name.contains(settings.baselineSession))) {
    return settings;
  }
  return settings.copyWith(baselineSession: names.first);
}

String _baseName(String p) => p.split(RegExp(r'[\\/]')).last;

/// Guesses rec_ID from a set of `<idx>_<recId>_<segment>.features.csv`
/// names: the longest common `_`-delimited prefix after the index.
String inferRecId(List<String> paths) {
  final stems = [
    for (final p in paths)
      _baseName(p)
          .replaceAll(RegExp(r'\.features\.csv$'), '')
          .replaceFirst(RegExp(r'^\d+[a-zA-Z]?_'), ''),
  ];
  if (stems.isEmpty) return '';
  if (stems.length == 1) {
    // Best effort: "<name>_<dd.mm.yyyy>_<segment>" -> up to the date token.
    final m = RegExp(
      r'^(.*?\d{1,2}\.\d{1,2}\.\d{2,4})_',
    ).firstMatch(stems.first);
    if (m != null) return m.group(1)!;
    final i = stems.first.lastIndexOf('_');
    return i > 0 ? stems.first.substring(0, i) : stems.first;
  }
  final parts = stems.map((s) => s.split('_')).toList();
  final common = <String>[];
  for (var i = 0; ; i++) {
    if (parts.any((p) => i >= p.length - 1)) break; // keep >=1 segment token
    final tok = parts.first[i];
    if (parts.every((p) => p[i] == tok)) {
      common.add(tok);
    } else {
      break;
    }
  }
  return common.join('_');
}

/// Script's clean_segment_name().
String cleanSegmentName(String fileName, String recId) {
  var name = fileName.replaceAll('.features.csv', '');
  name = name.replaceFirst(
    RegExp('^\\d+[a-zA-Z]?_${RegExp.escape(recId)}_'),
    '',
  );
  return name;
}

/// Sibling files matching `*_{recId}_*.features.csv`, sorted like
/// Python's sorted(glob(...)).
List<String> discoverSessionFiles(String dir, String recId) {
  final d = Directory(dir);
  if (!d.existsSync()) return [];
  final re = RegExp('_${RegExp.escape(recId)}_.*\\.features\\.csv\$');
  final out =
      d
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => re.hasMatch(_baseName(p)) && _baseName(p).contains('_'))
          .toList()
        ..sort();
  return out;
}

/// Reads just the header of a features CSV.
List<String> readCsvHeader(String path) {
  final raf = File(path).openSync();
  try {
    final bytes = <int>[];
    while (true) {
      final b = raf.readByteSync();
      if (b == -1 || b == 10) break;
      if (b != 13) bytes.add(b);
      if (bytes.length > 1 << 20) break;
    }
    return splitFeatureCsvLine(
      String.fromCharCodes(bytes),
    ).map((s) => s.trim()).toList();
  } finally {
    raf.closeSync();
  }
}

List<String> splitFeatureCsvLine(String line) {
  if (!line.contains('"')) return line.split(',');
  final out = <String>[];
  final buf = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (q && i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
      } else {
        q = !q;
      }
    } else if (c == ',' && !q) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

/// pd.to_numeric(errors='coerce') for the values found in feature CSVs.
double _toNumeric(String s) {
  final t = s.trim();
  if (t.isEmpty) return double.nan;
  final v = double.tryParse(t);
  if (v != null) return v;
  switch (t.toLowerCase()) {
    case 'inf':
    case '+inf':
    case 'infinity':
      return double.infinity;
    case '-inf':
    case '-infinity':
      return double.negativeInfinity;
  }
  return double.nan;
}

/// One session parsed for a set of features: epochs sorted, per feature a
/// (nEpochs x nCh) matrix aligned to [channels].
class ParsedSession {
  ParsedSession(this.path, this.epochs, this.values);
  final String path;

  /// feature -> sorted epoch numbers (after dropping all-NaN epochs).
  final Map<String, List<int>> epochs;

  /// feature -> row-major matrix (epochs x channels).
  final Map<String, Float64List> values;
}

/// Parses [path] extracting [features] only. Works on raw bytes so large
/// session files (80+ MB) are scanned without materialising every field.
ParsedSession parseFeatureCsv(
  String path,
  List<String> features,
  List<String> channels,
) {
  final bytes = File(path).readAsBytesSync();
  final n = bytes.length;
  var pos = 0;

  // Returns [start, end) of the next line (without \r\n), or null at EOF.
  (int, int)? nextLine() {
    if (pos >= n) return null;
    final s0 = pos;
    var e = s0;
    while (e < n && bytes[e] != 10) {
      e++;
    }
    pos = e + 1;
    var end = e;
    if (end > s0 && bytes[end - 1] == 13) end--;
    return (s0, end);
  }

  final first = nextLine();
  if (first == null) throw FormatException('Empty CSV: $path');
  final header = splitFeatureCsvLine(
    String.fromCharCodes(bytes, first.$1, first.$2),
  ).map((h) => h.trim()).toList();
  final iChan = header.indexOf('Chan');
  final iEpoch = header.indexOf('Epoch');
  if (iChan < 0 || iEpoch < 0) {
    throw FormatException('CSV missing Chan/Epoch columns: $path');
  }
  final featIdx = <String, int>{};
  for (final f in features) {
    final i = header.indexOf(f);
    if (i >= 0) featIdx[f] = i;
  }
  final chIndex = {for (var i = 0; i < channels.length; i++) channels[i]: i};
  final nCh = channels.length;
  final featNames = featIdx.keys.toList();
  final featCols = [for (final f in featNames) featIdx[f]!];
  var maxCol = math.max(iChan, iEpoch);
  for (final c in featCols) {
    maxCol = math.max(maxCol, c);
  }

  // epoch -> per-feature per-channel (sum, count) for pivot_table(mean)
  final sums = [for (final _ in featNames) <int, Float64List>{}];
  final counts = [for (final _ in featNames) <int, Int32List>{}];
  final starts = List<int>.filled(maxCol + 2, 0);
  final ends = List<int>.filled(maxCol + 2, 0);

  while (true) {
    final ln = nextLine();
    if (ln == null) break;
    final (a, b) = ln;
    if (b <= a) continue;
    List<String>? quoted;
    var nFields = 0;
    // locate the first maxCol+1 fields
    var fs = a;
    var hasQuote = false;
    for (var k = a; k < b; k++) {
      final ch = bytes[k];
      if (ch == 34) {
        hasQuote = true;
        break;
      }
      if (ch == 44) {
        if (nFields <= maxCol) {
          starts[nFields] = fs;
          ends[nFields] = k;
        }
        nFields++;
        fs = k + 1;
        if (nFields > maxCol) break;
      }
    }
    if (hasQuote) {
      quoted = splitFeatureCsvLine(String.fromCharCodes(bytes, a, b));
      nFields = quoted.length;
    } else if (nFields <= maxCol) {
      starts[nFields] = fs;
      ends[nFields] = b;
      nFields++;
    }
    final q = quoted;
    String field(int c) => q != null
        ? (c < q.length ? q[c] : '')
        : String.fromCharCodes(bytes, starts[c], ends[c]);
    if (nFields <= iChan || nFields <= iEpoch) continue;
    final ci = chIndex[field(iChan).trim()];
    if (ci == null) continue;
    final ev = double.tryParse(field(iEpoch).trim());
    if (ev == null) continue;
    final epoch = ev.round();
    for (var fi = 0; fi < featNames.length; fi++) {
      final col = featCols[fi];
      if (col >= nFields) continue;
      final v = _toNumeric(field(col));
      if (v.isNaN) continue; // pivot mean skips NaN
      final sm = sums[fi].putIfAbsent(epoch, () => Float64List(nCh));
      final ct = counts[fi].putIfAbsent(epoch, () => Int32List(nCh));
      sm[ci] += v;
      ct[ci] += 1;
    }
  }

  final epochsOut = <String, List<int>>{};
  final valuesOut = <String, Float64List>{};
  for (var fi = 0; fi < featNames.length; fi++) {
    // pivot_table(dropna=True): epochs whose values are all NaN vanish.
    final ep = sums[fi].keys.toList()..sort();
    final m = Float64List(ep.length * nCh);
    for (var r = 0; r < ep.length; r++) {
      final sm = sums[fi][ep[r]]!;
      final ct = counts[fi][ep[r]]!;
      for (var ch = 0; ch < nCh; ch++) {
        m[r * nCh + ch] = ct[ch] == 0 ? double.nan : sm[ch] / ct[ch];
      }
    }
    epochsOut[featNames[fi]] = ep;
    valuesOut[featNames[fi]] = m;
  }
  return ParsedSession(path, epochsOut, valuesOut);
}

/// Channel labels used in a features CSV. Returns the script's 32-channel
/// order when the file uses exactly that cap, otherwise the labels in order
/// of first appearance (restricted to channels with standard_1020 positions
/// by the caller).
List<String> detectChannels(String path, {int maxLines = 5000}) {
  final raf = File(path).openSync();
  try {
    final chunk = raf.readSync(4 << 20);
    final text = String.fromCharCodes(chunk);
    final lines = text.split('\n');
    if (lines.isEmpty) return kDefault32Channels;
    final header = splitFeatureCsvLine(
      lines.first.replaceAll('\r', ''),
    ).map((h) => h.trim()).toList();
    final iChan = header.indexOf('Chan');
    if (iChan < 0) return kDefault32Channels;
    final seen = <String>[];
    for (var i = 1; i < lines.length - 1 && i < maxLines; i++) {
      final cols = splitFeatureCsvLine(lines[i].replaceAll('\r', ''));
      if (cols.length <= iChan) continue;
      final c = cols[iChan].trim();
      if (c.isNotEmpty && !seen.contains(c)) seen.add(c);
    }
    if (seen.length == kDefault32Channels.length &&
        seen.toSet().containsAll(kDefault32Channels)) {
      return kDefault32Channels;
    }
    return seen.isEmpty ? kDefault32Channels : seen;
  } finally {
    raf.closeSync();
  }
}

/// Numeric feature columns of a CSV (header minus metadata columns).
List<String> numericFeatureColumns(String path) => readCsvHeader(
  path,
).where((h) => h.isNotEmpty && !kTopoMetaColumns.contains(h)).toList();

// ─────────────────────────────────────────────────────────────────────────
//  Numerics helpers (numpy / pandas semantics)
// ─────────────────────────────────────────────────────────────────────────

/// pandas Series.rolling(window, center=True, min_periods=1).mean()
Float64List rollingCenterMean(Float64List x, int window) {
  final n = x.length;
  final out = Float64List(n);
  if (window <= 1) {
    out.setAll(0, x);
    return out;
  }
  final lo = window ~/ 2; // offsets i-lo .. i+hi
  final hi = (window - 1) ~/ 2;
  for (var i = 0; i < n; i++) {
    final a = math.max(0, i - lo);
    final b = math.min(n - 1, i + hi);
    var s = 0.0;
    var c = 0;
    for (var j = a; j <= b; j++) {
      final v = x[j];
      if (!v.isNaN) {
        s += v;
        c++;
      }
    }
    out[i] = c >= 1 ? s / c : double.nan;
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────
//  Main computation
// ─────────────────────────────────────────────────────────────────────────

typedef TopoProgress = void Function(double fraction, String message);

class TopoStatsException implements Exception {
  TopoStatsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runs the whole pipeline for one feature. [parsed] may be supplied (e.g.
/// when exporting many features from one parse); otherwise files are read.
TopoStatsResult computeTopoStats({
  required List<String> files,
  required TopoStatsSettings settings,
  Map<String, ParsedSession>? parsed,
  TopoProgress? onProgress,
}) {
  final s = settings;
  final log = <String>[];
  if (files.isEmpty)
    throw TopoStatsException('No *.features.csv files selected.');
  final chans = s.channels;
  final nCh = chans.length;
  final segNames = [
    for (final f in files) cleanSegmentName(_baseName(f), s.recId),
  ];

  final baselineIdx = segNames.indexWhere((n) => n.contains(s.baselineSession));
  if (baselineIdx < 0) {
    throw TopoStatsException(
      "BASELINE_SESSION='${s.baselineSession}' does not match any segment name: $segNames",
    );
  }

  final seg = s.segmentDurationMin;
  final bTmin = (s.baselineTmin / seg).roundToDouble() * seg;
  final nBaseWin = math.max(1, (s.baselineDurationMin / seg).round());
  final bDur = nBaseWin * seg;
  final bTmax = bTmin + bDur;
  if ((bTmin - s.baselineTmin).abs() > 1e-9 ||
      (bDur - s.baselineDurationMin).abs() > 1e-9) {
    log.add(
      'NOTE: snapped baseline window from [${s.baselineTmin}, '
      '${s.baselineTmin + s.baselineDurationMin}] to [$bTmin, $bTmax] min.',
    );
  }

  final graph = ChannelGraph(buildChannelAdjacency(chans));

  // ---- per-session line data + matrices --------------------------------
  final sessT = <Float64List>[];
  final sessMat = <Float64List>[];
  final sessMean = <Float64List>[];
  final sessBand = <Float64List>[];
  final sessRepr = <Float64List?>[];
  final reprIdx = s.reprChan == null ? -1 : chans.indexOf(s.reprChan!);

  for (var i = 0; i < files.length; i++) {
    onProgress?.call(0.02 + 0.08 * i / files.length, 'Reading ${segNames[i]}…');
    final p =
        parsed?[files[i]] ?? parseFeatureCsv(files[i], [s.feature], chans);
    final ep = p.epochs[s.feature];
    final m = p.values[s.feature];
    if (ep == null || m == null) {
      throw TopoStatsException(
        "Feature '${s.feature}' not found in ${_baseName(files[i])}",
      );
    }
    final n = ep.length;
    final t = Float64List(n);
    for (var r = 0; r < n; r++) {
      t[r] = ep[r] * s.epochSize / 60.0;
    }
    final mean = Float64List(n);
    final band = Float64List(n);
    for (var r = 0; r < n; r++) {
      var sum = 0.0;
      var cnt = 0;
      for (var c = 0; c < nCh; c++) {
        final v = m[r * nCh + c];
        if (!v.isNaN) {
          sum += v;
          cnt++;
        }
      }
      final mu = cnt > 0 ? sum / cnt : double.nan;
      mean[r] = mu;
      var ss = 0.0;
      for (var c = 0; c < nCh; c++) {
        final v = m[r * nCh + c];
        if (!v.isNaN) ss += (v - mu) * (v - mu);
      }
      final sd = cnt > 1 ? math.sqrt(ss / (cnt - 1)) : double.nan;
      final sem = sd / math.sqrt(math.max(cnt, 1).toDouble());
      band[r] = switch (s.shadeMetric) {
        'sd' => sd,
        'sem' => sem,
        _ => 1.96 * sem,
      };
    }
    Float64List? repr;
    if (reprIdx >= 0) {
      final raw = Float64List(n);
      for (var r = 0; r < n; r++) {
        raw[r] = m[r * nCh + reprIdx];
      }
      repr = rollingCenterMean(raw, s.windowSize);
    }
    sessT.add(t);
    sessMat.add(m);
    sessMean.add(rollingCenterMean(mean, s.windowSize));
    sessBand.add(rollingCenterMean(band, s.windowSize));
    sessRepr.add(repr);
  }

  // ---- baseline matrix ------------------------------------------------
  final bt = sessT[baselineIdx];
  var btMax = -double.infinity;
  for (final v in bt) {
    if (v > btMax) btMax = v;
  }
  if (bt.isEmpty || btMax < bTmax - 1e-9) {
    throw TopoStatsException(
      "BASELINE_SESSION='${segNames[baselineIdx]}' is shorter than the requested "
      'baseline window [$bTmin, $bTmax] min.',
    );
  }
  List<Float64List> rowsWhere(int si, bool Function(double t) keep) {
    final t = sessT[si];
    final m = sessMat[si];
    return [
      for (var r = 0; r < t.length; r++)
        if (keep(t[r])) Float64List.sublistView(m, r * nCh, (r + 1) * nCh),
    ];
  }

  final baseRows = rowsWhere(baselineIdx, (t) => t >= bTmin && t < bTmax);

  // ---- windows + e-TFCE ---------------------------------------------------
  final allWindows = <List<TopoWindow>>[];
  var totalTests = 0;
  final segDefs = <List<(double, double)>>[];
  for (var i = 0; i < files.length; i++) {
    final t = sessT[i];
    final defs = <(double, double)>[];
    if (t.isNotEmpty) {
      var end = -double.infinity;
      for (final v in t) {
        if (v > end) end = v;
      }
      var start = 0.0;
      while (start + seg <= end + 1e-9) {
        final stop = start + seg;
        defs.add((start, stop));
        start = stop;
      }
    }
    segDefs.add(defs);
    totalTests += defs.length;
  }

  var done = 0;
  for (var i = 0; i < files.length; i++) {
    final wins = <TopoWindow>[];
    for (final (t0, t1) in segDefs[i]) {
      final isBase = i == baselineIdx && !(t1 <= bTmin || t0 >= bTmax);
      done++;
      if (isBase) {
        wins.add(TopoWindow(tStart: t0, tEnd: t1, isBaseline: true));
        continue;
      }
      onProgress?.call(
        0.1 + 0.88 * done / math.max(totalTests, 1),
        'e-TFCE ${segNames[i]} ${t0.toStringAsFixed(0)}–${t1.toStringAsFixed(0)} min',
      );
      final testRows = rowsWhere(i, (t) => t >= t0 && t < t1);
      final r = runETfce(
        test: testRows,
        base: baseRows,
        graph: graph,
        nPermutations: s.nPermutations,
        seed: s.randomSeed,
        tfceStart: s.tfceStart,
        tfceStep: s.tfceStep,
        formula: s.tfceFormula,
      );
      wins.add(
        TopoWindow(
          tStart: t0,
          tEnd: t1,
          isBaseline: false,
          tObs: r?.tObs ?? (Float64List(nCh)..fillRange(0, nCh, double.nan)),
          rawT: r?.rawT,
          pValues:
              r?.pValues ?? (Float64List(nCh)..fillRange(0, nCh, double.nan)),
          nTest: testRows.length,
        ),
      );
    }
    allWindows.add(wins);
  }

  // ---- FDR ------------------------------------------------------------------
  bool valid(TopoWindow w) =>
      !w.isBaseline && w.pValues != null && w.pValues!.every((p) => p.isFinite);
  if (s.fdrScope == 'feature' || s.fdrScope == 'session') {
    final groups = <List<TopoWindow>>[];
    if (s.fdrScope == 'feature') {
      groups.add([for (final ws in allWindows) ...ws.where(valid)]);
    } else {
      for (final ws in allWindows) {
        groups.add(ws.where(valid).toList());
      }
    }
    for (final g in groups) {
      if (g.isEmpty) continue;
      final stack = <double>[for (final w in g) ...w.pValues!];
      final r = fdrBH(stack, s.alpha);
      var ptr = 0;
      for (final w in g) {
        final n = w.pValues!.length;
        w.qValues = Float64List.sublistView(r.q, ptr, ptr + n);
        w.significant = r.reject.sublist(ptr, ptr + n);
        ptr += n;
      }
    }
  } else {
    for (final ws in allWindows) {
      for (final w in ws.where(valid)) {
        w.qValues = w.pValues;
        w.significant = [for (final p in w.pValues!) p < s.alpha];
      }
    }
  }

  // ---- y-limits (mean ± band and the repr overlay) ---------------------------
  var gMin = double.infinity;
  var gMax = -double.infinity;
  for (var i = 0; i < files.length; i++) {
    final mean = sessMean[i];
    final band = sessBand[i];
    for (var r = 0; r < mean.length; r++) {
      final lo = mean[r] - band[r];
      final hi = mean[r] + band[r];
      if (!lo.isNaN) {
        gMin = math.min(gMin, lo);
        gMax = math.max(gMax, lo);
      }
      if (!hi.isNaN) {
        gMin = math.min(gMin, hi);
        gMax = math.max(gMax, hi);
      }
    }
    final rp = sessRepr[i];
    if (rp != null) {
      for (final v in rp) {
        if (!v.isNaN) {
          gMin = math.min(gMin, v);
          gMax = math.max(gMax, v);
        }
      }
    }
  }
  if (!gMin.isFinite || !gMax.isFinite) {
    gMin = 0;
    gMax = 1;
  }
  final pad = 0.05 * (gMax > gMin ? gMax - gMin : 1.0);
  gMin -= pad;
  gMax += pad;

  // ---- colour scale ---------------------------------------------------------
  final vmax = autoVmax(null, s, windows: allWindows);

  final sessions = <TopoSession>[
    for (var i = 0; i < files.length; i++)
      TopoSession(
        name: segNames[i],
        path: files[i],
        tMin: sessT[i],
        mean: sessMean[i],
        band: sessBand[i],
        repr: sessRepr[i],
        windows: allWindows[i],
        matrix: sessMat[i],
      ),
  ];
  final nSig = allWindows.fold<int>(
    0,
    (a, ws) =>
        a +
        ws.fold<int>(
          0,
          (b, w) => b + (w.significant?.where((x) => x).length ?? 0),
        ),
  );
  log.add(
    '${s.feature}: ${sessions.fold<int>(0, (a, x) => a + x.windows.length)} windows, '
    'colour scale ±${vmax.toStringAsFixed(1)}, $nSig significant channel-windows',
  );
  onProgress?.call(1.0, 'Done');
  return TopoStatsResult(
    settings: s,
    sessions: sessions,
    baselineIndex: baselineIdx,
    baselineTmin: bTmin,
    baselineTmax: bTmax,
    yMin: gMin,
    yMax: gMax,
    vmax: vmax,
    log: log,
  );
}

/// TOPO_VABS, or max |value| over all tested windows (>= 1), as the script.
double autoVmax(
  List<TopoSession>? sessions,
  TopoStatsSettings s, {
  List<List<TopoWindow>>? windows,
}) {
  if (s.topoVabs != null) return s.topoVabs!;
  final all = windows ?? [for (final x in sessions!) x.windows];
  var m = double.negativeInfinity;
  var anyChunk = false;
  for (final ws in all) {
    for (final w in ws) {
      if (w.isBaseline) continue;
      final src = s.topoValue == TopoValue.rawT ? w.rawT : w.tObs;
      if (src == null || !src.any((v) => v.isFinite)) continue;
      anyChunk = true;
      for (final v in src) {
        if (v.isFinite) m = math.max(m, v.abs());
      }
    }
  }
  return anyChunk ? math.max(m, 1.0) : 1.0;
}
