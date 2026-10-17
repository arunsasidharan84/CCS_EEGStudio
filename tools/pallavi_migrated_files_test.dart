import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/erp/protocol_tools.dart';

void main() {
  test(
    'migrated Pallavi signals retain trials, markers and preprocessing history',
    () async {
      const root = '/Users/arunsasidharan/EEGdata/Pallavi';
      final loader = RecordingLoader();
      final cleaned = await loader.load(
        '$root/Pallavi_Task_Pre_2_clean.ccseeg',
      );
      expect(cleaned.sampleCount, 289130);
      expect(cleaned.sampleRate, 250);
      expect(cleaned.completedStages, contains('preprocess'));
      expect(cleaned.markers.length, greaterThan(1000));
      final epochs = await loader.load('$root/P300_v01.ccseeg');
      expect(epochs.epochCount, 483);
      expect(epochs.pointsPerEpoch, 501);
      expect(epochs.epochLabels!.where((s) => s == 'Standard').length, 280);
      expect(epochs.epochLabels!.where((s) => s == 'Pleasant').length, 39);
      final config = AnalysisConfig();
      applyErpProtocol(
        config,
        Map<String, dynamic>.from(
          jsonDecode(File('$root/P300_erp.ccsprotocol').readAsStringSync()),
        ),
      );
      expect(config.stimMarkers, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
