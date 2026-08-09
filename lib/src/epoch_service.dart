import 'dart:typed_data';
import 'models.dart';

class EpochOptions {
  const EpochOptions({
    required this.targetEvents,
    this.tmin = -0.5,
    this.tmax = 1.2,
    this.applyBaseline = true,
    this.baselineMin = -0.2,
    this.baselineMax = 0.0,
  });

  /// Event descriptions to epoch on (e.g. ['S 51', 'S 52']).
  final List<String> targetEvents;

  /// Start time relative to event in seconds (e.g. -0.5).
  final double tmin;

  /// End time relative to event in seconds (e.g. 1.2).
  final double tmax;

  /// Whether to apply baseline correction.
  final bool applyBaseline;

  /// Baseline window start relative to event (e.g. -0.2).
  final double baselineMin;

  /// Baseline window end relative to event (e.g. 0.0).
  final double baselineMax;
}

class EpochService {
  /// Generates an epoched [EegRecording] from continuous [recording] based on [options].
  EegRecording generateEpochs({
    required EegRecording recording,
    required EpochOptions options,
  }) {
    if (recording.preview.isEmpty || recording.sampleRate <= 0) {
      throw ArgumentError('Recording contains no valid data or sample rate.');
    }

    final targetSet = options.targetEvents.map((e) => e.trim().toLowerCase()).toSet();
    final matchingMarkers = recording.markers.where((m) {
      final desc = m.description.trim().toLowerCase();
      final type = m.type.trim().toLowerCase();
      if (targetSet.isEmpty) return true;
      return targetSet.contains(desc) ||
          targetSet.contains(type) ||
          targetSet.any((t) => desc.contains(t));
    }).toList();

    matchingMarkers.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));

    if (matchingMarkers.isEmpty) {
      throw StateError(
        'No matching events found for targets: ${options.targetEvents.join(', ')}',
      );
    }

    final rate = recording.sampleRate;
    final totalSamples = recording.sampleCount;
    final numChannels = recording.preview.length;

    final tminSamples = (options.tmin * rate).round();
    final pointsPerEpoch = ((options.tmax - options.tmin) * rate).round();
    if (pointsPerEpoch <= 0) {
      throw ArgumentError('Invalid tmin/tmax window: epoch length must be > 0.');
    }

    final baselineStartRel = ((options.baselineMin - options.tmin) * rate).round().clamp(0, pointsPerEpoch);
    final baselineEndRel = ((options.baselineMax - options.tmin) * rate).round().clamp(0, pointsPerEpoch);

    final epochedChannels = List<List<double>>.generate(numChannels, (_) => <double>[]);
    final epochLabels = <String>[];
    final retainedMarkers = <EegMarker>[];

    int epochIdx = 0;
    for (final marker in matchingMarkers) {
      final eventSample = (marker.startSeconds * rate).round();
      final epochStartSample = eventSample + tminSamples;
      final epochEndSample = epochStartSample + pointsPerEpoch;

      if (epochStartSample < 0 || epochEndSample > totalSamples) {
        continue; // Skip out-of-bounds events near recording edges
      }

      for (var c = 0; c < numChannels; c++) {
        final channelData = recording.preview[c];
        final epochWindow = List<double>.generate(
          pointsPerEpoch,
          (s) => channelData[epochStartSample + s].toDouble(),
        );

        if (options.applyBaseline && baselineEndRel > baselineStartRel) {
          double baselineSum = 0;
          final count = baselineEndRel - baselineStartRel;
          for (var s = baselineStartRel; s < baselineEndRel; s++) {
            baselineSum += epochWindow[s];
          }
          final baselineMean = baselineSum / count;
          for (var s = 0; s < pointsPerEpoch; s++) {
            epochWindow[s] -= baselineMean;
          }
        }

        epochedChannels[c].addAll(epochWindow);
      }

      epochLabels.add(marker.label.isNotEmpty ? marker.label : 'Epoch ${epochIdx + 1}');

      // Extract all markers from continuous recording that fall within this epoch's window
      for (final m in recording.markers) {
        final mSample = (m.startSeconds * rate).round();
        if (mSample >= epochStartSample && mSample < epochEndSample) {
          final relSec = (mSample - epochStartSample) / rate;
          retainedMarkers.add(EegMarker(
            type: m.type,
            description: m.description,
            startSeconds: relSec,
            durationSeconds: m.durationSeconds,
            channelIndex: m.channelIndex,
            epochIndex: epochIdx,
          ));
        }
      }

      epochIdx++;
    }

    if (epochIdx == 0) {
      throw StateError('All matching events fell out of bounds near recording boundaries.');
    }

    final newSampleCount = epochIdx * pointsPerEpoch;
    final epochedPreview = <Float32List>[
      for (var c = 0; c < numChannels; c++)
        Float32List.fromList(epochedChannels[c]),
    ];

    return EegRecording(
      path: '${recording.path}_epoched',
      dataPath: recording.dataPath,
      sampleRate: rate,
      labels: recording.labels,
      preview: epochedPreview,
      sampleCount: newSampleCount,
      format: recording.format,
      epochCount: epochIdx,
      pointsPerEpoch: pointsPerEpoch,
      epochLabels: epochLabels,
      markers: retainedMarkers,
    );
  }
}
