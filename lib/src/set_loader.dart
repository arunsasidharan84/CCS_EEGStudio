import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'extraction_service.dart';
import 'models.dart';

class SetLoader {
  /// Load a .set file. The companion .fdt is resolved from the same folder.
  /// An optional [fdtOverridePath] can be provided when the .fdt lives
  /// somewhere else (e.g. user explicitly selected it).
  Future<EegRecording> load(String path, {String? fdtOverridePath}) async {
    final executable = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_inspect_');
    final job = File('${temp.path}/inspect.json');
    await job.writeAsString(jsonEncode({
      'job_type': 'inspect_set',
      'input': path,
      'output': '',
      'format': 'set',
      'epoch_seconds': 1.0,
      'options': {
        'mode': 'inspect',
        'start_seconds': 0.0,
        'end_seconds': 0.0,
        'bin_seconds': 1.0,
        'psd': false,
        'fooof': false,
        'irasa': false,
        'nonlinear': false,
        'acw': false,
        'connectivity': false,
      },
    }));

    final process = await Process.run(executable, [job.path]);
    try { await temp.delete(recursive: true); } catch (_) {}

    if (process.exitCode != 0) {
      throw FormatException(
          'Engine failed to inspect SET file: ${process.stderr}');
    }

    final jsonStr = process.stdout
        .toString()
        .split('\n')
        .where((l) => !l.startsWith('PROGRESS') && l.trim().isNotEmpty)
        .join('\n');

    final data = jsonDecode(jsonStr);
    final srate = (data['sample_rate'] as num).toDouble();
    final labels = List<String>.from(data['labels']);
    final sampleCount = data['sample_count'] as int;
    final epochCount = data['epoch_count'] as int;
    final pointsPerEpoch = data['points_per_epoch'] as int;
    final datfile = data['datfile'] as String? ?? '';

    final channelCount = labels.length;

    // Resolve companion .fdt path (same folder as the .set)
    final String? fdtPath = fdtOverridePath ??
        (datfile.isEmpty
            ? null
            : File(path).parent.uri.resolve(datfile).toFilePath());

    final List<Float32List> preview;
    if (fdtPath == null) {
      preview = _previewZero(channelCount, sampleCount);
    } else {
      // No sandbox — direct read. If the file is missing, throw clearly.
      if (!File(fdtPath).existsSync()) {
        throw FileSystemException(
            'Companion .fdt file not found. Expected: $fdtPath', fdtPath);
      }
      preview = _readFdt(fdtPath, channelCount, sampleCount);
    }

    final markers = data['markers'] == null
        ? const <EegMarker>[]
        : [
            for (final m in data['markers'] as List)
              EegMarker.fromJson(m as Map<String, dynamic>),
          ];

    return EegRecording(
      path: path,
      dataPath: fdtPath,
      sampleRate: srate,
      labels: labels,
      preview: preview,
      sampleCount: sampleCount,
      format: 'set',
      epochCount: epochCount,
      pointsPerEpoch: pointsPerEpoch,
      markers: markers,
    );
  }

  /// Read EEGLAB .fdt binary data.
  ///
  /// EEGLAB writes EEG.data ([nchans × nframes]) via MATLAB fwrite which uses
  /// column-major order → the binary layout on disk is:
  ///   [ch0_t0, ch1_t0, … chN_t0, ch0_t1, ch1_t1, … chN_t1, …]
  /// i.e. offset for channel c at sample s = (s × nchans + c) × 4 bytes.
  List<Float32List> _readFdt(String fdtPath, int channels, int samples) {
    final bytes = File(fdtPath).readAsBytesSync();
    final expected = channels * samples * 4;
    if (bytes.length < expected) {
      throw FormatException(
          'FDT truncated: expected $expected bytes, got ${bytes.length}.');
    }
    final bd = ByteData.sublistView(bytes);
    const stride = 1;
    return [
      for (var c = 0; c < channels; c++)
        Float32List.fromList([
          for (var s = 0; s < samples; s += stride)
            bd.getFloat32((s * channels + c) * 4, Endian.little),
        ]),
    ];
  }

  List<Float32List> _previewZero(int channels, int samples) {
    const stride = 1;
    final pnts = (samples / stride).ceil();
    return [for (var c = 0; c < channels; c++) Float32List(pnts)];
  }
}
