import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/epoch_service.dart';
import 'package:ccs_eeg_app/src/recording_transform.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/erp/protocol_tools.dart';
import 'package:ccs_eeg_app/src/erp/output_naming.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';

void main() {
  test(
    'protocol preserves named events, baseline and averaging without paths',
    () {
      final config = AnalysisConfig()
        ..stimMarkers = ['11', '21']
        ..stimMarkerGroups = {
          'Correct': ['11'],
          'Error': ['21'],
        }
        ..stimTmin = -.3
        ..stimTmax = .8
        ..erpAnalysisProtocol = {
          'task': 'ERN',
          'profile_override': {
            'a_codes': ['Correct'],
            'b_codes': ['Error'],
            'roi': ['FCz'],
            'window': [0, .1],
          },
        };
      final saved =
          jsonDecode(jsonEncode(erpProtocolJson(config)))
              as Map<String, dynamic>;
      final restored = AnalysisConfig();
      applyErpProtocol(restored, saved);
      expect(restored.stimEpochSpec!.markerGroups, config.stimMarkerGroups);
      expect(restored.stimTmin, -.3);
      expect(restored.erpAnalysisProtocol, config.erpAnalysisProtocol);
      expect(restored.epochBeforeGedai, false);
      expect(
        () => applyErpProtocol(restored, {'schema': 'unknown'}),
        throwsFormatException,
      );
      saved['epoching']['tmax'] = -1;
      expect(() => applyErpProtocol(restored, saved), throwsFormatException);
      expect(restored.stimTmax, .8);
    },
  );
  test('derived names do not accumulate clean and epoch suffixes', () {
    expect(
      erpOutputName('/tmp/39_ERN_cleaned.edf', epoched: true, cleaned: true),
      '39_ERN_cleaned-epo_clean.ccseeg.json',
    );
    expect(
      erpOutputName(
        '39_ERN-epo_clean.ccseeg.json',
        epoched: true,
        cleaned: true,
      ),
      '39_ERN-epo_clean.ccseeg.json',
    );
    expect(
      erpOutputName('39_ERN-epo.ccseeg.json', epoched: true, cleaned: true),
      '39_ERN-epo_clean.ccseeg.json',
    );
  });
  test(
    'saved direct epochs retain cleaning, original anchors and condition labels',
    () async {
      final dir = Directory.systemTemp.createTempSync('erp-protocol');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = EegRecording(
        path: '${dir.path}/ERN_clean.ccseeg.json',
        sampleRate: 100,
        labels: const ['FCz'],
        preview: [Float32List(1000)],
        sampleCount: 1000,
        format: 'ccseeg-v1',
        completedStages: const ['preprocessing'],
        markers: const [
          EegMarker(type: 'Event', description: '11', startSeconds: 2),
          EegMarker(type: 'Event', description: '21', startSeconds: 5),
        ],
      );
      final epochs = EpochService().generateEpochs(
        recording: input,
        options: const EpochOptions(
          targetEvents: ['11', '21'],
          markerGroups: {
            'Correct': ['11'],
            'Error': ['21'],
          },
          tmin: -.2,
          tmax: .5,
        ),
      );
      final path = '${dir.path}/ERN-epo_clean.ccseeg.json';
      await RecordingTransform.save(
        epochs,
        path,
        sourcePath: input.path,
        operations: {},
      );
      final saved = jsonDecode(await File(path).readAsString()) as Map;
      expect(saved['epoch_onsets'], [2.0, 5.0]);
      final loaded = await RecordingLoader().load(path);
      expect(loaded.epochCount, 2);
      expect(loaded.epochLabels, ['Correct', 'Error']);
      expect(loaded.epochTmin, -.2);
      expect(loaded.completedStages, contains('preprocessing'));
      if (File('bridge/target/release/ccs-eeg-engine').existsSync()) {
        final inspected = await ErpWorkbenchService().execute(
          [
            {'path': path, 'subject': '01'},
          ],
          {'task': 'ERN'},
          dir.path,
          inspect: true,
        );
        final file = (inspected['files'] as List).single as Map;
        expect(file['is_epoched'], true);
        expect(file['marker_counts'], {'Correct': 1, 'Error': 1});
        expect(file['profile'], isNotNull);
      }
    },
  );
}
