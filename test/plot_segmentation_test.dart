// test/plot_segmentation_test.dart
//
// Verifies that a pooled batch CSV is split back into its constituent
// recordings before plotting.
//
// The regression: batch runs concatenate every recording into one CSV, and the
// plotter used to treat that whole file as a single continuous recording.
// Epochs from different subjects/sessions were averaged together and the time
// axis silently restarted at each file boundary, so the output was
// meaningless for any batch of more than one file.

import 'dart:io';

import 'package:ccs_eeg_app/src/feature_plotter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a CSV in the engine's real output format.
String _pooledCsv({required List<String> recordings, int epochs = 40}) {
  final buf = StringBuffer()
    ..writeln('Alpha_PSD,Theta_PSD,Chan,Epoch,epoch_label,filename,subjid,'
        'sessn,condn,bin_idx,bin_start_s,bin_end_s,mode');
  for (var r = 0; r < recordings.length; r++) {
    for (var e = 1; e <= epochs; e++) {
      for (final chan in ['Fp1', 'Cz', 'O2']) {
        // Give each recording a distinct level so an accidental pooling would
        // be visible rather than silently averaging out.
        final alpha = (r + 1) * 10 + e * 0.1;
        final theta = (r + 1) * 5 + e * 0.05;
        buf.writeln('$alpha,$theta,$chan,$e,NA,${recordings[r]},'
            'sub${r + 1},ses1,rest,0,0.000,80.000,full');
      }
    }
  }
  return buf.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ccs_plot_seg_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('pooled CSV is split into one plot folder per recording', () async {
    final csv = File('${tmp.path}/Batch_features.csv')
      ..writeAsStringSync(
          _pooledCsv(recordings: ['subj01_rest', 'subj02_rest', 'subj03_rest']));
    final outDir = '${tmp.path}/plots';

    final results = await generateFeaturePlotsDetailed(
      csvPaths: [csv.path],
      outputDir: outDir,
      options: const PlotOptions(
        nTopoWindows: 3,
        smoothingWindow: 5,
        epochSizeSeconds: 2.0,
        features: ['Alpha_PSD'],
      ),
    );

    final scopes = results.map((r) => r.scope).toSet();
    expect(scopes, containsAll(['subj01_rest', 'subj02_rest', 'subj03_rest']),
        reason: 'each recording must get its own plot scope');
    expect(scopes, contains('group'),
        reason: 'a group overlay must be produced for multi-recording input');

    for (final name in ['subj01_rest', 'subj02_rest', 'subj03_rest', 'group']) {
      expect(Directory('$outDir/$name').existsSync(), isTrue,
          reason: 'missing output folder for $name');
    }

    for (final r in results) {
      final f = File(r.path);
      expect(f.existsSync(), isTrue, reason: r.path);
      expect(f.lengthSync(), greaterThan(512),
          reason: 'PNG suspiciously small: ${r.path}');
    }
  });

  test('metadata columns are not plotted as features', () async {
    final csv = File('${tmp.path}/one.features.csv')
      ..writeAsStringSync(_pooledCsv(recordings: ['subj01_rest']));

    final results = await generateFeaturePlotsDetailed(
      csvPaths: [csv.path],
      outputDir: '${tmp.path}/plots',
      options: const PlotOptions(
        nTopoWindows: 2,
        smoothingWindow: 5,
        epochSizeSeconds: 2.0,
      ),
    );

    final features = results.map((r) => r.feature).toSet();
    expect(features, {'Alpha_PSD', 'Theta_PSD'});
    // bin_idx / bin_start_s / bin_end_s parse as valid doubles and were
    // previously rendered as three meaningless "features".
    for (final meta in [
      'bin_idx',
      'bin_start_s',
      'bin_end_s',
      'Epoch',
      'subjid',
    ]) {
      expect(features, isNot(contains(meta)),
          reason: '$meta is metadata, not a feature');
    }
  });

  test('single recording writes directly into the output directory', () async {
    final csv = File('${tmp.path}/solo.features.csv')
      ..writeAsStringSync(_pooledCsv(recordings: ['solo_rec']));
    final outDir = '${tmp.path}/solo_plots';

    final results = await generateFeaturePlotsDetailed(
      csvPaths: [csv.path],
      outputDir: outDir,
      options: const PlotOptions(
        nTopoWindows: 2,
        smoothingWindow: 5,
        epochSizeSeconds: 2.0,
        features: ['Alpha_PSD'],
      ),
    );

    expect(results, hasLength(1));
    // No subfolder churn for the common single-file case.
    expect(File(results.first.path).parent.path,
        Directory(outDir).absolute.path.replaceAll(RegExp(r'/$'), ''));
    expect(Directory('$outDir/group').existsSync(), isFalse);
  });

  test('segmentByFile can be turned off', () async {
    final csv = File('${tmp.path}/pooled.csv')
      ..writeAsStringSync(_pooledCsv(recordings: ['a_rec', 'b_rec']));

    final results = await generateFeaturePlotsDetailed(
      csvPaths: [csv.path],
      outputDir: '${tmp.path}/nosplit',
      options: const PlotOptions(
        nTopoWindows: 2,
        smoothingWindow: 5,
        epochSizeSeconds: 2.0,
        features: ['Alpha_PSD'],
        segmentByFile: false,
      ),
    );

    expect(results.map((r) => r.scope).toSet(), hasLength(1),
        reason: 'with splitting off the CSV is one dataset again');
  });
}
