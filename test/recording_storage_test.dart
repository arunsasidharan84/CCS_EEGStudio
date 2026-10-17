import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';

void main() {
  EegRecording recording(bool epochs) => EegRecording(
    path: 'memory',
    sampleRate: 100,
    labels: ['Fz', 'Channel_name_longer_than_16'],
    sampleCount: 230,
    format: 'ccseeg',
    preview: [
      for (var c = 0; c < 2; c++)
        Float32List.fromList([
          for (var i = 0; i < 230; i++) 30 * math.sin(i * .17 + c),
        ]),
    ],
    epochCount: epochs ? 2 : 1,
    pointsPerEpoch: epochs ? 115 : null,
    epochLabels: epochs ? ['Target', 'Standard'] : null,
    epochTmin: epochs ? -.2 : null,
    epochStartSeconds: epochs ? [10, 20] : [],
    completedStages: ['preprocess'],
    provenance: const {
      'preprocessing': {'reference_mode': 'average'},
    },
    markers: [
      EegMarker(
        type: 'Stimulus',
        description: 'S 10',
        startSeconds: .2,
        epochIndex: epochs ? 0 : null,
      ),
    ],
  );
  for (final format in RecordingFileFormat.values)
    for (final epochs in [false, true]) {
      test(
        '${format.name} ${epochs ? 'epochs' : 'continuous'} preserves signals and metadata',
        () async {
          final dir = Directory.systemTemp.createTempSync('ccs-storage-test');
          addTearDown(() => dir.deleteSync(recursive: true));
          final input = recording(epochs),
              path = '${dir.path}/recording.${format.name}';
          await RecordingStorage.save(
            input,
            path,
            provenance: {
              'epoch_protocol': {'tmin': -.2, 'tmax': .94},
            },
          );
          final loaded = await RecordingLoader().load(path);
          expect(loaded.labels, input.labels);
          expect(loaded.sampleCount, 230);
          expect(loaded.isEpoched, epochs);
          expect(loaded.epochLabels, input.epochLabels);
          expect(loaded.epochTmin, input.epochTmin);
          expect(loaded.completedStages, contains('preprocess'));
          expect(loaded.markers.single.description, 'S 10');
          expect(loaded.provenance['epoch_protocol'], isNotNull);
          expect(
            loaded.provenance['preprocessing']['reference_mode'],
            'average',
          );
          for (var c = 0; c < 2; c++)
            for (var i = 0; i < 230; i++)
              expect(
                loaded.preview[c][i],
                closeTo(
                  input.preview[c][i],
                  format == RecordingFileFormat.edf ? .001 : 1e-4,
                ),
              );
          if (format != RecordingFileFormat.ccseeg) {
            final meta = jsonDecode(File('$path.ccsmeta').readAsStringSync());
            expect(meta['data_bytes'], File(path).lengthSync());
            expect(File('$path.json').existsSync(), false);
          }
        },
      );
    }
  test(
    'format preference persists independently of analysis settings',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-format-preference');
      addTearDown(() {
        dir.deleteSync(recursive: true);
        RecordingStorage.preferredFormat = RecordingFileFormat.ccseeg;
      });
      final path = '${dir.path}/storage.ccssettings';
      await RecordingStorage.setPreferredFormat(
        RecordingFileFormat.edf,
        path: path,
      );
      RecordingStorage.preferredFormat = RecordingFileFormat.ccseeg;
      await RecordingStorage.loadPreferences(path: path);
      expect(RecordingStorage.extension, 'edf');
      expect(
        RecordingStorage.withExtension('subject-epo.ccseeg.json'),
        'subject-epo.edf',
      );
    },
  );
  test(
    'failed companion replacement keeps the previous signal intact',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-pair-rollback');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/old.edf';
      File(path).writeAsStringSync('previous data');
      Directory('$path.ccsmeta').createSync();
      await expectLater(
        RecordingStorage.save(recording(false), path),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(path).readAsStringSync(), 'previous data');
    },
  );
  test(
    'fractional EDF sampling rate is preserved without event drift',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-edf-fractional');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/fractional.edf';
      final r = EegRecording(
        path: 'memory',
        format: 'ccseeg',
        sampleRate: 249.856,
        labels: ['Fz'],
        preview: [Float32List(300)],
        sampleCount: 300,
        markers: const [
          EegMarker(type: 'Event', description: 'test', startSeconds: .9),
        ],
      );
      await RecordingStorage.save(r, path);
      final restored = await RecordingLoader().load(path);
      expect(restored.sampleRate, 249.856);
      expect(restored.sampleCount, 300);
      expect(restored.markers.single.startSeconds, .9);
    },
  );
  test('stale EDF metadata is rejected', () async {
    final dir = Directory.systemTemp.createTempSync('ccs-stale-meta');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/recording.edf';
    await RecordingStorage.save(recording(false), path);
    final f = File('$path.ccsmeta'), m = jsonDecode(f.readAsStringSync());
    m['data_bytes'] = 1;
    f.writeAsStringSync(jsonEncode(m));
    await expectLater(RecordingLoader().load(path), throwsFormatException);
  });
}
