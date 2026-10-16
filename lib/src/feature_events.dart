import 'dart:convert';
import 'dart:io';
import 'models.dart';
import 'topostats/topostats_engine.dart' show splitFeatureCsvLine;

/// Source-time events. Epoch-local markers are restored to the source timeline;
/// copies created by overlapping windows are deduplicated for plotting.
List<Map<String, dynamic>> featureEvents(EegRecording recording) {
  final events = <String, Map<String, dynamic>>{};
  for (final marker in recording.markers) {
    final parent = marker.epochIndex;
    final onset =
        marker.startSeconds +
        (parent == null
            ? 0
            : parent < recording.epochStartSeconds.length
            ? recording.epochStartSeconds[parent]
            : parent *
                  (recording.pointsPerEpoch ?? recording.sampleCount) /
                  recording.sampleRate);
    final event = <String, dynamic>{
      'type': marker.type,
      'label': marker.label,
      'onset_s': onset,
      'duration_s': marker.durationSeconds,
      if (marker.channelIndex != null) 'channel_index': marker.channelIndex,
    };
    events[jsonEncode(event)] = event;
  }
  return events.values.toList()..sort(
    (a, b) => (a['onset_s'] as double).compareTo(b['onset_s'] as double),
  );
}

String _quote(String s) => '"${s.replaceAll('"', '""')}"';

/// Repeat an event in every intersecting epoch, retaining its exact onset.
/// Half-open intervals avoid assigning a boundary event to the preceding epoch.
Future<void> appendFeatureEvents(File file, EegRecording recording) async {
  final events = featureEvents(recording);
  final temporary = File('${file.path}.events.tmp');
  final sink = temporary.openWrite();
  var startIndex = -1, endIndex = -1;
  var header = true;
  try {
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final fields = splitFeatureCsvLine(line);
      if (header) {
        startIndex = fields.indexOf('epoch_start_s');
        endIndex = fields.indexOf('epoch_end_s');
        if (startIndex < 0 || endIndex < 0)
          throw const FormatException('Feature CSV lacks epoch timestamps');
        sink.writeln('$line,event_markers');
        header = false;
        continue;
      }
      if (line.trim().isEmpty) continue;
      final start = double.parse(fields[startIndex]),
          end = double.parse(fields[endIndex]);
      final selected = events.where((e) {
        final onset = e['onset_s'] as double,
            duration = e['duration_s'] as double;
        return onset < end &&
            (duration > 0 ? onset + duration > start : onset >= start);
      }).toList();
      sink.writeln('$line,${_quote(jsonEncode(selected))}');
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  await temporary.rename(file.path);
}

List<Map<String, dynamic>> readFeatureEvents(String path) {
  final events = <String, Map<String, dynamic>>{};
  // CSV exports contain single-line JSON (newlines are JSON escaped).
  var index = -1;
  for (final line in File(path).readAsLinesSync()) {
    if (index == -1) {
      index = splitFeatureCsvLine(line).indexOf('event_markers');
      if (index < 0) return [];
      continue;
    }
    final fields = splitFeatureCsvLine(line);
    if (fields.length <= index || fields[index].isEmpty) continue;
    final decoded = jsonDecode(fields[index]) as List;
    for (final value in decoded) {
      final event = Map<String, dynamic>.from(value as Map);
      events[jsonEncode(event)] = event;
    }
  }
  return events.values.toList();
}
