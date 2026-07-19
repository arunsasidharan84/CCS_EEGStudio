// test/feature_plotter_test.dart
//
// Integration-style test for the Dart-native feature plotter.
// Mirrors PlotFeatures_20260710.py using the real Thukdam pilot data.
//
// Run with:
//   cd /Users/arunsasidharan/Code/ActiveProjects/CCS_EEGStudio
//   flutter test test/feature_plotter_test.dart --timeout 5m

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:ccs_eeg_app/src/feature_plotter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── Mirror PlotFeatures_20260710.py settings ─────────────────────────────
  const recId      = 'Pilot_Tukdam_09.07.2026';
  const epochSize  = 2.0;
  const windowSize = 25;
  const nTopoWin   = 10;

  // Match the Python featurelist (subset for speed — add more as needed).
  final featureList = [
    'ACW',
    'Alpha_Irasa',
    'Delta_Irasa',
    'Theta_Irasa',
    'dfa_nonlinear',
    'sample_entropy_nonlinear',
    'conn_wpli_Alpha',
    'conn_wpli_Theta',
  ];

  final dataDir = '/Users/arunsasidharan/EEGdata/ThukdamStudy/20260709';
  final outDir  = '/Users/arunsasidharan/EEGdata/ThukdamStudy/DartPlots';

  test(
    'generates feature plots matching PlotFeatures_20260710.py output',
    () async {
    // ── Discover CSV files (same glob as the Python script) ─────────────────
    final dir = Directory(dataDir);
    expect(dir.existsSync(), isTrue,
        reason: 'Data directory not found: $dataDir');

    final csvFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.contains(recId) && f.path.endsWith('.features.csv'))
        .map((f) => f.path)
        .toList()
      ..sort();

    expect(csvFiles, isNotEmpty,
        reason: 'No .features.csv files found for $recId in $dataDir');

    print('\n── Input files (${csvFiles.length}) ──────────────────────────');
    for (final f in csvFiles) {
      print('  ${f.split('/').last}');
    }

    // ── Create output directory ───────────────────────────────────────────
    Directory(outDir).createSync(recursive: true);
    print('\n── Output directory ─────────────────────────────────────────');
    print('  $outDir\n');

    // ── Generate plots ────────────────────────────────────────────────────
    print('── Generating ${featureList.length} plots… ──────────────────');
    final saved = await generateFeaturePlots(
      csvPaths: csvFiles,
      outputDir: outDir,
      options: PlotOptions(
        nTopoWindows:     nTopoWin,
        smoothingWindow:  windowSize,
        epochSizeSeconds: epochSize,
        features:         featureList,
        montagePath:      null, // use auto standard 10-10
      ),
      onProgress: (p, msg) {
        final bar = ('█' * (p * 40).round()).padRight(40, '░');
        print('[$bar] ${(p * 100).toStringAsFixed(0).padLeft(3)}%  $msg');
      },
    );

    // ── Verify output ─────────────────────────────────────────────────────
    print('\n── Saved PNGs ───────────────────────────────────────────────');
    for (final p in saved) {
      final file = File(p);
      expect(file.existsSync(), isTrue, reason: 'PNG not created: $p');
      final size = file.lengthSync();
      expect(size, greaterThan(1024), reason: 'PNG suspiciously small: $p');
      print('  ${p.split('/').last.padRight(48)} ${(size / 1024).toStringAsFixed(1)} KB');
    }

    expect(saved.length, equals(featureList.length),
        reason: 'Expected ${featureList.length} plots, got ${saved.length}');

    // Open the output folder for visual inspection.
    if (Platform.isMacOS) {
      await Process.run('open', [outDir]);
    }

    print('\n✓ All ${saved.length} plots verified.');
  },
    skip: !Directory(dataDir).existsSync() ? 'Local data directory not found: $dataDir' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
