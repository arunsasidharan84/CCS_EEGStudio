import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_details.dart';
import 'package:ccs_eeg_app/src/recording_save_dialog.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/processing_progress.dart';
import 'package:ccs_eeg_app/src/erp/output_naming.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';

void main() {
  test('save panels receive a stem and canonical output has one extension', () {
    expect(recordingDialogStem('Sakshi-epo_clean.edf.edf'), 'Sakshi-epo_clean');
    expect(
      RecordingStorage.withExtension('Sakshi.edf.edf', RecordingFileFormat.edf),
      'Sakshi.edf',
    );
    expect(
      erpOutputName(
        'Sakshi-epo_clean.edf.edf',
        epoched: true,
        cleaned: true,
        extension: 'edf',
      ),
      'Sakshi-epo_clean.edf',
    );
    expect(
      erpOutputName(
        'test.xdf',
        epoched: false,
        cleaned: true,
        extension: 'edf',
      ),
      'test_clean.edf',
    );
  });
  test(
    'legacy saved timing is recovered from recorded parent protocol',
    () async {
      final temp = Directory.systemTemp.createTempSync('history-timing-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final r = EegRecording(
        path: 'memory',
        sampleRate: 100,
        labels: ['Fz'],
        preview: [Float32List(100)],
        sampleCount: 100,
        pointsPerEpoch: 50,
        epochCount: 2,
        epochLabels: ['Standard', 'Pleasant'],
        format: 'ccseeg',
        provenance: {
          'parent_provenance': {
            'epoch_protocol': {'tmin': -.5},
          },
          'preprocessing': {
            'ica_method': 'runica',
            'ica_fit_asr': true,
            'asr_mode': 'off',
          },
          'summary': {
            'warnings': ['ICA/ASR skipped: short filter'],
            'ica': null,
          },
        },
      );
      final path = '${temp.path}/epochs.edf';
      await RecordingStorage.save(r, path);
      final restored = await RecordingLoader().load(path);
      expect(restored.epochTmin, -.5);
      expect(recordingWarnings(restored), ['ICA/ASR skipped: short filter']);
      expect(
        recordingHistory(
          restored,
        ).any((v) => v.$1 == 'ICA / ICLabel' && v.$2.contains('not completed')),
        isTrue,
      );
      expect(
        recordingHistory(restored).any((v) => v.$1 == 'ICA training-copy ASR'),
        isTrue,
      );
    },
  );
  testWidgets(
    'processing shows elapsed time, iteration ceiling and cancellation',
    (tester) async {
      var stopped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessingProgress(
              progress: .48,
              message: 'ICA iteration 12/512 (convergence dependent)',
              stopping: false,
              onCancel: () => stopped = true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('Elapsed 0m'), findsOneWidget);
      expect(find.textContaining('at most 512'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      expect(stopped, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'preprocessing/export retains event zero and progress never runs backwards',
    () async {
      final temp = Directory.systemTemp.createTempSync('processing-timing-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final rec = EegRecording(
        path: '${temp.path}/input.ccseeg',
        format: 'ccseeg',
        sampleRate: 100,
        labels: ['Fz'],
        sampleCount: 100,
        preview: [
          Float32List.fromList(List.generate(100, (i) => i.toDouble())),
        ],
        epochCount: 2,
        pointsPerEpoch: 50,
        epochTmin: -.2,
        epochLabels: ['Standard', 'Pleasant'],
      );
      final cfg = AnalysisConfig()
        ..filter = false
        ..downsample = false
        ..badChannels = false
        ..interpolate = false
        ..gedai = false
        ..epochBeforeGedai = false;
      final progress = <double>[];
      final cleaned = await ExtractionService().preprocess(
        recording: rec,
        outputPath: '${temp.path}/clean.edf',
        options: cfg.toPreprocessingOptions(),
        onProgress: (p, message) => progress.add(p),
      );
      expect(cleaned.epochTmin, -.2);
      expect(cleaned.epochLabels, ['Standard', 'Pleasant']);
      expect(cleaned.epochCount, 2);
      expect(progress.last, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    },
  );
}
