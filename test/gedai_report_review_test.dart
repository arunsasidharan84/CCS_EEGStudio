import 'dart:io';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/report/feature_report.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GEDAI threshold is shared by preprocessing configuration', () {
    final cfg = AnalysisConfig()..gedaiThreshold = '4.5';
    expect(cfg.toPreprocessingOptions().toJson()['gedai_threshold'], '4.5');
  });
  testWidgets(
    'render matched raw and cleaned report for review',
    (tester) async {
      await tester.runAsync(() async {
        final font = FontLoader('DejaVuSans')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                File('assets/fonts/DejaVuSans.ttf').readAsBytesSync(),
              ),
            ),
          );
        await font.load();
        final loader = RecordingLoader();
        final raw = await loader.load(
          '/Users/arunsasidharan/EEGdata/EEG_analysis_demo/Girish/SampleData/Sub01_03_WMTask01.edf',
        );
        final clean = await loader.load(
          '/Users/arunsasidharan/EEGdata/EEG_analysis_demo/TestBin/Sub01_03_WMTask01_clean.ccseeg.json',
        );
        await writeFeatureReport(
          outputPath:
              '${Directory.current.path}/output/pdf/Sub01_03_WMTask01_review.pdf',
          csvPath:
              '/Users/arunsasidharan/EEGdata/EEG_analysis_demo/TestBin/Sub01_03_WMTask01_clean.features.csv',
          recording: clean,
          raw: raw,
          prep: (AnalysisConfig()..downsample = false).toPreprocessingOptions(),
        );
      });
    },
    skip: !File(
      '/Users/arunsasidharan/EEGdata/EEG_analysis_demo/TestBin/Sub01_03_WMTask01_clean.features.csv',
    ).existsSync(),
  );
}
