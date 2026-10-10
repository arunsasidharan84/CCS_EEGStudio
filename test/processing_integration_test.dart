import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final engine = File(
    '${Directory.current.path}/bridge/target/release/ccs-eeg-engine${Platform.isWindows ? '.exe' : ''}',
  );
  test(
    'preprocessing preserves annotations and completion history',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs_integration_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final rec = EegRecording(
        path: '${dir.path}/S01_Rest.ccseeg.json',
        sampleRate: 10,
        labels: const ['Fz', 'Cz'],
        preview: [
          Float32List.fromList([for (var i = 0; i < 40; i++) i.toDouble()]),
          Float32List.fromList([for (var i = 0; i < 40; i++) i.toDouble() * 2]),
        ],
        sampleCount: 40,
        format: 'ccseeg',
        markers: const [
          EegMarker(
            type: 'Annotation',
            description: 'Cue',
            startSeconds: 2.5,
            durationSeconds: 0,
          ),
        ],
      );
      final config = AnalysisConfig()
        ..downsample = false
        ..filter = false
        ..badChannels = false
        ..gedai = false
        ..interpolate = false
        ..epochBeforeGedai = true;
      final out = await ExtractionService().preprocess(
        recording: rec,
        outputPath: '${dir.path}/arbitrary_name.ccseeg.json',
        options: config.toPreprocessingOptions(),
        onProgress: (_, __) {},
      );
      expect(out.pointsPerEpoch, 10);
      expect(out.completedStages, contains('preprocess'));
      expect(out.markers.single.epochIndex, 2);
      expect(out.markers.single.startSeconds, .5);
    },
    skip: !engine.existsSync(),
  );
  test(
    'extraction retains original recording identity and overlap timestamps',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs_integration_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final rec = EegRecording(
        path: '${dir.path}/S01_01_Rest_prepared.ccseeg.json',
        sampleRate: 10,
        labels: const ['Fz', 'Cz'],
        preview: [
          for (final amplitude in [1.0, 2.0])
            Float32List.fromList([
              for (var i = 0; i < 40; i++)
                amplitude * math.sin(2 * math.pi * 2 * i / 10),
            ]),
        ],
        sampleCount: 40,
        format: 'ccseeg',
        epochCount: 4,
        pointsPerEpoch: 10,
        epochStartSeconds: const [0, .5, 1, 1.5],
      );
      final config = AnalysisConfig()
        ..fooof = false
        ..irasa = false
        ..nonlinear = false
        ..acw = false
        ..mic = false
        ..coh = false
        ..featureReferenceMode = 'none';
      final csv = '${dir.path}/features.csv';
      await ExtractionService().run(
        recordings: [rec],
        outputPath: csv,
        options: config.toExtractionOptions(),
        epochSeconds: 2,
        onProgress: (_, __) {},
      );
      final lines = File(csv).readAsLinesSync();
      final headers = splitFeatureCsvLine(lines.first);
      final row = splitFeatureCsvLine(lines[1]);
      expect(row[headers.indexOf('filename')], 'S01_01_Rest_prepared');
      expect(row[headers.indexOf('subjid')], 'S01');
      final parsed = parseFeatureCsv(csv, ['Delta_PSD'], ['Fz', 'Cz']);
      expect(parsed.epochEndSeconds, {1: 1.0, 2: 1.5, 3: 2.0, 4: 2.5});
      expect(File('$csv.analysis.json').existsSync(), isTrue);
    },
    skip: !engine.existsSync(),
  );
}
