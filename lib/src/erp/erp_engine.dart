// lib/src/erp/erp_engine.dart
//
// Two-condition ERP analysis, a port of ThukdamStudy/scripts/compute_mmn_erp.py.
// For each epoched file (session) and one electrode it computes:
//   - per-epoch baseline correction over a pre-stimulus window
//   - condition means ± SEM, optionally Savitzky–Golay smoothed (31, 3)
//   - a cluster-based permutation test over the whole waveform (Welch t,
//     |t| > t.ppf(1 - α/2, nA + nB - 2), max cluster mass null, 1000 perms)
//   - Welch t, df, p and Cohen's d on the window-mean amplitude, with a
//     bootstrap 95 % CI of d
//   - a bootstrap distribution of the mismatch (B - A) in the window, for
//     comparing sessions (Cohen's d between the bootstrap distributions)
// Random numbers come from the numpy default_rng port with seed 42 (fresh
// generator per test, as in the script), so the numbers match the Python
// output.
//
// Pure Dart (no Flutter), so it can run in a background isolate.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ccseeg_reader.dart';
import 'np_random.dart';
import 'sci_stats.dart';

/// One experimental condition: the epochs whose label matches.
class ErpCondition {
  const ErpCondition({
    required this.name,
    this.markers = const [],
    this.pattern = '',
  });

  /// Display name (e.g. "Standard (S51)").
  final String name;

  /// Epoch labels/markers that belong to this condition (exact match after
  /// normalisation, e.g. "S 51" matches "Stimulus/S 51" and "S51").
  final List<String> markers;

  /// Optional extra regular expression (case-insensitive), e.g. r"\bS\s*51\b".
  final String pattern;

  bool get isEmpty => markers.isEmpty && pattern.trim().isEmpty;

