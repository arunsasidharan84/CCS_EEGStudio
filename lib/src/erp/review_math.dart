import 'dart:math' as math;
import 'workbench_figures.dart';

/// Symmetric centred moving average. Display only; measurements use raw means.
List<double> smoothErp(List<double> values, List<double> times, double ms) {
  if (ms <= 0 || times.length < 2) return values.toList();
  final radius = (ms / 2000 / (times[1] - times[0])).round();
  return [
    for (var i = 0; i < values.length; i++)
      values
              .sublist(
                math.max(0, i - radius),
                math.min(values.length, i + radius + 1),
              )
              .reduce((a, b) => a + b) /
          (math.min(values.length, i + radius + 1) - math.max(0, i - radius)),
  ];
}

Map<String, double?> reviewMeasures(
  List<double> times,
  List<double> y,
  double lo,
  double hi,
  double polarity,
) {
  final indices = [
    for (var i = 0; i < times.length; i++)
      if (times[i] >= lo - 1e-10 && times[i] <= hi + 1e-10) i,
  ];
  if (indices.length < 2 || times.length != y.length) return {};

  final effPolarity = polarity.abs() > 1e-6
      ? polarity
      : () {
          final winMean =
              indices.map((i) => y[i]).reduce((a, b) => a + b) / indices.length;
          var maxPos = 0.0, maxNeg = 0.0;
          for (final i in indices) {
            final diff = y[i] - winMean;
            if (diff > maxPos) maxPos = diff;
            if (-diff > maxNeg) maxNeg = -diff;
          }
          return maxPos >= maxNeg ? 1.0 : -1.0;
        }();

  double signed = 0, positive = 0, negative = 0;
  final cumulative = <double>[0];
  for (var k = 1; k < indices.length; k++) {
    final i = indices[k - 1], j = indices[k];
    final dt = times[j] - times[i];
    signed += (y[i] + y[j]) * dt / 2;
    positive += (math.max(0, y[i]) + math.max(0, y[j])) * dt / 2;
    negative += (math.min(0, y[i]) + math.min(0, y[j])) * dt / 2;
    cumulative.add(
      cumulative.last +
          (math.max(0, effPolarity * y[i]) + math.max(0, effPolarity * y[j])) *
              dt /
              2,
    );
  }

  // Find candidate local extrema within the window (excluding window endpoints)
  final localPeaks = <int>[];
  final oppLocalPeaks = <int>[];
  for (var k = 1; k < indices.length - 1; k++) {
    final prev = y[indices[k - 1]],
        curr = y[indices[k]],
        next = y[indices[k + 1]];
    if (effPolarity > 0) {
      if (curr >= prev && curr >= next && (curr > prev || curr > next)) {
        localPeaks.add(indices[k]);
      }
      if (curr <= prev && curr <= next && (curr < prev || curr < next)) {
        oppLocalPeaks.add(indices[k]);
      }
    } else {
      if (curr <= prev && curr <= next && (curr < prev || curr < next)) {
        localPeaks.add(indices[k]);
      }
      if (curr >= prev && curr >= next && (curr > prev || curr > next)) {
        oppLocalPeaks.add(indices[k]);
      }
    }
  }

  int peak;
  if (localPeaks.isNotEmpty) {
    peak = localPeaks.first;
    for (final p in localPeaks) {
      if (effPolarity * y[p] > effPolarity * y[peak]) peak = p;
    }
  } else {
    // If no local peak of effPolarity, find maximum in window
    peak = indices.first;
    for (final i in indices) {
      if (effPolarity * y[i] > effPolarity * y[peak]) peak = i;
    }
    // If the extremum lands on the window endpoint, but an interior local peak exists
    // (e.g. component polarity was positive like P2/P3a but setting was negative),
    // pick the prominent interior local peak instead of an endpoint artifact.
    if ((peak == indices.first || peak == indices.last) &&
        oppLocalPeaks.isNotEmpty) {
      var bestOpp = oppLocalPeaks.first;
      for (final p in oppLocalPeaks) {
        if (-effPolarity * y[p] > -effPolarity * y[bestOpp]) bestOpp = p;
      }
      peak = bestOpp;
    }
  }

  double? area, onset;
  if (cumulative.last > 0) {
    final k = List.generate(
      indices.length - 1,
      (i) => i + 1,
    ).firstWhere((i) => cumulative[i] >= cumulative.last * .5);
    final fraction =
        (cumulative.last * .5 - cumulative[k - 1]) /
        (cumulative[k] - cumulative[k - 1]);
    area =
        times[indices[k - 1]] +
        fraction * (times[indices[k]] - times[indices[k - 1]]);
  }
  final threshold = effPolarity * y[peak] * .5;
  if (threshold > 0) {
    for (var k = 1; k < indices.length; k++) {
      final i = indices[k - 1], j = indices[k];
      if (j > peak) break;
      final a = effPolarity * y[i], b = effPolarity * y[j];
      if (a < threshold && b >= threshold) {
        onset = times[i] + (threshold - a) / (b - a) * (times[j] - times[i]);
        break;
      }
    }
  }
  return {
    'mean': indices.map((i) => y[i]).reduce((a, b) => a + b) / indices.length,
    'signed_auc': signed,
    'positive_auc': positive,
    'negative_auc': negative,
    'peak_amplitude': y[peak],
    'peak_latency_ms': times[peak] * 1000,
    'fractional_area_latency_ms': area == null ? null : area * 1000,
    'fractional_peak_latency_ms': onset == null ? null : onset * 1000,
  };
}

