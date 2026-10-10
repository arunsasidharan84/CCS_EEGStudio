import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'models.dart';

/// Cropping and sliding subepochs operate on original parent epochs, never
/// on the concatenation of adjacent trials.
class RecordingTransform {
  static EegRecording crop(EegRecording input, double start, double end) {
    if (input.preview.isEmpty ||
        input.preview.any((ch) => ch.length != input.sampleCount)) {
      throw ArgumentError(
        'Full-resolution data must be loaded before preparing a recording.',
      );
    }
    final parentPoints = input.pointsPerEpoch ?? input.sampleCount;
    final a = (start * input.sampleRate).round();
    final b = (end * input.sampleRate).round();
    if (!start.isFinite ||
        !end.isFinite ||
        a < 0 ||
        b <= a ||
        b > parentPoints) {
      throw ArgumentError(
        'Crop endpoints must lie within the recording or each parent epoch.',
      );
    }
    final parents = input.pointsPerEpoch == null
        ? 1
        : input.sampleCount ~/ parentPoints;
    final channels = [
      for (final ch in input.preview)
        Float32List.fromList([
          for (var p = 0; p < parents; p++)
            ...ch.sublist(p * parentPoints + a, p * parentPoints + b),
        ]),
    ];
    final markers = <EegMarker>[];
    for (final marker in input.markers) {
      final time = marker.startSeconds;
      if (time >= start && time < end)
        markers.add(
          EegMarker(
            type: marker.type,
            description: marker.description,
            startSeconds: time - start,
            durationSeconds: math.min(marker.durationSeconds, end - time),
            channelIndex: marker.channelIndex,
            epochIndex: marker.epochIndex,
          ),
        );
    }
    return _copy(
      input,
      channels,
      parents,
      input.pointsPerEpoch == null ? null : b - a,
      markers: markers,
      epochLabels: input.epochLabels,
      epochStartSeconds: input.pointsPerEpoch == null
          ? const []
          : [
              for (var p = 0; p < parents; p++)
                (p < input.epochStartSeconds.length
                        ? input.epochStartSeconds[p]
                        : p * parentPoints / input.sampleRate) +
                    start,
            ],
      sourceDurationSeconds: parents * (end - start),
      epochTmin: input.epochTmin == null ? null : input.epochTmin! + start,
    );
  }

  /// Select complete epochs on the stitched display timeline.
  static EegRecording cropEpochRange(
    EegRecording input,
    double start,
    double end,
  ) {
    final points = input.pointsPerEpoch;
    if (points == null) return crop(input, start, end);
    if (input.preview.any((ch) => ch.length != input.sampleCount))
      throw ArgumentError('Full-resolution data is required');
    final a = (start * input.sampleRate).round(),
        b = (end * input.sampleRate).round();
    if (!start.isFinite ||
        !end.isFinite ||
        a < 0 ||
        b <= a ||
        b > input.sampleCount ||
        a % points != 0 ||
        b % points != 0)
      throw ArgumentError(
        'Across-recording endpoints must align with complete epoch boundaries',
      );
    final first = a ~/ points, last = b ~/ points;
    final markers = <EegMarker>[];
    for (final marker in input.markers) {
      if (marker.epochIndex != null) {
        if (marker.epochIndex! < first || marker.epochIndex! >= last) continue;
        markers.add(
          EegMarker(
            type: marker.type,
            description: marker.description,
            startSeconds: marker.startSeconds,
            durationSeconds: marker.durationSeconds,
            channelIndex: marker.channelIndex,
            epochIndex: marker.epochIndex! - first,
          ),
        );
      } else if (marker.startSeconds >= start && marker.startSeconds < end) {
        markers.add(
          EegMarker(
            type: marker.type,
            description: marker.description,
            startSeconds: marker.startSeconds - start,
            durationSeconds: marker.durationSeconds,
            channelIndex: marker.channelIndex,
          ),
        );
      }
    }
    final original = [
      for (var epoch = first; epoch < last; epoch++)
        epoch < input.epochStartSeconds.length
            ? input.epochStartSeconds[epoch]
            : epoch * points / input.sampleRate,
    ];
    return _copy(
      input,
      [for (final ch in input.preview) Float32List.fromList(ch.sublist(a, b))],
      last - first,
      points,
      markers: markers,
      epochLabels: input.epochLabels?.sublist(first, last),
      epochTmin: input.epochTmin,
      epochStartSeconds: [for (final onset in original) onset - original.first],
      sourceDurationSeconds:
          original.last - original.first + points / input.sampleRate,
    );
  }

