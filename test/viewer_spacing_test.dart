import 'dart:typed_data';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/event_navigation.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'viewer panels collapse independently, reclaim height and retain time',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rec = EegRecording(
        path: '/tmp/compact.edf',
        sampleRate: 10,
        labels: const ['Cz'],
        preview: [Float32List(3000)],
        sampleCount: 3000,
        format: 'EDF',
        markers: const [
          EegMarker(type: 'Event', description: '11', startSeconds: 60),
          EegMarker(type: 'Event', description: '12', startSeconds: 65),
        ],
      );
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
      double height() =>
          tester.getSize(find.byKey(const ValueKey('waveform-area'))).height;
      final compact = height();
      expect(compact, greaterThan(570));
      expect(find.text('Autoscale'), findsNothing);
      await tester.tap(find.text('Controls'));
      await tester.pump();
      expect(find.text('Autoscale'), findsOneWidget);
      expect(height(), lessThan(compact));
      await tester.tap(find.text('Controls'));
      await tester.pump();
      final nav = find.byKey(const ValueKey('recording-overview'));
      final rect = tester.getRect(nav);
      await tester.tapAt(Offset(rect.left + rect.width * .2, rect.center.dy));
      await tester.pump();
      final start = tester
          .widget<EventLabelLane>(find.byType(EventLabelLane))
          .start;
      await tester.tap(find.text('Event labels'));
      await tester.pump();
      expect(find.byType(EventLabelLane), findsNothing);
      expect(height(), greaterThan(compact));
      await tester.tap(find.text('Overview'));
      await tester.pump();
      expect(find.byType(RecordingNavigator), findsNothing);
      await tester.tap(find.byTooltip('Focus waveform'));
      await tester.pump();
      await tester.tap(find.byTooltip('Restore panels'));
      await tester.pump();
      expect(find.byType(RecordingNavigator), findsNothing);
      expect(find.byType(EventLabelLane), findsNothing);
      await tester.tap(find.text('Overview'));
      await tester.tap(find.text('Event labels'));
      await tester.pump();
      expect(
        tester.widget<EventLabelLane>(find.byType(EventLabelLane)).start,
        start,
      );
      await tester.binding.setSurfaceSize(const Size(520, 600));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Focus waveform'));
      await tester.pump();
      expect(find.byType(RecordingNavigator), findsNothing);
      expect(height(), greaterThan(480));
      await tester.tap(find.text('Overview'));
      await tester.pump();
      expect(find.byType(RecordingNavigator), findsOneWidget);
      expect(find.byTooltip('Focus waveform'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
