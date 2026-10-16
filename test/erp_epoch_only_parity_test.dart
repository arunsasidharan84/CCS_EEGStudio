import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/epoch_service.dart';
import 'package:ccs_eeg_app/src/recording_transform.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';

void main() {
  const source =
      '/Volumes/One Touch/Arun/EEGdata/DemoData/ERP_CORE/ERP_CORE_EDFformat/ERN/39_ERN_cleaned.edf';
  test(
    'epoch-only preserves supplied cleaned ERP CORE ERN without extra cleaning',
    () async {
      final loader = RecordingLoader();
      final raw = await loader.load(source);
      final epoch = EpochService().generateEpochs(
        recording: raw,
        options: const EpochOptions(
          targetEvents: [
            '111',
            '121',
            '212',
            '222',
            '112',
            '122',
            '211',
            '221',
          ],
          markerGroups: {
            'Correct': ['111', '121', '212', '222'],
            'Incorrect': ['112', '122', '211', '221'],
          },
          tmin: -.6,
          tmax: 1.2,
          baselineMin: -.4,
          baselineMax: -.2,
        ),
      );
      final dir = Directory('output/erp_review_validation/epoch-only')
        ..createSync(recursive: true);
      final path = '${dir.absolute.path}/39_ERN-epo.ccseeg.json';
      await RecordingTransform.save(
        epoch,
        path,
        sourcePath: source,
        operations: {'cleaning': 'none; reuse supplied cleaned EDF'},
      );
      final expected =
          jsonDecode(
                File(
                  'output/erp_review_validation/edf/erp_results.json',
                ).readAsStringSync(),
              )
              as Map;
      final reference = (expected['files'] as List).first as Map;
      final profile = Map<String, dynamic>.from(reference['profile'] as Map)
        ..['a_codes'] = ['Correct']
        ..['b_codes'] = ['Incorrect'];
      final result = await ErpWorkbenchService().execute(
        [
          {'path': path, 'subject': '39'},
        ],
        {'task': 'ERN', 'profile_override': profile, 'permutations': 20},
        dir.absolute.path,
      );
      expect(result['failures'], isEmpty);
      final file = (result['files'] as List).first as Map;
      expect(file['n_a'], 319);
      expect(file['n_b'], 82);
      for (final key in ['a', 'b']) {
        final a = (file[key] as List).cast<num>(),
            b = (reference[key] as List).cast<num>();
        expect(a.length, b.length);
        var error = 0.0;
        for (var i = 0; i < a.length; i++) {
          final d = (a[i] - b[i]).abs().toDouble();
          if (d > error) error = d;
        }
        expect(error, lessThan(1e-5));
      }
      expect(
        (file['measurements'] as Map)['B_minus_A']['mean'],
        closeTo(-9.6756651766875, 1e-5),
      );
    },
    skip:
        !File(source).existsSync() ||
        !File('output/erp_review_validation/edf/erp_results.json').existsSync(),
  );
}
