// Explicit real-data diagnostic; not part of the default unit-test suite.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';

void main() {
  test(
    'isolate preprocessing stages on the supplied ERN recording',
    () async {
      const source =
          '/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/ERP_CORE_EDFformat/ERN/39_ERN_cleaned.edf';
      const side =
          '/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/39_ERN_cleaned-epo_clean.ccseeg.json.preprocessing.json';
      final provenance = jsonDecode(await File(side).readAsString()) as Map;
      expect(provenance['source_path'], source);
      final saved = Map<String, dynamic>.from(
        provenance['preprocessing'] as Map,
      );
      final raw = await RecordingLoader().load(source);
      final root = Directory(
        Platform.environment['ERN_DIAG_OUTPUT'] ?? 'output/ern_stage_diagnosis',
      )..createSync(recursive: true);
      final results = <Map<String, dynamic>>[];
      for (var stage = 0; stage <= 5; stage++) {
        final name = [
          'epoch_only',
          'downsample',
          'filter',
          'bad_channels',
          'gedai',
          'interpolation',
        ][stage];
        final dir = Directory('${root.path}/$name')
          ..createSync(recursive: true);
        final path = '${dir.absolute.path}/39_ERN-epo.ccseeg.json';
        final options = PreprocessingOptions.fromJson({
          ...saved,
          'downsample': stage >= 1,
          'filter': stage >= 2,
          'badchannel': stage >= 3,
          'gedai': stage >= 4,
          'interpolate': stage >= 5,
        });
        stdout.writeln('START $name');
        final processed = await ExtractionService().preprocess(
          recording: raw,
          outputPath: path,
          options: options,
          onProgress: (p, m) {},
        );
        final profile = {
          'task': 'ERN',
          'component_name': 'ERN',
          'a_name': 'Correct',
          'b_name': 'Incorrect',
          'a_codes': ['Correct'],
          'b_codes': ['Incorrect'],
          'roi': ['FCz'],
          'epoch': [-.6, 1.2],
          'baseline': [-.4, -.2],
          'window': [0, .1],
          'polarity': -1.0,
          'lateralized': false,
        };
        final analysis = await ErpWorkbenchService().execute(
          [
            {'path': path, 'subject': '39'},
          ],
          {'task': 'ERN', 'profile_override': profile, 'permutations': 20},
          dir.absolute.path,
        );
        expect(analysis['failures'], isEmpty);
        final f = (analysis['files'] as List).first as Map;
        final summary = {
          'stage': name,
          'sample_rate': processed.sampleRate,
          'correct_trials': f['n_a'],
          'incorrect_trials': f['n_b'],
          'error_minus_correct_mean_uv':
              (f['measurements'] as Map)['B_minus_A']['mean'],
        };
        results.add(summary);
        stdout.writeln('RESULT ${jsonEncode(summary)}');
        await File('${root.path}/stages.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'source_path': source,
            'provenance': side,
            'design':
                'Cumulative stages; each stage reruns from the source, using the saved settings. Analysis baseline -400..-200 ms; measurement 0..100 ms, FCz.',
            'stages': results,
          }),
        );
      }
      expect(
        (results[1]['error_minus_correct_mean_uv'] as num).toDouble(),
        closeTo(-9.645528804518227, 1e-5),
      );
      expect(
        (results.last['error_minus_correct_mean_uv'] as num).toDouble(),
        lessThan(0),
      );
      expect(results.last['correct_trials'], 319);
      expect(results.last['incorrect_trials'], 82);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
