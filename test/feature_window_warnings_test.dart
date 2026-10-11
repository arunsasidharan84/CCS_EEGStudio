import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/feature_window_warnings.dart';

void main() {
  EegRecording rec({int? points}) => EegRecording(
    path: 'test',
    sampleRate: 250,
    labels: const ['Fz'],
    preview: [Float32List(250)],
    sampleCount: 250,
    format: 'ccseeg',
    pointsPerEpoch: points,
  );
  test('saved epochs determine warning despite longer UI setting', () {
    final cfg = AnalysisConfig()
      ..dfaFei = true
      ..epochSeconds = 60;
    expect(
      featureWindowWarnings(cfg, rec(points: 250)).join(),
      contains('1.00 s'),
    );
    expect(
      featureWindowWarnings(cfg, rec()).where((s) => s.contains('fE:I')),
      isEmpty,
    );
  });
  test('warnings apply only to selected families', () {
    final cfg = AnalysisConfig()
      ..dfaFei = false
      ..epochSeconds = 2;
    expect(
      featureWindowWarnings(cfg, rec()).any((s) => s.contains('fE:I')),
      false,
    );
    cfg
      ..fooof = true
      ..epochSeconds = .5;
    expect(featureWindowWarnings(cfg, rec()).join(), contains('FOOOF / IRASA'));
  });
  test('compact output defaults retain individual data and PDFs', () {
    final cfg = AnalysisConfig();
    expect(cfg.perFileCsv, true);
    expect(cfg.combinedCsv, false);
    expect(cfg.topoStatsPdf, true);
    expect(cfg.topoStatsPng, false);
  });
}
