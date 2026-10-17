import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/models.dart';

void main() {
  testWidgets(
    'single trial shows its actual duration; stitched view restores time window',
    (tester) async {
      final rec = EegRecording(
        path: 'epochs.ccseeg',
        format: 'ccseeg',
        sampleRate: 250,
        labels: ['Pz'],
        sampleCount: 850,
        preview: [Float32List(850)],
        pointsPerEpoch: 425,
        epochCount: 2,
        epochLabels: ['A', 'B'],
        epochTmin: -.5,
      );
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EegViewer(
              recording: rec,
              selection: const ViewerSelection.empty(),
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Epoch · 1.70 s'), findsWidgets);
      expect(find.text('20 s'), findsNothing);
      await tester.tap(find.text('Stitch epochs').first);
      await tester.pumpAndSettle();
      expect(find.text('Epoch · 1.70 s'), findsNothing);
      expect(find.text('20 s'), findsWidgets);
    },
  );
}
