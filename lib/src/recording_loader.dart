import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'edf_loader.dart';
import 'fieldtrip_mat_loader.dart';
import 'fif_loader.dart';
import 'models.dart';
import 'extraction_service.dart' show ExtractionService;
import 'orbit_loader.dart';
import 'set_loader.dart';
import 'vhdr_loader.dart';
import 'xdf_loader.dart';

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
      final full = await Isolate.run(
        () => RecordingLoader()._loadPortable(output),
      );
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
        provenance: recording.provenance,
        epochStartSeconds: recording.epochStartSeconds,
        sourceDurationSeconds: recording.sourceDurationSeconds,
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  final _pendingLoads = <void Function()>[];

  /// Stop actual parsing, not just discard its result after it finishes.
  void cancelPendingLoads() {
    for (final cancel in List.of(_pendingLoads)) {
      cancel();
    }
  }

  Future<EegRecording> load(
    String path, {
    int? xdfStreamId,
    void Function(double?, String)? onProgress,
  }) async {
    final port = ReceivePort();
    final done = Completer<EegRecording>();
    final exited = Completer<void>();
    // Cancellation may arrive while spawn is pending. Observe early errors now;
    // the same error is still forwarded by the await below.
    done.future.ignore();
    Isolate? worker;
    void cancel() {
      worker?.kill(priority: Isolate.immediate);
      if (!done.isCompleted)
        done.completeError(StateError('File loading cancelled'));
    }

    _pendingLoads.add(cancel);
    final subscription = port.listen((message) {
      if (message == null) {
        if (!exited.isCompleted) exited.complete();
        if (!done.isCompleted) {
          done.completeError(
            StateError('File loader stopped before returning a recording'),
          );
        }
        return;
      }
      if (done.isCompleted) return;
      if (message is List && message.first == 'progress') {
        onProgress?.call(message[1] as double?, message[2] as String);
      } else if (message is EegRecording) {
        done.complete(message);
      } else if (message is List && message.first == 'error') {
        done.completeError(FormatException(message[1] as String));
      } else if (message is List) {
        done.completeError(StateError(message.first.toString()));
      }
    });
    try {
      worker = await Isolate.spawn(
        _recordingWorker,
        (path, xdfStreamId, port.sendPort),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (done.isCompleted) worker.kill(priority: Isolate.immediate);
      return await done.future;
    } finally {
      _pendingLoads.remove(cancel);
      worker?.kill(priority: Isolate.immediate);
      // Windows cannot reopen/delete a file until the parsing worker has exited.
      // Keep the exit port alive even when the result was cancelled earlier.
      if (worker != null) await exited.future;
      await subscription.cancel();
      port.close();
    }
  }

  Future<EegRecording> _loadInWorker(
    String path, {
    int? xdfStreamId,
    void Function(double)? onProgress,
  }) async {
    if (path.toLowerCase().endsWith('.xdf'))
      return XdfLoader().load(
        path,
        streamId: xdfStreamId,
        onProgress: onProgress,
      );
    if (path.toLowerCase().endsWith('.ccseeg') ||
        path.toLowerCase().endsWith('.ccseeg.json') ||
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
    return EegRecording(
      path: path,
      sampleRate: eeg.sampleRateHz,
      labels: eeg.channelLabels,
      preview: [
        for (final channel in eeg.channelSamples)
          Float32List.fromList([
            for (var i = 0; i < channel.length; i++) channel[i],
          ]),
      ],
      sampleCount: sampleCount,
      format: 'edf',
      markers: eeg.markers,
    );
  }

  EegRecording _restoreExternalMetadata(EegRecording rec) {
    final sidecar = File('${rec.path}.ccsmeta');
    if (!sidecar.existsSync()) return rec;
    final m = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
    if (m['schema'] != 'ccs-recording-metadata-v1' ||
        m['data_bytes'] != File(rec.path).lengthSync()) {
      throw const FormatException(
        'The .ccsmeta sidecar does not match this recording. Restore the matching signal/metadata pair.',
      );
    }
    final labels = (m['labels'] as List).cast<String>();
    final count = (m['sample_count'] as num).toInt();
    final pts = (m['source_epoch_samples'] as num?)?.toInt();
    final rate = (m['sample_rate'] as num).toDouble();
    if (!rate.isFinite || rate <= 0)
      throw const FormatException('Invalid metadata sampling rate.');
    if (labels.length != rec.labels.length ||
        count <= 0 ||
        count > rec.sampleCount ||
        (pts != null && (pts <= 0 || count % pts != 0))) {
      throw const FormatException('Invalid recording metadata dimensions.');
    }
    return EegRecording(
      path: rec.path,
      dataPath: rec.dataPath,
      format: rec.format,
      sampleRate: rate,
      labels: labels,
      sampleCount: count,
      preview: [
        for (final ch in rec.preview)
          ch.length == rec.sampleCount && count < ch.length
              ? Float32List.sublistView(ch, 0, count)
              : ch,
      ],
      epochCount: pts == null ? 1 : count ~/ pts,
      pointsPerEpoch: pts,
      epochLabels: (m['epoch_labels'] as List?)?.cast<String>(),
      epochTmin: (m['epoch_tmin'] as num?)?.toDouble(),
      markers: [
        for (final v in m['markers'] as List? ?? [])
          EegMarker.fromJson(Map<String, dynamic>.from(v as Map)),
      ],
      provenance: Map<String, dynamic>.from(m['provenance'] as Map? ?? {}),
      completedStages: (m['completed_stages'] as List? ?? []).cast<String>(),
      epochStartSeconds: [
        for (final v in m['epoch_start_seconds'] as List? ?? [])
          (v as num).toDouble(),
      ],
      sourceDurationSeconds: (m['source_duration_seconds'] as num?)?.toDouble(),
    );
  }

  EegRecording _loadPortable(String path) {
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    if (json['format'] != 'ccseeg-v1') {
      throw const FormatException(
        'This JSON is not an EEG recording. Choose a signal file rather than settings, a protocol or a metadata sidecar.',
      );
    }
    final labels = [
      for (final value in json['labels'] as List) value as String,
    ];
    final channels = [
      for (final channel in json['channels'] as List)
        Float32List.fromList([
          for (final value in channel as List) (value as num).toDouble(),
        ]),
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
    if (!json.containsKey('completed_stages') &&
        (File('$path.ccshistory').existsSync() ||
            File('$path.preprocessing.json').existsSync() ||
            RegExp(
              r'(_clean|_preprocessed)\.ccseeg(?:\.json)?$',
              caseSensitive: false,
            ).hasMatch(path))) {
      if (!stages.contains('preprocess')) stages.add('preprocess');
    }
    Map<String, dynamic> provenance = Map<String, dynamic>.from(
      json['provenance'] as Map? ?? {},
    );
    final sidecar = File(
      File('$path.ccshistory').existsSync()
          ? '$path.ccshistory'
          : '$path.preprocessing.json',
    );
    if (sidecar.existsSync() && !json.containsKey('provenance')) {
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
    return EegRecording(
      path: path,
      completedStages: stages,
      provenance: provenance,
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
      preview: channels,
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

Future<void> _recordingWorker((String, int?, SendPort) request) async {
  final (path, streamId, port) = request;
  try {
    port.send(['progress', null, 'Reading and decoding recording…']);
    final loader = RecordingLoader();
    var last = -1;
    final loaded = await loader._loadInWorker(
      path,
      xdfStreamId: streamId,
      onProgress: (value) {
        final percent = (value * 100).floor();
        if (percent != last) {
          last = percent;
          port.send([
            'progress',
            value * .95,
            value < .75
                ? 'Reading XDF streams…'
                : 'Aligning XDF samples and markers…',
          ]);
        }
      },
    );
    port.send([
      'progress',
      null,
      'Restoring annotations and recording metadata…',
    ]);
    port.send(loader._restoreExternalMetadata(loaded));
  } catch (error) {
    port.send(['error', error.toString()]);
  }
}
