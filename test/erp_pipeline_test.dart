// test/erp_pipeline_test.dart
//
// End-to-end ERP pipeline on raw BrainVision recordings, run with the real
// engine (bridge/target/release/ccs-eeg-engine):
//   raw .vhdr -> downsample 250 Hz + filter -> stimulus epochs S 51 / S 52
//   (-0.5..1.2 s, baseline -0.2..0) -> bad channels + GEDAI (one trial per
//   window) + interpolation -> *-epo_clean.ccseeg.json -> ERP analysis at Fz.
// Skipped when the data are not on this machine.

import 'dart:io';

import 'package:ccs_eeg_app/src/channel_types.dart';
import 'package:ccs_eeg_app/src/erp/erp_engine.dart';
import 'package:ccs_eeg_app/src/erp/erp_view.dart' show exportErpOutputs;
import 'package:ccs_eeg_app/src/extraction_service.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _study = '/Users/arunsasidharan/EEGdata/ThukdamStudy';

final _cases = [
  (
    '$_study/20260710/RawData/2_Pilot_Tukdam_10.07.2026_EM_MMN_VR.vhdr',
    '$_study/20260710/Figures_TopoStats_Dart/erp_pipeline',
  ),
  (
    '$_study/20260922/RawData/2_Pilot_Tukdam_22.09.2026_Meditation.vhdr',
    '$_study/20260922/Analysis_20260922/ERP',
  ),
];

Future<void> _fonts() async {
  final f = FontLoader('DejaVuSans')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/DejaVuSans.ttf').readAsBytesSync(),
        ),
      ),
    );
  await f.load();
  const mono = '/System/Library/Fonts/Supplemental/Courier New.ttf';
  if (File(mono).existsSync()) {
    final m = FontLoader('Menlo')
      ..addFont(
        Future.value(ByteData.sublistView(File(mono).readAsBytesSync())),
      );
    await m.load();
  }
}

void main() {
  for (final (raw, outDir) in _cases) {
    final name = raw.split('/').last.replaceAll('.vhdr', '');
    testWidgets(
      'stimulus-locked preprocessing + ERP: $name',
      (tester) async {
        await tester.runAsync(() async {
          await _fonts();
          final sw = Stopwatch()..start();
          final rec = await RecordingLoader().load(raw);
          final cfg = AnalysisConfig()
            ..stimEpochs = true
            ..stimMarkers = ['S 51', 'S 52'];
          final ch = ChannelTypeMap.autoDetect(rec.labels);
          Directory(outDir).createSync(recursive: true);
          final out = '$outDir/$name${cfg.cleanSuffix}.ccseeg.json';
          final log = <String>[];
          final clean = await ExtractionService().preprocess(
            recording: rec,
            outputPath: out,
            options: cfg.toPreprocessingOptions(
              nonEegChannels: ch.nonEegChannels,
            ),
            onProgress: (p, m) {
              if (m.isNotEmpty) log.add(m);
            },
          );
          // ignore: avoid_print
          print(
            '$name preprocessed in ${sw.elapsedMilliseconds} ms\n  ${log.where((l) => l.contains('epoch') || l.contains('GEDAI on') || l.contains('Bad')).join('\n  ')}',
          );
          expect(clean.isEpoched, isTrue);
          expect(clean.pointsPerEpoch, 426);
          expect(clean.epochTmin, closeTo(-0.5, 1e-9));
          expect(clean.epochLabels!.length, clean.epochCount);
          expect(clean.sampleCount, clean.epochCount * 426);

          final an = ErpEngine.analyzeFiles([
            ErpEngine.load(out, electrodes: {'Fz'}),
          ], const ErpSettings());
          final r = an.results.single;
          // ignore: avoid_print
          print(
            '  Fz: n_std=${r.nA} n_dev=${r.nB} t=${r.tWindow.toStringAsFixed(3)} '
            'p=${r.pWindow.toStringAsFixed(4)} d=${r.dWindow.toStringAsFixed(3)} '
            'clusters=${r.clusters.length} (sig ${r.significant(0.05).length})',
          );
          expect(r.nA, greaterThan(500));
          expect(r.nB, greaterThan(100));
          final written = await exportErpOutputs(an, '$outDir/ERP_analysis_Fz');
          expect(written.length, 6);
        });
      },
      timeout: const Timeout(Duration(minutes: 15)),
      skip: !File(raw).existsSync(),
    );
  }
}
