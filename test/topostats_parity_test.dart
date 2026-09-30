// test/topostats_parity_test.dart
//
// Parity of the Plots & Report / TopoStats pipeline with
// PlotFeaturesTopoStats_20260801.py (MNE 1.12.1, matplotlib 3.10).
//
// The fixture test/fixtures/topostats_ref_Gamma1_Irasa.json was produced by
// running the reference script's own functions on the Thukdam pilot data
// (baseline EO_EC_AT_VP [0-2] min, Gamma1_Irasa, 500 permutations, seed 42).
//
// Needs the real data; skipped when it is not present. Override the folder
// with TOPOSTATS_DATA=/path/to/20260710.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ccs_eeg_app/src/topostats/topo_interp.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_figure.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultData =
    '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260710/Analysis_20260710';

void main() {
  final dataDir = Platform.environment['TOPOSTATS_DATA'] ?? _defaultData;
  final hasData = Directory(dataDir).existsSync();
  final ref =
      jsonDecode(
            File(
              'test/fixtures/topostats_ref_Gamma1_Irasa.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  List<String> files() {
    final recId = 'Pilot_Tukdam_10.07.2026';
    return discoverSessionFiles(dataDir, recId);
  }

  const settings = TopoStatsSettings(
    recId: 'Pilot_Tukdam_10.07.2026',
    feature: 'Gamma1_Irasa',
    baselineSession: 'EO_EC_AT_VP',
    baselineTmin: 0.0,
    baselineDurationMin: 2.0,
  );

  test('rec_ID inference and session names', () {
    final names = [
      '1_Pilot_Tukdam_10.07.2026_EO_EC_AT_VP.features.csv',
      '4_Pilot_Tukdam_10.07.2026_Pre-Med_Rest.features.csv',
    ];
    expect(inferRecId(names), 'Pilot_Tukdam_10.07.2026');
    expect(
      cleanSegmentName(names[1], 'Pilot_Tukdam_10.07.2026'),
      'Pre-Med_Rest',
    );
  });

  test('Clough-Tocher topomap grid matches MNE (_GridData / scipy)', () {
    final chk = ref['zi_check'] as Map<String, dynamic>;
    final w =
        ((ref['sessions'] as List)[chk['session'] as int]['wins']
            as List)[chk['window'] as int];
    final values = [for (final v in w['t'] as List) (v as num).toDouble()];
    final interp = TopoInterpolator.forChannels(settings.channels);
    final z = interp.grid(values);
    final zr = chk['z'] as List;
    var maxd = 0.0;
    for (var i = 0; i < z.length; i++) {
      if (zr[i] == null) {
        expect(
          z[i].isNaN,
          isTrue,
          reason: 'cell $i should be outside the hull',
        );
      } else {
        maxd = (z[i] - (zr[i] as num)).abs() > maxd
            ? (z[i] - (zr[i] as num)).abs()
            : maxd;
      }
    }
    expect(maxd, lessThan(1e-9));
    final levels = contourLevels(z, 3);
    expect(levels, [
      for (final l in chk['levels'] as List) (l as num).toDouble(),
    ]);
  });

  test(
    'e-TFCE + BH-FDR statistics match MNE 1.12.1 exactly',
    () {
      final r = computeTopoStats(files: files(), settings: settings);
      final rs = ref['sessions'] as List;
      expect(r.sessions.map((s) => s.name).toList(), ref['names']);
      var nWin = 0, nSigMismatch = 0;
      for (var i = 0; i < rs.length; i++) {
        final sess = r.sessions[i];
        final rsess = rs[i] as Map<String, dynamic>;
        final rt = rsess['t'] as List;
        expect(sess.tMin.length, rt.length);
        for (var k = 0; k < rt.length; k += 97) {
          expect(sess.tMin[k], closeTo((rt[k] as num).toDouble(), 1e-12));
          expect(
            sess.mean[k],
            closeTo(((rsess['mean'] as List)[k] as num).toDouble(), 1e-12),
          );
          expect(
            sess.band[k],
            closeTo(((rsess['band'] as List)[k] as num).toDouble(), 1e-12),
          );
        }
        final wins = rsess['wins'] as List;
        expect(sess.windows.length, wins.length, reason: sess.name);
        for (var j = 0; j < wins.length; j++) {
          final rw = wins[j] as Map<String, dynamic>;
          final w = sess.windows[j];
          expect(w.tStart, (rw['t0'] as num).toDouble());
          expect(w.isBaseline, rw['base']);
          if (w.isBaseline) continue;
          nWin++;
          for (var c = 0; c < 32; c++) {
            expect(
              w.tObs![c],
              closeTo((rw['t'][c] as num).toDouble(), 1e-9),
              reason: '${sess.name} win $j ch $c t_obs',
            );
            expect(
              w.pValues![c],
              (rw['p'][c] as num).toDouble(),
              reason: '${sess.name} win $j ch $c p',
            );
            expect(
              w.qValues![c],
              closeTo((rw['q'][c] as num).toDouble(), 1e-12),
            );
            if (w.significant![c] != rw['sig'][c]) nSigMismatch++;
          }
        }
      }
      expect(nWin, greaterThan(60));
      expect(nSigMismatch, 0);
      expect(r.vmax, closeTo(8.6, 0.05));
    },
    skip: hasData ? false : 'Thukdam data not found at $dataDir',
  );

  testWidgets('renders the figure at 200 dpi (7150 x 1180 like the script)', (
    tester,
  ) async {
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
      final r = computeTopoStats(files: files(), settings: settings);
      final fig = TopoFigure(r);
      expect((fig.widthIn * 200).round(), 7150);
      expect((fig.heightIn * 200).round(), 1180);
      final png = await fig.toPng(dpi: 200);
      final out = Directory('$dataDir/../Figures_TopoStats_Dart')
        ..createSync(recursive: true);
      File('${out.path}/${r.outputFileName}.png').writeAsBytesSync(png);
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 7150);
    });
  }, skip: !hasData);
}
