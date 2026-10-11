import 'dart:typed_data';

import 'erp/stim_epochs.dart';

export 'erp/stim_epochs.dart' show StimEpochSpec;

class LoadedEeg {
  const LoadedEeg({
    required this.sampleRateHz,
    required this.channelLabels,
    required this.channelSamples,
    required this.sourceDescription,
    this.markers = const [],
  });

  final double sampleRateHz;
  final List<String> channelLabels;
  final List<List<double>> channelSamples;
  final String sourceDescription;
  final List<EegMarker> markers;
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
    this.completedStages = const [],
    this.epochStartSeconds = const [],
    this.sourceDurationSeconds,
  });

  final List<String> completedStages;
  final List<double> epochStartSeconds;
  final double? sourceDurationSeconds;
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
  bool get isEpoched => epochCount >= 1 && (pointsPerEpoch ?? 0) > 0;
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
    this.referenceMode = 'none',
    this.referenceChannels = const [],
    this.firTaps = 0,
    this.badVarianceRatio = 25,
    this.splineStiffness = 4,
    this.splineRegularization = 1e-5,
    this.filterType = 'fir',
    this.iirOrder = 4,
    this.notchWidthHz = 1,
    this.notchTransitionHz = 2,
    this.sourceSnr = 3,
    this.sourceRegions = const [],
    this.epochBeforeGedai = false,
    this.nonEegChannels = const [],
    this.stimEpochs,
    this.icaMethod = 'none',
    this.icaBlink = true,
    this.icaOther = true,
    this.icaEyeChannel = '',
    this.icaBlinkEpochs = 20,
    this.icaBlinkThreshold = 0.99,
    this.icaBlinkThresholdFloor = 0.60,
    this.icaRemoveEcg = true,
    this.icaArtefacts = const [],
    this.icaOtherThreshold = 0.99,
    this.icaOtherThresholdFloor = 0.60,
    this.icaFitAsr = true,
    this.icaFitAsrCutoff = 15,
    this.icaSeed = 1,
    this.asrMode = 'off',
    this.asrCutoff = 20,
    this.asrVariant = 'standard',
    this.asrAdaptAlpha = 0.05,
    this.asrEmbedDim = 8,
    this.asrEmbedTau = 2,
    this.asrModes = 4,
    this.muscleMethod = 'none',
    this.bsscaNRemove = 3,
    this.iccThreshold = 0.7,
    this.wicaLevels = 5,
  });

  factory PreprocessingOptions.fromJson(
    Map<String, dynamic> json,
  ) => PreprocessingOptions(
    downsample: json['downsample'] as bool? ?? true,
    downsampleFreq: (json['downsample_freq'] as num?)?.toDouble() ?? 250,
    filter: json['filter'] as bool? ?? true,
    lowHz: (json['low_hz'] as num?)?.toDouble() ?? 0.5,
    highHz: (json['high_hz'] as num?)?.toDouble() ?? 40,
    notchHz: (json['notch_hz'] as num?)?.toDouble() ?? 50,
    badchannel: json['badchannel'] as bool? ?? true,
    gedai: json['gedai'] as bool? ?? true,
    interpolate: json['interpolate'] as bool? ?? true,
    gedaiEpochSeconds: (json['gedai_epoch_seconds'] as num?)?.toDouble() ?? 1,
    gedaiThreshold: json['gedai_threshold'] as String? ?? 'auto',
    referenceMode: json['reference_mode'] as String? ?? 'none',
    referenceChannels:
        (json['reference_channels'] as List?)?.cast<String>() ?? const [],
    firTaps: (json['fir_taps'] as num?)?.toInt() ?? 0,
    filterType: json['filter_type'] as String? ?? 'fir',
    iirOrder: (json['iir_order'] as num?)?.toInt() ?? 4,
    notchWidthHz: (json['notch_width_hz'] as num?)?.toDouble() ?? 1,
    notchTransitionHz: (json['notch_transition_hz'] as num?)?.toDouble() ?? 2,
    sourceSnr: (json['source_snr'] as num?)?.toDouble() ?? 3,
    sourceRegions:
        (json['source_regions'] as List?)?.cast<String>() ?? const [],
    sourceLocalization: json['source_localization'] as bool? ?? false,
    epochBeforeGedai: json['epoch_before_gedai'] as bool? ?? false,
    nonEegChannels:
        (json['non_eeg_channels'] as List?)?.cast<String>() ?? const [],
    icaMethod: json['ica_method'] as String? ?? 'none',
    icaBlink: json['ica_blink'] as bool? ?? true,
    icaOther: json['ica_other'] as bool? ?? true,
    icaEyeChannel: json['ica_eye_channel'] as String? ?? '',
    icaBlinkEpochs: (json['ica_blink_epochs'] as num?)?.toInt() ?? 20,
    icaBlinkThreshold: (json['ica_blink_threshold'] as num?)?.toDouble() ?? 0.99,
    icaBlinkThresholdFloor:
        (json['ica_blink_threshold_floor'] as num?)?.toDouble() ?? 0.60,
    icaRemoveEcg: json['ica_remove_ecg'] as bool? ?? true,
    icaArtefacts: (json['ica_artefacts'] as List?)?.cast<String>() ?? const [],
    icaOtherThreshold: (json['ica_other_threshold'] as num?)?.toDouble() ?? 0.99,
    icaOtherThresholdFloor:
        (json['ica_other_threshold_floor'] as num?)?.toDouble() ?? 0.60,
    icaFitAsr: json['ica_fit_asr'] as bool? ?? true,
    icaFitAsrCutoff: (json['ica_fit_asr_cutoff'] as num?)?.toDouble() ?? 15,
    icaSeed: (json['ica_seed'] as num?)?.toInt() ?? 1,
    asrMode: json['asr_mode'] as String? ?? 'off',
    asrCutoff: (json['asr_cutoff'] as num?)?.toDouble() ?? 20,
    asrVariant: json['asr_variant'] as String? ?? 'standard',
    asrAdaptAlpha: (json['asr_adapt_alpha'] as num?)?.toDouble() ?? 0.05,
    asrEmbedDim: (json['asr_embed_dim'] as num?)?.toInt() ?? 8,
    asrEmbedTau: (json['asr_embed_tau'] as num?)?.toInt() ?? 2,
    asrModes: (json['asr_modes'] as num?)?.toInt() ?? 4,
    muscleMethod: json['muscle_method'] as String? ?? 'none',
    bsscaNRemove: (json['bsscca_n_remove'] as num?)?.toInt() ?? 3,
    iccThreshold: (json['icc_threshold'] as num?)?.toDouble() ?? 0.7,
    wicaLevels: (json['wica_levels'] as num?)?.toInt() ?? 5,
  );

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
  final String referenceMode;
  final List<String> referenceChannels;
  final int firTaps;
  final double badVarianceRatio, splineRegularization;
  final int splineStiffness;
  final String filterType;
  final int iirOrder;
  final double notchWidthHz, notchTransitionHz, sourceSnr;
  final List<String> sourceRegions;
  final bool epochBeforeGedai;

  /// ICA cleaning run before ASR / GEDAI: 'none' | 'runica' | 'picard'
  /// (blink-locked stage + second stage, components classified by ICLabel).
  final String icaMethod;
  final bool icaBlink, icaOther, icaRemoveEcg, icaFitAsr;

  /// Blink-detection channel label (empty = automatic frontal channel).
  final String icaEyeChannel;
  final int icaBlinkEpochs, icaSeed;

  /// ASR burst cutoff of the copy ICA is fitted on (MATLAB `ica2_BurstCriterion`).
  final double icaFitAsrCutoff;
  final double icaBlinkThreshold,
      icaBlinkThresholdFloor,
      icaOtherThreshold,
      icaOtherThresholdFloor;

  /// ICLabel classes removed by the second ICA stage (empty = Muscle,
  /// Line Noise, Channel Noise).
  final List<String> icaArtefacts;

  /// Artifact Subspace Reconstruction: 'off' | 'correct' | 'reject'.
  final String asrMode;
  final double asrCutoff;

  /// ASR flavour: 'standard' | 'riemannian' | 'adaptive' | 'juggler_dbscan' |
  /// 'juggler_gev' | 'easr' | 'vmd' | 'emd'.
  final String asrVariant;
  final double asrAdaptAlpha;
  final int asrEmbedDim;
  final int asrEmbedTau;
  final int asrModes;

  /// Non-ASR muscle/motion cleaner: 'none' | 'bss_cca' | 'icanclean' | 'wica'.
  final String muscleMethod;
  final int bsscaNRemove;
  final double iccThreshold;
  final int wicaLevels;

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
    'reference_mode': referenceMode,
    'reference_channels': referenceChannels,
    'fir_taps': firTaps,
    'bad_variance_ratio': badVarianceRatio,
    'spline_stiffness': splineStiffness,
    'spline_regularization': splineRegularization,
    'filter_type': filterType,
    'iir_order': iirOrder,
    'notch_width_hz': notchWidthHz,
    'notch_transition_hz': notchTransitionHz,
    'source_snr': sourceSnr,
    'source_regions': sourceRegions,
    'epoch_before_gedai': epochBeforeGedai,
    'non_eeg_channels': nonEegChannels,
    'ica_method': icaMethod,
    'ica_blink': icaBlink,
    'ica_other': icaOther,
    'ica_eye_channel': icaEyeChannel,
    'ica_blink_epochs': icaBlinkEpochs,
    'ica_blink_threshold': icaBlinkThreshold,
    'ica_blink_threshold_floor': icaBlinkThresholdFloor,
    'ica_remove_ecg': icaRemoveEcg,
    'ica_artefacts': icaArtefacts,
    'ica_other_threshold': icaOtherThreshold,
    'ica_other_threshold_floor': icaOtherThresholdFloor,
    'ica_fit_asr': icaFitAsr,
    'ica_fit_asr_cutoff': icaFitAsrCutoff,
    'ica_seed': icaSeed,
    'asr_mode': asrMode,
    'asr_cutoff': asrCutoff,
    'asr_variant': asrVariant,
    'asr_adapt_alpha': asrAdaptAlpha,
    'asr_embed_dim': asrEmbedDim,
    'asr_embed_tau': asrEmbedTau,
    'asr_modes': asrModes,
    'muscle_method': muscleMethod,
    'bsscca_n_remove': bsscaNRemove,
    'icc_threshold': iccThreshold,
    'wica_levels': wicaLevels,
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
    this.gcContrast = false,
    this.dfaFei = false,
    this.psdWindowSeconds = 1,
    this.psdAverage = 'median',
    this.psdBands = const [],
    this.advancedParameters = const {},
    this.referenceMode = 'average',
    this.referenceChannels = const [],
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
  final bool gcContrast;
  final bool dfaFei;
  final double psdWindowSeconds;
  final String psdAverage;
  final List<Map<String, dynamic>> psdBands;
  final Map<String, dynamic> advancedParameters;
  final String referenceMode;
  final List<String> referenceChannels;
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
    'psd_window_seconds': psdWindowSeconds,
    'psd_average': psdAverage,
    'psd_bands': psdBands,
    'advanced_parameters': advancedParameters,
    'reference_mode': referenceMode,
    'reference_channels': referenceChannels,
    'fooof': fooof,
    'irasa': irasa,
    'nonlinear': nonlinear,
    'acw': acw,
    'connectivity': connectivity,
    'mic': mic,
    'mim': mim,
    'gc': gc,
    'gc_tr': gcTr,
    'gc_contrast': gcContrast,
    'dfa_fei': dfaFei,
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
  String gedaiThreshold = 'auto';
  // ICA (runica / Picard + ICLabel) and ASR, run before GEDAI.
  String icaMethod = 'none';
  bool icaBlink = true;
  bool icaOther = true;
  String icaEyeChannel = '';
  int icaBlinkEpochs = 20;
  double icaBlinkThreshold = 0.99;
  double icaBlinkThresholdFloor = 0.60;
  bool icaRemoveEcg = true;
  double icaFitAsrCutoff = 15;
  List<String> icaArtefacts = [];
  double icaOtherThreshold = 0.99;
  double icaOtherThresholdFloor = 0.60;
  bool icaFitAsr = true;
  int icaSeed = 1;
  String asrMode = 'off';
  double asrCutoff = 20;
  String asrVariant = 'standard';
  double asrAdaptAlpha = 0.05;
  int asrEmbedDim = 8;
  int asrEmbedTau = 2;
  int asrModes = 4;
  String muscleMethod = 'none';
  int bsscaNRemove = 3;
  double iccThreshold = 0.7;
  int wicaLevels = 5;
  String referenceMode = 'none';
  List<String> referenceChannels = [];
  int firTaps = 0;
  double badVarianceRatio = 25, splineRegularization = 1e-5;
  int splineStiffness = 4;
  String filterType = 'fir';
  int iirOrder = 4;
  double notchWidthHz = 1, notchTransitionHz = 2, sourceSnr = 3;
  List<String> sourceRegions = [];

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
  double psdWindowSeconds = 1;
  String psdAverage = 'median';
  List<Map<String, dynamic>> psdBands = [];
  Map<String, dynamic> featureParameters = {};
  String featureReferenceMode = 'average';
  List<String> featureReferenceChannels = [];
  bool fooof = true;
  bool irasa = true;
  bool nonlinear = true;
  bool acw = true;

  // Multivariate connectivity
  bool mic = true;
  bool mim = false;
  bool gc = false;
  bool gcTr = false;
  bool gcContrast = false;
  bool dfaFei = false;

  // Bivariate connectivity
  bool coh = true;
  bool plv = false;
  bool ciplv = false;
  bool pli = false;
  bool wpli = false;

  bool get anyConnectivity =>
      mic ||
      mim ||
      gc ||
      gcTr ||
      gcContrast ||
      coh ||
      plv ||
      ciplv ||
      pli ||
      wpli;

  bool get anyFeature =>
      psd || fooof || irasa || nonlinear || dfaFei || acw || anyConnectivity;

  // ── Channel handling ─────────────────────────────────────────────────────
  /// Drop non-EEG channels and re-reference to the common average.
  bool removeNonEeg = true;

  /// Comma-separated filename exclusion patterns.
  List<String> exclusions = const ['OBD', 'HRDT', 'ARSQ'];

  // ── Outputs ──────────────────────────────────────────────────────────────
  /// Write one features CSV per input file.
  bool perFileCsv = true;

  /// Also write a single pooled CSV across all inputs.
  bool combinedCsv = false;

  bool generatePlots = true;

  /// Also write one combined TopoStats PDF (summary + every figure) and one
  /// stats table per recording next to the PNGs.
  bool topoStatsPdf = true;
  bool topoStatsPng = false;

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
        gedaiThreshold: gedaiThreshold,
        referenceMode: referenceMode,
        referenceChannels: referenceChannels,
        firTaps: firTaps,
        badVarianceRatio: badVarianceRatio,
        splineStiffness: splineStiffness,
        splineRegularization: splineRegularization,
        filterType: filterType,
        iirOrder: iirOrder,
        notchWidthHz: notchWidthHz,
        notchTransitionHz: notchTransitionHz,
        sourceSnr: sourceSnr,
        sourceRegions: sourceRegions,
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
      gedaiThreshold: gedaiThreshold,
      referenceMode: referenceMode,
      referenceChannels: referenceChannels,
      firTaps: firTaps,
      badVarianceRatio: badVarianceRatio,
      splineStiffness: splineStiffness,
      splineRegularization: splineRegularization,
      filterType: filterType,
      iirOrder: iirOrder,
      notchWidthHz: notchWidthHz,
      notchTransitionHz: notchTransitionHz,
      sourceSnr: sourceSnr,
      sourceRegions: sourceRegions,
      sourceLocalization: false,
      epochBeforeGedai: epochBeforeGedai,
      nonEegChannels: nonEegChannels,
      stimEpochs: stimEpochSpec,
      icaMethod: icaMethod,
      icaBlink: icaBlink,
      icaOther: icaOther,
      icaEyeChannel: icaEyeChannel,
      icaBlinkEpochs: icaBlinkEpochs,
      icaBlinkThreshold: icaBlinkThreshold,
      icaBlinkThresholdFloor: icaBlinkThresholdFloor,
      icaRemoveEcg: icaRemoveEcg,
      icaArtefacts: icaArtefacts,
      icaOtherThreshold: icaOtherThreshold,
      icaOtherThresholdFloor: icaOtherThresholdFloor,
      icaFitAsr: icaFitAsr,
      icaFitAsrCutoff: icaFitAsrCutoff,
      icaSeed: icaSeed,
      asrMode: asrMode,
      asrCutoff: asrCutoff,
      asrVariant: asrVariant,
      asrAdaptAlpha: asrAdaptAlpha,
      asrEmbedDim: asrEmbedDim,
      asrEmbedTau: asrEmbedTau,
      asrModes: asrModes,
      muscleMethod: muscleMethod,
      bsscaNRemove: bsscaNRemove,
      iccThreshold: iccThreshold,
      wicaLevels: wicaLevels,
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
    dfaFei: dfaFei,
    acw: acw,
    connectivity: anyConnectivity,
    mic: mic,
    mim: mim,
    gc: gc,
    gcTr: gcTr,
    gcContrast: gcContrast,
    psdWindowSeconds: psdWindowSeconds,
    psdAverage: psdAverage,
    psdBands: psdBands,
    advancedParameters: featureParameters,
    referenceMode: featureReferenceMode,
    referenceChannels: featureReferenceChannels,
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
