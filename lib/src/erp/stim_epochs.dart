// lib/src/erp/stim_epochs.dart
//
// Stimulus-locked epoching for ERP work. The events are picked here from the
// raw recording's markers. The engine then cuts the epochs after
// downsampling and filtering, and before bad-channel detection, GEDAI (one
// trial per window) and interpolation.

import '../models.dart';
import 'erp_engine.dart' show ErpCondition, normaliseMarker;

class StimEpochSpec {
  const StimEpochSpec({
    this.markers = const ['S 51', 'S 52'],
    this.pattern = '',
    this.tmin = -0.5,
    this.tmax = 1.2,
    this.baseline = true,
    this.baselineStart = -0.2,
    this.baselineEnd = 0.0,
    this.cropStartMarker = '',
    this.cropMinutes = 0,
  });

  /// Markers to epoch on (e.g. "S 51", "Stimulus/S 52").
  final List<String> markers;

  /// Optional extra regular expression over the marker label.
  final String pattern;
  final double tmin, tmax;
  final bool baseline;
  final double baselineStart, baselineEnd;

  /// Optional time limit: only events from the first [cropStartMarker] up to
  /// [cropMinutes] after it (0 = to the end). For example, the MNE script
  /// keeps 15 min after "S  8" for the Meditation session.
  final String cropStartMarker;
  final double cropMinutes;

  ErpCondition get _matcher =>
      ErpCondition(name: 'events', markers: markers, pattern: pattern);

  /// Label written to epoch_labels: "Stimulus/S 51" (MNE annotation style).
  static String eventLabel(EegMarker m) {
    final t = m.type.trim(), d = m.description.trim();
    if (d.isEmpty) return t;
    if (t.isEmpty || d.toLowerCase().startsWith('${t.toLowerCase()}/'))
      return d;
    return '$t/$d';
  }

  bool matches(EegMarker m) =>
      _matcher.matches(eventLabel(m)) ||
      _matcher.matches(m.description) ||
      _matcher.matches(m.type);

  /// Events to epoch on: (onset seconds, label), sorted by time. Events inside
  /// a rejected interval, or outside the accepted intervals, are left out.
  List<(double, String)> selectEvents(
    List<EegMarker> markers, {
    ViewerSelection selection = const ViewerSelection.empty(),
  }) {
    var start = double.negativeInfinity, end = double.infinity;
    if (cropStartMarker.trim().isNotEmpty) {
      final c = ErpCondition(name: 'crop', markers: [cropStartMarker]);
      final first =
          markers
              .where(
                (m) => c.matches(eventLabel(m)) || c.matches(m.description),
              )
              .toList()
            ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
      if (first.isEmpty) {
        throw StateError(
          'Crop marker "$cropStartMarker" was not found in the recording.',
        );
      }
      start = first.first.startSeconds;
      if (cropMinutes > 0) end = start + cropMinutes * 60;
    }
    bool inside(double t, List<List<double>> iv) =>
        iv.any((x) => t >= x[0] && t <= x[1]);
    final out = <(double, String)>[];
    for (final m in markers) {
      final t = m.startSeconds;
      if (t < start || t > end) continue;
      if (!matches(m)) continue;
      if (selection.acceptedIntervals.isNotEmpty &&
          !inside(t, selection.acceptedIntervals))
        continue;
      if (inside(t, selection.rejectedIntervals)) continue;
      out.add((t, eventLabel(m)));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// JSON block for the engine's preprocessing options.
  Map<String, dynamic> toEngineJson(List<(double, String)> events) => {
    'onsets': [for (final e in events) e.$1],
    'labels': [for (final e in events) e.$2],
    'tmin': tmin,
    'tmax': tmax,
    if (baseline) 'baseline': [baselineStart, baselineEnd],
  };

  Map<String, dynamic> toJson() => {
    'markers': markers,
    'pattern': pattern,
    'tmin': tmin,
    'tmax': tmax,
    'baseline': baseline ? [baselineStart, baselineEnd] : null,
    if (cropStartMarker.isNotEmpty) 'crop_start_marker': cropStartMarker,
    if (cropMinutes > 0) 'crop_minutes': cropMinutes,
  };

  /// Human-readable summary for logs and reports.
  String describe() {
    final m = [
      ...markers,
      if (pattern.trim().isNotEmpty) '/$pattern/',
    ].join(', ');
    return 'epochs $tmin..$tmax s on [$m]'
        '${baseline ? ', baseline $baselineStart..$baselineEnd s' : ''}'
        '${cropStartMarker.isNotEmpty ? ', from first "$cropStartMarker"${cropMinutes > 0 ? ' for $cropMinutes min' : ''}' : ''}';
  }
}

/// Distinct marker labels in a recording with their counts (for pickers).
Map<String, int> markerInventory(List<EegMarker> markers) {
  final out = <String, int>{};
  for (final m in markers) {
    final l = StimEpochSpec.eventLabel(m);
    out[l] = (out[l] ?? 0) + 1;
  }
  return out;
}

/// "Stimulus/S 51" -> "S 51" (the short code shown on chips).
String markerShortName(String label) {
  final parts = label.split('/');
  return parts.length > 1 ? parts.sublist(1).join('/') : label;
}

bool markerListContains(List<String> list, String label) {
  final n = normaliseMarker(markerShortName(label));
  return list.any((m) => normaliseMarker(markerShortName(m)) == n);
}
