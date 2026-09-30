import 'dart:typed_data';

import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('epoched recordings can switch to stitched scrolling', (
    tester,
  ) async {
    final recording = EegRecording(
      path: '/tmp/epochs.set',
      sampleRate: 10,
      labels: const ['Cz'],
      preview: [Float32List.fromList(List.generate(60, (i) => i.toDouble()))],
      sampleCount: 60,
      format: 'EEGLAB SET',
      epochCount: 3,
      pointsPerEpoch: 20,
      epochLabels: const ['A', 'B', 'C'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: EegViewer(
              recording: recording,
              selection: const ViewerSelection.empty(),
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Epoch 1 / 3'), findsOneWidget);
    expect(find.text('Stitch epochs'), findsOneWidget);

    await tester.tap(find.text('Stitch epochs'));
    await tester.pumpAndSettle();

    expect(find.text('Epoch 1 / 3'), findsNothing);
    expect(find.text('Stitched epochs'), findsOneWidget);
  });

  testWidgets('raw and epoched recordings share timeline and stitch state', (
    tester,
  ) async {
    final raw = EegRecording(
      path: '/tmp/raw.edf',
      sampleRate: 10,
      labels: const ['Cz'],
      preview: [Float32List.fromList(List.generate(1000, (i) => i.toDouble()))],
      sampleCount: 1000,
      format: 'EDF',
    );
    final epochs = EegRecording(
      path: '/tmp/clean.ccseeg.json',
      sampleRate: 10,
      labels: const ['Cz'],
      preview: [Float32List.fromList(List.generate(1000, (i) => i.toDouble()))],
      sampleCount: 1000,
      format: 'CCSEEG',
      epochCount: 50,
      pointsPerEpoch: 20,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: _SwitchingViewer(raw: raw, epochs: epochs),
      ),
    );
    await tester.tap(find.byIcon(Icons.chevron_right).last);
    await tester.pump();
    expect(find.text('Epoch 2 / 50'), findsOneWidget);

    await tester.tap(find.text('Show raw'));
    await tester.pump();
    await tester.tap(find.text('Show epochs'));
    await tester.pump();
    expect(find.text('Epoch 2 / 50'), findsOneWidget);

    await tester.tap(find.text('Stitch epochs'));
    await tester.pump();
    await tester.tap(find.text('Show raw'));
    await tester.pump();
    await tester.tap(find.text('Show epochs'));
    await tester.pump();
    expect(find.text('Stitched epochs'), findsOneWidget);
  });
}

class _SwitchingViewer extends StatefulWidget {
  const _SwitchingViewer({required this.raw, required this.epochs});
  final EegRecording raw;
  final EegRecording epochs;

  @override
  State<_SwitchingViewer> createState() => _SwitchingViewerState();
}

class _SwitchingViewerState extends State<_SwitchingViewer> {
  late EegRecording current = widget.epochs;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => current = widget.raw),
              child: const Text('Show raw'),
            ),
            TextButton(
              onPressed: () => setState(() => current = widget.epochs),
              child: const Text('Show epochs'),
            ),
          ],
        ),
        Expanded(
          child: EegViewer(
            recording: current,
            selection: const ViewerSelection.empty(),
            onSelectionChanged: (_) {},
          ),
        ),
      ],
    ),
  );
}
