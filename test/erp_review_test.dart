import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/review_math.dart';
import 'package:ccs_eeg_app/src/erp/review_workspace.dart';

Map<String, dynamic> file(String id, double gain) => {
  'path': '$id-$gain.ccseeg.json',
  'subject': id,
  'task': 'ERN',
  'times': [-.1, 0.0, .1, .2],
  'labels': ['FCz', 'Cz'],
  'a': [gain, gain, gain, gain],
  'b': [0.0, gain * 2, gain * 4, 0.0],
  'difference': [-gain, gain, gain * 3, -gain],
  'channel_difference': [
    [-gain, gain, gain * 3, -gain],
    [0.0, gain, gain * 2, 0.0],
  ],
  'profile': {
    'task': 'ERN',
    'a_name': 'Correct',
    'b_name': 'Incorrect',
    'roi': ['FCz'],
    'window': [0.0, .1],
    'polarity': -1.0,
  },
};
void main() {
  test('participant weighting and SEM use people, not files or trials', () {
    final people = reviewParticipants([
      file('01', 1),
      file('01', 3),
      file('02', 8),
    ]);
    expect(people.length, 2);
    expect(people.first['a'], [2, 2, 2, 2]);
    expect(
      reviewAverage([for (final p in people) (p['a'] as List).cast<double>()]),
      [5, 5, 5, 5],
    );
    expect(
      reviewSem([
        [2, 2],
        [8, 8],
      ]),
      [3, 3],
    );
    expect(
      reviewSem([
        [2, 2],
      ]),
      isEmpty,
    );
  });
  test(
    'window measurements preserve signed polarity and exact map samples',
    () {
      final f = file('01', 1), t = (f['times'] as List).cast<double>();
      final m = reviewMeasures(
        t,
        (f['difference'] as List).cast<double>(),
        0,
        .1,
        -1,
      );
      expect(m['mean'], 2);
      expect(m['signed_auc'], closeTo(.2, 1e-12));
      expect(
        m['peak_amplitude'],
        1,
      ); // Negative peak means minimum, not a sign flip.
      expect(reviewTopo(f, 0, .1), [2, 1.5]);
      final old = {...f}..remove('channel_difference');
      expect(reviewTopo(old, -.1, .2), isNull);
    },
  );
  test('display smoothing leaves measurements and exports unsmoothed', () {
    final x = <double>[0, 0, 10, 0, 0], t = [0.0, .01, .02, .03, .04];
    expect(smoothErp(x, t, 20), [0, 10 / 3, 10 / 3, 10 / 3, 0]);
    expect(x, [0, 0, 10, 0, 0]);
    final csv = reviewCsv(
      [file('01', 1), file('01', 3)],
      {'01': 'Treatment'},
      ['mean', 'peak_latency_ms'],
      0,
      .1,
    );
    expect(csv, contains('"Group"'));
    expect(csv, contains('"Treatment"'));
    expect(csv, contains('"mean_ERP"'));
    expect(csv, isNot(contains('signed_auc_ERP')));
    expect(csv.split('\n').where((r) => r.isNotEmpty).length, 4);
    expect(csv, contains('"unsmoothed participant average"'));
  });
  test('interactive measurements match native Rust ERP results', () {
    final path = File('output/erp_saved_trial_validation/erp_results.json');
    if (!path.existsSync()) return;
    final f =
        ((jsonDecode(path.readAsStringSync()) as Map)['files'] as List).first
            as Map;
    final t = (f['times'] as List)
        .cast<num>()
        .map((n) => n.toDouble())
        .toList();
    final p = f['profile'] as Map, w = (p['window'] as List).cast<num>();
    for (final key in ['a', 'b', 'difference']) {
      final m = reviewMeasures(
        t,
        (f[key] as List).cast<num>().map((n) => n.toDouble()).toList(),
        w[0].toDouble(),
        w[1].toDouble(),
        (p['polarity'] as num).toDouble(),
      );
      final expected =
          (f['measurements'] as Map)[key == 'difference'
                  ? 'B_minus_A'
                  : key.toUpperCase()]
              as Map;
      for (final name in m.keys) {
        final native = name.endsWith('_ms')
            ? name.replaceFirst('_ms', '')
            : name;
        final value = expected[native];
        if (value == null) {
          expect(m[name], isNull);
        } else {
          expect(
            m[name],
            closeTo(
              (value as num).toDouble() * (name.endsWith('_ms') ? 1000 : 1),
              1e-9,
            ),
          );
        }
      }
    }
  });
  testWidgets(
    'review offers participant selection, smoothing, windows and export',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ErpReviewWorkspace(
            files: [file('01', 1), file('02', 3)],
            task: 'ERN',
            output: '/tmp/erp-review-test',
          ),
        ),
      );
      expect(find.text('Interactive batch review'), findsNothing);
      expect(find.text('Export CSV'), findsOneWidget);
      expect(find.text('Label groups'), findsOneWidget);
      expect(find.byType(RangeSlider), findsOneWidget);
      expect(find.text('Grand average'), findsOneWidget);
      await tester.tap(find.text('Participant differences'));
      await tester.pump();
      await tester.tap(find.text('Smoothing off'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smooth 16 ms (display)').last);
      await tester.pumpAndSettle();
      expect(find.text('Smooth 16 ms (display)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(
        find.text('Select participants to view their waveforms.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('real saved ERP review renders its live scalp map', (
    tester,
  ) async {
    final path = File('output/erp_review_validation/saved/erp_results.json');
    if (!path.existsSync()) return;
    final result = jsonDecode(path.readAsStringSync()) as Map;
    final files = (result['files'] as List)
        .map((f) => Map<String, dynamic>.from(f as Map))
        .toList();
    final font = FontLoader('DejaVuSans')
      ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    await font.load();
    await tester.binding.setSurfaceSize(const Size(1500, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'DejaVuSans'),
        home: RepaintBoundary(
          key: key,
          child: ErpReviewWorkspace(
            files: files,
            task: 'ERN',
            output: '/tmp/erp-review-test',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        'output/erp_review_validation/review_ui.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });

  test('peak latency returns true local peak timepoint and avoids window endpoints', () {
    // Waveform with a clear positive peak at 200 ms (t=0.2 s) within window [0.1, 0.4]
    final times = [0.0, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.5];
    final y = [0.0, 1.0, 3.0, 7.5, 3.2, 1.2, 0.5, 0.2, 0.0];

    // Matching positive polarity (+1):
    final mPos = reviewMeasures(times, y, 0.1, 0.4, 1.0);
    expect(mPos['peak_latency_ms'], 200.0);
    expect(mPos['peak_amplitude'], 7.5);

    // Auto polarity (0.0):
    final mAuto = reviewMeasures(times, y, 0.1, 0.4, 0.0);
    expect(mAuto['peak_latency_ms'], 200.0);
    expect(mAuto['peak_amplitude'], 7.5);

    // Opposite polarity (-1.0):
    // Should NOT get stuck at window endpoint (100 ms or 400 ms), but detect the interior peak!
    final mNeg = reviewMeasures(times, y, 0.1, 0.4, -1.0);
    expect(mNeg['peak_latency_ms'], 200.0);
  });
}
