import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'edf_loader.dart';
import 'fif_loader.dart';
import 'models.dart';
import 'set_loader.dart';
import 'vhdr_loader.dart';

class RecordingLoader {
  final _setLoader = SetLoader();
  final _vhdrLoader = VhdrLoader();
  final _fifLoader = FifLoader();

  Future<EegRecording> load(String path) async {
    if (path.toLowerCase().endsWith('.ccseeg.json') || path.toLowerCase().endsWith('.json')) return _loadPortable(path);
    if (path.toLowerCase().endsWith('.fif')) {
      return await _fifLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.set')) {
      return await _setLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.vhdr')) {
      return _vhdrLoader.load(path);
    }
    // EDF / EDF+
    final eeg = EdfLoader().load(path);
    final sampleCount = eeg.channelSamples.first.length;
    const stride = 1;
    return EegRecording(
      path: path,
      sampleRate: eeg.sampleRateHz,
      labels: eeg.channelLabels,
      preview: [
        for (final channel in eeg.channelSamples)
          Float32List.fromList([
            for (var i = 0; i < channel.length; i += stride) channel[i],
          ]),
      ],
      sampleCount: sampleCount,
      format: 'edf',
    );
  }

  EegRecording _loadPortable(String path) {
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    if (json['format'] != 'ccseeg-v1') {
      throw const FormatException('Unsupported portable EEG file.');
    }
    final labels = [
      for (final value in json['labels'] as List) value as String,
    ];
    final channels = [
      for (final channel in json['channels'] as List)
        [for (final value in channel as List) (value as num).toDouble()],
    ];
    final sampleRate = (json['sample_rate'] as num).toDouble();
    final sampleCount = channels.isEmpty ? 0 : channels.first.length;
    final sourceEpochSamples = (json['source_epoch_samples'] as num?)?.toInt();
    final int? pointsPerEpoch = (sourceEpochSamples != null && sourceEpochSamples > 0) ? sourceEpochSamples : null;
    final int epochCount = (pointsPerEpoch != null && pointsPerEpoch > 0 && sampleCount >= pointsPerEpoch)
        ? (sampleCount ~/ pointsPerEpoch)
        : 1;
    final epochLabels = json['epoch_labels'] == null
        ? null
        : [for (final value in json['epoch_labels'] as List) value as String];
    const stride = 1;
    return EegRecording(
      path: path,
      sampleRate: sampleRate,
      labels: labels,
      preview: [
        for (final channel in channels)
          Float32List.fromList([
            for (var i = 0; i < channel.length; i += stride) channel[i],
          ]),
      ],
      sampleCount: sampleCount,
      format: 'ccseeg',
      epochCount: epochCount,
      pointsPerEpoch: pointsPerEpoch,
      epochLabels: epochLabels,
    );
  }
}
