import 'dart:typed_data';

import 'erp/stim_epochs.dart';

export 'erp/stim_epochs.dart' show StimEpochSpec;

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

class EegMarker {
  const EegMarker({
    required this.type,
    required this.description,
    required this.startSeconds,
    this.durationSeconds = 0.0,
    this.channelIndex,
    this.epochIndex,
  });

  final String type;
  final String description;
  final double startSeconds;
  final double durationSeconds;
  final int? channelIndex;
  final int? epochIndex;

  String get label => description.isNotEmpty ? description : type;

  Map<String, dynamic> toJson() => {
    'type': type,
    'description': description,
    'start_seconds': startSeconds,
    'duration_seconds': durationSeconds,
    if (channelIndex != null) 'channel_index': channelIndex,
    if (epochIndex != null) 'epoch_index': epochIndex,
  };

  factory EegMarker.fromJson(Map<String, dynamic> json) => EegMarker(
    type: json['type'] as String? ?? 'Marker',
    description: json['description'] as String? ?? '',
    startSeconds: (json['start_seconds'] as num?)?.toDouble() ?? 0.0,
    durationSeconds: (json['duration_seconds'] as num?)?.toDouble() ?? 0.0,
    channelIndex: (json['channel_index'] as num?)?.toInt(),
    epochIndex: (json['epoch_index'] as num?)?.toInt(),
  );
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
    this.markers = const [],
    this.epochTmin,
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
  final List<EegMarker> markers;

  /// Start of each epoch relative to its event (s), for stimulus-locked
  /// epochs. Null for continuous data or fixed-length epochs.
  final double? epochTmin;

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
    this.nonEegChannels = const [],
    this.stimEpochs,
  });

  /// Stimulus-locked epoching (ERP): cut epochs around these markers after
  /// filtering and before bad-channel detection / GEDAI / interpolation.
  final StimEpochSpec? stimEpochs;

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

  /// Channels the user has marked as non-EEG.  These are excluded from bad
  /// channel detection, interpolation and the common average reference.
  final List<String> nonEegChannels;

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
    'non_eeg_channels': nonEegChannels,
    if (stimEpochs != null) 'stim_epochs_spec': stimEpochs!.toJson(),
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
    this.nonEegChannels = const [],
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

  /// Explicit non-EEG channel labels for this recording.  When non-empty the
  /// engine drops exactly these channels rather than applying its own built-in
  /// name heuristics, so the UI and the engine can never disagree.
  final List<String> nonEegChannels;

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
    'non_eeg_channels': nonEegChannels,
  };
}

/// Mutable analysis configuration shared by the Interactive and Batch tabs.
///
/// Both tabs bind to the *same* instance, which guarantees the two workflows
/// expose an identical option set: a feature added here shows up in both
/// places, and a setting changed in one tab carries over to the other.  This
/// replaces the previous arrangement where the Batch tab re-declared a subset
/// of the flags inline and silently omitted connectivity, duration mode and
/// source localisation.
class AnalysisConfig {
  // ── Preprocessing ────────────────────────────────────────────────────────
  bool downsample = true;
  double downsampleFreq = 250;
  bool filter = true;
  double lowHz = 0.5;
  double highHz = 40;
  double notchHz = 50;
  bool badChannels = true;
  bool gedai = true;
  bool interpolate = true;
  bool epochBeforeGedai = true;
  double gedaiEpochSeconds = 1;

  // ── Stimulus-locked epochs (ERP) ────────────────────────────────────────
  bool stimEpochs = false;
  List<String> stimMarkers = const ['S 51', 'S 52'];
  String stimPattern = '';
  double stimTmin = -0.5;
  double stimTmax = 1.2;
  bool stimBaseline = true;
  double stimBaselineStart = -0.2;
  double stimBaselineEnd = 0.0;
  String stimCropMarker = '';
  double stimCropMinutes = 0;

  StimEpochSpec? get stimEpochSpec => !stimEpochs
      ? null
      : StimEpochSpec(
          markers: stimMarkers,
          pattern: stimPattern,
          tmin: stimTmin,
          tmax: stimTmax,
          baseline: stimBaseline,
          baselineStart: stimBaselineStart,
          baselineEnd: stimBaselineEnd,
          cropStartMarker: stimCropMarker,
          cropMinutes: stimCropMinutes,
        );

