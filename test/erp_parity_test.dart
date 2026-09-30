// test/erp_parity_test.dart
//
// Parity of the ERP module with ThukdamStudy/scripts/compute_mmn_erp.py.
//
// test/fixtures/erp_ref_Fz.json was made by running the script's own
// functions (numpy 2.4, scipy 1.17) on the three *-epo_clean.ccseeg.json files
// in 20260710/Analysis_20260710 (electrode Fz, baseline -0.2..0 s, window
// 0.10..0.25 s, 1000 permutations, 2000 bootstrap, seed 42), and
// erp_stats_summary_Fz.csv is the script's CSV output. Tests that need the
// real data are skipped when it is absent (override with ERP_DATA=/path).

import 'dart:convert';
import 'dart:io';

import 'package:ccs_eeg_app/src/erp/ccseeg_reader.dart';
import 'package:ccs_eeg_app/src/erp/erp_engine.dart';
import 'package:ccs_eeg_app/src/erp/erp_figure.dart';
import 'package:ccs_eeg_app/src/erp/erp_view.dart' show exportErpOutputs;
import 'package:ccs_eeg_app/src/erp/np_random.dart';
import 'package:ccs_eeg_app/src/erp/sci_stats.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultData =
    '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260710/Analysis_20260710';

double _d(dynamic v) => (v as num).toDouble();
List<double> _l(dynamic v) => [for (final x in v as List) _d(x)];

void _close(List<double> a, List<double> b, double tol, String what) {
  expect(a.length, b.length, reason: '$what length');
  var worst = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs() / (1 + b[i].abs());
    if (d > worst) worst = d;
  }
  expect(worst, lessThan(tol), reason: '$what max rel diff $worst');
}

Future<void> _loadFonts() async {
  final f = FontLoader('DejaVuSans')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/DejaVuSans.ttf').readAsBytesSync(),
        ),
      ),
    );
  await f.load();
  // The window-statistics boxes use a monospace font (Menlo in the app).
  for (final p in [
    '/System/Library/Fonts/Supplemental/Courier New.ttf',
    '/Library/Fonts/Courier New.ttf',
  ]) {
    if (File(p).existsSync()) {
      final m = FontLoader(
        'Menlo',
      )..addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
      await m.load();
      break;
    }
  }
}

