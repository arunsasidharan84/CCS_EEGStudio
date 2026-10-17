import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/models.dart';

void main() {
  testWidgets(
    'Pallavi waveform display filtering runs without blocking the viewer',
    (tester) async {
      const path =
          '/Users/arunsasidharan/EEGdata/Pallavi/Pallavi_Task_Pre_2.vhdr';
      if (!File(path).existsSync()) return;
      final rec = await tester.runAsync(() => RecordingLoader().load(path));
      await tester.binding.setSurfaceSize(const Size(1500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EegViewer(
              recording: rec,
              filterEnabled: true,
              selection: const ViewerSelection.empty(),
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Display filtering failed'), findsNothing);
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pump();
        await tester.pump();
        if (find
            .text('Display filters running · raw preview')
            .evaluate()
            .isEmpty)
          break;
      }
      expect(find.textContaining('Display filtering failed'), findsNothing);
      expect(find.text('Display filters running · raw preview'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
