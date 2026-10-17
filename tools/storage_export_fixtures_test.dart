// Generate small interchange fixtures for independent MNE/EDF verification.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';

void main() {
  test('write continuous and epoched interchange fixtures', () async {
    final dir = Directory('/tmp/ccs-storage-reference');
    await dir.create(recursive: true);
    for (final epochs in [false, true]) {
      final r = EegRecording(
        path: 'memory',
        sampleRate: 100,
        labels: ['Fz', 'Long_electrode_name'],
        sampleCount: 230,
        format: 'ccseeg',
        preview: [
          for (var c = 0; c < 2; c++)
            Float32List.fromList([
              for (var i = 0; i < 230; i++) 30 * math.sin(i * .17 + c),
            ]),
        ],
        pointsPerEpoch: epochs ? 115 : null,
        epochCount: epochs ? 2 : 1,
        epochLabels: epochs ? ['Target', 'Standard'] : null,
        epochTmin: epochs ? -.2 : null,
        epochStartSeconds: epochs ? [10, 20] : [],
        completedStages: ['preprocess'],
        markers: [
          EegMarker(
            type: 'Stimulus',
            description: 'S 10',
            startSeconds: .2,
            epochIndex: epochs ? 0 : null,
          ),
        ],
      );
      for (final fmt in RecordingFileFormat.values)
        await RecordingStorage.save(
          r,
          '${dir.path}/${epochs ? 'epochs' : 'raw'}.${fmt.name}',
          provenance: {
            'epoch_protocol': {'tmin': -.2, 'tmax': .94},
          },
        );
    }
  });
}
