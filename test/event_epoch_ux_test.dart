import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/epoch_service.dart';
import 'package:ccs_eeg_app/src/event_navigation.dart';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/edf_loader.dart';
import 'package:ccs_eeg_app/src/erp/event_group_editor.dart';
import 'package:ccs_eeg_app/src/erp/stim_epoch_panel.dart';

void main() {
  const events = [
    EegMarker(type: 'Event', description: '12', startSeconds: 2),
    EegMarker(type: 'Event', description: '112', startSeconds: 4),
    EegMarker(type: 'Event', description: '22', startSeconds: 6),
  ];
  test(
    'named conditions persist without changing raw codes or matching substrings',
    () {
      final c = AnalysisConfig()
        ..stimEpochs = true
        ..stimMarkers = ['12', '22']
        ..stimMarkerGroups = {
          'Correct': ['12', '22'],
        };
      final saved = c.toPreprocessingOptions();
      expect(saved.epochBeforeGedai, false);
      final copy = PreprocessingOptions.fromJson(saved.toJson()).stimEpochs!;
      expect(copy.selectEvents(events), [(2.0, 'Correct'), (6.0, 'Correct')]);
      final rec = EegRecording(
        path: '/tmp/input.edf',
        sampleRate: 100,
        labels: const ['Cz'],
        preview: [Float32List(1000)],
        sampleCount: 1000,
        format: 'EDF',
        markers: events,
      );
      final ep = EpochService().generateEpochs(
        recording: rec,
        options: const EpochOptions(
          targetEvents: ['12', '22'],
          markerGroups: {
            'Correct': ['12', '22'],
          },
          tmin: -.1,
          tmax: .2,
          applyBaseline: false,
        ),
      );
      expect(ep.epochCount, 2);
      expect(ep.epochLabels, ['Correct', 'Correct']);
      expect(ep.markers.map((e) => e.description), containsAll(['12', '22']));
      expect(ep.markers.any((e) => e.description == '112'), false);
    },
  );
  testWidgets('users can label and combine event codes without regex', (
    tester,
  ) async {
    var groups = <String, List<String>>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => EventGroupEditor(
              groups: groups,
              markers: const ['11', '12', '111'],
              onChanged: (g) => update(() => groups = g),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add labeled group…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Stimulus');
    await tester.tap(find.text('11'));
    await tester.tap(find.text('12'));
    await tester.tap(find.text('Save group'));
    await tester.pumpAndSettle();
    expect(groups, {
      'Stimulus': ['11', '12'],
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'panel reflects shared config changes instead of stale marker text',
    (tester) async {
      final c = AnalysisConfig()
        ..stimEpochs = true
        ..stimMarkers = ['S 51'];
      Widget panel() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StimEpochPanel(config: c, markers: events),
          ),
        ),
      );
      await tester.pumpWidget(panel());
      c.stimMarkers = ['12', '22'];
      await tester.pumpWidget(panel());
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, '12, 22');
      expect(find.text('Advanced marker matching'), findsOneWidget);
    },
  );
  testWidgets(
    'dense event labels stay outside signals and overview click navigates',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1050));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final font = FontLoader('DejaVuSans')
        ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      await font.load();
      const path =
          '/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/ERP_CORE_EDFformat/ERN/39_ERN_cleaned.edf';
      final loaded = File(path).existsSync() ? EdfLoader().load(path) : null;
      final rec = loaded != null
          ? EegRecording(
              path: path,
              sampleRate: loaded.sampleRateHz,
              labels: loaded.channelLabels,
              preview: loaded.channelSamples.map(Float32List.fromList).toList(),
              sampleCount: loaded.channelSamples.first.length,
              format: 'EDF',
              markers: loaded.markers,
            )
          : EegRecording(
              path: '/tmp/test.edf',
              sampleRate: 10,
              labels: const ['Cz'],
              preview: [Float32List(1000)],
              sampleCount: 1000,
              format: 'EDF',
              markers: events,
            );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'DejaVuSans',
            ),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: EegViewer(
                recording: rec,
                selection: const ViewerSelection.empty(),
                onSelectionChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final nav = find.byKey(const ValueKey('recording-overview'));
      final rect = tester.getRect(nav);
      await tester.tapAt(Offset(rect.left + rect.width * .6, rect.center.dy));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EventLabelLane>(find.byType(EventLabelLane)).start,
        greaterThan(rec.durationSeconds * .4),
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = Directory('output/epoch_ux_validation')
          ..createSync(recursive: true);
        await File(
          '${out.path}/event_navigation.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
}
