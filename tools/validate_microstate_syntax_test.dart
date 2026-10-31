// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/microstate_analysis.dart';

void main() {
  test(
    'four complete epoched Amritharekha recordings',
    () async {
      const folder = String.fromEnvironment('MICROSTATE_DATA_DIR');
      if (folder.isEmpty) {
        markTestSkipped(
          'Set MICROSTATE_DATA_DIR to the folder of SET/FDT epoch recordings.',
        );
        return;
      }
      const configuredOutput = String.fromEnvironment('MICROSTATE_OUTPUT_DIR');
      final output = configuredOutput.isEmpty
          ? Directory.systemTemp.createTempSync('microstate_validation_').path
          : configuredOutput;
      final paths =
          Directory(folder)
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => p.endsWith('.set'))
              .toList()
            ..sort();
      final recordings = [
        for (final path in paths.take(4)) await RecordingLoader().load(path),
      ];
      for (final r in recordings) {
        print(
          '${r.path}: ${r.labels.length} channels ${r.epochCount} epochs ${r.pointsPerEpoch} points ${r.sampleRate} Hz',
        );
        expect(r.isEpoched, true);
      }
      final progress = <double>[];
      final result = await MicrostateService().run(
        recordings: recordings,
        outputDirectory: output,
        options: const MicrostateOptions(selectedStates: 4),
        onProgress: (p, m) {
          progress.add(p);
          print('${(100 * p).round()}% $m');
        },
      );
      expect(result.recordings.length, 4);
      expect(progress.last, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      for (var i = 0; i < 4; i++) {
        final r = result.recordings[i];
        expect(r.sequence.length, recordings[i].sampleCount);
        expect(r.syntax['windows'], greaterThan(0));
        final rows = File('$output/${r.sampleCsv}').readAsLinesSync();
        expect(rows.length, r.sequence.length + 1);
        final header = rows.first.split(',');
        for (final row in rows.skip(1)) {
          final v = row.split(',');
          expect(
            int.parse(v[1]),
            int.parse(v[0]) ~/ recordings[i].pointsPerEpoch!,
          );
          final assigned = double.parse(v[header.indexOf('assigned_fit_pct')]);
          expect(assigned, inInclusiveRange(0, 100.000001));
          expect(
            assigned,
            closeTo(double.parse(v[header.indexOf('fit_${v[5]}_pct')]), 1e-8),
          );
          final relative = [
            for (var c = 0; c < header.length; c++)
              if (header[c].startsWith('relative_fit_')) double.parse(v[c]),
          ].fold(0.0, (a, b) => a + b);
          expect(relative, closeTo(100, 1e-6));
        }
      }
      final single = await MicrostateService().run(
        recordings: [recordings.first],
        outputDirectory: '$output/interactive-single',
        options: const MicrostateOptions(
          selectedStates: 4,
          syntaxWordLength: 3,
        ),
        onProgress: (p, m) {},
      );
      expect(single.recordings.single.syntax['windows'], greaterThan(0));
      print(
        jsonEncode({
          'files': 4,
          'samples': [for (final r in result.recordings) r.sequence.length],
          'syntax_windows': [
            for (final r in result.recordings) r.syntax['windows'],
          ],
        }),
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
