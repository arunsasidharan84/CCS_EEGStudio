// Layout smoke tests for the ERP view and the stimulus-epoch panel.
import 'dart:io';

import 'package:ccs_eeg_app/src/erp/erp_view.dart';
import 'package:ccs_eeg_app/src/erp/stim_epoch_panel.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _epo =
    '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260710/Analysis_20260710/'
    '2_Pilot_Tukdam_10.07.2026_EM_MMN_VR-epo_clean.ccseeg.json';

void main() {
  testWidgets('ERP view lays out without overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(body: ErpAnalysisView()),
      ),
    );
    expect(find.text('Compute'), findsOneWidget);
    expect(find.text('CONDITIONS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ERP view lists an epoched file and its markers',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(body: ErpAnalysisView(extraFiles: [_epo])),
        ),
      );
      await tester.runAsync(() => Future.delayed(const Duration(seconds: 4)));
      await tester.pump();
      expect(find.textContaining('750 epochs'), findsOneWidget);
      expect(find.textContaining('S 51  ×600'), findsNWidgets(2));
      expect(find.text('600 epochs'), findsOneWidget);
      expect(find.text('150 epochs'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: !File(_epo).existsSync(),
  );

  testWidgets('stimulus epoch panel with detected markers', (tester) async {
    final cfg = AnalysisConfig()..stimEpochs = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: StimEpochPanel(
                config: cfg,
                markers: const [
                  EegMarker(
                    type: 'Stimulus',
                    description: 'S 51',
                    startSeconds: 2,
                  ),
                  EegMarker(
                    type: 'Stimulus',
                    description: 'S 52',
                    startSeconds: 4,
                  ),
                  EegMarker(
                    type: 'Stimulus',
                    description: 'S 55',
                    startSeconds: 6,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      find.text(
        '2 events match in this recording. Saved as <name>-epo_clean.ccseeg.json with epoch labels and times.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('S 55'));
    await tester.pump();
    expect(cfg.stimMarkers, ['S 51', 'S 52', 'S 55']);
    expect(tester.takeException(), isNull);
  });
}
