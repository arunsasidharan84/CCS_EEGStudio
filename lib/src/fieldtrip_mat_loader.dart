import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'extraction_service.dart';
import 'models.dart';

/// Loads FieldTrip MATLAB v5 files containing an `ftData` struct.
class FieldTripMatLoader {
  Future<EegRecording> load(String path) async {
    final executable = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_mat_');
    final job = File('${temp.path}/inspect_mat.json');
    await job.writeAsString(
      jsonEncode({
        'job_type': 'inspect_mat',
        'input': path,
        'output': '',
        'format': 'mat',
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
      }),
    );

    final process = await Process.run(executable, [job.path]);
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
    if (process.exitCode != 0) {
      throw FormatException(
        'Engine failed to inspect FieldTrip MAT file: ${process.stderr}',
      );
    }
    final jsonText = process.stdout
        .toString()
        .split('\n')
        .where((line) => !line.startsWith('PROGRESS') && line.trim().isNotEmpty)
        .join('\n');
    final data = jsonDecode(jsonText) as Map<String, dynamic>;
    final preview = <Float32List>[
      for (final channel in data['preview'] as List)
        Float32List.fromList([
          for (final value in channel as List) (value as num).toDouble(),
        ]),
    ];
    return EegRecording(
      path: path,
      sampleRate: (data['sample_rate'] as num).toDouble(),
      labels: List<String>.from(data['labels'] as List),
      preview: preview,
      sampleCount: data['sample_count'] as int,
      format: 'mat',
      epochCount: data['epoch_count'] as int,
      pointsPerEpoch: data['points_per_epoch'] as int,
      epochLabels: data['epoch_labels'] == null
          ? null
          : List<String>.from(data['epoch_labels'] as List),
    );
  }
}
