import 'dart:io';
import 'models.dart';

/// EEGLAB text event exports alongside EDFs, as supplied by ERP CORE.
/// Latency is in seconds. Never guess samples from a large numeric value.
List<EegMarker>? loadEeglabEventSidecar(String path, double durationSeconds) {
  final file = File(path.replaceFirst(RegExp(r'\.[^.]+$'), '.evt'));
  if (!file.existsSync()) return null;
  final lines = file.readAsLinesSync();
  if (lines.isEmpty) throw const FormatException('Empty .evt sidecar');
  final header = lines.first
      .split('\t')
      .map((s) => s.trim().toLowerCase())
      .toList();
  final type = header.indexOf('type'),
      latency = header.indexOf('latency'),
      duration = header.indexOf('duration');
  if (type < 0 || latency < 0)
    throw const FormatException('EVT needs type and latency columns (seconds)');
  final markers = <EegMarker>[];
  for (final line in lines.skip(1).where((s) => s.trim().isNotEmpty)) {
    final row = line.split('\t');
    if (row.length <= type || row.length <= latency)
      throw const FormatException('Truncated EVT row');
    final onset = double.tryParse(row[latency]);
    if (onset == null ||
        !onset.isFinite ||
        onset < 0 ||
        onset > durationSeconds + 1)
      throw const FormatException(
        'EVT latency must be seconds within the recording',
      );
    markers.add(
      EegMarker(
        type: 'Event',
        description: row[type].trim(),
        startSeconds: onset,
        durationSeconds: duration >= 0 && row.length > duration
            ? double.tryParse(row[duration]) ?? 0
            : 0,
      ),
    );
  }
  return markers;
}
