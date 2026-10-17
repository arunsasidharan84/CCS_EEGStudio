import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/filtered_file_picker.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/recording_transform.dart';
import 'package:ccs_eeg_app/src/models.dart';

void main() {
  test('recording picker excludes metadata, protocols and results', () {
    final dir = Directory.systemTemp.createTempSync('ccs-file-identity');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final name in [
      'x.preprocessing.json',
      'x.preparation.json',
      'protocol.json',
      'erp_results.json',
    ]) {
      final file = File('${dir.path}/$name')
        ..writeAsStringSync('{"source_path":"x","schema":"settings"}');
      expect(isEegRecordingFile(file.path), false);
    }
    final signal = File('${dir.path}/P300_v01.json')
      ..writeAsStringSync('{"format":"ccseeg-v1","channels":[[1.0]]}');
    expect(isEegRecordingFile(signal.path), true);
  });
  test(
    'dedicated extension preserves signals, event times and epoch labels',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'ccs-dedicated-extension',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final rec = EegRecording(
        path: 'memory',
        format: 'ccseeg',
        sampleRate: 100,
        labels: ['Fz'],
        sampleCount: 4,
        preview: [
          Float32List.fromList([1, 2, 3, 4]),
        ],
        epochCount: 2,
        pointsPerEpoch: 2,
        epochLabels: ['Correct', 'Incorrect'],
        epochTmin: -.01,
        markers: const [
          EegMarker(
            type: 'Stimulus',
            description: 'S10',
            startSeconds: .01,
            epochIndex: 0,
          ),
        ],
      );
      final path = '${dir.path}/P300-epo_clean.ccseeg';
      await RecordingTransform.save(
        rec,
        path,
        sourcePath: 'memory',
        operations: {},
      );
      final restored = await RecordingLoader().load(path);
      expect(restored.preview.single, rec.preview.single);
      expect(restored.epochLabels, rec.epochLabels);
      expect(restored.markers.single.startSeconds, .01);
      expect(restored.pointsPerEpoch, 2);
    },
  );
}
