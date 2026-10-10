import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'edf_loader.dart';
import 'fieldtrip_mat_loader.dart';
import 'fif_loader.dart';
import 'models.dart';
import 'extraction_service.dart' show ExtractionService;
import 'orbit_loader.dart';
import 'set_loader.dart';
import 'vhdr_loader.dart';

class RecordingLoader {
  final _setLoader = SetLoader();
  final _vhdrLoader = VhdrLoader();
  final _fifLoader = FifLoader();
  final _fieldTripMatLoader = FieldTripMatLoader();

  /// Materialize full samples only when a preparation operation needs them.
  Future<EegRecording> loadFull(EegRecording recording) async {
    if (recording.preview.isNotEmpty &&
        recording.preview.every((ch) => ch.length == recording.sampleCount))
      return recording;
    if (recording.preview.isNotEmpty &&
        recording.preview.first.length == recording.sampleCount)
      throw StateError(
        'This recording contains channels with different sampling rates. Select or resample matching-rate channels before preparing it.',
      );
    final temp = await Directory.systemTemp.createTemp('ccs_full_recording_');
    try {
      final output = '${temp.path}/full.ccseeg.json';
      final job = File('${temp.path}/job.json');
      await job.writeAsString(
        jsonEncode({
          'job_type': 'export_portable',
          'input': recording.path,
          'output': output,
          'format': recording.format,
          'data_path': recording.dataPath,
          'sample_rate': recording.sampleRate,
          'labels': recording.labels,
          'sample_count': recording.sampleCount,
          'epoch_count': recording.epochCount,
          'points_per_epoch': recording.pointsPerEpoch,
          'epoch_seconds': 1,
          'selected_channels': recording.labels,
          'options': {
            'mode': 'full',
            'start_seconds': 0,
            'end_seconds': 0,
            'bin_seconds': 60,
            'psd': false,
            'fooof': false,
            'irasa': false,
            'nonlinear': false,
            'acw': false,
            'connectivity': false,
          },
        }),
      );
      final result = await Process.run(ExtractionService.findEngine(), [
        job.path,
      ]);
      if (result.exitCode != 0)
        throw StateError(
          'Could not load full-resolution data: ${result.stderr}',
        );
      final full = _loadPortable(output);
      if (full.sampleCount != recording.sampleCount)
        throw StateError(
          'Full-resolution export does not match the input sample count.',
        );
      return EegRecording(
        path: recording.path,
        dataPath: recording.dataPath,
        sampleRate: full.sampleRate,
        labels: full.labels,
        preview: full.preview,
        sampleCount: full.sampleCount,
        format: recording.format,
        epochCount: full.epochCount,
        pointsPerEpoch: full.pointsPerEpoch,
        epochLabels: full.epochLabels,
        epochTmin: recording.epochTmin,
        markers: recording.markers,
        completedStages: recording.completedStages,
        epochStartSeconds: recording.epochStartSeconds,
        sourceDurationSeconds: recording.sourceDurationSeconds,
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<EegRecording> load(String path) async {
    if (path.toLowerCase().endsWith('.ccseeg.json') ||
        path.toLowerCase().endsWith('.json'))
      return _loadPortable(path);
    if (path.toLowerCase().endsWith('.fif')) {
      return await _fifLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.mat')) {
      return await _fieldTripMatLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.set')) {
      return await _setLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.vhdr')) {
      return _vhdrLoader.load(path);
    }
    if (path.toLowerCase().endsWith('.orb') ||
        path.toLowerCase().endsWith('.signal')) {
      return OrbLoader().load(path);
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
      markers: eeg.markers,
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
    final int? pointsPerEpoch =
        (sourceEpochSamples != null && sourceEpochSamples > 0)
        ? sourceEpochSamples
        : null;
    final int epochCount =
        (pointsPerEpoch != null &&
            pointsPerEpoch > 0 &&
            sampleCount >= pointsPerEpoch)
        ? (sampleCount ~/ pointsPerEpoch)
        : 1;
    final epochLabels = json['epoch_labels'] == null
        ? null
        : [for (final value in json['epoch_labels'] as List) value as String];
    var markers = json['markers'] == null
        ? const <EegMarker>[]
        : [
            for (final m in json['markers'] as List)
              EegMarker.fromJson(m as Map<String, dynamic>),
          ];
    final stages =
        (json['completed_stages'] as List?)?.cast<String>().toList() ??
        <String>[];
    if (File('$path.preprocessing.json').existsSync() ||
        RegExp(
          r'(_clean|_preprocessed)\.ccseeg\.json$',
          caseSensitive: false,
        ).hasMatch(path)) {
      if (!stages.contains('preprocess')) stages.add('preprocess');
    }
    Map<String, dynamic> provenance = {};
    final sidecar = File('$path.preprocessing.json');
    if (sidecar.existsSync()) {
      try {
        provenance =
            jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {}
    }
    if ((provenance['summary'] as Map?)?['source_localized'] == true &&
        !stages.contains('source'))
      stages.add('source');
    final onsets =
        (json['epoch_start_seconds'] ?? provenance['epoch_start_seconds'])
            as List?;
    if (markers.isEmpty && provenance['markers'] is List) {
      markers = [
        for (final marker in provenance['markers'] as List)
          EegMarker.fromJson(Map<String, dynamic>.from(marker as Map)),
      ];
    }
    const stride = 1;
    return EegRecording(
      path: path,
      completedStages: stages,
      epochStartSeconds:
          onsets?.map((value) => (value as num).toDouble()).toList() ??
          const [],
      sourceDurationSeconds:
          ((json['source_duration_seconds'] ??
                      provenance['source_duration_seconds'])
                  as num?)
              ?.toDouble(),
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
      markers: markers,
      epochTmin: (json['epoch_tmin'] as num?)?.toDouble(),
    );
  }
}