  bool matches(String label) {
    final l = normaliseMarker(label);
    for (final m in markers) {
      final n = normaliseMarker(m);
      if (n.isEmpty) continue;
      if (l == n || l.endsWith('/$n')) return true;
      // "S 51" ~ "S51" ~ "Stimulus/S 51": token match on the code part
      if (_code(l) != null && _code(l) == _code(n)) return true;
    }
    final p = pattern.trim();
    if (p.isNotEmpty) {
      try {
        if (RegExp(p, caseSensitive: false).hasMatch(label)) return true;
      } catch (_) {
        if (label.toLowerCase().contains(p.toLowerCase())) return true;
      }
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'markers': markers,
    'pattern': pattern,
  };
  factory ErpCondition.fromJson(Map<String, dynamic> j) => ErpCondition(
    name: j['name'] as String? ?? '',
    markers: [
      for (final m in (j['markers'] as List? ?? const [])) m.toString(),
    ],
    pattern: j['pattern'] as String? ?? '',
  );
}

/// "Stimulus/S  51 " -> "stimulus/s 51"
String normaliseMarker(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Code part of a BrainVision-style marker: "stimulus/s 51" -> "s51".
String? _code(String n) {
  final last = n.split('/').last;
  final m = RegExp(r'^([a-z]+)\s*(\d+)$').firstMatch(last);
  if (m == null) return null;
  return '${m.group(1)}${int.parse(m.group(2)!)}';
}

class ErpSettings {
  const ErpSettings({
    this.electrode = 'Fz',
    this.condA = const ErpCondition(name: 'Standard (S51)', markers: ['S 51']),
    this.condB = const ErpCondition(name: 'Deviant (S52)', markers: ['S 52']),
    this.tmin = -0.5,
    this.tmax = 1.2,
    this.useFileEpochTimes = true,
    this.baselineStart = -0.2,
    this.baselineEnd = 0.0,
    this.winStart = 0.10,
    this.winEnd = 0.25,
    this.nPerm = 1000,
    this.nBoot = 2000,
    this.clusterAlpha = 0.05,
    this.alpha = 0.05,
    this.seed = 42,
    this.smooth = true,
    this.smoothWindow = 31,
    this.smoothOrder = 3,
    this.componentName = 'MMN',
  });

  final String electrode;
  final ErpCondition condA, condB;

  /// Epoch start/end (s). Used when the file does not store its own epoch
  /// times, or when [useFileEpochTimes] is false.
  final double tmin, tmax;
  final bool useFileEpochTimes;
  final double baselineStart, baselineEnd;
  final double winStart, winEnd;
  final int nPerm, nBoot;
  final double clusterAlpha, alpha;
  final int seed;
  final bool smooth;
  final int smoothWindow, smoothOrder;

  /// Label of the component window in figures ("MMN window 100–250 ms").
  final String componentName;

  ErpSettings copyWith({
    String? electrode,
    ErpCondition? condA,
    ErpCondition? condB,
    double? tmin,
    double? tmax,
    bool? useFileEpochTimes,
    double? baselineStart,
    double? baselineEnd,
    double? winStart,
    double? winEnd,
    int? nPerm,
    int? nBoot,
    double? clusterAlpha,
    double? alpha,
    int? seed,
    bool? smooth,
    int? smoothWindow,
    int? smoothOrder,
    String? componentName,
  }) => ErpSettings(
    electrode: electrode ?? this.electrode,
    condA: condA ?? this.condA,
    condB: condB ?? this.condB,
    tmin: tmin ?? this.tmin,
    tmax: tmax ?? this.tmax,
    useFileEpochTimes: useFileEpochTimes ?? this.useFileEpochTimes,
    baselineStart: baselineStart ?? this.baselineStart,
    baselineEnd: baselineEnd ?? this.baselineEnd,
    winStart: winStart ?? this.winStart,
    winEnd: winEnd ?? this.winEnd,
    nPerm: nPerm ?? this.nPerm,
    nBoot: nBoot ?? this.nBoot,
    clusterAlpha: clusterAlpha ?? this.clusterAlpha,
    alpha: alpha ?? this.alpha,
    seed: seed ?? this.seed,
    smooth: smooth ?? this.smooth,
    smoothWindow: smoothWindow ?? this.smoothWindow,
    smoothOrder: smoothOrder ?? this.smoothOrder,
    componentName: componentName ?? this.componentName,
  );

  factory ErpSettings.fromJson(Map<String, dynamic> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    List<double> pair(String k, List<double> def) => [
      for (final v in (j[k] as List? ?? def)) (v as num).toDouble(),
    ];
    final b = pair('baseline', const [-0.2, 0.0]);
    final w = pair('window', const [0.10, 0.25]);
    return ErpSettings(
      electrode: j['electrode'] as String? ?? 'Fz',
      condA: j['cond_a'] == null
          ? const ErpCondition(name: 'Standard (S51)', markers: ['S 51'])
          : ErpCondition.fromJson((j['cond_a'] as Map).cast<String, dynamic>()),
      condB: j['cond_b'] == null
          ? const ErpCondition(name: 'Deviant (S52)', markers: ['S 52'])
          : ErpCondition.fromJson((j['cond_b'] as Map).cast<String, dynamic>()),
      tmin: d('tmin', -0.5),
      tmax: d('tmax', 1.2),
      useFileEpochTimes: j['use_file_epoch_times'] as bool? ?? true,
      baselineStart: b[0],
      baselineEnd: b[1],
      winStart: w[0],
      winEnd: w[1],
      nPerm: (j['n_perm'] as num?)?.toInt() ?? 1000,
      nBoot: (j['n_boot'] as num?)?.toInt() ?? 2000,
      clusterAlpha: d('cluster_alpha', 0.05),
      alpha: d('alpha', 0.05),
      seed: (j['seed'] as num?)?.toInt() ?? 42,
      smooth: j['smooth'] as bool? ?? true,
      smoothWindow: (j['smooth_window'] as num?)?.toInt() ?? 31,
      smoothOrder: (j['smooth_order'] as num?)?.toInt() ?? 3,
      componentName: j['component'] as String? ?? 'MMN',
    );
  }

  Map<String, dynamic> toJson() => {
    'electrode': electrode,
    'cond_a': condA.toJson(),
    'cond_b': condB.toJson(),
    'tmin': tmin,
    'tmax': tmax,
    'use_file_epoch_times': useFileEpochTimes,
    'baseline': [baselineStart, baselineEnd],
    'window': [winStart, winEnd],
    'n_perm': nPerm,
    'n_boot': nBoot,
    'cluster_alpha': clusterAlpha,
    'alpha': alpha,
    'seed': seed,
    'smooth': smooth,
    'smooth_window': smoothWindow,
    'smooth_order': smoothOrder,
    'component': componentName,
  };
}

class ErpCluster {
  const ErpCluster(
    this.startIdx,
    this.endIdx,
    this.mass,
    this.sign,
    this.pValue,
  );
  final int startIdx, endIdx; // end exclusive
  final double mass, sign, pValue;
}

/// Epochs of one electrode in one file, split by condition.
class ErpEpochs {
  ErpEpochs({
    required this.fileLabel,
    required this.path,
    required this.times,
    required this.a,
    required this.b,
    required this.warnings,
  });
  final String fileLabel, path;
  final Float64List times;
  final List<Float64List> a, b; // baseline-corrected
  final List<String> warnings;
}

class ErpFileResult {
  ErpFileResult({
    required this.fileLabel,
    required this.path,
    required this.times,
    required this.aMean,
    required this.aSem,
    required this.bMean,
    required this.bSem,
    required this.nA,
    required this.nB,
    required this.tObs,
    required this.tThresh,
    required this.clusters,
    required this.tWindow,
    required this.pWindow,
    required this.dWindow,
    required this.dfWindow,
    required this.dBootLo,
    required this.dBootHi,
    required this.mismatchBoot,
    required this.mismatchMean,
    required this.mismatchLo,
    required this.mismatchHi,
    required this.aWindowMean,
    required this.bWindowMean,
    required this.warnings,
  });

  final String fileLabel, path;
  final Float64List times, aMean, aSem, bMean, bSem, tObs;
  final int nA, nB;
  final double tThresh;
  final List<ErpCluster> clusters;
  final double tWindow, pWindow, dWindow, dfWindow, dBootLo, dBootHi;
  final Float64List mismatchBoot;
  final double mismatchMean, mismatchLo, mismatchHi;

  /// Window mean of the (plotted, i.e. smoothed) condition means, as in the
  /// script's CSV (std_window_mean_uV / dev_window_mean_uV).
  final double aWindowMean, bWindowMean;
  final List<String> warnings;

  List<ErpCluster> significant(double alpha) => [
    for (final c in clusters)
      if (c.pValue <= alpha) c,
  ];
}

class ErpBetween {
  const ErpBetween(this.i, this.j, this.d);
  final int i, j;
  final double d;
}

class ErpAnalysis {
  ErpAnalysis(this.settings, this.results, this.between);
  final ErpSettings settings;
  final List<ErpFileResult> results;
  final List<ErpBetween> between;
}

/// Scalp-wide condition summaries for the configured component window.
/// Values are pooled across the selected sessions at the epoch level.
class ErpTopoResult {
  ErpTopoResult({
    required this.labels,
    required this.windowA,
    required this.windowB,
    required this.windowT,
    required this.windowP,
    required this.pointA,
    required this.pointB,
    required this.pointT,
    required this.pointP,
    required this.pointSeconds,
    required this.nA,
    required this.nB,
  });

  final List<String> labels;
  final List<double> windowA, windowB, windowT, windowP;
  final List<double> pointA, pointB, pointT, pointP;
  final double pointSeconds;
  final List<int> nA, nB;
}

/// Summary of the markers found in a set of epoched files.
class ErpMarkerInventory {
  ErpMarkerInventory(
    this.counts,
    this.labels,
    this.tmin,
    this.tmax,
    this.sampleRate,
    this.samplesPerEpoch,
  );
  final Map<String, int> counts;
  final List<String> labels;
  final double? tmin, tmax, sampleRate;
  final int? samplesPerEpoch;
}

class ErpEngine {
  /// Loads an epoched ccseeg file. Only [electrodes] are parsed (all when
  /// null).
  static CcsEegData load(String path, {Set<String>? electrodes}) {
    final up = electrodes?.map((e) => e.toUpperCase()).toSet();
    return CcsEegData.read(
      path,
      keepChannel: up == null ? null : (l) => up.contains(l.toUpperCase()),
    );
  }

  static ErpMarkerInventory inventory(List<CcsEegData> files) {
    final counts = <String, int>{};
    for (final f in files) {
      for (final l in f.epochLabels ?? const <String>[]) {
        counts[l] = (counts[l] ?? 0) + 1;
      }
    }
    final labels = <String>{for (final f in files) ...f.labels}.toList();
    final first = files.isEmpty ? null : files.first;
    return ErpMarkerInventory(
      counts,
      labels,
      first?.epochTmin,
      first?.epochTmax,
      first?.sampleRate,
      first?.sourceEpochSamples,
    );
  }

  /// Extracts one electrode's epochs split by condition (script:
  /// load_epo_json_electrode).
  static ErpEpochs extract(CcsEegData d, ErpSettings s) {
    final warnings = <String>[];
    final ci = d.labels.indexWhere(
      (l) => l.toUpperCase() == s.electrode.toUpperCase(),
    );
    if (ci < 0) {
      throw ArgumentError(
        "Electrode '${s.electrode}' not found in ${d.fileLabel}. "
        'Available electrodes: ${d.labels.join(', ')}',
      );
    }
    final labels = d.epochLabels;
    final nS = d.sourceEpochSamples;
    if (labels == null || nS == null || nS <= 0) {
      throw StateError(
        '${d.fileLabel} is not epoched (no epoch_labels / source_epoch_samples). '
        'Epoch it on stimulus markers in Preprocess first.',
      );
    }
    final nE = labels.length;
    var flat = d.channels[ci];
    final need = nE * nS;
    if (flat.length != need) {
      warnings.add(
        '${d.fileLabel}: channel length ${flat.length} != $nE epochs × $nS '
        'samples; ${flat.length < need ? 'zero-padded' : 'truncated'} as in the script',
      );
      final f2 = Float64List(need);
      f2.setRange(0, math.min(need, flat.length), flat);
      flat = f2;
    }
    double tmin = s.tmin, tmax = s.tmax;
    if (s.useFileEpochTimes && d.epochTmin != null) {
      tmin = d.epochTmin!;
      tmax = d.epochTmax ?? (tmin + (nS - 1) / d.sampleRate);
    }
    final times = npLinspace(tmin, tmax, nS);
    if (nS > 1 &&
        d.sampleRate > 0 &&
        ((times[1] - times[0]) - 1 / d.sampleRate).abs() > 1e-3) {
      warnings.add(
        '${d.fileLabel}: epoch times (${tmin}s..${tmax}s over $nS samples) '
        'do not match the ${d.sampleRate} Hz sample rate; check tmin/tmax',
      );
    }
    final bIdx = [
      for (var k = 0; k < nS; k++)
        if (times[k] >= s.baselineStart && times[k] <= s.baselineEnd) k,
    ];
    if (bIdx.isEmpty) {
      throw ArgumentError(
        'Baseline window (${s.baselineStart}, ${s.baselineEnd}) has no samples in epoch.',
      );
    }
    final a = <Float64List>[], b = <Float64List>[];
    final bufB = Float64List(bIdx.length);
    for (var e = 0; e < nE; e++) {
      final inA = s.condA.matches(labels[e]);
      final inB = s.condB.matches(labels[e]);
      if (!inA && !inB) continue;
      final ep = Float64List.sublistView(flat, e * nS, (e + 1) * nS);
      for (var k = 0; k < bIdx.length; k++) {
        bufB[k] = ep[bIdx[k]];
      }
      final bm = npMean(bufB);
      final c = Float64List(nS);
      for (var k = 0; k < nS; k++) {
        c[k] = ep[k] - bm;
      }
      if (inA) a.add(c);
      if (inB) b.add(c);
    }
    return ErpEpochs(
      fileLabel: d.fileLabel,
      path: d.path,
      times: times,
      a: a,
      b: b,
      warnings: warnings,
    );
  }

  /// Column mean over trials (numpy mean(axis=0): sequential over rows).
  static Float64List _colMean(List<Float64List> x, int n) {
    final m = Float64List(n);
    for (final r in x) {
      for (var k = 0; k < n; k++) {
        m[k] += r[k];
      }
    }
    for (var k = 0; k < n; k++) {
      m[k] /= x.length;
    }
    return m;
  }

  /// Column variance (ddof) over trials, two-pass like numpy.
  static Float64List _colVar(List<Float64List> x, Float64List mean, int ddof) {
    final n = mean.length;
    final v = Float64List(n);
    for (final r in x) {
      for (var k = 0; k < n; k++) {
        final d = r[k] - mean[k];
        v[k] += d * d;
      }
    }
    for (var k = 0; k < n; k++) {
      v[k] /= (x.length - ddof);
    }
    return v;
  }

  static Float64List _sem(List<Float64List> x, Float64List mean) {
    final v = _colVar(x, mean, 1);
    final n = math.sqrt(x.length.toDouble());
    return Float64List.fromList([for (final y in v) math.sqrt(y) / n]);
  }

  /// Welch t per time point (scipy ttest_ind(axis=0, equal_var=False),
  /// NaN -> 0 like np.nan_to_num).
  static Float64List welchT(List<Float64List> a, List<Float64List> b, int n) {
    final ma = _colMean(a, n), mb = _colMean(b, n);
    final va = _colVar(a, ma, 1), vb = _colVar(b, mb, 1);
    final t = Float64List(n);
    for (var k = 0; k < n; k++) {
      final den = math.sqrt(va[k] / a.length + vb[k] / b.length);
      final v = (ma[k] - mb[k]) / den;
      t[k] = v.isFinite
          ? v
          : (v.isNaN
                ? 0.0
                : (v > 0 ? 1.7976931348623157e308 : -1.7976931348623157e308));
    }
    return t;
  }

  static List<ErpCluster> _findClusters(Float64List t, double thresh) {
    final out = <ErpCluster>[];
    final n = t.length;
    var i = 0;
    while (i < n) {
      if (t[i].abs() > thresh) {
        final start = i;
        final s = t[i].sign;
        var mass = 0.0;
        while (i < n && t[i].abs() > thresh && t[i].sign == s) {
          i++;
        }
        for (var k = start; k < i; k++) {
          mass += t[k].abs();
        }
        out.add(ErpCluster(start, i, mass, s, double.nan));
      } else {
        i++;
      }
    }
    return out;
  }

  static double _maxClusterMass(Float64List t, double thresh) {
    var best = 0.0;
    final n = t.length;
    var i = 0;
    while (i < n) {
      if (t[i].abs() > thresh) {
        final s = t[i].sign;
        var mass = 0.0;
        while (i < n && t[i].abs() > thresh && t[i].sign == s) {
          mass += t[i].abs();
          i++;
        }
        if (mass > best) best = mass;
      } else {
        i++;
      }
    }
    return best;
  }

  /// Cluster-based permutation test (script: cluster_permutation_test).
  static (Float64List, List<ErpCluster>, double) clusterPermutationTest(
    List<Float64List> a,
    List<Float64List> b,
    int n, {
    int nPerm = 1000,
    double pThresh = 0.05,
    int seed = 42,
    void Function(double)? onProgress,
  }) {
    final nA = a.length, nB = b.length;
    final df = (nA + nB - 2).toDouble();
    final thresh = tPpf(1 - pThresh / 2, df);
    final tObs = welchT(a, b, n);
    final obs = _findClusters(tObs, thresh);
    if (nPerm <= 0) return (tObs, obs, thresh);

    final rng = NpGenerator(seed);
    final pooled = [...a, ...b];
    final nT = pooled.length;
    // Row-major matrix, centred per column for a stable one-pass variance.
    final colMean = _colMean(pooled, n);
    final x = Float64List(nT * n);
    for (var r = 0; r < nT; r++) {
      final row = pooled[r];
      for (var k = 0; k < n; k++) {
        x[r * n + k] = row[k] - colMean[k];
      }
    }
    final totS = Float64List(n), totQ = Float64List(n);
    for (var r = 0; r < nT; r++) {
      for (var k = 0; k < n; k++) {
        final v = x[r * n + k];
        totS[k] += v;
        totQ[k] += v * v;
      }
    }
    final sA = Float64List(n), qA = Float64List(n), tp = Float64List(n);
    final nullMax = Float64List(nPerm);
    for (var p = 0; p < nPerm; p++) {
      final perm = rng.permutation(nT);
      sA.fillRange(0, n, 0);
      qA.fillRange(0, n, 0);
      for (var j = 0; j < nA; j++) {
        final off = perm[j] * n;
        for (var k = 0; k < n; k++) {
          final v = x[off + k];
          sA[k] += v;
          qA[k] += v * v;
        }
      }
      for (var k = 0; k < n; k++) {
        final sB = totS[k] - sA[k], qB = totQ[k] - qA[k];
        final mA = sA[k] / nA, mB = sB / nB;
        final vA = (qA[k] - nA * mA * mA) / (nA - 1);
        final vB = (qB - nB * mB * mB) / (nB - 1);
        final den = math.sqrt(vA / nA + vB / nB);
        final v = (mA - mB) / den;
        tp[k] = v.isFinite ? v : 0.0;
      }
      nullMax[p] = _maxClusterMass(tp, thresh);
      if (onProgress != null && p % 50 == 0) onProgress(p / nPerm);
    }
    final clusters = [
      for (final c in obs)
        ErpCluster(
          c.startIdx,
          c.endIdx,
          c.mass,
          c.sign,
          (nullMax.where((m) => m >= c.mass).length + 1) / (nPerm + 1),
        ),
    ];
    return (tObs, clusters, thresh);
  }

  static Float64List windowMeans(
    List<Float64List> epochs,
    Float64List times,
    double w0,
    double w1,
  ) {
    final idx = [
      for (var k = 0; k < times.length; k++)
        if (times[k] >= w0 && times[k] <= w1) k,
    ];
    final buf = Float64List(idx.length);
    return Float64List.fromList([
      for (final e in epochs)
        () {
          for (var j = 0; j < idx.length; j++) {
            buf[j] = e[idx[j]];
          }
          return npMean(buf);
        }(),
    ]);
  }

  /// Bootstrap CI of Cohen's d (script: bootstrap_d_ci).
  static (double, double) bootstrapDCi(
    List<double> a,
    List<double> b, {
    int nBoot = 2000,
    int seed = 42,
    double ci = 95,
  }) {
    final rng = NpGenerator(seed);
    final ds = Float64List(nBoot);
    for (var i = 0; i < nBoot; i++) {
      final ra = rng.choice(a, a.length);
      final rb = rng.choice(b, b.length);
      ds[i] = cohensD(ra, rb);
    }
    return (
      npPercentile(ds, (100 - ci) / 2),
      npPercentile(ds, 100 - (100 - ci) / 2),
    );
  }

  /// Bootstrap of the mismatch (mean B − mean A) in the window.
  static Float64List mismatchBootstrap(
    List<double> a,
    List<double> b, {
    int nBoot = 2000,
    int seed = 42,
  }) {
    final rng = NpGenerator(seed);
    final out = Float64List(nBoot);
    for (var i = 0; i < nBoot; i++) {
      final rs = rng.choice(a, a.length);
      final rd = rng.choice(b, b.length);
      out[i] = npMean(rd) - npMean(rs);
    }
    return out;
  }

  static ErpFileResult analyzeEpochs(
    ErpEpochs ee,
    ErpSettings s, {
    void Function(double, String)? onProgress,
  }) {
    final n = ee.times.length;
    if (ee.a.length < 2 || ee.b.length < 2) {
      throw StateError(
        '${ee.fileLabel}: need at least 2 epochs per condition '
        '(${s.condA.name}: ${ee.a.length}, ${s.condB.name}: ${ee.b.length}). '
        'Check the condition markers.',
      );
    }
    var aMean = _colMean(ee.a, n), bMean = _colMean(ee.b, n);
    var aSem = _sem(ee.a, aMean), bSem = _sem(ee.b, bMean);
    if (s.smooth && n >= s.smoothWindow) {
      aMean = savgolFilter(aMean, window: s.smoothWindow, order: s.smoothOrder);
      aSem = savgolFilter(aSem, window: s.smoothWindow, order: s.smoothOrder);
      bMean = savgolFilter(bMean, window: s.smoothWindow, order: s.smoothOrder);
      bSem = savgolFilter(bSem, window: s.smoothWindow, order: s.smoothOrder);
    }
    onProgress?.call(
      0.05,
      '${ee.fileLabel}: cluster permutation test (${s.nPerm})',
    );
    final (tObs, clusters, thresh) = clusterPermutationTest(
      ee.a,
      ee.b,
      n,
      nPerm: s.nPerm,
      pThresh: s.clusterAlpha,
      seed: s.seed,
      onProgress: (p) => onProgress?.call(0.05 + 0.6 * p, ''),
    );

    final aw = windowMeans(ee.a, ee.times, s.winStart, s.winEnd);
    final bw = windowMeans(ee.b, ee.times, s.winStart, s.winEnd);
    final w = welchTTest(aw, bw);
    final d = cohensD(aw, bw);
    onProgress?.call(0.7, '${ee.fileLabel}: bootstrap (${s.nBoot})');
    final (lo, hi) = bootstrapDCi(aw, bw, nBoot: s.nBoot, seed: s.seed);
    final mb = mismatchBootstrap(aw, bw, nBoot: s.nBoot, seed: s.seed);

    final wIdx = [
      for (var k = 0; k < n; k++)
        if (ee.times[k] >= s.winStart && ee.times[k] <= s.winEnd) k,
    ];
    double wmean(Float64List m) => npMean([for (final k in wIdx) m[k]]);

    return ErpFileResult(
      fileLabel: ee.fileLabel,
      path: ee.path,
      times: ee.times,
      aMean: aMean,
      aSem: aSem,
      bMean: bMean,
      bSem: bSem,
      nA: ee.a.length,
      nB: ee.b.length,
      tObs: tObs,
      tThresh: thresh,
      clusters: clusters,
      tWindow: w.t,
      pWindow: w.p,
      dWindow: d,
      dfWindow: w.df,
      dBootLo: lo,
      dBootHi: hi,
      mismatchBoot: mb,
      mismatchMean: npMean(mb),
      mismatchLo: npPercentile(mb, 2.5),
      mismatchHi: npPercentile(mb, 97.5),
      aWindowMean: wmean(aMean),
      bWindowMean: wmean(bMean),
      warnings: ee.warnings,
    );
  }

  /// Full analysis over several files (sessions), in file order.
  static ErpAnalysis analyzeFiles(
    List<CcsEegData> files,
    ErpSettings s, {
    void Function(double, String)? onProgress,
  }) {
    final results = <ErpFileResult>[];
    for (var i = 0; i < files.length; i++) {
      final ee = extract(files[i], s);
      onProgress?.call(
        i / files.length,
        '${ee.fileLabel}: ${s.condA.name} n=${ee.a.length}, ${s.condB.name} n=${ee.b.length}',
      );
      results.add(
        analyzeEpochs(
          ee,
          s,
          onProgress: (p, m) => onProgress?.call((i + p) / files.length, m),
        ),
      );
    }
    return ErpAnalysis(s, results, betweenSessions(results));
  }

  /// Builds condition A, condition B, B−A and Welch-statistic scalp maps.
  /// The point map uses the sample nearest the midpoint of the configured
  /// component window; the window map averages every sample in that window.
  static ErpTopoResult analyzeTopography(
    List<CcsEegData> files,
    ErpSettings s, {
    double? pointSeconds,
    void Function(double, String)? onProgress,
  }) {
    final labels = <String>[];
    for (final file in files) {
      for (final label in file.labels) {
        if (!labels.any((x) => x.toUpperCase() == label.toUpperCase())) {
          labels.add(label);
        }
      }
    }
    final wa = <double>[], wb = <double>[], wt = <double>[], wp = <double>[];
    final pa = <double>[], pb = <double>[], pt = <double>[], pp = <double>[];
    final na = <int>[], nb = <int>[];
    final targetPoint = pointSeconds ?? (s.winStart + s.winEnd) / 2;
    var actualPoint = targetPoint;
    for (var ci = 0; ci < labels.length; ci++) {
      final aWindow = <double>[], bWindow = <double>[];
      final aPoint = <double>[], bPoint = <double>[];
      for (final file in files) {
        if (!file.labels.any(
          (x) => x.toUpperCase() == labels[ci].toUpperCase(),
        )) {
          continue;
        }
        final epochs = extract(file, s.copyWith(electrode: labels[ci]));
        aWindow.addAll(
          windowMeans(epochs.a, epochs.times, s.winStart, s.winEnd),
        );
        bWindow.addAll(
          windowMeans(epochs.b, epochs.times, s.winStart, s.winEnd),
        );
        var point = 0;
        var distance = double.infinity;
        for (var k = 0; k < epochs.times.length; k++) {
          final d = (epochs.times[k] - targetPoint).abs();
          if (d < distance) {
            distance = d;
            point = k;
          }
        }
        actualPoint = epochs.times[point];
        aPoint.addAll([for (final epoch in epochs.a) epoch[point]]);
        bPoint.addAll([for (final epoch in epochs.b) epoch[point]]);
      }
      if (aWindow.length < 2 || bWindow.length < 2) {
        wa.add(double.nan);
        wb.add(double.nan);
        wt.add(double.nan);
        wp.add(double.nan);
        pa.add(double.nan);
        pb.add(double.nan);
        pt.add(double.nan);
        pp.add(double.nan);
      } else {
        final w = welchTTest(aWindow, bWindow);
        final p = welchTTest(aPoint, bPoint);
        wa.add(npMean(aWindow));
        wb.add(npMean(bWindow));
        wt.add(w.t);
        wp.add(w.p);
        pa.add(npMean(aPoint));
        pb.add(npMean(bPoint));
        pt.add(p.t);
        pp.add(p.p);
      }
      na.add(aWindow.length);
      nb.add(bWindow.length);
      onProgress?.call(
        (ci + 1) / labels.length,
        'Scalp maps: ${labels[ci]} (${ci + 1}/${labels.length})',
      );
    }
    return ErpTopoResult(
      labels: labels,
      windowA: wa,
      windowB: wb,
      windowT: wt,
      windowP: wp,
      pointA: pa,
      pointB: pb,
      pointT: pt,
      pointP: pp,
      pointSeconds: actualPoint,
      nA: na,
      nB: nb,
    );
  }

  static List<ErpBetween> betweenSessions(List<ErpFileResult> r) => [
    for (var i = 0; i < r.length; i++)
      for (var j = i + 1; j < r.length; j++)
        ErpBetween(i, j, cohensD(r[i].mismatchBoot, r[j].mismatchBoot)),
  ];

  // ───────────────────────────── outputs ─────────────────────────────────

  /// stats_summary_<electrode>.csv, same columns and number formats as the
  /// script.
  static String statsCsv(ErpAnalysis an) {
    final b = StringBuffer();
    b.write(
      'file,n_std,n_dev,std_window_mean_uV,dev_window_mean_uV,'
      't_window,df_window,p_window,cohend_window,d_ci_lo,d_ci_hi,'
      'mismatch_mean_uV,mismatch_ci_lo,mismatch_ci_hi,'
      'significant_clusters(start_s-end_s:p)\n',
    );
    String f(double v, int d) => v.toStringAsFixed(d);
    for (final r in an.results) {
      final n = r.times.length;
      final sig = [
        for (final c in r.clusters)
          if (c.pValue <= 0.05)
            '${f(r.times[c.startIdx], 3)}-${f(r.times[math.min(c.endIdx, n - 1)], 3)}:${f(c.pValue, 4)}',
      ].join(';');
      b.write(
        '${r.fileLabel},${r.nA},${r.nB},'
        '${f(r.aWindowMean, 4)},${f(r.bWindowMean, 4)},'
        '${f(r.tWindow, 4)},${f(r.dfWindow, 2)},${f(r.pWindow, 6)},${f(r.dWindow, 4)},'
        '${f(r.dBootLo, 4)},${f(r.dBootHi, 4)},'
        '${f(r.mismatchMean, 4)},${f(r.mismatchLo, 4)},${f(r.mismatchHi, 4)},'
        '"$sig"\n',
      );
    }
    b.write("\nBetween-file effect size (Cohen's d) of mismatch magnitude:\n");
    b.write('file_a,file_b,cohend\n');
    for (final x in an.between) {
      b.write(
        '${an.results[x.i].fileLabel},${an.results[x.j].fileLabel},${f(x.d, 4)}\n',
      );
    }
    return b.toString();
  }

  /// Per-time-point waveforms (for re-plotting elsewhere).
  static String waveformsCsv(ErpAnalysis an) {
    final b = StringBuffer(
      'file,time_s,a_mean_uV,a_sem_uV,b_mean_uV,b_sem_uV,diff_uV,t_obs\n',
    );
    for (final r in an.results) {
      for (var k = 0; k < r.times.length; k++) {
        b.write(
          '${r.fileLabel},${r.times[k].toStringAsFixed(4)},'
          '${r.aMean[k]},${r.aSem[k]},${r.bMean[k]},${r.bSem[k]},'
          '${r.bMean[k] - r.aMean[k]},${r.tObs[k]}\n',
        );
      }
    }
    return b.toString();
  }

  static Future<void> writeCsvs(ErpAnalysis an, String outDir) async {
    await Directory(outDir).create(recursive: true);
    final e = an.settings.electrode;
    await File(
      '$outDir${Platform.pathSeparator}stats_summary_$e.csv',
    ).writeAsString(statsCsv(an));
    await File(
      '$outDir${Platform.pathSeparator}erp_waveforms_$e.csv',
    ).writeAsString(waveformsCsv(an));
  }
}
