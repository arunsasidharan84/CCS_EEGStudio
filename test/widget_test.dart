import 'dart:ui';

import 'package:ccs_eeg_app/src/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const CcsEegApp());
    await tester.pumpAndSettle();
  }

  testWidgets('shows the two workflow modes', (tester) async {
    await pumpApp(tester);

    expect(find.text('CCS EEG'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);

    // The split between the two modes must be explicit in the UI, not implied.
    expect(find.text('Single Recording'), findsOneWidget);
    expect(find.text('one file · with viewer'), findsOneWidget);
    expect(find.text('Batch'), findsOneWidget);
    expect(find.text('many files · unattended'), findsOneWidget);
  });

  testWidgets('single-recording mode exposes a Run button per stage',
      (tester) async {
    await pumpApp(tester);

    // Stage 1 is expanded by default.
    expect(find.text('Run Preprocessing'), findsOneWidget);

    // Stage 3 is expanded by default and must have its own Run button —
    // previously extraction was only reachable from a global sidebar button
    // while every other stage had an inline one.
    expect(find.text('Run Feature Extraction'), findsOneWidget);

    // Stage 2 and Stage 4 reveal theirs when expanded.
    await tester.tap(find.text('SOURCE SPACE'));
    await tester.pumpAndSettle();
    expect(find.text('Run Source Localisation'), findsOneWidget);

    await tester.tap(find.text('PLOTS & REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('Run Plot Generation'), findsOneWidget);
  });

  testWidgets('channel types panel is present and empty before load',
      (tester) async {
    await pumpApp(tester);

    expect(find.text('CHANNEL TYPES'), findsOneWidget);
    await tester.tap(find.text('CHANNEL TYPES'));
    await tester.pumpAndSettle();
    expect(find.text('Load a recording to detect channel types.'),
        findsOneWidget);
  });

  testWidgets('batch mode offers the full feature family set', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Batch'));
    await tester.pumpAndSettle();

    expect(find.text('Batch Pipeline'), findsOneWidget);
    expect(find.text('Stage 1: Preprocessing'), findsOneWidget);
    expect(find.text('Stage 2: Feature Extraction'), findsOneWidget);
    expect(find.text('Stage 3: Plots'), findsOneWidget);

    // Connectivity families used to be missing from Batch entirely — both tabs
    // now render the same shared widget, so they must appear here.
    final stage2 = find.ancestor(
      of: find.text('Stage 2: Feature Extraction'),
      matching: find.byType(Material),
    );
    expect(stage2, findsWidgets);

    for (final family in [
      'PSD band power',
      'FOOOF / specparam',
      'IRASA',
      'Nonlinear dynamics',
      'Autocorrelation window (ACW)',
      'MIC',
      'MIM',
      'Granger Causality',
      'GC-TR',
      'Coherence (COH)',
      'PLV',
      'ciPLV',
      'PLI',
      'wPLI',
    ]) {
      expect(find.text(family), findsWidgets,
          reason: 'Batch mode is missing the "$family" option');
    }
  });

  testWidgets('batch mode offers per-file and combined CSV outputs',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Batch'));
    await tester.pumpAndSettle();

    expect(find.text('One CSV per file'), findsOneWidget);
    expect(find.text('Combined CSV across files'), findsOneWidget);
  });

  testWidgets('batch plots can be split per recording', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Batch'));
    await tester.pumpAndSettle();

    expect(find.text('Plot each recording separately'), findsWidgets);
    expect(find.text('Group overlay across recordings'), findsWidgets);
  });

  testWidgets('run buttons are disabled until there is something to run',
      (tester) async {
    await pumpApp(tester);

    FilledButton buttonWithLabel(String label) => tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(FilledButton),
          ),
        );

    expect(buttonWithLabel('Run Preprocessing').onPressed, isNull,
        reason: 'no recording loaded yet');
    expect(buttonWithLabel('Run Feature Extraction').onPressed, isNull,
        reason: 'no recording loaded yet');
  });
}
