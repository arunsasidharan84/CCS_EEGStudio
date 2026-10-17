import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';

void main() {
  test(
    'cancel stops native job without replacing previous output; service can retry',
    () async {
      final dir = Directory.systemTemp.createTempSync('ccs-cancel-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final engine = File('${dir.path}/engine');
      await engine.writeAsString(
        '#!/bin/sh\necho "PROGRESS 10 Ready" >&2\nexec sleep 40\n',
      );
      await Process.run('chmod', ['+x', engine.path]);
      final output = File('${dir.path}/out.ccseeg.json')
        ..writeAsStringSync('previous output');
      final input = EegRecording(
        path: '${dir.path}/memory',
        sampleRate: 100,
        labels: ['Fz'],
        preview: [Float32List(1000)],
        sampleCount: 1000,
        format: 'ccseeg',
      );
      final service = ExtractionService(enginePath: engine.path);
      var started = 0;
      for (var attempt = 0; attempt < 2; attempt++) {
        final clock = Stopwatch()..start();
        final job = service.preprocess(
          recording: input,
          outputPath: output.path,
          options: AnalysisConfig().toPreprocessingOptions(),
          onProgress: (p, m) {
            if (m == 'Ready') {
              started++;
              service.cancel();
            }
          },
        );
        await expectLater(
          job.timeout(const Duration(seconds: 10)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('cancelled'),
            ),
          ),
        );
        expect(clock.elapsed.inSeconds, lessThan(10));
        expect(output.readAsStringSync(), 'previous output');
      }
      expect(started, 2);
    },
    skip: Platform.isWindows,
  );
}
