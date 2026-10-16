import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/erp_workbench_view.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';
import 'package:ccs_eeg_app/src/erp/workbench_report.dart';
import 'package:ccs_eeg_app/src/edf_loader.dart';

void main() {
  test(
    'folder discovery prefers cleaned files and limits participants across tasks',
    () {
      final dir = Directory.systemTemp.createTempSync('erp_discovery_');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final task in ['MMN', 'N170']) {
        Directory('${dir.path}/$task').createSync();
        for (final n in [1, 2, 3]) {
          for (final suffix in ['', '_cleaned']) {
            File(
              '${dir.path}/$task/${n}_$task$suffix.edf',
            ).writeAsStringSync('');
          }
        }
      }
      final paths = discoverErpRecordings(dir.path, firstSubjects: 2);
      expect(paths.length, 4);
      expect(paths.every((p) => p.endsWith('_cleaned.edf')), true);
      expect(paths.any((p) => p.contains('/3_')), false);
    },
  );
  test('raw EDF loading exposes ERP CORE sidecar markers', () {
    final p =
        '/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/ERP_CORE_EDFformat/MMN/1_MMN_cleaned.edf';
    if (!File(p).existsSync()) return;
    final raw = EdfLoader().load(p);
    expect(raw.markers.length, 1002);
    expect(raw.markers.where((m) => m.description == '70').length, 200);
  });
  testWidgets('guided ERP starts with a clear input action', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ErpWorkbenchView())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Folder'), findsOneWidget);
    expect(
      find.text(
        'Choose recordings, inspect the markers, then review the proposed analysis.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('ERP CORE compact report and results view render', (
    tester,
  ) async {
    final path =
        '${Directory.current.path}/output/erp_core_validation/erp_results.json';
    if (!File(path).existsSync()) return;
    final font = FontLoader('DejaVuSans')
      ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    await font.load();
    final result = Map<String, dynamic>.from(
      jsonDecode(File(path).readAsStringSync()) as Map,
    );
    await tester.runAsync(() async {
      final out = await writeErpWorkbenchReport(result, File(path).parent.path);
      expect(File(out).lengthSync(), greaterThan(10000));
    });
    await tester.binding.setSurfaceSize(const Size(1500, 1050));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          fontFamily: 'DejaVuSans',
          scaffoldBackgroundColor: const Color(0xFF0F172A),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ErpWorkbenchView(initialResultPath: path),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Waveforms'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${File(path).parent.path}/erp_workbench_preview.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });
  testWidgets('advanced ERP models and decoding remain interactive', (
    tester,
  ) async {
    final path =
        '${Directory.current.path}/output/erp_core_advanced_validation/erp_results.json';
    if (!File(path).existsSync()) return;
    final result = jsonDecode(File(path).readAsStringSync()) as Map;
    await tester.runAsync(() async {
      final dir = Directory('/tmp/erp-advanced-report')
        ..createSync(recursive: true);
      final pdf = await writeErpWorkbenchReport(
        Map<String, dynamic>.from(result),
        dir.path,
      );
      expect(File(pdf).lengthSync(), greaterThan(10000));
    });
    expect(result['failures'], isEmpty);
    for (final file in result['files']) {
      expect(file['regression'], isA<Map>());
      expect(
        file['deconvolution']['solver'].every((s) => s['converged'] == true),
        isTrue,
      );
      expect(file['decoding']['folds_used'], greaterThanOrEqualTo(2));
    }
    await tester.binding.setSurfaceSize(const Size(1500, 1050));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ErpWorkbenchView(initialResultPath: path)),
      ),
    );
    await tester.pumpAndSettle();
    for (final tab in [
      'Models',
      'Decoding',
      'Group / topography',
      'Measurements',
      'Quality',
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
  });
}
