import 'dart:io';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/orbit_loader.dart';
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
    'CSV pooling aligns different column orders and missing outcomes',
    () async {
      final dir = Directory.systemTemp.createTempSync('csv_pool_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/a.csv')
        ..writeAsStringSync('filename,Alpha_PSD,Theta_PSD\na,1,2\n');
      final b = File('${dir.path}/b.csv')
        ..writeAsStringSync('Theta_PSD,filename,Beta1_PSD\n4,b,5\n');
      final out = '${dir.path}/pooled.csv';
      await ExtractionService().compileCsvFiles([a.path, b.path], out);
      final rows = File(
        out,
      ).readAsLinesSync().map(splitFeatureCsvLine).toList();
      expect(rows[0], ['filename', 'Alpha_PSD', 'Theta_PSD', 'Beta1_PSD']);
      expect(rows[2], ['b', '', '4', '5']);
    },
  );
  test(
    'preprocessing saves overlapping windows after cleaning',
    () async {
      final dir = Directory.systemTemp.createTempSync('pre_overlap_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final rec = EegRecording(
        path: '${dir.path}/input.ccseeg.json',
        sampleRate: 10,
        labels: const ['Fz', 'Cz'],
        preview: [Float32List(40), Float32List(40)],
        sampleCount: 40,
        format: 'ccseeg',
      );
      final cfg = AnalysisConfig()
        ..filter = false
        ..gedai = false
        ..badChannels = false
        ..interpolate = false
        ..downsample = false
        ..epochBeforeGedai = true;
      final saved = await ExtractionService().preprocess(
        recording: rec,
        outputPath: '${dir.path}/clean.ccseeg.json',
        options: cfg.toPreprocessingOptions(),
        outputWindowSeconds: 1,
        outputOverlapSeconds: .5,
        onProgress: (_, __) {},
      );
      expect(saved.epochCount, 7);
      expect(saved.pointsPerEpoch, 10);
      expect(saved.epochStartSeconds, [0, .5, 1, 1.5, 2, 2.5, 3]);
    },
    skip: !engine.existsSync(),
  );
  test(
    'continuous FieldTrip inspection and overlapping extraction retain full data',
    () async {
      const path =
          '/Users/arunsasidharan/EEGdata/OpenDatasets/psiconnect whole dataset/sub-PC001_ses-01_task-meditation_Clean-ft.mat';
      final rec = await RecordingLoader().load(path);
      expect(rec.isEpoched, false);
      expect(rec.pointsPerEpoch, isNull);
      expect(rec.durationSeconds, greaterThan(240));
      final dir = Directory.systemTemp.createTempSync('ft_overlap_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cfg = AnalysisConfig()
        ..fooof = false
        ..irasa = false
        ..nonlinear = false
        ..acw = false
        ..mic = false
        ..coh = false;
      final csv = '${dir.path}/features.csv';
      await ExtractionService().run(
        recordings: [rec],
        outputPath: csv,
        options: cfg.toExtractionOptions(),
        epochSeconds: 2,
        epochOverlapSeconds: 1,
        onProgress: (_, __) {},
      );
      final lines = File(csv).readAsLinesSync();
      final head = splitFeatureCsvLine(lines.first);
      final epochs = lines
          .skip(1)
          .where((l) => l.isNotEmpty)
          .map((l) => splitFeatureCsvLine(l)[head.indexOf('Epoch')])
          .toSet();
      expect(epochs.length, (rec.durationSeconds - 2).floor() + 1);
    },
    skip:
        !engine.existsSync() ||
        !File(
          '/Users/arunsasidharan/EEGdata/OpenDatasets/psiconnect whole dataset/sub-PC001_ses-01_task-meditation_Clean-ft.mat',
        ).existsSync(),
  );
  test('Orbit input is handed to engine as portable data', () async {
    final dir = Directory.systemTemp.createTempSync('orb_engine_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/sample.orb')
      ..writeAsStringSync(
        [for (var i = 0; i < 250; i++) '{"A":[$i],"B":[${i * 2}],"E":25,"C":0}']
            .join('\n'),
      );
    final rec = OrbLoader().load(file.path);
    final cfg = AnalysisConfig()
      ..downsample = false
      ..filter = false
      ..badChannels = false
      ..gedai = false
      ..interpolate = false
      ..epochBeforeGedai = false
      ..featureReferenceMode = 'none'
      ..fooof = false
      ..irasa = false
      ..nonlinear = false
      ..acw = false
      ..mic = false
      ..coh = false;
    final clean = await ExtractionService().preprocess(
      recording: rec,
      outputPath: '${dir.path}/clean.ccseeg.json',
      options: cfg.toPreprocessingOptions(),
      onProgress: (_, __) {},
    );
    expect(clean.labels, ['AF7', 'AF8', 'PPG']);
    expect(clean.sampleCount, 250);
    final csv = '${dir.path}/features.csv';
    await ExtractionService().run(
      recordings: [rec],
      outputPath: csv,
      options: cfg.toExtractionOptions(),
      epochSeconds: 1,
      onProgress: (_, __) {},
    );
    expect(File(csv).readAsStringSync(), contains('AF7'));
  }, skip: !engine.existsSync());
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
