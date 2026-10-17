// Explicit real-data benchmark. Original files are read only.
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';

void main() {
  test(
    'Pallavi full-resolution loading keeps UI isolate responsive',
    () async {
      final paths = [
        '/Users/arunsasidharan/EEGdata/Pallavi/Pallavi_Task_Pre_2.vhdr',
        '/Users/arunsasidharan/EEGdata/Pallavi/P300_v01.json',
      ];
      for (final path in paths) {
        if (!File(path).existsSync()) continue;
        var ticks = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => ticks++,
        );
        final clock = Stopwatch()..start();
        final rec = await RecordingLoader().load(path);
        timer.cancel();
        expect(rec.labels, hasLength(path.endsWith('.vhdr') ? 63 : 61));
        expect(rec.preview.first.length, rec.sampleCount);
        expect(ticks, greaterThan(2));
        // ignore: avoid_print
        print(
          '${File(path).uri.pathSegments.last}: ${clock.elapsedMilliseconds} ms; UI heartbeats=$ticks; channels=${rec.labels.length}; samples=${rec.sampleCount}; rate=${rec.sampleRate}; events=${rec.markers.length}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
