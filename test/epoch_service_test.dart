import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/epoch_service.dart';

void main() {
  group('EpochService', () {
    test('generates event-based epochs with baseline correction', () {
      const rate = 100.0;
      final ch0 = Float32List.fromList(List.generate(1000, (i) => i.toDouble()));
      final ch1 = Float32List.fromList(List.generate(1000, (i) => (i * 2).toDouble()));

      final recording = EegRecording(
        path: 'test.vhdr',
        sampleRate: rate,
        labels: const ['Fz', 'Cz'],
        preview: [ch0, ch1],
        sampleCount: 1000,
        format: 'vhdr',
        markers: const [
          EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 2.0), // sample 200
          EegMarker(type: 'Stimulus', description: 'S 52', startSeconds: 5.0), // sample 500
          EegMarker(type: 'Stimulus', description: 'S 51', startSeconds: 7.0), // sample 700
        ],
      );

      final service = EpochService();
      final epoched = service.generateEpochs(
        recording: recording,
        options: const EpochOptions(
          targetEvents: ['S 51'],
          tmin: -0.5,
          tmax: 1.0,
          applyBaseline: true,
          baselineMin: -0.2,
          baselineMax: 0.0,
        ),
      );

      expect(epoched.epochCount, 2);
      expect(epoched.isEpoched, isTrue);
      // tmin = -0.5s (-50 samples), tmax = 1.0s (+100 samples) -> length 150 samples per epoch
      expect(epoched.pointsPerEpoch, 150);
      expect(epoched.sampleCount, 300); // 2 epochs * 150
      expect(epoched.epochLabels, const ['S 51', 'S 51']);
    });
  });
}
