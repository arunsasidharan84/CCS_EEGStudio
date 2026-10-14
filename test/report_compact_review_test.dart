import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/report/feature_report.dart';

void main() {
  const csv =
      '/Users/arunsasidharan/EEGdata/OpenDatasets/Testbin/sub-PC001_ses-01_task-meditation_Clean-ft.features.csv';
  const mat =
      '/Users/arunsasidharan/EEGdata/OpenDatasets/psiconnect whole dataset/sub-PC001_ses-01_task-meditation_Clean-ft.mat';
  testWidgets(
    'compact report for 64-channel FieldTrip input',
    (tester) async {
      await tester.runAsync(() async {
        final font = FontLoader('DejaVuSans')
          ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
        await font.load();
        final rec = await RecordingLoader().load(mat);
        await writeFeatureReport(
          outputPath: 'output/pdf/PC001_compact_report.pdf',
          csvPath: csv,
          recording: rec,
          epochSeconds: 5,
        );
        expect(
          File('output/pdf/PC001_compact_report.pdf').lengthSync(),
          greaterThan(1000),
        );
      });
    },
    skip: !File(csv).existsSync() || !File(mat).existsSync(),
  );
}
