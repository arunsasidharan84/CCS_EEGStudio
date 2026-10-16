import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source method and custom atlas survive preprocessing options serialization',
    () {
      final cfg = AnalysisConfig()
        ..sourceMethod = 'sloreta'
        ..sourceModelPath = '/tmp/hcpex.json.gz';
      final options = cfg.toPreprocessingOptions(sourceLocalizationOnly: true);
      final restored = PreprocessingOptions.fromJson(options.toJson());
      expect(restored.sourceMethod, 'sloreta');
      expect(restored.sourceModelPath, '/tmp/hcpex.json.gz');
    },
  );
  test('GCMI TE and graph choices reach the native options', () {
    final cfg = AnalysisConfig()
      ..gcmi = true
      ..transferEntropy = true
      ..spectralGraph = true
      ..connectivityOutput = 'graph'
      ..graphDensity = .3
      ..teMaxDelay = 10
      ..teSourceHistory = 2
      ..teTargetHistory = 3
      ..teHistoryStep = 2;
    final json = cfg.toExtractionOptions().toJson();
    final info = json['information'] as Map;
    expect(info['gcmi'], true);
    expect(info['te'], true);
    expect(info['spectral_graph'], true);
    expect(info['output'], 'graph');
    expect(info['graph_density'], .3);
    expect(info['te_max_delay'], 10);
    expect(info['te_source_history'], 2);
    expect(info['te_target_history'], 3);
    expect(info['te_history_step'], 2);
    expect(info['te_estimator'], 'time_copula_cmi');
  });
}
