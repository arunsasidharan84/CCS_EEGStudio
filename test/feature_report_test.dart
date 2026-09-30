// Renders the new per-recording feature report and the batch TopoStats
// outputs on the Thukdam pilot data (skipped when the data is absent).

import 'dart:io';

import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/report/feature_report.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _analysis =
    '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260710/Analysis_20260922';
const _out =
    '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260710/Figures_TopoStats_Dart';

Future<void> _loadFont() async {
  final f = FontLoader('DejaVuSans')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/DejaVuSans.ttf').readAsBytesSync(),
        ),
      ),
    );
  await f.load();
}

void main() {
  final has = Directory(_analysis).existsSync();

  testWidgets(
    'feature report PDF',
    (tester) async {
      await tester.runAsync(() async {
        await _loadFont();
        Directory(_out).createSync(recursive: true);
        const stem = '$_analysis/4_Pilot_Tukdam_10.07.2026_Pre-Med_Rest_clean';
        final rec = await RecordingLoader().load('$stem.ccseeg.json');
        final sw = Stopwatch()..start();
        await writeFeatureReport(
          outputPath: '$_out/Pre-Med_Rest_features_report.pdf',
          csvPath: '$stem.features.csv',
          recording: rec,
        );
        // ignore: avoid_print
        print(
          'report ${sw.elapsedMilliseconds} ms, '
          '${File('$_out/Pre-Med_Rest_features_report.pdf').lengthSync()} bytes',
        );
      });
    },
    skip: !has,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'batch TopoStats outputs',
    (tester) async {
      await tester.runAsync(() async {
        await _loadFont();
        final csvs =
            Directory(_analysis)
                .listSync()
                .map((e) => e.path)
                .where((p) => p.endsWith('_clean.features.csv'))
                .toList()
              ..sort();
        final sw = Stopwatch()..start();
        final out = await generateTopoStatsFigures(
          csvPaths: csvs,
          outputDir: '$_out/batch',
          onProgress: (p, m) {
            // ignore: avoid_print
            if (m.isNotEmpty) print(m);
          },
        );
        // ignore: avoid_print
        print('batch: ${out.length} figures in ${sw.elapsedMilliseconds} ms');
        expect(out, isNotEmpty);
      });
    },
    skip: !has,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
