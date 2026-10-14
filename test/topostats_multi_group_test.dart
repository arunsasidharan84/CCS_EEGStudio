// test/topostats_multi_group_test.dart

import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TopoPlotGroup manages files and session names', () {
    final group = TopoPlotGroup(
      id: 'group_1',
      recId: 'Pilot_Day1',
      files: [
        '/data/1_Pilot_Day1_Baseline.features.csv',
        '/data/2_Pilot_Day1_Task.features.csv',
      ],
    );

    expect(group.activeFiles.length, 2);
    expect(group.sessionNames, ['Baseline', 'Task']);

    group.disabled.add('/data/2_Pilot_Day1_Task.features.csv');
    expect(group.activeFiles.length, 1);
    expect(group.sessionNames, ['Baseline']);
  });

  test('groupByRecording partitions files across distinct days/recordings', () {
    final files = [
      '/data/1_Pilot_Day1_Baseline.features.csv',
      '/data/2_Pilot_Day1_Meditation.features.csv',
      '/data/1_Pilot_Day2_Baseline.features.csv',
      '/data/2_Pilot_Day2_Meditation.features.csv',
    ];

    final groups = groupByRecording(files);
    expect(groups.length, 2);
    expect(groups.keys, contains('Pilot_Day1'));
    expect(groups.keys, contains('Pilot_Day2'));
  });

  testWidgets('TopoStatsView renders multi-group controls when seeded with files', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final files = [
      '/data/1_Pilot_Day1_Baseline.features.csv',
      '/data/2_Pilot_Day1_Meditation.features.csv',
      '/data/1_Pilot_Day2_Baseline.features.csv',
      '/data/2_Pilot_Day2_Meditation.features.csv',
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopoStatsView(
            featureFilePaths: files,
            title: 'Plots & Report',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title and Settings appear
    expect(find.text('Plots & Report'), findsOneWidget);
    expect(find.text('RECORDINGS'), findsOneWidget);
    expect(find.text('Open folder'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);
  });
}
