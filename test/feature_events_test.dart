import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_transform.dart';
import 'package:ccs_eeg_app/src/feature_events.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';

void main() {
  test(
    'overlapping epochs retain exact source events and full durations',
    () async {
      final raw = EegRecording(
        path: 'raw',
        sampleRate: 10,
        labels: ['Fz'],
        preview: [Float32List(100)],
        sampleCount: 100,
        format: 'ccseeg',
        markers: const [
          EegMarker(type: 'cue', description: 'Cue, "α"', startSeconds: 3.25),
          EegMarker(
            type: 'state',
            description: 'Task',
            startSeconds: 1,
            durationSeconds: 6,
          ),
          EegMarker(type: 'end', description: 'Boundary', startSeconds: 5),
        ],
      );
      final epochs = RecordingTransform.subepoch(raw, 5, 2);
      expect(epochs.epochStartSeconds, [0, 3]);
      final events = featureEvents(epochs);
      expect(events.length, 3);
      expect(events.singleWhere((e) => e['type'] == 'cue')['onset_s'], 3.25);
      expect(events.singleWhere((e) => e['type'] == 'state')['duration_s'], 6);
      final temp = Directory.systemTemp.createTempSync('event_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final csv = File('${temp.path}/features.csv')
        ..writeAsStringSync(
          'Alpha_PSD,Chan,Epoch,epoch_start_s,epoch_end_s\n1,Fz,1,0,5\n2,Fz,2,3,8\n',
        );
      await appendFeatureEvents(csv, epochs);
      expect(readFeatureEvents(csv.path).length, 3);
      final rows = csv.readAsLinesSync();
      expect(splitFeatureCsvLine(rows[1]).last, contains('Cue'));
      expect(splitFeatureCsvLine(rows[1]).last, isNot(contains('Boundary')));
      expect(splitFeatureCsvLine(rows[2]).last, contains('Boundary'));
      expect(numericFeatureColumns(csv.path), isNot(contains('event_markers')));
    },
  );
}