  static EegRecording subepoch(
    EegRecording input,
    double duration,
    double overlap,
  ) {
    final window = (duration * input.sampleRate).round();
    final hop = ((duration - overlap) * input.sampleRate).round();
    if (input.preview.isEmpty ||
        input.preview.any((ch) => ch.length != input.sampleCount)) {
      throw ArgumentError(
        'Full-resolution data must be loaded before preparing a recording.',
      );
    }
    final parentPoints = input.pointsPerEpoch ?? input.sampleCount;
    if (!duration.isFinite ||
        !overlap.isFinite ||
        overlap < 0 ||
        window < 2 ||
        hop < 1 ||
        window > parentPoints) {
      throw ArgumentError(
        'Use a positive window within each parent epoch and overlap smaller than the window.',
      );
    }
    final parents = input.pointsPerEpoch == null
        ? 1
        : input.sampleCount ~/ parentPoints;
    final starts = <int>[];
    final onsets = <double>[];
    final labels = <String>[];
    final markers = <EegMarker>[];
    for (var parent = 0; parent < parents; parent++) {
      for (var offset = 0; offset + window <= parentPoints; offset += hop) {
        final epoch = starts.length;
        starts.add(parent * parentPoints + offset);
        onsets.add(
          (parent < input.epochStartSeconds.length
                  ? input.epochStartSeconds[parent]
                  : parent * parentPoints / input.sampleRate) +
              offset / input.sampleRate,
        );
        labels.add(
          '${input.epochLabels != null && parent < input.epochLabels!.length ? input.epochLabels![parent] : 'Trial ${parent + 1}'} / ${(offset / input.sampleRate).toStringAsFixed(3)} s',
        );
        for (final marker in input.markers) {
          if (input.pointsPerEpoch != null && marker.epochIndex != parent)
            continue;
          final sample = (marker.startSeconds * input.sampleRate).round();
          if (sample >= offset && sample < offset + window)
            markers.add(
              EegMarker(
                type: marker.type,
                description: marker.description,
                startSeconds: (sample - offset) / input.sampleRate,
                durationSeconds: math.min(
                  marker.durationSeconds,
                  (offset + window - sample) / input.sampleRate,
                ),
                channelIndex: marker.channelIndex,
                epochIndex: epoch,
              ),
            );
        }
      }
    }
    return _copy(
      input,
      [
        for (final ch in input.preview)
          Float32List.fromList([
            for (final start in starts) ...ch.sublist(start, start + window),
          ]),
      ],
      starts.length,
      window,
      markers: markers,
      epochLabels: labels,
      epochTmin: input.epochTmin,
      epochStartSeconds: onsets,
      sourceDurationSeconds:
          input.sourceDurationSeconds ?? input.durationSeconds,
    );
  }

  static EegRecording _copy(
    EegRecording input,
    List<Float32List> channels,
    int epochs,
    int? points, {
    required List<EegMarker> markers,
    List<String>? epochLabels,
    double? epochTmin,
    List<double> epochStartSeconds = const [],
    double? sourceDurationSeconds,
  }) => EegRecording(
    path: '${input.path}_prepared',
    completedStages: input.completedStages,
    epochStartSeconds: epochStartSeconds,
    sourceDurationSeconds: sourceDurationSeconds,
    sampleRate: input.sampleRate,
    labels: input.labels,
    preview: channels,
    sampleCount: channels.first.length,
    format: 'ccseeg',
    epochCount: epochs,
    pointsPerEpoch: points,
    markers: markers,
    epochLabels: epochLabels,
    epochTmin: epochTmin,
  );

  static Future<void> save(
    EegRecording input,
    String path, {
    required String sourcePath,
    required Map<String, dynamic> operations,
  }) async {
    await File(path).writeAsString(
      jsonEncode({
        'format': 'ccseeg-v1',
        'sample_rate': input.sampleRate,
        'labels': input.labels,
        'channels': [for (final ch in input.preview) ch.toList()],
        'source_epoch_samples': input.pointsPerEpoch,
        'epoch_labels': input.epochLabels,
        'markers': [for (final marker in input.markers) marker.toJson()],
        'completed_stages': input.completedStages,
        'epoch_start_seconds': input.epochStartSeconds,
        'source_duration_seconds': input.sourceDurationSeconds,
        if (input.epochTmin != null) 'epoch_tmin': input.epochTmin,
      }),
    );
    await File(
      '$path.preparation.json',
    ).writeAsString(jsonEncode({'source_path': sourcePath, ...operations}));
  }
}
