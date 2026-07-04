import 'dart:typed_data';

class LoadedEeg {
  const LoadedEeg({
    required this.sampleRateHz,
    required this.channelLabels,
    required this.channelSamples,
    required this.sourceDescription,
  });

  final double sampleRateHz;
  final List<String> channelLabels;
  final List<List<double>> channelSamples;
  final String sourceDescription;
}

class EegRecording {
  const EegRecording({
    required this.path,
    required this.sampleRate,
    required this.labels,
    required this.preview,
    required this.sampleCount,
    required this.format,
    this.dataPath,
    this.epochCount = 1,
    this.pointsPerEpoch,
    this.epochLabels,
  });

  final String path;
  final String? dataPath;
  final double sampleRate;
  final List<String> labels;
  final List<Float32List> preview;
  final int sampleCount;
  final String format;
  final int epochCount;
  final int? pointsPerEpoch;
  final List<String>? epochLabels;

  double get durationSeconds => sampleCount / sampleRate;
  bool get isEpoched => epochCount > 1 && (pointsPerEpoch ?? 0) > 0;
  double get epochDurationSeconds =>
      isEpoched ? (pointsPerEpoch! / sampleRate) : durationSeconds;
}

enum DurationMode { full, interval, bins, middleTwoMinutes }

class ViewerSelection {
  const ViewerSelection({
    required this.selectedChannels,
    required this.acceptedIntervals,
    required this.rejectedIntervals,
  });

  const ViewerSelection.empty()
    : selectedChannels = const [],
      acceptedIntervals = const [],
      rejectedIntervals = const [];

  final List<String> selectedChannels;
  final List<List<double>> acceptedIntervals;
  final List<List<double>> rejectedIntervals;

  bool get hasLimits =>
      selectedChannels.isNotEmpty ||
      acceptedIntervals.isNotEmpty ||
      rejectedIntervals.isNotEmpty;
}

class PreprocessingOptions {
  const PreprocessingOptions({
    required this.downsample,
    required this.downsampleFreq,
    required this.filter,
    required this.lowHz,
    required this.highHz,
    required this.notchHz,
    required this.badchannel,
    required this.gedai,
    required this.interpolate,
    required this.gedaiEpochSeconds,
    required this.gedaiThreshold,
    this.sourceLocalization = false,
    this.epochBeforeGedai = false,
  });

  final bool downsample;
  final double downsampleFreq;
  final bool filter;
  final double lowHz;
  final double highHz;
  final double notchHz;
  final bool badchannel;
  final bool gedai;
  final bool interpolate;
  final double gedaiEpochSeconds;
  final String gedaiThreshold;
  final bool sourceLocalization;
  final bool epochBeforeGedai;

  Map<String, dynamic> toJson() => {
    'downsample': downsample,
    'downsample_freq': downsampleFreq,
    'filter': filter,
    'low_hz': lowHz,
    'high_hz': highHz,
    'notch_hz': notchHz,
    'badchannel': badchannel,
    'gedai': gedai,
    'interpolate': interpolate,
    'gedai_epoch_seconds': gedaiEpochSeconds,
    'gedai_threshold': gedaiThreshold,
    'source_localization': sourceLocalization,
    'epoch_before_gedai': epochBeforeGedai,
  };
}

class ExtractionOptions {
  const ExtractionOptions({
    required this.mode,
    required this.startSeconds,
    required this.endSeconds,
    required this.binSeconds,
    required this.psd,
    required this.fooof,
    required this.irasa,
    required this.nonlinear,
    required this.acw,
    required this.connectivity,
    required this.mic,
    required this.mim,
    required this.gc,
    required this.gcTr,
    required this.coh,
    required this.plv,
    required this.ciplv,
    required this.pli,
    required this.wpli,
    required this.removeNonEeg,
    required this.exclusions,
  });

  final DurationMode mode;
  final double startSeconds;
  final double endSeconds;
  final double binSeconds;
  final bool psd;
  final bool fooof;
  final bool irasa;
  final bool nonlinear;
  final bool acw;
  final bool connectivity;
  final bool mic;
  final bool mim;
  final bool gc;
  final bool gcTr;
  final bool coh;
  final bool plv;
  final bool ciplv;
  final bool pli;
  final bool wpli;
  final bool removeNonEeg;
  final List<String> exclusions;

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'start_seconds': startSeconds,
    'end_seconds': endSeconds,
    'bin_seconds': binSeconds,
    'psd': psd,
    'fooof': fooof,
    'irasa': irasa,
    'nonlinear': nonlinear,
    'acw': acw,
    'connectivity': connectivity,
    'mic': mic,
    'mim': mim,
    'gc': gc,
    'gc_tr': gcTr,
    'coh': coh,
    'plv': plv,
    'ciplv': ciplv,
    'pli': pli,
    'wpli': wpli,
    'remove_non_eeg': removeNonEeg,
    'exclusions': exclusions,
  };
}
