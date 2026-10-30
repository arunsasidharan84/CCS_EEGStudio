import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/batch_profiles.dart';
import 'package:ccs_eeg_app/src/erp/erp_workbench_view.dart';
import 'package:ccs_eeg_app/src/models.dart';

void main() {
  testWidgets('Batch Workspace owns EEG, ERP and Microstate profiles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var profile = 'EEG';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => BatchProfilesView(
              profile: profile,
              onChanged: (v) => update(() => profile = v),
              eeg: const Text('EEG stages'),
              erp: const Text('ERP batch inputs'),
              microstates: const Text('Shared microstate template'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('EEG stages'), findsOneWidget);
    await tester.tap(find.text('ERP'));
    await tester.pump();
    expect(find.text('ERP batch inputs'), findsOneWidget);
    expect(find.text('EEG stages'), findsNothing);
    await tester.tap(find.text('Microstates'));
    await tester.pump();
    expect(find.text('Shared microstate template'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'interactive ERP asks for saved condition groups, not files or markers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final font = FontLoader('DejaVuSans')
        ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      await font.load();
      final imageKey = GlobalKey();
      final dir = Directory.systemTemp.createTempSync('erp-saved-ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/39_ERN.ccseeg.json';
      File(path).writeAsStringSync('{}');
      final rec = EegRecording(
        path: path,
        sampleRate: 250,
        labels: const ['FCz', 'Cz'],
        preview: [Float32List(852), Float32List(852)],
        sampleCount: 852,
        format: 'ccseeg',
        pointsPerEpoch: 426,
        epochCount: 2,
        epochLabels: const ['Congruent', 'Incongruent'],
        epochTmin: -.5,
      );
      final inspection = {
        'files': [
          {
            'path': path,
            'is_epoched': true,
            'can_regroup': false,
            'event_count': 401,
            'marker_counts': {'Congruent': 202, 'Incongruent': 199},
            'profile': {
              'task': 'ERN',
              'component_name': 'ERN',
              'a_name': 'Correct response',
              'b_name': 'Error response',
              'a_codes': ['111', '121', '212', '222'],
              'b_codes': ['112', '122', '211', '221'],
              'roi': ['FCz'],
              'epoch': [-.5, 1.2],
              'baseline': [-.4, -.2],
              'window': [0.0, .1],
              'polarity': -1.0,
              'lateralized': false,
            },
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'DejaVuSans',
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: imageKey,
              child: ErpWorkbenchView(
                activeRecording: rec,
                config: AnalysisConfig(),
                batchMode: false,
                initialInspection: inspection,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Folder'), findsNothing);
      expect(find.text('Files'), findsNothing);
      expect(find.text('Choose from detected markers…'), findsNothing);
      expect(find.text('Event timing source'), findsNothing);
      expect(find.textContaining('trials ready · use saved'), findsOneWidget);
      await tester.tap(find.text('Component guide'));
      await tester.pumpAndSettle();
      expect(find.textContaining('RESPONSE-locked'), findsOneWidget);
      final a = find.text('Congruent ×202').first;
      await tester.ensureVisible(a);
      await tester.tap(a);
      await tester.pump();
      final b = find.text('Incongruent ×199').last;
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pump();
      expect(find.text('Group A · Congruent'), findsOneWidget);
      expect(find.text('Group B · Incongruent'), findsOneWidget);
      expect(find.text('Average & analyse ERP'), findsOneWidget);
      expect(
        tester.getRect(find.text('Average & analyse ERP')).bottom,
        lessThan(1100),
      );
      await tester.ensureVisible(find.text('2  Compare conditions'));
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            imageKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(
          'output/erp_saved_trial_validation',
        ).createSync(recursive: true);
        await File(
          'output/erp_saved_trial_validation/interactive_groups.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
  );
}
