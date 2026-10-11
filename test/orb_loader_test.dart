import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/orbit_loader.dart';

void main() {
  group('OrbLoader', () {
    test('scalar C status does not create extra EEG channels', () {
      final dir = Directory.systemTemp.createTempSync('orb_status_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/sample.orb')
        ..writeAsStringSync('{"A":[100,200],"B":[300,400],"E":25,"C":0}');
      final rec = OrbLoader().load(file.path);
      expect(rec.labels, ['AF7', 'AF8', 'PPG']);
      expect(rec.sampleCount, 2);
      expect(rec.preview[0], [-1, -2]);
    });

    const testPath =
        '/Users/arunsasidharan/EEGdata/NeuroYukti/NeuroYukti/Arun01_P1782187508706_Watching_Video_2026-06-28T20-52-28.778337.orb';
    test(
      'successfully loads real timestamp-prefixed Orbit .orb files',
      () {
        final loader = OrbLoader();
        final recording = loader.load(testPath);

        expect(recording.labels.contains('AF7'), isTrue);
        expect(recording.labels.contains('AF8'), isTrue);
        expect(recording.sampleCount, greaterThan(0));
        expect(recording.sampleRate, 250.0);
      },
      skip: File(testPath).existsSync()
          ? false
          : 'External Orbit fixture is unavailable',
    );
  });
}
