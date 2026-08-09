import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/orbit_loader.dart';

void main() {
  group('OrbLoader', () {
    test('successfully loads real timestamp-prefixed Orbit .orb files', () {
      const testPath = '/Users/arunsasidharan/EEGdata/NeuroYukti/NeuroYukti/Arun01_P1782187508706_Watching_Video_2026-06-28T20-52-28.778337.orb';
      final loader = OrbLoader();
      final recording = loader.load(testPath);

      expect(recording.labels.contains('AF7'), isTrue);
      expect(recording.labels.contains('AF8'), isTrue);
      expect(recording.sampleCount, greaterThan(0));
      expect(recording.sampleRate, 250.0);
    });
  });
}
