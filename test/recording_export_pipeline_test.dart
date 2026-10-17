import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';

void main() {
  for (final fmt in [RecordingFileFormat.fif, RecordingFileFormat.edf]) {
    test('${fmt.name} exported epochs work in native ERP analysis', () async {
      final dir = Directory.systemTemp.createTempSync('ccs-export-native');
      addTearDown(() => dir.deleteSync(recursive: true));
      final rec = EegRecording(
        path: 'memory',
        format: 'ccseeg',
        sampleRate: 100,
        labels: ['Fz', 'Pz'],
        sampleCount: 115 * 8,
        preview: [
          for (var c = 0; c < 2; c++)
            Float32List.fromList([
              for (var i = 0; i < 115 * 8; i++)
                math.sin(i * .2 + c) + ((i ~/ 115) % 2) * 2,
            ]),
        ],
        epochCount: 8,
        pointsPerEpoch: 115,
        epochLabels: [
          for (var e = 0; e < 8; e++) e % 2 == 0 ? 'Target' : 'Standard',
        ],
        epochTmin: -.2,
        epochStartSeconds: [for (var e = 0; e < 8; e++) 10 + e * 3.0],
      );
      final path = '${dir.path}/epochs.${fmt.name}';
      await RecordingStorage.save(rec, path);
      final job = File('${dir.path}/job.json');
      job.writeAsStringSync(
        jsonEncode({
          'job_type': 'erp_workbench',
          'inputs': [
            {'path': path, 'subject': '01'},
          ],
          'output': '${dir.path}/results',
          'options': {
            'task': 'Custom',
            'permutations': 100,
            'correct_only': false,
            'profile_override': {
              'task': 'Custom',
              'a_codes': ['Target'],
              'b_codes': ['Standard'],
              'a_name': 'Target',
              'b_name': 'Standard',
              'roi': ['Fz'],
              'epoch': [-.2, .94],
              'baseline': [-.2, 0],
              'window': [.3, .6],
              'polarity': 1,
              'lateralized': false,
            },
          },
        }),
      );
      final result = await Process.run(ExtractionService.findEngine(), [
        job.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final report = jsonDecode(
        File('${dir.path}/results/erp_results.ccserp').readAsStringSync(),
      );
      expect(report['failures'], isEmpty);
      expect(report['files'][0]['n_a'], 4);
      expect(report['files'][0]['n_b'], 4);
      expect(
        report['files'][0]['accepted_events'][0]['onset_s'],
        closeTo(10.2, 1e-9),
      );
    });
    test(
      'preprocessing saves directly as ${fmt.name} with history and events',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'ccs-preprocess-export',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final rec = EegRecording(
          path: 'memory',
          format: 'ccseeg',
          sampleRate: 100,
          labels: ['Fz', 'Pz'],
          sampleCount: 1000,
          preview: [Float32List(1000), Float32List(1000)],
          markers: const [
            EegMarker(type: 'Stimulus', description: 'S 10', startSeconds: 2),
          ],
        );
        final path = '${dir.path}/clean.${fmt.name}';
        await ExtractionService().preprocess(
          recording: rec,
          outputPath: path,
          options: const PreprocessingOptions(
            downsample: false,
            downsampleFreq: 100,
            filter: false,
            lowHz: .5,
            highHz: 40,
            notchHz: 50,
            badchannel: false,
            gedai: false,
            interpolate: false,
            gedaiEpochSeconds: 1,
            gedaiThreshold: 'auto',
          ),
          onProgress: (_, _) {},
        );
        final loaded = await RecordingLoader().load(path);
        expect(loaded.completedStages, contains('preprocess'));
        expect(loaded.markers.single.startSeconds, 2);
        expect(loaded.provenance['preprocessing'], isMap);
        expect(File('$path.ccsmeta').existsSync(), true);
        expect(File('$path.preprocessing.json').existsSync(), false);
      },
    );
  }
}
