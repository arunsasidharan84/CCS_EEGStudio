import 'models.dart';

/// Advice uses the actual saved parent epoch, rather than the UI's cut length.
List<String> featureWindowWarnings(AnalysisConfig config, EegRecording rec) {
  final seconds = rec.pointsPerEpoch != null
      ? rec.pointsPerEpoch! / rec.sampleRate
      : config.epochSeconds;
  final gcLags = (config.featureParameters['gc_lags'] as num?)?.toInt() ?? 25;
  final warnings = <String>[];
  if (config.dfaFei && seconds < 60) {
    warnings.add(
      'DFA / fE:I: ${seconds.toStringAsFixed(2)} s windows are shorter '
      'than the recommended 60 s for the full band range. Lower-frequency '
      'bands can be empty; fE:I can also be missing when its validity criteria '
      'are not met. Use longer continuous windows or prepare longer parent '
      'epochs. Increasing the extraction setting does not merge saved epochs.',
    );
  }
  if ((config.fooof || config.irasa) && seconds < 1) {
    warnings.add(
      'FOOOF / IRASA need at least 1 s windows; selected windows are '
      '${seconds.toStringAsFixed(2)} s.',
    );
  }
  if (config.psd && seconds < config.psdWindowSeconds) {
    warnings.add(
      'PSD: the Welch window (${config.psdWindowSeconds} s) exceeds '
      'the analysis window (${seconds.toStringAsFixed(2)} s) and will be shortened.',
    );
  }
  if ((config.gc || config.gcTr || config.gcContrast) &&
      seconds * rec.sampleRate <= gcLags + 1) {
    warnings.add(
      'GC / GC-TR: too few samples for ${gcLags} lags; '
      'use longer epochs or fewer lags.',
    );
  }
  return warnings;
}
