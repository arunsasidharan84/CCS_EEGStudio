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

  testWidgets('shows the pipeline workspace and batch queue', (tester) async {
    await pumpApp(tester);

    expect(find.text('CCS EEG'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);

    expect(find.text('WORKFLOW MODULES'), findsOneWidget);
    expect(find.text('Continuous EEG'), findsWidgets);
    expect(find.text('Choose where to begin'), findsOneWidget);
    expect(find.text('BATCH'), findsOneWidget);
  });

  testWidgets('single-recording mode exposes a Run button per stage',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Preprocess'));
    await tester.pumpAndSettle();
    expect(find.text('Run Preprocessing'), findsOneWidget);

    await tester.tap(find.text('Feature Extraction'));
    await tester.pumpAndSettle();
    expect(find.text('Run Feature Extraction'), findsOneWidget);

    await tester.tap(find.text('Source Space'));
    await tester.pumpAndSettle();
    expect(find.text('Run Source Localisation'), findsOneWidget);

    await tester.tap(find.text('Plots & Report'));
    await tester.pumpAndSettle();
    expect(find.text('Run Plot Generation'), findsOneWidget);
  });

  testWidgets('channel types panel is present and empty before load',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('Preprocess'));
    await tester.pumpAndSettle();
    expect(find.text('CHANNEL TYPES'), findsOneWidget);
    await tester.tap(find.text('CHANNEL TYPES'));
    await tester.pumpAndSettle();
    expect(find.text('Load a recording to detect channel types.'),
        findsOneWidget);
  });

  testWidgets('batch mode offers the full feature family set', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('BATCH'));
    await tester.pumpAndSettle();

    expect(find.text('BATCH QUEUE'), findsOneWidget);
    expect(find.text('Stage 1: Preprocessing'), findsOneWidget);
    expect(find.text('Stage 2: Feature Extraction'), findsOneWidget);
    expect(find.text('Stage 3: Plots'), findsOneWidget);

    // Connectivity families used to be missing from Batch entirely — both tabs
    // now render the same shared widget, so they must appear here.
    final stage2 = find.ancestor(
      of: find.text('Stage 2: Feature Extraction'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.borderRadius != null,
      ),
    );
    expect(stage2, findsOneWidget);
    final stage2Scroll = find.descendant(
      of: stage2,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('PSD band power'),
      250,
      scrollable: stage2Scroll,
    );

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
    await tester.tap(find.text('BATCH'));
    await tester.pumpAndSettle();

    final stage2 = find.ancestor(
      of: find.text('Stage 2: Feature Extraction'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.borderRadius != null,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('One CSV per file'),
      300,
      scrollable: find.descendant(of: stage2, matching: find.byType(Scrollable)),
    );
    expect(find.text('One CSV per file'), findsOneWidget);
    expect(find.text('Combined CSV across files'), findsOneWidget);
  });

  testWidgets('batch plots can be split per recording', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('BATCH'));
    await tester.pumpAndSettle();

    final stage3 = find.ancestor(
      of: find.text('Stage 3: Plots'),
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.borderRadius != null,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Plot each recording separately'),
      250,
      scrollable: find.descendant(of: stage3, matching: find.byType(Scrollable)),
    );
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

    await tester.tap(find.text('Preprocess'));
    await tester.pumpAndSettle();
    expect(buttonWithLabel('Run Preprocessing').onPressed, isNull,
        reason: 'no recording loaded yet');
    await tester.tap(find.text('Feature Extraction'));
    await tester.pumpAndSettle();
    expect(buttonWithLabel('Run Feature Extraction').onPressed, isNull,
        reason: 'no recording loaded yet');
  });

  testWidgets('microstates module exposes interactive and batch analysis',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Continuous EEG').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('EEG Microstates').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Microstates'));
    await tester.pumpAndSettle();

    expect(find.text('MICROSTATE ANALYSIS'), findsOneWidget);
    expect(find.text('Choose recording'), findsOneWidget);
    expect(find.text('Input'), findsWidgets);
    expect(find.text('Configure'), findsWidgets);
    expect(find.text('Results'), findsWidgets);
    expect(find.text('Interactive'), findsOneWidget);
    expect(find.text('Batch'), findsWidgets);
    expect(find.text('Run Microstate Analysis'), findsOneWidget);

    await tester.tap(find.text('Batch').last);
    await tester.pumpAndSettle();
    expect(find.text('Add recordings'), findsOneWidget);
  });
}