  /// File suffix of preprocessed outputs ("-epo_clean" for stimulus epochs).
  String get cleanSuffix => stimEpochs ? '-epo_clean' : '_clean';

  // ── Source space ─────────────────────────────────────────────────────────
  bool sourceLocalization = false;

  // ── Epoching / duration ──────────────────────────────────────────────────
  double epochSeconds = 2;
  DurationMode mode = DurationMode.full;
  double startSeconds = 0;
  double endSeconds = 120;
  double binSeconds = 60;

  // ── Feature families ─────────────────────────────────────────────────────
  bool psd = true;
  bool fooof = true;
  bool irasa = true;
  bool nonlinear = true;
  bool acw = true;

  // Multivariate connectivity
  bool mic = true;
  bool mim = false;
  bool gc = false;
  bool gcTr = false;

  // Bivariate connectivity
  bool coh = true;
  bool plv = false;
  bool ciplv = false;
  bool pli = false;
  bool wpli = false;

  bool get anyConnectivity =>
      mic || mim || gc || gcTr || coh || plv || ciplv || pli || wpli;

  bool get anyFeature =>
      psd || fooof || irasa || nonlinear || acw || anyConnectivity;

  // ── Channel handling ─────────────────────────────────────────────────────
  /// Drop non-EEG channels and re-reference to the common average.
  bool removeNonEeg = true;

  /// Comma-separated filename exclusion patterns.
  List<String> exclusions = const ['OBD', 'HRDT', 'ARSQ'];

  // ── Outputs ──────────────────────────────────────────────────────────────
  /// Write one features CSV per input file.
  bool perFileCsv = true;

  /// Also write a single pooled CSV across all inputs.
  bool combinedCsv = true;

  bool generatePlots = true;

  /// Also write one combined TopoStats PDF (summary + every figure) and one
  /// stats table per recording next to the PNGs.
  bool topoStatsPdf = true;

  bool generatePdfReport = true;

  int nTopoWindows = 2;
  int smoothingWindow = 25;

  // ── Derived option objects ───────────────────────────────────────────────

  PreprocessingOptions toPreprocessingOptions({
    List<String> nonEegChannels = const [],
    bool sourceLocalizationOnly = false,
  }) {
    if (sourceLocalizationOnly) {
      return PreprocessingOptions(
        downsample: false,
        downsampleFreq: downsampleFreq,
        filter: false,
        lowHz: lowHz,
        highHz: highHz,
        notchHz: notchHz,
        badchannel: false,
        gedai: false,
        interpolate: false,
        gedaiEpochSeconds: gedaiEpochSeconds,
        gedaiThreshold: 'auto',
        sourceLocalization: true,
        epochBeforeGedai: false,
        nonEegChannels: nonEegChannels,
      );
    }
    return PreprocessingOptions(
      downsample: downsample,
      downsampleFreq: downsampleFreq,
      filter: filter,
      lowHz: lowHz,
      highHz: highHz,
      notchHz: notchHz,
      badchannel: badChannels,
      gedai: gedai,
      interpolate: interpolate,
      gedaiEpochSeconds: gedaiEpochSeconds,
      gedaiThreshold: 'auto',
      sourceLocalization: false,
      epochBeforeGedai: epochBeforeGedai,
      nonEegChannels: nonEegChannels,
      stimEpochs: stimEpochSpec,
    );
  }

  ExtractionOptions toExtractionOptions({
    List<String> nonEegChannels = const [],
    bool applyExclusions = true,
  }) => ExtractionOptions(
    mode: mode,
    startSeconds: startSeconds,
    endSeconds: endSeconds,
    binSeconds: binSeconds,
    psd: psd,
    fooof: fooof,
    irasa: irasa,
    nonlinear: nonlinear,
    acw: acw,
    connectivity: anyConnectivity,
    mic: mic,
    mim: mim,
    gc: gc,
    gcTr: gcTr,
    coh: coh,
    plv: plv,
    ciplv: ciplv,
    pli: pli,
    wpli: wpli,
    removeNonEeg: removeNonEeg,
    exclusions: applyExclusions ? exclusions : const [],
    nonEegChannels: nonEegChannels,
  );
}