void main() {
  final dataDir = Platform.environment['ERP_DATA'] ?? _defaultData;
  final ref =
      jsonDecode(File('test/fixtures/erp_ref_Fz.json').readAsStringSync())
          as Map<String, dynamic>;
  final names = [for (final f in ref['files'] as List) f['file'] as String];
  final hasData = names.every((n) => File('$dataDir/$n').existsSync());

  group('numpy default_rng port', () {
    final r = ref['rng'] as Map<String, dynamic>;
    test('PCG64 raw output (seed 42)', () {
      final g = NpGenerator(42);
      for (final s in r['raw42'] as List) {
        final v = g.nextUint64();
        expect(BigInt.from(v).toUnsigned(64).toString(), s);
      }
    });
    test('permutation / integers / choice', () {
      expect(NpGenerator(42).permutation(750).sublist(0, 30), r['perm750']);
      expect(NpGenerator(42).integers(600, 30), r['int600']);
      final g = NpGenerator(7);
      expect(g.permutation(10), r['seed7_perm10']);
      expect(
        g.choice(List<double>.generate(150, (i) => i.toDouble()), 10),
        _l(r['seed7_choice150']),
      );
    });
  });

  group('scipy equivalents', () {
    test('Student t sf / ppf', () {
      for (final row in ref['tdist'] as List) {
        final t = _d(row[0]), df = _d(row[1]);
        expect(tTwoSidedP(t, df), closeTo(_d(row[2]), 1e-12));
        expect(tPpf(0.975, df), closeTo(_d(row[3]), 1e-10));
      }
    });
    test('savgol_filter(31, 3, mode=interp)', () {
      final s = ref['savgol'] as Map<String, dynamic>;
      _close(savgolFilter(_l(s['x'])), _l(s['y']), 1e-10, 'savgol');
    });
  });

  test('condition markers match BrainVision labels', () {
    const a = ErpCondition(name: 'A', markers: ['S 51']);
    expect(a.matches('Stimulus/S 51'), isTrue);
    expect(a.matches('Stimulus/S  51'), isTrue);
    expect(a.matches('S51'), isTrue);
    expect(a.matches('Stimulus/S 52'), isFalse);
    expect(a.matches('Stimulus/S 5'), isFalse);
    const r = ErpCondition(name: 'B', pattern: r'\bS\s*52\b');
    expect(r.matches('Stimulus/S 52'), isTrue);
    expect(r.matches('Stimulus/S 51'), isFalse);
  });

  test('stimulus event selection with crop window and rejected intervals', () {
    final markers = [
      const EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 5),
      const EegMarker(type: 'Stimulus', description: 'S  8', startSeconds: 10),
      const EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 12),
      const EegMarker(type: 'Stimulus', description: 'S 52', startSeconds: 20),
      const EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 30),
      const EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 100),
    ];
    const spec = StimEpochSpec(
      markers: ['S 51', 'S 52'],
      cropStartMarker: 'S 8',
      cropMinutes: 1,
    );
    final ev = spec.selectEvents(
      markers,
      selection: const ViewerSelection(
        selectedChannels: [],
        acceptedIntervals: [],
        rejectedIntervals: [
          [29, 31],
        ],
      ),
    );
    expect(ev, [(12.0, 'Stimulus/S 51'), (20.0, 'Stimulus/S 52')]);
  });

  group('compute_mmn_erp.py on the Thukdam pilot (Fz)', () {
    late ErpAnalysis an;
    late List<CcsEegData> files;
    setUpAll(() {
      if (!hasData) return;
      final sw = Stopwatch()..start();
      files = [for (final n in names) ErpEngine.load('$dataDir/$n')];
      an = ErpEngine.analyzeFiles(files, const ErpSettings());
      // ignore: avoid_print
      print(
        'ERP analysis of ${files.length} files: ${sw.elapsedMilliseconds} ms',
      );
    });

    test(
      'per-file waveforms, clusters and window statistics',
      () {
        final rs = ref['files'] as List;
        for (var i = 0; i < rs.length; i++) {
          final e = rs[i] as Map<String, dynamic>;
          final r = an.results[i];
          expect(r.nA, e['n_std']);
          expect(r.nB, e['n_dev']);
          expect(r.times.length, e['n_times']);
          _close(r.aMean, _l(e['std_mean']), 1e-9, 'std_mean $i');
          _close(r.aSem, _l(e['std_sem']), 1e-9, 'std_sem $i');
          _close(r.bMean, _l(e['dev_mean']), 1e-9, 'dev_mean $i');
          _close(r.bSem, _l(e['dev_sem']), 1e-9, 'dev_sem $i');
          _close(r.tObs, _l(e['t_obs']), 1e-9, 't_obs $i');
          expect(r.tThresh, closeTo(_d(e['t_thresh']), 1e-10));
          final cl = e['clusters'] as List;
          expect(r.clusters.length, cl.length, reason: 'clusters $i');
          for (var k = 0; k < cl.length; k++) {
            expect(r.clusters[k].startIdx, cl[k]['start']);
            expect(r.clusters[k].endIdx, cl[k]['end']);
            expect(r.clusters[k].mass, closeTo(_d(cl[k]['mass']), 1e-8));
            expect(
              r.clusters[k].pValue,
              closeTo(_d(cl[k]['p']), 1e-12),
              reason: 'cluster $k p of file $i',
            );
          }
          expect(r.tWindow, closeTo(_d(e['t_window']), 1e-9));
          expect(r.pWindow, closeTo(_d(e['p_window']), 1e-10));
          expect(r.dWindow, closeTo(_d(e['d_window']), 1e-10));
          expect(r.dBootLo, closeTo(_d(e['d_lo']), 1e-10));
          expect(r.dBootHi, closeTo(_d(e['d_hi']), 1e-10));
          _close(
            r.mismatchBoot.sublist(0, 5),
            _l(e['mismatch_first']),
            1e-10,
            'mismatch boot $i',
          );
          expect(r.mismatchMean, closeTo(_d(e['mismatch_mean']), 1e-10));
          expect(r.mismatchLo, closeTo(_d(e['mismatch_lo']), 1e-10));
          expect(r.mismatchHi, closeTo(_d(e['mismatch_hi']), 1e-10));
        }
        for (final b in ref['between'] as List) {
          final x = an.between.firstWhere((y) => y.i == b[0] && y.j == b[1]);
          expect(x.d, closeTo(_d(b[2]), 1e-9));
        }
      },
      skip: hasData ? false : 'ERP data not found in $dataDir',
    );

    test(
      'stats_summary_Fz.csv is identical to the script output',
      () {
        final want = File(
          'test/fixtures/erp_stats_summary_Fz.csv',
        ).readAsStringSync();
        expect(ErpEngine.statsCsv(an), want);
      },
      skip: hasData ? false : 'ERP data not found',
    );

    test(
      'real recording produces finite multi-electrode scalp maps',
      () {
        final topo = ErpEngine.analyzeTopography([
          files.first,
        ], const ErpSettings());
        expect(topo.labels.length, greaterThanOrEqualTo(30));
        expect(
          topo.windowA.where((v) => v.isFinite).length,
          greaterThanOrEqualTo(30),
        );
        expect(
          topo.windowP.where((v) => v.isFinite).length,
          greaterThanOrEqualTo(30),
        );
      },
      skip: hasData ? false : 'ERP data not found',
    );

    testWidgets('figures and exports', (tester) async {
      await tester.runAsync(() async {
        await _loadFonts();
        final wave = ErpWaveformFigure(an);
        expect((wave.widthIn * 150).round(), 1350);
        expect((wave.heightIn * 150).round(), 1440);
        final eff = ErpEffectFigure(an);
        expect((eff.widthIn * 150).round(), 1125);
        expect((eff.heightIn * 150).round(), 1500);
        final out = '$dataDir/MMN_analysis_Fz_Dart';
        final written = await exportErpOutputs(an, out);
        for (final p in written) {
          expect(File(p).lengthSync(), greaterThan(100), reason: p);
        }
      });
    }, skip: !hasData);
  });

  test('reader handles key order and skipped channels', () {
    final json =
        '{"labels":["Fz","Cz"],"format":"ccseeg-v1","channels":[[1.5,-2,3e-1],[4,5,6]],'
        '"sample_rate":250.0,"source_epoch_samples":3,"epoch_labels":["Stimulus/S 51"],"epoch_tmin":-0.5}';
    final d = CcsEegData.parse(
      Uint8List.fromList(utf8.encode(json)),
      'x-epo.ccseeg.json',
      keepChannel: (l) => l == 'Cz',
    );
    expect(d.labels, ['Fz', 'Cz']);
    expect(d.channels[0].length, 0);
    expect(d.channels[1], [4.0, 5.0, 6.0]);
    expect(d.epochTmin, -0.5);
    expect(d.sourceEpochSamples, 3);
    final all = CcsEegData.parse(
      Uint8List.fromList(utf8.encode(json)),
      'x.ccseeg.json',
    );
    expect(all.channels[0], [1.5, -2.0, 0.3]);
  });

  test(
    'scalp analysis provides point and window maps with electrode statistics',
    () {
      final json = jsonEncode({
        'format': 'ccseeg-v1',
        'sample_rate': 1.0,
        'labels': ['Fz', 'Cz', 'Pz'],
        'channels': [
          [0, 0, 1, 0, 0, 2, 0, 0, 4, 0, 0, 6],
          [0, 0, 2, 0, 0, 3, 0, 0, 5, 0, 0, 8],
          [0, 0, -1, 0, 0, -2, 0, 0, -4, 0, 0, -7],
        ],
        'source_epoch_samples': 3,
        'epoch_labels': ['S 51', 'S 51', 'S 52', 'S 52'],
        'epoch_tmin': -1.0,
        'epoch_tmax': 1.0,
      });
      final data = CcsEegData.parse(
        Uint8List.fromList(utf8.encode(json)),
        'synthetic-epo.ccseeg.json',
      );
      const settings = ErpSettings(
        baselineStart: -1,
        baselineEnd: 0,
        winStart: 1,
        winEnd: 1,
      );
      final topo = ErpEngine.analyzeTopography([data], settings);
      expect(topo.labels, ['Fz', 'Cz', 'Pz']);
      expect(topo.pointSeconds, 1);
      expect(topo.nA, [2, 2, 2]);
      expect(topo.nB, [2, 2, 2]);
      expect(topo.windowA, topo.pointA);
      expect(topo.windowB, topo.pointB);
      expect(topo.windowB[0] - topo.windowA[0], 3.5);
      expect(topo.windowP.every((p) => p.isFinite), isTrue);
    },
  );
}
