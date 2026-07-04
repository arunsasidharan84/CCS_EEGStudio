import 'dart:io';

import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sampleDir = Platform.environment['CCS_EEG_SAMPLE_DATA'];

  test(
    'loads supplied EDF metadata and preview',
    () async {
      final eeg = await RecordingLoader().load('$sampleDir/EEG_RestEyesClosed.edf');
      expect(eeg.labels, isNotEmpty);
      expect(eeg.sampleRate, greaterThan(0));
      expect(eeg.preview.first, isNotEmpty);
    },
    skip: sampleDir == null
        ? 'Set CCS_EEG_SAMPLE_DATA for integration test'
        : false,
  );

  test(
    'loads external-float EEGLAB SET metadata and preview',
    () async {
      final eeg = await RecordingLoader().load('$sampleDir/AKNLTP014_REMED1_RCB.set');
      expect(eeg.labels.length, 129);
      expect(eeg.sampleRate, 1000);
      expect(eeg.dataPath, endsWith('.fdt'));
      expect(eeg.preview.first, isNotEmpty);
    },
    skip: sampleDir == null
        ? 'Set CCS_EEG_SAMPLE_DATA for integration test'
        : false,
  );
}
