import 'dart:io';
import 'dart:typed_data';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/edf_loader.dart';
import 'package:ccs_eeg_app/src/recording_transform.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/filtered_file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EDF time-annotated lists become crop markers on display timeline', () {
    final bytes = Uint8List.fromList(
      '+30\x14\x14\x00+30.5\x150.25\x14Cue\x14\x00'.codeUnits,
    );
    final markers = parseEdfAnnotations(bytes, displayRecordStart: 2);
    expect(markers.single.startSeconds, 2.5);
    expect(markers.single.durationSeconds, .25);
    expect(markers.single.description, 'Cue');
  });

  EegRecording source({bool epoched = false}) => EegRecording(
    path: 'example',
    sampleRate: 10,
    labels: const ['Fz'],
    preview: [
      Float32List.fromList([for (var i = 0; i < 40; i++) i.toDouble()]),
    ],
    sampleCount: 40,
    format: 'ccseeg',
    epochCount: epoched ? 2 : 1,
    pointsPerEpoch: epoched ? 20 : null,
    epochLabels: epoched ? ['A', 'B'] : null,
    markers: const [
      EegMarker(
        type: 'event',
        description: 'start',
        startSeconds: 1,
        durationSeconds: 0,
      ),
    ],
    completedStages: const ['preprocess'],
  );
  test('crop uses half-open endpoints and shifts annotations', () {
    final out = RecordingTransform.crop(source(), 1, 3);
    expect(out.preview.first, [for (var i = 10; i < 30; i++) i.toDouble()]);
    expect(out.markers.single.startSeconds, 0);
    expect(out.completedStages, contains('preprocess'));
  });
  test('subepoch overlap never crosses trial boundaries', () {
    final out = RecordingTransform.subepoch(source(epoched: true), 1, .5);
    expect(out.epochCount, 6);
    expect(out.pointsPerEpoch, 10);
    expect(out.preview.first.sublist(20, 30), [
      for (var i = 10; i < 20; i++) i.toDouble(),
    ]);
    expect(out.preview.first.sublist(30, 40), [
      for (var i = 20; i < 30; i++) i.toDouble(),
    ]);
    expect(out.epochLabels!.last, contains('B'));
  });
  test('across-recording crop preserves complete epochs and labels', () {
    final out = RecordingTransform.cropEpochRange(source(epoched: true), 2, 4);
    expect(out.epochCount, 1);
    expect(out.isEpoched, isTrue);
    expect(out.epochLabels, ['B']);
    expect(out.preview.first, [for (var i = 20; i < 40; i++) i.toDouble()]);
    expect(out.epochStartSeconds, [0]);
    expect(
      () => RecordingTransform.cropEpochRange(source(epoched: true), .5, 3),
      throwsArgumentError,
    );
  });
  test('invalid overlap and crop bounds are rejected', () {
    expect(
      () => RecordingTransform.subepoch(source(), 1, 1),
      throwsArgumentError,
    );
    expect(() => RecordingTransform.crop(source(), -1, 2), throwsArgumentError);
    expect(
      () => RecordingTransform.crop(source(epoched: true), 0, 3),
      throwsArgumentError,
    );
  });
  test(
    'saved prepared recording retains epoch boundaries and history',
    () async {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final output = '${dir.path}/prepared.ccseeg.json';
      final out = RecordingTransform.subepoch(source(epoched: true), 1, .5);
      await RecordingTransform.save(
        out,
        output,
        sourcePath: 'example',
        operations: {'overlap_seconds': .5},
      );
      final loaded = await RecordingLoader().load(output);
      expect(loaded.pointsPerEpoch, 10);
      expect(loaded.epochLabels!.length, 6);
      expect(loaded.completedStages, contains('preprocess'));
    },
  );
  test(
    'wildcards support filename alternatives and case-insensitive matching',
    () {
      expect(
        matchesFilename('/data/S01_REST.edf', '*rest*.edf;*Task*.edf'),
        isTrue,
      );
      expect(matchesFilename('/data/S02_Task.edf', 'S??_*.edf'), isTrue);
      expect(matchesFilename('/data/Other.csv', '*rest*.edf'), isFalse);
    },
  );
}