List<double> reviewAverage(List<List<double>> arrays) => arrays.isEmpty
    ? []
    : [
        for (var i = 0; i < arrays.first.length; i++)
          arrays.map((a) => a[i]).reduce((a, b) => a + b) / arrays.length,
      ];
List<double> reviewSem(List<List<double>> arrays) {
  if (arrays.length < 2) return [];
  final mean = reviewAverage(arrays);
  return [
    for (var i = 0; i < mean.length; i++)
      math.sqrt(
        arrays.map((a) => math.pow(a[i] - mean[i], 2)).reduce((a, b) => a + b) /
            (arrays.length - 1) /
            arrays.length,
      ),
  ];
}

/// Average repeated recordings within participant first, then weight people equally.
List<Map<String, dynamic>> reviewParticipants(
  List<Map<String, dynamic>> files,
) {
  final bySubject = <String, List<Map<String, dynamic>>>{};
  for (final file in files) {
    final id = '${file['subject']}';
    bySubject.putIfAbsent(id, () => []).add(file);
  }
  return [
    for (final entry in bySubject.entries)
      {
        ...entry.value.first,
        'subject': entry.key,
        'n_files': entry.value.length,
        for (final key in ['a', 'b', 'difference'])
          key: reviewAverage([for (final f in entry.value) erpNumbers(f[key])]),
      },
  ];
}

/// Exact full-resolution maps for newly generated results; legacy maps only at saved window.
List<double>? reviewTopo(Map<String, dynamic> file, double lo, double hi) {
  final times = erpNumbers(file['times']);
  if (times.where((t) => t >= lo - 1e-10 && t <= hi + 1e-10).length < 2)
    return null;
  if (file['channel_difference'] is List) {
    final indices = [
      for (var i = 0; i < times.length; i++)
        if (times[i] >= lo - 1e-10 && times[i] <= hi + 1e-10) i,
    ];
    final result = <double>[];
    for (final channel in file['channel_difference'] as List) {
      final values = channel as List;
      if (values.length != times.length) return null;
      var sum = 0.0;
      for (final i in indices) {
        final value = values[i];
        if (value is! num || !value.isFinite) return null;
        sum += value.toDouble();
      }
      result.add(sum / indices.length);
    }
    return result;
  }
  final w = erpNumbers(erpMap(file['profile'])['window']);
  if (w.length == 2 && (lo - w[0]).abs() < 1e-8 && (hi - w[1]).abs() < 1e-8)
    return erpNumbers(file['topo_difference']);
  return null;
}

String reviewCsv(
  List<Map<String, dynamic>> files,
  Map<String, String> groups,
  Iterable<String> metrics,
  double lo,
  double hi,
) {
  String quote(Object? value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';
  final lines = <String>[
    [
      'filename',
      'subjid',
      'Group',
      'condn',
      'Chan',
      'Epoch',
      'epoch_label',
      'window_start_ms',
      'window_end_ms',
      'n_recordings',
      'measurement_input',
      ...metrics.map((m) => '${m}_ERP'),
    ].map(quote).join(','),
  ];
  for (final f in reviewParticipants(files)) {
    final p = erpMap(f['profile']), times = erpNumbers(f['times']);
    for (final key in ['a', 'b', 'difference']) {
      final label = key == 'a'
          ? '${p['a_name']}'
          : key == 'b'
          ? '${p['b_name']}'
          : '${p['b_name']} minus ${p['a_name']}';
      final values = reviewMeasures(
        times,
        erpNumbers(f[key]),
        lo,
        hi,
        (p['polarity'] as num?)?.toDouble() ?? -1,
      );
      lines.add(
        [
          f['path'],
          f['subject'],
          groups['${f['subject']}'] ?? 'Unlabelled',
          label,
          (p['roi'] as List? ?? []).join('+'),
          0,
          label,
          lo * 1000,
          hi * 1000,
          f['n_files'],
          'unsmoothed participant average',
          ...metrics.map((m) => values[m]),
        ].map(quote).join(','),
      );
    }
  }
  return '${lines.join('\n')}\n';
}

/// Smooth every displayed condition, leaving analysis arrays untouched.
Map<String, dynamic> smoothedErpDisplay(
  Map<String, dynamic> data,
  double ms,
) => {
  ...data,
  for (final key in ['a', 'b', 'difference'])
    key: smoothErp(erpNumbers(data[key]), erpNumbers(data['times']), ms),
  if (data['condition_waves'] is Map)
    'condition_waves': {
      for (final e in (data['condition_waves'] as Map).entries)
        e.key: smoothErp(erpNumbers(e.value), erpNumbers(data['times']), ms),
    },
  if (ms > 0) 'sem_difference': [],
  if (ms > 0) 'condition_sems': {},
};
