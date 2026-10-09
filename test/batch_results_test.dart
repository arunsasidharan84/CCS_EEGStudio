import 'dart:io';

import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late List<String> sessions;
  late String combined;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('batch_results_test_');
    sessions = [];
    final pooled = StringBuffer('filename,Chan,Epoch,Gamma1_Irasa\n');
    for (final name in ['Sub01_01_Rest', 'Sub01_02_Task']) {
      final rows = StringBuffer('filename,Chan,Epoch,Gamma1_Irasa\n');
      for (var epoch = 1; epoch <= 70; epoch++) {
        for (final channel in ['F3', 'Fz', 'F4']) {
          final row = '$name,$channel,$epoch,${0.1 + epoch * 0.001}\n';
          rows.write(row);
          pooled.write(row);
        }
      }
      final path = '${dir.path}/$name.features.csv';
      File(path).writeAsStringSync(rows.toString());
      sessions.add(path);
    }
    combined = '${dir.path}/Batch_features.csv';
    File(combined).writeAsStringSync(pooled.toString());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('mixed batch outputs plot individual sessions exactly once', () {
    final files = prepareSessionFeatureCsvs([
      combined,
      ...sessions,
      sessions.first,
    ], '${dir.path}/scratch');
    expect(files, sessions);
  });

  test('combined-only export becomes separate recording sessions', () {
    final files = prepareSessionFeatureCsvs([combined], '${dir.path}/scratch');
    expect(files.length, 2);
    expect(files.every((p) => !p.endsWith('Batch_features.csv')), isTrue);
    for (var i = 0; i < files.length; i++) {
      expect(
        File(files[i]).readAsStringSync(),
        File(sessions[i]).readAsStringSync(),
      );
    }
  });

  test('pooled CSV handles quoted filenames', () {
    File(combined).writeAsStringSync(
      'filename,Chan,Epoch,Gamma1_Irasa\n'
      '"Sub01_01_Rest, eyes closed",Fz,1,0.1\n'
      'Sub01_02_Task,Fz,1,0.2\n',
    );
    final files = prepareSessionFeatureCsvs([combined], '${dir.path}/scratch');
    expect(files.length, 2);
    expect(files.first, contains('Rest, eyes closed.features.csv'));
  });

  test('deselecting baseline selects a valid remaining baseline', () {
    final names = sessions
        .map((p) => cleanSegmentName(p.split('/').last, inferRecId(sessions)))
        .toList();
    final settings = TopoStatsSettings(
      baselineSession: names.first,
      recId: inferRecId(sessions),
      channels: const ['F3', 'Fz', 'F4'],
      nPermutations: 2,
    );
    final repaired = settingsForSessions(settings, [names.last]);
    expect(repaired.baselineSession, names.last);
    final result = computeTopoStats(files: [sessions.last], settings: repaired);
    expect(result.sessions.length, 1);
    expect(settingsForSessions(repaired, []).baselineSession, names.last);
  });

  testWidgets(
    'viewer excludes pooled export and repairs baseline on deselection',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopoStatsView(featureFilePaths: [combined, ...sessions]),
          ),
        ),
      );
      Future<void> finish() async {
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (tester
                  .widgetList<Checkbox>(find.byType(Checkbox))
                  .first
                  .onChanged !=
              null)
            return;
        }
        fail('Plot calculation did not finish');
      }

      await finish();
      expect(find.text('Batch_features.csv'), findsNothing);
      final checks = find.byType(Checkbox);
      await tester.tap(checks.first);
      await tester.pump();
      await finish();
      final expectedBaseline = cleanSegmentName(
        sessions.last.split('/').last,
        inferRecId(sessions),
      );
      final baseline = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .firstWhere(
            (w) => w.items!.any((item) => item.value == expectedBaseline),
          );
      expect(baseline.value, expectedBaseline);
      expect(find.textContaining('does not match any segment'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      expect(
        find.text('Select a recording to view its results.'),
        findsOneWidget,
      );
      expect(find.textContaining('does not match any segment'), findsNothing);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await finish();
      expect(find.textContaining('does not match any segment'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
