import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'extraction_service.dart';
import 'models.dart';

class FifLoader {
  Future<EegRecording> load(String path) async {
    final executable = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_fif_');
    final job = File('${temp.path}/inspect_fif.json');
    await job.writeAsString(jsonEncode({
      'job_type': 'inspect_fif',
      'input': path,
      'output': '',
      'format': 'fif',
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
        'mic': false,
        'mim': false,
        'gc': false,
        'gc_tr': false,
        'coh': false,
        'plv': false,
        'ciplv': false,
        'pli': false,
        'wpli': false,
        'remove_non_eeg': false,
        'exclusions': [],
      },
    }));

    final process = await Process.run(executable, [job.path]);
    try {
      await temp.delete(recursive: true);
    } catch (_) {}

    if (process.exitCode != 0) {
      throw FormatException(
          'Engine failed to inspect FIF file: ${process.stderr}');
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

    final epochLabels = data['epoch_labels'] == null
        ? null
        : List<String>.from(data['epoch_labels']);

    final previewList = data['preview'] as List;
    final preview = <Float32List>[
      for (final ch in previewList)
        Float32List.fromList([for (final val in ch as List) (val as num).toDouble()]),
    ];

    return EegRecording(
      path: path,
      sampleRate: srate,
      labels: labels,
      preview: preview,
      sampleCount: sampleCount,
      format: 'fif',
      epochCount: epochCount,
      pointsPerEpoch: pointsPerEpoch,
      epochLabels: epochLabels,
    );
  }
}
