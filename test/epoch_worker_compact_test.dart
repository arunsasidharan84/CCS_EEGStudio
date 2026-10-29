import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/epoch_service.dart';
import 'package:ccs_eeg_app/src/erp/stim_epoch_panel.dart';

void main() {
  const event = EegMarker(type: 'Stimulus', description: 'S 10', startSeconds: 2);
  testWidgets('epoch worker accepts plain signal data from a live Flutter view', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Epochs'))));
    final recording = EegRecording(path: 'memory', sampleRate: 100,
      labels: ['Fz'], preview: [Float32List(400)], sampleCount: 400,
      format: 'ccseeg', markers: const [event]);
    final epochs = await tester.runAsync(() => generateEpochsInWorker(
      recording: recording, selectedMarkers: const [event],
      options: const EpochOptions(targetEvents: [], tmin: -.1, tmax: .2,
        applyBaseline: false, markerGroups: {'Standard': ['S 10']}),
    ));
    expect(epochs!.epochCount, 1);
    expect(epochs.epochLabels, ['Standard']);
    expect(epochs.markers.any((m) => m.label == 'S 10'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact dialog prioritizes conditions and hides duplicate raw selection', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final config = AnalysisConfig()..stimEpochs = true
      ..stimMarkers = ['Standard', 'S 10']..stimMarkerGroups = {'Standard': ['S 10']};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: StimEpochPanel(config: config, compact: true, showEnableControl: false,
        markers: const [event, EegMarker(type: 'Boundary', description: 'New Segment', startSeconds: 0)]),
    ))));
    expect(find.text('Conditions'), findsOneWidget);
    expect(find.text('Standard · S 10'), findsOneWidget);
    expect(find.text('Epoch on markers (comma separated)'), findsNothing);
    expect(find.text('Event-based trials (ERP)'), findsNothing);
    expect(find.text('Only from marker (optional)'), findsNothing);
    expect(find.text('Start relative to event'), findsOneWidget);
    await tester.tap(find.text('Add condition…'));
    await tester.pumpAndSettle();
    expect(find.text('S 10'), findsOneWidget);
    expect(find.text('New Segment'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove group'));
    await tester.pumpAndSettle();
    expect(config.stimMarkerGroups, isEmpty);
    expect(config.stimMarkers, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
