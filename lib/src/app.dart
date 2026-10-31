import 'feature_window_warnings.dart';
import 'app_instance.dart';
import 'recording_details.dart';
import 'recording_save_dialog.dart';
import 'processing_progress.dart';
import 'xdf_loader.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'channel_types.dart';
import 'eeg_viewer.dart';
import 'extraction_service.dart';
import 'models.dart';
import 'topostats/topostats_batch.dart';
import 'report/feature_report.dart';
import 'topostats/topostats_engine.dart' show TopoStatsSettings;
import 'recording_loader.dart';
import 'recording_storage.dart';
import 'recording_preparation_dialog.dart';
import 'filtered_file_picker.dart';
import 'group_statistics.dart';
import 'processing_settings_dialog.dart';
import 'erp_analysis.dart';
import 'erp/erp_workbench_view.dart';
import 'batch_profiles.dart';
import 'erp/stim_epoch_panel.dart';
import 'epoch_service.dart';
import 'recording_transform.dart';
import 'erp/protocol_tools.dart';
import 'erp/output_naming.dart';
import 'topostats_analysis.dart';
import 'microstate_analysis.dart';
import 'update_checker.dart';

// ── Design tokens (ScoringNidra palette) ──────────────────────────────────
const _bgColor = Color(0xFF0F172A);
const _cardColor = Color(0xFF1E293B);
const _accentBlue = Color(0xFF3B82F6);
const _accentGreen = Color(0xFF22C55E);
const _accentAmber = Color(0xFFF59E0B);
const _accentPurple = Color(0xFF7C3AED);
const _accentPink = Color(0xFFA855F7);
const _textMuted = Color(0xFF94A3B8);
const _borderColor = Color(0x1FFFFFFF);

const _rawExtensions = [
  'edf',
  'set',
  'fif',
  'mat',
  'vhdr',
  'xdf',
  'json',
  'ccseeg',
  'orb',
  'signal',
];
const _processedExtensions = ['ccseeg', 'json', 'fif', 'edf'];
const _anyInputExtensions = [
  'edf',
  'set',
  'fif',
  'mat',
  'vhdr',
  'xdf',
  'json',
  'ccseeg',
  'orb',
  'signal',
];

// ── Pipeline module definitions ───────────────────────────────────────
enum _Module {
  loadRaw,
  preprocess,
  epochs,
  sourceSpace,
  featureExtraction,
  plotsReport,
  erpAnalysis,
  topoStats,
  microstates,
  groupStatistics,
}

class _PipelinePreset {
  final String label;
  final String description;
  final IconData icon;
  final List<_Module> modules;
  const _PipelinePreset(this.label, this.description, this.icon, this.modules);
}

const _presets = <String, _PipelinePreset>{
  'continuous': _PipelinePreset(
    'Continuous EEG',
    'Clean, inspect, extract features, and report',
    Icons.multiline_chart,
    [
      _Module.loadRaw,
      _Module.preprocess,
      _Module.sourceSpace,
      _Module.featureExtraction,
      _Module.plotsReport,
      _Module.groupStatistics,
    ],
  ),
  'erp': _PipelinePreset(
    'ERP Analysis',
    'Epoch and analyse event responses',
    Icons.show_chart,
    [_Module.loadRaw, _Module.preprocess, _Module.epochs, _Module.erpAnalysis],
  ),
  'full': _PipelinePreset(
    'Full Pipeline',
    'All analysis modules in one workspace',
    Icons.account_tree,
    [
      _Module.loadRaw,
      _Module.preprocess,
      _Module.sourceSpace,
      _Module.featureExtraction,
      _Module.plotsReport,
      _Module.epochs,
      _Module.erpAnalysis,
      _Module.topoStats,
      _Module.microstates,
      _Module.groupStatistics,
    ],
  ),
  'microstates': _PipelinePreset(
    'EEG Microstates',
    'Canonical maps, dynamics, and sequence complexity',
    Icons.grain,
    [_Module.loadRaw, _Module.preprocess, _Module.microstates],
  ),
};

String _moduleLabel(_Module m) => switch (m) {
  _Module.groupStatistics => 'Group Statistics',
  _Module.loadRaw => 'Open Recording',
  _Module.epochs => 'Epochs',
  _Module.preprocess => 'Preprocess',
  _Module.sourceSpace => 'Source Space',
  _Module.featureExtraction => 'Feature Extraction',
  _Module.plotsReport => 'Plots & Report',
  _Module.erpAnalysis => 'ERP Analysis',
  _Module.topoStats => 'TopoStats',
  _Module.microstates => 'Microstates',
};

String _moduleSubtitle(_Module m) => switch (m) {
  _Module.groupStatistics => 'Metadata, LMM / GLM, contrasts',
  _Module.loadRaw => 'Raw, preprocessed or saved epochs',
  _Module.epochs => 'Events → named condition trials',
  _Module.preprocess => 'Filter, re-reference, clean',
  _Module.sourceSpace => 'Minimum-norm source analysis',
  _Module.featureExtraction => 'Spectral, connectivity, non-linear',
  _Module.plotsReport => 'Topomaps & line plots',
  _Module.erpAnalysis => 'Event waveforms & stats',
  _Module.topoStats => 'e-TFCE & FDR topomaps',
  _Module.microstates => 'Segmentation, dynamics & complexity',
};

IconData _moduleIcon(_Module m) => switch (m) {
  _Module.groupStatistics => Icons.groups,
  _Module.loadRaw => Icons.file_open,
  _Module.epochs => Icons.content_cut,
  _Module.preprocess => Icons.cleaning_services,
  _Module.sourceSpace => Icons.psychology,
  _Module.featureExtraction => Icons.analytics,
  _Module.plotsReport => Icons.stacked_line_chart,
  _Module.erpAnalysis => Icons.show_chart,
  _Module.topoStats => Icons.map,
  _Module.microstates => Icons.grain,
};

Color _moduleColor(_Module m) => switch (m) {
  _Module.groupStatistics => _accentPurple,
  _Module.loadRaw => _accentBlue,
  _Module.epochs => _accentGreen,
  _Module.preprocess => _accentPurple,
  _Module.sourceSpace => _accentBlue,
  _Module.featureExtraction => _accentGreen,
  _Module.plotsReport => _accentAmber,
  _Module.erpAnalysis => const Color(0xFFEC4899),
  _Module.topoStats => const Color(0xFF06B6D4),
  _Module.microstates => const Color(0xFF06B6D4),
};

class CcsEegApp extends StatelessWidget {
  const CcsEegApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'CCS EEG Studio',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accentBlue,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: _bgColor,
      cardColor: _cardColor,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(borderSide: BorderSide(color: _borderColor)),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: _borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: _accentBlue),
        ),
        labelStyle: TextStyle(color: _textMuted),
        isDense: true,
        filled: true,
        fillColor: _bgColor,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? _accentBlue
              : Colors.transparent,
        ),
        side: const BorderSide(color: _textMuted),
        checkColor: WidgetStateProperty.all(Colors.white),
      ),
    ),
    home: const FeatureHome(),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  App structure
// ═══════════════════════════════════════════════════════════════════════════
//
//  Single-workspace pipeline builder:
//
//    PIPELINE SIDEBAR    — Configurable flowchart of analysis modules.
//                         Preset pipelines: Continuous EEG, ERP, Full.
//    MAIN CONTENT AREA   — Shows the selected module's settings, viewer,
//                         or results.
//    BATCH PANEL          — Collapsible bottom panel for multi-file
//                         unattended execution of the configured pipeline.
//
//  Analysis modules (parallel, composable):
//    PREPROCESS & VIEW  — Load raw EEG, preprocess, inspect waveforms.
//    ERP ANALYSIS       — Open → optional cleaning → Epochs → ERP stats.
//    FEATURE ANALYSIS   — Preprocessed EEG → epoch-level features.
//    EEG MICROSTATES    — (Coming soon) Microstate segmentation.
//    PLOTS & REPORT     — Topomaps & line plots from feature CSVs.
//    TOPOSTATS          — e-TFCE & FDR topomaps.
//
// ═══════════════════════════════════════════════════════════════════════════

class FeatureHome extends StatefulWidget {
  const FeatureHome({super.key});
  @override
  State<FeatureHome> createState() => _FeatureHomeState();
}

/// Pipeline stage that produced the recording currently under analysis.
enum _Stage { raw, preprocessed, source, direct }

class _FeatureHomeState extends State<FeatureHome>
    with SingleTickerProviderStateMixin {
  final _loader = RecordingLoader();
  final _service = ExtractionService();

  /// Single source of truth for every analysis option, shared by both modes.
  final _cfg = AnalysisConfig();

  // ── Pipeline state ──────────────────────────────────────────────────────
  String _presetKey = 'continuous';
  late List<_Module> _pipeline;
  _Module? _selectedModule;
  bool _sidebarCollapsed = false;
  bool _batchMaximized = false;
  String _batchProfile = 'EEG';
  bool _workspaceMaximized = false;
  bool _waveformMaximized = false;

  // ── Text controllers (bound to _cfg on change) ──────────────────────────
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController(text: '120');
  final _bin = TextEditingController(text: '60');
  final _epoch = TextEditingController(text: '2');
  final _epochOverlap = TextEditingController(text: '0');
  final _dfaWindow = TextEditingController(text: '60');
  final _prepOverlap = TextEditingController(text: '0');
  bool _batchPreprocessedInput = false;
  String? _groupInputCsv;
  bool _batchOpenGroupAfter = true;
  final _batchSubjectLimit = TextEditingController(text: '0');
  final _gedaiEpoch = TextEditingController(text: '1');
  final _gedaiThreshold = TextEditingController(text: 'auto');
  final _exclude = TextEditingController(text: 'OBD, HRDT, ARSQ');
  final _preDownsample = TextEditingController(text: '250');
  final _preLow = TextEditingController(text: '0.5');
  final _preHigh = TextEditingController(text: '40');
  final _preNotch = TextEditingController(text: '50');
  final _topoWindows = TextEditingController(text: '2');
  final _smoothing = TextEditingController(text: '25');

  // ══ SINGLE-RECORDING MODE STATE ═════════════════════════════════════════
  //
  // One recording is under analysis at a time, while the files opened during
  // the session remain available as tabs in the viewer. This makes comparing
  // recordings explicit without confusing them with batch inputs.

  final List<EegRecording> _openedRecordings = [];

  /// Stage 1 input — the raw recording as loaded from disk.
  EegRecording? _raw;

  /// Stage 1 output.
  EegRecording? _preprocessed;

  /// Stage 2 output (selected source inverse projection).
  EegRecording? _source;

  /// A file loaded straight into Stage 3, bypassing Stages 1 and 2.
  ///
  /// This is tracked separately from [_raw] precisely so it does *not* show up
  /// in the Stage 1 file list — previously both went into one `_recordings`
  /// list, so loading a preprocessed file for extraction made it look like an
  /// unprocessed input queued for cleaning.
  EegRecording? _directInput;

  /// Stage 3 output.
  String? _featuresCsv;

  /// Stage 4 output directory.
  String? _plotsDir;
  List<String> _batchResultCsvs = [];

  /// Channel type assignment for the recording currently under analysis.
  ChannelTypeMap _channels = ChannelTypeMap.empty();

  ViewerSelection _selection = const ViewerSelection.empty();

  /// Resolved extraction input: explicit load > source > preprocessed > raw.
  EegRecording? get _activeRecording =>
      _directInput ?? _source ?? _preprocessed ?? _raw;

  _Stage? get _activeStage {
    if (_directInput != null) return _Stage.direct;
    if (_source != null) return _Stage.source;
    if (_preprocessed != null) return _Stage.preprocessed;
    if (_raw != null) return _Stage.raw;
    return null;
  }

  /// Every distinct recording produced so far, for the viewer's stage switcher.
  List<EegRecording> get _stageRecordings {
    final result = <EegRecording>[];
    for (final recording in [
      _directInput,
      _source,
      _preprocessed,
      _raw,
      ..._openedRecordings,
    ]) {
      if (recording != null &&
          !result.any((existing) => existing.path == recording.path)) {
        result.add(recording);
      }
    }
    return result;
  }

  // ══ BATCH MODE STATE ════════════════════════════════════════════════════

  final List<String> _batchPrepFiles = [];
  final List<String> _batchFeatFiles = [];
  final List<String> _batchPlotFiles = [];
  bool _batchFeatUsePrep = true;
  bool _batchPlotUseFeat = true;
  String? _batchPrepOutputDir;
  String? _batchFeatOutputDir;
  String? _batchPlotOutputDir;

  /// Preprocessed files actually produced by the last Stage 1 batch run.
  ///
  /// Stage 2 used to *predict* these paths by string-rewriting the Stage 1
  /// inputs, which silently went wrong whenever a file failed or the output
  /// directory changed between runs.  Recording what was really written
  /// removes that guesswork.
  final List<String> _batchPrepOutputs = [];
  final List<String> _batchFeatOutputs = [];

  bool _running = false;
  bool _loadingRecording = false;
  String _loadingMessage = '';
  String _appVersion = '';
  double _progress = 0;
  bool _stopRequested = false;

  // ── Sub-accordion state ──────────────────────────────────────────────────
  bool _step1OptsExpanded = false;
  bool _step3FeatExpanded = true;
  bool _step3OtherExpanded = false;
  bool _channelsExpanded = false;

  // ── Log panel ───────────────────────────────────────────────────────────
  bool _logVisible = false;
  bool _checkingForUpdates = false;
  final List<String> _logs = [];
  final ValueNotifier<int> _batchProgressPulse = ValueNotifier(0);
  final Map<String, String> _batchFileStatus = {};
  final List<String> _batchProgressLog = [];
  String _batchRunTitle = '';
  String _batchCurrent = '';
  int _batchDone = 0;
  int _batchTotal = 0;
  int _batchFailed = 0;
  double _batchFileProgress = 0;
  bool _batchProgressActive = false;
  bool _batchProgressFinished = false;
  bool _batchCancelRequested = false;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((info) {
          if (mounted) setState(() => _appVersion = 'v${info.version}');
        })
        .catchError((Object _) {});
    RecordingStorage.loadPreferences().then((_) {
      if (mounted) setState(() {});
    });
    _pipeline = List.of(_presets['continuous']!.modules);
    _selectedModule = _Module.loadRaw;
    _preLow.addListener(_syncConfigFromControllers);
    _preHigh.addListener(_syncConfigFromControllers);
    _preNotch.addListener(_syncConfigFromControllers);
    _preDownsample.addListener(_syncConfigFromControllers);
    _epoch.addListener(_syncConfigFromControllers);
    _epochOverlap.addListener(_syncConfigFromControllers);
    _dfaWindow.addListener(_syncConfigFromControllers);
    _prepOverlap.addListener(_syncConfigFromControllers);
    _gedaiEpoch.addListener(_syncConfigFromControllers);
    _gedaiThreshold.addListener(_syncConfigFromControllers);
    _start.addListener(_syncConfigFromControllers);
    _end.addListener(_syncConfigFromControllers);
    _bin.addListener(_syncConfigFromControllers);
    _exclude.addListener(_syncConfigFromControllers);
    _topoWindows.addListener(_syncConfigFromControllers);
    _smoothing.addListener(_syncConfigFromControllers);
    _syncConfigFromControllers();
  }

  /// Pushes text-field values into the shared config.
  ///
  /// Numeric fields keep their previous value when the text is mid-edit and
  /// unparseable, so clearing a box to retype it doesn't momentarily reset the
  /// setting to a default.
  void _syncConfigFromControllers() {
    final gedaiEpoch = double.tryParse(_gedaiEpoch.text);
    _cfg
      ..gedaiThreshold = _gedaiThreshold.text.trim().toLowerCase()
      ..lowHz = double.tryParse(_preLow.text) ?? _cfg.lowHz
      ..highHz = double.tryParse(_preHigh.text) ?? _cfg.highHz
      ..notchHz = double.tryParse(_preNotch.text) ?? _cfg.notchHz
      ..downsampleFreq =
          double.tryParse(_preDownsample.text) ?? _cfg.downsampleFreq
      ..dfaFeiWindowSeconds = double.tryParse(_dfaWindow.text) ?? 60
      ..epochSeconds = double.tryParse(_epoch.text) ?? _cfg.epochSeconds
      ..epochOverlapSeconds = double.tryParse(_epochOverlap.text) ?? 0
      ..preprocessingOverlapSeconds = double.tryParse(_prepOverlap.text) ?? 0
      ..gedaiEpochSeconds =
          gedaiEpoch != null && gedaiEpoch.isFinite && gedaiEpoch > 0
          ? gedaiEpoch
          : _cfg.gedaiEpochSeconds
      ..startSeconds = double.tryParse(_start.text) ?? _cfg.startSeconds
      ..endSeconds = double.tryParse(_end.text) ?? _cfg.endSeconds
      ..binSeconds = double.tryParse(_bin.text) ?? _cfg.binSeconds
      ..nTopoWindows = int.tryParse(_topoWindows.text) ?? _cfg.nTopoWindows
      ..smoothingWindow = int.tryParse(_smoothing.text) ?? _cfg.smoothingWindow
      ..exclusions = _exclude.text
          .split(',')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList();
    setState(() {});
  }

  bool get _usesExistingEpochs =>
      !_batchMaximized && _activeRecording?.pointsPerEpoch != null;

  String? get _gedaiEpochError {
    if (!_cfg.gedai) return null;
    final threshold = _gedaiThreshold.text.trim().toLowerCase();
    final numeric = double.tryParse(threshold);
    if (!['auto', 'auto-', 'auto+'].contains(threshold) &&
        (numeric == null || !numeric.isFinite || numeric < 0 || numeric > 12)) {
      return 'Use auto, auto-, auto+, or a numeric threshold from 0 to 12.';
    }
    if (_cfg.stimEpochs || _usesExistingEpochs) return null;
    final value = double.tryParse(_gedaiEpoch.text);
    if (value == null || !value.isFinite || value <= 0) {
      return 'GEDAI epoch size must be greater than 0 seconds.';
    }
    return null;
  }

  @override
  void dispose() {
    for (final c in [
      _start,
      _end,
      _bin,
      _epoch,
      _epochOverlap,
      _dfaWindow,
      _prepOverlap,
      _batchSubjectLimit,
      _gedaiEpoch,
      _gedaiThreshold,
      _exclude,
      _preDownsample,
      _preLow,
      _preHigh,
      _preNotch,
      _topoWindows,
      _smoothing,
    ]) {
      c.dispose();
    }
    _loader.cancelPendingLoads();
    _batchProgressPulse.dispose();
    super.dispose();
  }

  void _log(String value) {
    if (value.isEmpty || !mounted) return;
    setState(() {
      _logs.add(value);
      if (_logs.length > 400) _logs.removeAt(0);
    });
    if (_batchProgressActive) {
      _batchProgressLog.add(value);
      if (_batchProgressLog.length > 1000) {
        _batchProgressLog.removeRange(0, 250);
      }
      _batchProgressPulse.value++;
    }
  }

  Future<void> _openAppInstance() async {
    try {
      await openAppInstance();
      _log('Opened another independent app instance.');
    } catch (error) {
      _log('Unable to open another instance: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open another instance: $error')),
        );
      }
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checkingForUpdates) return;
    setState(() => _checkingForUpdates = true);
    _log('Checking GitHub for CCS EEG Studio updates…');
    try {
      final info = await UpdateChecker.check();
      if (!mounted) return;
      _log(
        info.hasUpdate
            ? 'Update ${info.latestVersion} is available.'
            : 'CCS EEG Studio ${info.currentVersion} is up to date.',
      );
      await showDialog<void>(
        context: context,
        builder: (_) => AppUpdateDialog(info: info),
      );
    } catch (error) {
      if (!mounted) return;
      _log('Update check failed: $error');
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cloud_off, color: _accentAmber),
              SizedBox(width: 10),
              Text('Could not check for updates'),
            ],
          ),
          content: Text(
            '$error\n\nCheck your internet connection and try again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingForUpdates = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  SINGLE-RECORDING MODE — file loading
  // ══════════════════════════════════════════════════════════════════════

  /// Opens a raw recording and keeps previously opened files available in the
  /// viewer switcher. Selecting a different input resets only derived outputs.
  Future<void> _loadRaw({_Module? destination}) async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _rawExtensions,
      recordingsOnly: true,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
    });
    try {
      _log('Loading ${_shortName(path)}…');
      final rec = await _loadRecordingWithFeedback(path);
      if (_stopRequested || !mounted) return;
      _restoreSavedEpochProtocol(rec);
      setState(() {
        for (final existing in _stageRecordings) {
          if (!_openedRecordings.any((r) => r.path == existing.path))
            _openedRecordings.add(existing);
        }
        _openedRecordings.removeWhere((item) => item.path == rec.path);
        _openedRecordings.add(rec);
        _raw = rec;
        _selectedModule = destination ?? _Module.loadRaw;
        _preprocessed = null;
        _source = null;
        _directInput = null;
        final csv =
            '${File(rec.path).parent.path}${Platform.pathSeparator}${_stem(rec.path)}.features.csv';
        _featuresCsv = File(csv).existsSync() ? csv : null;
        final figures =
            '${File(rec.path).parent.path}${Platform.pathSeparator}Figures_TopoStats';
        _plotsDir = _featuresCsv != null && Directory(figures).existsSync()
            ? figures
            : null;
        _selection = const ViewerSelection.empty();
        _channels = ChannelTypeMap.autoDetect(rec.labels);
      });
      _logChannelDetection();
      _log('✓ Loaded ${_shortName(path)}');
    } catch (e) {
      _log('✗ ERROR ${_shortName(path)}: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _restoreSavedEpochProtocol(EegRecording recording) {
    if (!recording.isEpoched) return;
    final embedded =
        recording.provenance['epoch_protocol'] ??
        (recording.provenance['preprocessing'] as Map?)?['stim_epochs_spec'];
    if (embedded is Map) {
      applyErpProtocol(_cfg, {...erpProtocolJson(_cfg), 'epoching': embedded});
      return;
    }
    for (final suffix in [
      '.ccspreparation',
      '.ccshistory',
      '.preparation.json',
      '.preprocessing.json',
    ]) {
      final file = File('${recording.path}$suffix');
      if (!file.existsSync()) continue;
      try {
        final saved = jsonDecode(file.readAsStringSync()) as Map;
        final spec =
            saved['epoch_protocol'] ??
            (saved['preprocessing'] as Map?)?['stim_epochs_spec'];
        if (spec is Map) {
          applyErpProtocol(_cfg, {...erpProtocolJson(_cfg), 'epoching': spec});
          return;
        }
      } catch (_) {
        /* Older files may have no reusable epoch settings. */
      }
    }
  }

  void _selectOpenedRecording(EegRecording recording) {
    _restoreSavedEpochProtocol(recording);
    setState(() {
      _raw = recording;
      _selectedModule = _Module.loadRaw;

      _directInput = recording;
      final csv =
          '${File(recording.path).parent.path}${Platform.pathSeparator}${_stem(recording.path)}.features.csv';
      _featuresCsv = File(csv).existsSync() ? csv : null;
      final figures =
          '${File(recording.path).parent.path}${Platform.pathSeparator}Figures_TopoStats';
      _plotsDir = _featuresCsv != null && Directory(figures).existsSync()
          ? figures
          : null;
      _selection = const ViewerSelection.empty();
      _channels = ChannelTypeMap.autoDetect(recording.labels);
    });
    _log('Active recording: ${_shortName(recording.path)}');
  }

  /// Loads a preprocessed file as the Stage 2 input, bypassing Stage 1.
  Future<void> _loadForSourceLocalisation() async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _processedExtensions,
      recordingsOnly: true,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    try {
      _log('Loading ${_shortName(path)} into Stage 2…');
      final rec = await _loadRecordingWithFeedback(path);
      setState(() {
        _preprocessed = rec;
        _source = null;
        _directInput = null;
        _featuresCsv = null;
        _channels = _channels.rebaseOnto(rec.labels);
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Stage 2 input: ${_shortName(path)}');
    } catch (e) {
      _log('✗ ERROR loading for Stage 2: $e');
    }
  }

  /// Loads a file straight into Stage 3 (feature extraction).
  ///
  /// Only one file — extracting features from many files is Batch mode's job,
  /// and mixing the two here is exactly what made the old flow confusing.
  Future<void> _loadForExtraction() async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _anyInputExtensions,
      recordingsOnly: true,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    try {
      _log('Loading ${_shortName(path)} into Stage 3…');
      final rec = await _loadRecordingWithFeedback(path);
      setState(() {
        _directInput = rec;
        _featuresCsv = null;
        _plotsDir = null;
        _channels = ChannelTypeMap.autoDetect(rec.labels);
        _selection = const ViewerSelection.empty();
      });
      _logChannelDetection();
      _log('✓ Stage 3 input: ${_shortName(path)}');
    } catch (e) {
      _log('✗ ERROR loading for Stage 3: $e');
    }
  }

  void _logChannelDetection() {
    final nonEeg = _channels.nonEegChannels;
    if (nonEeg.isEmpty) {
      _log('  All ${_channels.labels.length} channels detected as EEG.');
    } else {
      _log(
        '  ${_channels.eegCount} EEG, ${nonEeg.length} non-EEG '
        '(${nonEeg.take(8).join(', ')}${nonEeg.length > 8 ? '…' : ''})',
      );
    }
  }

  Future<EegRecording> _loadRecordingWithFeedback(String path) async {
    final wasRunning = _running;
    setState(() {
      _running = true;
      _loadingRecording = true;
      _stopRequested = false;
      _progress = 0;
      _loadingMessage = 'Opening ${_shortName(path)}…';
    });
    // Paint the busy controls before starting parsing/stream inspection.
    await Future<void>.delayed(Duration.zero);
    try {
      int? streamId;
      if (path.toLowerCase().endsWith('.xdf')) {
        final streams = await inspectXdfInWorker(path);
        if (_stopRequested || !mounted)
          throw StateError('File loading cancelled');
        if (streams.length > 1) {
          streamId = await showDialog<int>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('Choose the XDF signal stream'),
              children: [
                for (final stream in streams)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, stream.id),
                    child: Text('$stream'),
                  ),
              ],
            ),
          );
          if (streamId == null)
            throw StateError('XDF stream selection cancelled');
        } else if (streams.length == 1) {
          streamId = streams.single.id;
        }
      }
      return await _loader.load(
        path,
        xdfStreamId: streamId,
        onProgress: (p, message) {
          if (mounted)
            setState(() {
              _progress = p ?? 0;
              _loadingMessage = message;
            });
        },
      );
    } finally {
      if (mounted)
        setState(() {
          _running = wasRunning;
          _loadingRecording = false;
        });
    }
  }

  void _cancel() {
    setState(() => _stopRequested = true);
    if (_batchProgressActive) _batchCancelRequested = true;
    _loader.cancelPendingLoads();
    _service.cancel();
    _log('Stopping operation… wait for it to finish before restarting.');
  }

  void _clearPipeline() {
    if (_running) return;
    setState(() {
      _raw = null;
      _openedRecordings.clear();
      _preprocessed = null;
      _source = null;
      _directInput = null;
      _featuresCsv = null;
      _plotsDir = null;
      _channels = ChannelTypeMap.empty();
      _selection = const ViewerSelection.empty();
    });
    _log('Cleared the pipeline.');
  }

  // ══════════════════════════════════════════════════════════════════════
  //  SINGLE-RECORDING MODE — stage runners
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _runPreprocessing() async {
    final input = _activeRecording;
    if (input == null) {
      _log('Load a raw recording first.');
      return;
    }
    if (_gedaiEpochError case final error?) {
      _log(error);
      return;
    }
    if (_presetKey != 'erp' && _cfg.stimEpochs && !input.isEpoched) {
      final spec = _cfg.stimEpochSpec!;
      var count = 0;
      String? selectionError;
      try {
        count = spec.selectEvents(input.markers, selection: _selection).length;
      } catch (e) {
        selectionError = e.toString();
      }
      if (count < 2 || selectionError != null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Choose matching events'),
            content: Text(
              selectionError ??
                  '$count events match the current selection. Select marker chips or add a named group in Event-based trials before preprocessing. The previous recording may use different event codes.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back to event settings'),
              ),
            ],
          ),
        );
        return;
      }
    }
    final path = await saveRecordingDialog(
      context,
      dialogTitle: 'Save cleaned EEG file',
      fileName: erpOutputName(
        input.path,
        extension: RecordingStorage.extension,
        epoched:
            input.isEpoched ||
            (_presetKey != 'erp' && (_cfg.stimEpochs || _cfg.epochBeforeGedai)),
        cleaned: true,
      ),
      allowedExtensions: [RecordingStorage.extension],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
      _logVisible = true;
    });
    try {
      final cleaned = await _service.preprocess(
        recording: input,
        outputPath: RecordingStorage.withExtension(path),
        selection: _selection,
        outputOverlapSeconds:
            (_presetKey == 'erp' || _cfg.stimEpochs || !_cfg.epochBeforeGedai)
            ? 0
            : _cfg.preprocessingOverlapSeconds,
        outputWindowSeconds: _cfg.gedaiEpochSeconds,
        options: PreprocessingOptions.fromJson({
          ..._cfg
              .toPreprocessingOptions(nonEegChannels: _channels.nonEegChannels)
              .toJson(),
          if (_presetKey == 'erp') ...{
            'stim_epochs_spec': null,
            'epoch_before_gedai': false,
          },
        }),
        onProgress: (p, m) {
          _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() {
        _preprocessed = cleaned;
        _openedRecordings.removeWhere((r) => r.path == cleaned.path);
        _openedRecordings.add(cleaned);
        _source = null;
        _directInput = null;
        _channels = _channels.rebaseOnto(cleaned.labels);
        _selection = const ViewerSelection.empty();
      });
      if (_presetKey == 'erp')
        setState(
          () => _selectedModule = cleaned.isEpoched
              ? _Module.erpAnalysis
              : _Module.epochs,
        );
      _log(
        '${recordingWarnings(cleaned).isEmpty ? '✓ Preprocessed' : '⚠ Saved with processing warnings'}: ${cleaned.path}',
      );
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runSourceLocalisation() async {
    final input = _preprocessed ?? _raw;
    if (input == null) {
      _log('Run Stage 1 or load a preprocessed file first.');
      return;
    }
    final path = await saveRecordingDialog(
      context,
      dialogTitle: 'Save source localized EEG file',
      fileName: '${_stem(input.path)}_source.${RecordingStorage.extension}',
      allowedExtensions: [RecordingStorage.extension],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
      _logVisible = true;
    });
    try {
      final sourced = await _service.preprocess(
        recording: input,
        outputPath: RecordingStorage.withExtension(path),
        selection: _selection,
        options: _cfg.toPreprocessingOptions(
          nonEegChannels: _channels.nonEegChannels,
          sourceLocalizationOnly: true,
        ),
        onProgress: (p, m) {
          _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() {
        _source = sourced;
        _directInput = null;
        _channels = ChannelTypeMap.autoDetect(sourced.labels);
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Source localisation complete: ${sourced.path}');
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<bool> _confirmFeatureWindows(EegRecording rec) async {
    final warnings = featureWindowWarnings(_cfg, rec);
    if (warnings.isEmpty || !mounted) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Review feature window settings'),
            content: SizedBox(width: 520, child: Text(warnings.join('\n\n'))),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Change settings'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue with missing / limited values'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// Stage 3 — feature extraction for the single active recording.
  ///
  /// This now has its own Run button in the Stage 3 card, matching Stages 1
  /// and 2, instead of being reachable only from a global button at the bottom
  /// of the sidebar.
  Future<void> _runFeatureExtraction() async {
    final input = _activeRecording;
    if (input == null) {
      _log('Load a file before running extraction.');
      return;
    }
    if (!_cfg.anyFeature) {
      _log('Select at least one feature family.');
      return;
    }
    if (!await _confirmFeatureWindows(input)) return;
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save extracted EEG features',
      fileName: '${_stem(input.path)}.features.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (path == null) return;

    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
      _logVisible = true;
    });
    try {
      final options = _cfg.toExtractionOptions(
        nonEegChannels: _channels.nonEegChannels,
        // Filename exclusions filter a batch queue; they make no sense when
        // the user has explicitly chosen this one file.
        applyExclusions: false,
      );
      await _service.run(
        recordings: [input],
        outputPath: path,
        options: options,
        epochSeconds: _cfg.epochSeconds,
        epochOverlapSeconds: _cfg.epochOverlapSeconds,
        subepochExisting: _cfg.subepochExisting,
        selection: _selection,
        onProgress: (p, m) {
          _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() => _featuresCsv = path);
      _log('✓ Extraction complete: $path');

      if (_cfg.generatePdfReport) {
        await _writeReport(
          path,
          input,
          options,
          raw: identical(input, _raw) ? null : _raw,
          excludedChannels: _channels.nonEegChannels,
        );
      }
      if (_cfg.generatePlots) {
        await _runPlotting(csvPaths: [path], announce: false);
      }
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Stage 4 — plots for the active recording's feature CSV.
  Future<void> _runPlotsForActive() async {
    final csv = _featuresCsv;
    if (csv == null) {
      _log(
        'Run feature extraction first, or use Generate Plots… to pick a CSV.',
      );
      return;
    }
    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
      _logVisible = true;
    });
    try {
      await _runPlotting(csvPaths: [csv], announce: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runPlotting({
    required List<String> csvPaths,
    required bool announce,
    String? outputDir,
  }) async {
    if (announce)
      _log('Generating TopoStats plots (PlotFeaturesTopoStats parity)…');
    try {
      final dir = outputDir ?? Directory(csvPaths.first).parent.path;
      final window = double.tryParse(_topoWindows.text.trim()) ?? 2.0;
      // Sessions are grouped per recording ID (the script's rec_ID); each
      // recording gets one figure per feature.
      final results = await generateTopoStatsFigures(
        csvPaths: csvPaths,
        outputDir: dir,
        base: TopoStatsSettings(
          epochSize: _cfg.epochSeconds,
          windowSize: _cfg.smoothingWindow,
          segmentDurationMin: window > 0 ? window : 2.0,
          baselineDurationMin: window > 0 ? window : 2.0,
        ),
        writePdf: _cfg.topoStatsPdf,
        writePng: _cfg.topoStatsPng || !_cfg.topoStatsPdf,
        onProgress: (p, msg) {
          if (msg.isNotEmpty) _log('  [Plots] $msg');
          if (mounted) setState(() => _progress = p);
        },
      );
      final recs = results.map((r) => r.recId).toSet();
      setState(
        () => _plotsDir = '$dir${Platform.pathSeparator}Figures_TopoStats',
      );
      _log(
        '✓ ${results.length} TopoStats figures across ${recs.length} '
        '${recs.length == 1 ? 'recording' : 'recordings'} → $_plotsDir',
      );
    } catch (e) {
      _log('⚠ Plotting failed: $e');
    }
  }

  Future<void> _writeReport(
    String csvPath,
    EegRecording rec,
    ExtractionOptions options, {
    EegRecording? raw,
    String? outputPath,
    List<String> excludedChannels = const [],
  }) async {
    try {
      var reportPrep = _cfg.toPreprocessingOptions(
        nonEegChannels: excludedChannels,
      );
      final provenance = File(
        File('${rec.path}.ccshistory').existsSync()
            ? '${rec.path}.ccshistory'
            : '${rec.path}.preprocessing.json',
      );
      if (provenance.existsSync()) {
        final saved =
            jsonDecode(await provenance.readAsString()) as Map<String, dynamic>;
        if (saved['preprocessing'] is Map<String, dynamic>) {
          reportPrep = PreprocessingOptions.fromJson(
            saved['preprocessing'] as Map<String, dynamic>,
          );
        }
      }
      if (raw == null) {
        final metadata = File(
          File('${rec.path}.ccshistory').existsSync()
              ? '${rec.path}.ccshistory'
              : '${rec.path}.preprocessing.json',
        );
        String? source;
        if (metadata.existsSync()) {
          final saved =
              jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          if (saved['timeline_preserved'] == true)
            source = saved['source_path'] as String?;
        } else {
          for (final path in _batchPrepFiles) {
            if ('${_stem(path)}${_cfg.cleanSuffix}' == _stem(rec.path)) {
              source = path;
              break;
            }
          }
        }
        if (source != null && File(source).existsSync())
          raw = await _loader.load(source);
      }
      final reportPath =
          outputPath ??
          csvPath.replaceAll(
            RegExp(r'(\.features)?\.csv$', caseSensitive: false),
            '.analysis_report.pdf',
          );
      await writeFeatureReport(
        outputPath: reportPath,
        csvPath: csvPath,
        recording: rec,
        raw: raw,
        prep: reportPrep,
        options: options,
        epochSeconds: _cfg.epochSeconds,
        detailed: _cfg.detailedReport,
        excludedChannels: excludedChannels,
      );
      _log('✓ PDF report: $reportPath');
    } catch (e) {
      _log('⚠ PDF report skipped: $e');
    }
  }

  Future<void> _compileCsv() async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (pick == null) return;
    final out = await FilePicker.saveFile(
      dialogTitle: 'Save compiled CSV',
      fileName: 'CCS_EEG_compiled_features.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (out == null) return;
    final inputs = pick.files.map((f) => f.path).whereType<String>().toList();
    await _service.compileCsvFiles(inputs, out);
    _log('✓ Compiled CSV: $out');
  }

  void _openPlotDialog() {
    final batch = _resolveBatchPlotInputs();
    final candidates = <String>[
      if (batch.isNotEmpty)
        ...batch
      else if (_featuresCsv != null && File(_featuresCsv!).existsSync())
        _featuresCsv!,
    ];
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF060D1A),
            foregroundColor: Colors.white,
            title: const Text('Plots & Report', style: TextStyle(fontSize: 16)),
          ),
          body: TopoStatsView(
            featureFilePaths: candidates,
            runLabel: 'Run Plot Generation',
            title: 'Plots & Report',
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Build
  // ══════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopBar(),
          if (_running) _progressBar(),
          if (_selectedModule != null &&
              !_batchMaximized &&
              !_workspaceMaximized &&
              !_waveformMaximized)
            _buildPipelineSidebar(),
          Expanded(
            child: _batchMaximized
                ? _buildBatchBar(fillAvailable: true)
                : _buildModuleContent(),
          ),
          if (!_batchMaximized && !_workspaceMaximized && !_waveformMaximized)
            _buildLogPanel(),
        ],
      ),
    );
  }

  List<String> get _featureFilesForTopoStats {
    if (_batchResultCsvs.isNotEmpty)
      return preferSessionFeatureCsvs(_batchResultCsvs);
    if (_batchFeatOutputs.isNotEmpty)
      return preferSessionFeatureCsvs(_batchFeatOutputs);
    if (_featuresCsv != null && File(_featuresCsv!).existsSync())
      return [_featuresCsv!];
    if (_activeRecording != null) {
      try {
        final parentDir = File(_activeRecording!.path).parent;
        if (parentDir.existsSync()) {
          final list = parentDir
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => p.endsWith('.features.csv'))
              .toList();
          list.sort();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    return [];
  }

  // ── Top bar ─────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      height: 50,
      color: const Color(0xFF060D1A),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _accentBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _accentBlue.withValues(alpha: 0.4)),
            ),
            child: const Text(
              'CCS EEG',
              style: TextStyle(
                color: _accentBlue,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'Studio',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_appVersion.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                _appVersion,
                style: const TextStyle(color: _textMuted, fontSize: 11),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              Icons.home_outlined,
              size: 18,
              color: _selectedModule == null ? _accentBlue : _textMuted,
            ),
            tooltip: 'Workflow overview',
            onPressed: () => setState(() => _selectedModule = null),
          ),
          const SizedBox(width: 16),
          // Sidebar toggle
          IconButton(
            icon: Icon(
              _sidebarCollapsed ? Icons.menu : Icons.menu_open,
              size: 18,
              color: _textMuted,
            ),
            tooltip: _sidebarCollapsed ? 'Show pipeline' : 'Hide pipeline',
            onPressed: () =>
                setState(() => _sidebarCollapsed = !_sidebarCollapsed),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message:
                'Open an independent app window for another recording or analysis. '
                'Use a separate output folder for simultaneous analyses.',
            child: TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('New instance'),
              onPressed: _openAppInstance,
            ),
          ),
          // Pipeline preset dropdown
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _cardColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _borderColor),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _presetKey,
                dropdownColor: _cardColor,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                icon: const Icon(
                  Icons.expand_more,
                  size: 16,
                  color: _textMuted,
                ),
                items: _presets.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(e.value.icon, size: 13, color: _accentBlue),
                            const SizedBox(width: 6),
                            Text(e.value.label),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _presetKey = v;
                    _pipeline = List.of(_presets[v]!.modules);
                    _selectedModule = _Module.loadRaw;
                  });
                },
              ),
            ),
          ),
          const Spacer(),
          if (_activeRecording != null) ...[
            IconButton(
              tooltip: 'Processing history',
              icon: const Icon(Icons.history, size: 18),
              onPressed: () => showRecordingDetails(context, _activeRecording!),
            ),
            _statusChip(
              '${_channels.eegCount} EEG'
              '${_channels.nonEegCount > 0 ? ' · ${_channels.nonEegCount} aux' : ''}',
              _accentGreen,
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Clear pipeline',
              onPressed: _running ? null : _clearPipeline,
              icon: const Icon(Icons.close, size: 16, color: _textMuted),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
          const SizedBox(width: 8),
          _topBarButton(
            icon: _checkingForUpdates
                ? Icons.hourglass_top
                : Icons.system_update_alt,
            label: _checkingForUpdates ? 'Checking…' : 'Updates',
            active: _checkingForUpdates,
            onTap: _checkForUpdates,
          ),
          const SizedBox(width: 6),
          // Batch is a separate workspace, not a drawer with multiple partly
          // open states. Pressing the same clearly-labelled control closes it.
          _topBarButton(
            icon: _batchMaximized ? Icons.close : Icons.queue_play_next,
            label: _batchMaximized ? 'Close Batch' : 'Batch Workspace',
            active: _batchMaximized,
            onTap: () => setState(() {
              if (!_batchMaximized)
                _batchProfile = _presetKey == 'erp'
                    ? 'ERP'
                    : _presetKey == 'microstates'
                    ? 'Microstates'
                    : 'EEG';
              _batchMaximized = !_batchMaximized;
              _workspaceMaximized = false;
              _waveformMaximized = false;
            }),
          ),
          const SizedBox(width: 6),
          _topBarButton(
            icon: Icons.terminal,
            label: 'Log',
            active: _logVisible,
            onTap: () => setState(() => _logVisible = !_logVisible),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle, color: color, size: 13),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    ),
  );

  Widget _topBarButton({
    required IconData icon,
    required String label,
    bool active = false,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? _accentBlue.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? _accentBlue.withValues(alpha: 0.4) : _borderColor,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? _accentBlue : _textMuted),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? _accentBlue : _textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Single-recording sidebar
  // ══════════════════════════════════════════════════════════════════════

  // ── Pipeline sidebar ────────────────────────────────────────────────────

  List<_Module> get _orderedPipeline {
    final modules = List<_Module>.of(_pipeline);
    if (_cfg.erpEpochFirst &&
        modules.contains(_Module.epochs) &&
        modules.contains(_Module.preprocess)) {
      modules.remove(_Module.epochs);
      modules.insert(modules.indexOf(_Module.preprocess), _Module.epochs);
    }
    return modules;
  }

  Widget _erpOrderChoice() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: DropdownButtonFormField<bool>(
      key: ValueKey('erp-order-${_cfg.erpEpochFirst}'),
      initialValue: _cfg.erpEpochFirst,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'ERP preparation order',
        isDense: true,
      ),
      items: const [
        DropdownMenuItem(value: false, child: Text('Clean → Epoch')),
        DropdownMenuItem(value: true, child: Text('Epoch → Clean')),
      ],
      onChanged: _running
          ? null
          : (value) => setState(() => _cfg.erpEpochFirst = value ?? false),
    ),
  );

  _Module get _afterEpochs =>
      _cfg.erpEpochFirst ? _Module.preprocess : _Module.erpAnalysis;

  Widget _buildPipelineSidebar() => Material(
    color: const Color(0xFF0A1628),
    child: SizedBox(
      height: 58,
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Text('WORKFLOW MODULES', style: TextStyle(fontSize: 10)),
          const Tooltip(
            message:
                'Return to any step to edit settings. Run the step again to apply changes to a new output.',
            child: Icon(Icons.account_tree, size: 18),
          ),
          if (_pipeline.contains(_Module.epochs))
            SizedBox(width: 190, child: _erpOrderChoice()),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _orderedPipeline.length; i++) ...[
                    if (i > 0) const Icon(Icons.chevron_right, size: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        avatar: Icon(
                          _moduleIcon(_orderedPipeline[i]),
                          size: 16,
                        ),
                        label: Text(_moduleLabel(_orderedPipeline[i])),
                        selected: _selectedModule == _orderedPipeline[i],
                        onSelected: (_) => setState(
                          () => _selectedModule = _orderedPipeline[i],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildModuleContent() {
    final mod = _selectedModule;
    if (mod == null) {
      return _buildWorkflowOverview();
    }

    switch (mod) {
      case _Module.loadRaw:
      case _Module.preprocess:
      case _Module.epochs:
      case _Module.sourceSpace:
        // These modules share the EEG viewer layout
        return _buildViewerLayout(mod);
      case _Module.featureExtraction:
        return _buildFeatureExtractionLayout();
      case _Module.plotsReport:
        return _buildPlotsLayout();
      case _Module.erpAnalysis:
        return ErpAnalysisView(
          config: _cfg,
          onPrepare: () => setState(() => _selectedModule = _Module.epochs),
          onOpenRecording: () => _loadRaw(destination: _Module.erpAnalysis),
          onOpenBatch: () => setState(() {
            _batchProfile = 'ERP';
            _batchMaximized = true;
          }),
          activeRecording: _activeRecording,
          extraFiles: [
            for (final p in _batchPrepOutputs)
              if (p.contains('-epo')) p,
          ],
        );
      case _Module.topoStats:
        return TopoStatsView(
          key: const ValueKey('topostats'),
          featureFilePaths: _featureFilesForTopoStats,
          runLabel: 'Run TopoStats',
          title: 'TopoStats',
        );
      case _Module.groupStatistics:
        return GroupStatisticsWorkbench(
          initialCsvPath:
              _groupInputCsv ??
              _batchFeatOutputs
                  .where((p) => p.endsWith('Batch_features.csv'))
                  .firstOrNull,
        );
      case _Module.microstates:
        return MicrostateAnalysisView(activeRecording: _activeRecording);
    }
  }

  Widget _buildWorkflowOverview() {
    final preset = _presets[_presetKey]!;
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _accentBlue.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(preset.icon, color: _accentBlue),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preset.label,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preset.description,
                    style: const TextStyle(color: _textMuted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'Choose where to begin',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Modules share the active recording, but each can also be used independently.',
          style: TextStyle(color: _textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 900
                ? 3
                : constraints.maxWidth > 560
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (index, module) in _orderedPipeline.indexed)
                  SizedBox(
                    width: width,
                    child: InkWell(
                      onTap: () => setState(() => _selectedModule = module),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _borderColor),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: _moduleColor(
                                module,
                              ).withValues(alpha: .15),
                              foregroundColor: _moduleColor(module),
                              child: Icon(_moduleIcon(module), size: 19),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '${index + 1}.',
                                        style: const TextStyle(
                                          color: _textMuted,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        _moduleLabel(module),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _moduleSubtitle(module),
                                    style: const TextStyle(
                                      color: _textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.arrow_forward_ios,
                              size: 13,
                              color: _textMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        if (_activeRecording == null) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _accentBlue.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _accentBlue.withValues(alpha: .25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.tips_and_updates_outlined, color: _accentBlue),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Start with Open Recording for a connected workflow, or open a standalone analysis module and choose files there.',
                    style: TextStyle(color: _textMuted, fontSize: 12),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _loadRaw,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Open recording'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildViewerLayout(_Module activeModule) {
    return Row(
      children: [
        if (!_waveformMaximized)
          SizedBox(
            width: 280,
            child: Material(
              color: const Color(0xFF0A1628),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 4),
                children: [
                  if (activeModule == _Module.loadRaw) _buildLoadRawContent(),
                  if (activeModule == _Module.preprocess) _buildStage1Content(),
                  if (activeModule == _Module.epochs) _buildEpochsContent(),
                  if (activeModule == _Module.preprocess) _buildChannelsCard(),
                  if (activeModule == _Module.sourceSpace)
                    _buildStage2Content(),
                ],
              ),
            ),
          ),
        if (!_waveformMaximized)
          const VerticalDivider(width: 1, color: _borderColor),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: EegViewer(
                  recording: _activeRecording,
                  rawRecording: _raw,
                  allRecordings: _stageRecordings,
                  onSelectRecording: (rec) {
                    if (_running) return;
                    if (_openedRecordings.any(
                      (item) => item.path == rec.path,
                    )) {
                      _selectOpenedRecording(rec);
                    } else {
                      setState(() => _directInput = rec);
                    }
                  },
                  onRequestEpochs: _epochActiveRecording,
                  onEpochsGenerated: (epoched) {
                    if (_running) return;
                    setState(() => _preprocessed = epoched);
                  },
                  selection: _selection,
                  onSelectionChanged: (v) => setState(() => _selection = v),
                  filterEnabled: _cfg.filter,
                  lowHz: _cfg.lowHz,
                  highHz: _cfg.highHz,
                  notchHz: _cfg.notchHz,
                ),
              ),
              Positioned(
                right: 18,
                bottom: 12,
                child: Tooltip(
                  message: _waveformMaximized
                      ? 'Restore waveform layout'
                      : 'Maximize waveform',
                  child: FloatingActionButton.small(
                    heroTag: 'waveform-maximize',
                    backgroundColor: const Color(0xDD1E293B),
                    foregroundColor: Colors.white,
                    onPressed: () => setState(() {
                      _waveformMaximized = !_waveformMaximized;
                      if (_waveformMaximized) {
                        _workspaceMaximized = false;
                        _batchMaximized = false;
                      }
                    }),
                    child: Icon(
                      _waveformMaximized
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureExtractionLayout() {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: Material(
            color: const Color(0xFF0A1628),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 4),
              children: [
                _buildStage3Content(),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    onPressed: _compileCsv,
                    icon: const Icon(
                      Icons.table_chart,
                      size: 14,
                      color: _accentPink,
                    ),
                    label: const Text(
                      'Compile CSVs…',
                      style: TextStyle(color: _accentPink, fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _accentPink),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, color: _borderColor),
        Expanded(
          child: _activeRecording != null
              ? EegViewer(
                  recording: _activeRecording,
                  rawRecording: _raw,
                  allRecordings: _stageRecordings,
                  onSelectRecording: (rec) {
                    if (_running) return;
                    if (_openedRecordings.any(
                      (item) => item.path == rec.path,
                    )) {
                      _selectOpenedRecording(rec);
                    } else {
                      setState(() => _directInput = rec);
                    }
                  },
                  onRequestEpochs: _epochActiveRecording,
                  onEpochsGenerated: (epoched) {
                    if (_running) return;
                    setState(() => _preprocessed = epoched);
                  },
                  selection: _selection,
                  onSelectionChanged: (v) => setState(() => _selection = v),
                  filterEnabled: _cfg.filter,
                  lowHz: _cfg.lowHz,
                  highHz: _cfg.highHz,
                  notchHz: _cfg.notchHz,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.equalizer,
                        size: 48,
                        color: _textMuted.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Open EEG: EDF, XDF, BrainVision, SET, FIF, MAT or CCSEEG',
                        style: TextStyle(color: _textMuted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _openBatchResultsFolder() async {
    final dir = _plotsDir;
    if (dir == null || !Directory(dir).existsSync()) return;
    try {
      final executable = Platform.isMacOS
          ? 'open'
          : Platform.isWindows
          ? 'explorer'
          : 'xdg-open';
      await Process.run(executable, [dir]);
    } catch (e) {
      _log('Could not open results folder: $e');
    }
  }

  void _viewBatchResults() {
    setState(() {
      _batchMaximized = false;
      _workspaceMaximized = false;
      _waveformMaximized = false;
      _sidebarCollapsed = false;
      _selectedModule = _Module.plotsReport;
      _logVisible = false;
    });
  }

  Widget _buildPlotsLayout() {
    // Interactive figure identical to PlotFeaturesTopoStats_20260801.py
    // (line plots + e-TFCE topomaps), with PNG/PDF/CSV export.
    return TopoStatsView(
      key: const ValueKey('plots-report'),
      featureFilePaths: _featureFilesForTopoStats,
      initialSettings: TopoStatsSettings(
        epochSize: _cfg.epochSeconds,
        windowSize: _cfg.smoothingWindow,
        segmentDurationMin: double.tryParse(_topoWindows.text.trim()) ?? 2.0,
        baselineDurationMin: double.tryParse(_topoWindows.text.trim()) ?? 2.0,
      ),
      runLabel: 'Run Plot Generation',
      title: 'Plots & Report',
    );
  }

  // ── Stage 1 ─────────────────────────────────────────────────────────────

  Widget _buildEpochsContent() {
    final recording = _activeRecording;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Create trials for ERP averaging',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _cfg.erpEpochFirst
                ? '1. Open continuous EEG.\n2. Define events, named groups and trial windows.\n3. Save trials, then clean them in Preprocess.\n4. Average the saved groups in ERP Analysis.'
                : '1. Open raw or preprocessed continuous EEG.\n2. Select events and name condition groups.\n3. Set the trial/baseline window and save.\n4. Average the saved condition groups in ERP Analysis.',
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _running
                ? null
                : () => _loadRaw(destination: _Module.epochs),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open recording / preprocessed EEG…'),
          ),
          if (recording != null) ...[
            _recordingChip(recording),
            const SizedBox(height: 12),
            _infoBox(
              recording.isEpoched
                  ? '${recording.epochCount} saved trials ready. ${_cfg.erpEpochFirst ? 'Clean these saved trials next, or skip cleaning if already preprocessed.' : 'Reuse them directly for averaging; no new epoching is needed.'}'
                  : 'Epoching preserves existing cleaning and annotations. Filtering, ICA, ASR and GEDAI do not run in this step.',
              _accentBlue,
            ),
            FilledButton.icon(
              onPressed: _running ? null : _epochActiveRecording,
              icon: Icon(
                recording.isEpoched ? Icons.arrow_forward : Icons.content_cut,
              ),
              label: Text(
                recording.isEpoched
                    ? (_cfg.erpEpochFirst
                          ? 'Next: Clean saved trials'
                          : 'Next: Average & analyse')
                    : 'Define events & save epochs…',
              ),
            ),
            if (recording.isEpoched && _cfg.erpEpochFirst)
              TextButton(
                onPressed: _running
                    ? null
                    : () =>
                          setState(() => _selectedModule = _Module.erpAnalysis),
                child: const Text('Already cleaned? Average & analyse'),
              ),
          ] else
            _infoBox(
              'Open a recording to begin. Settings and protocol files are not EEG recordings.',
              _accentBlue,
            ),
        ],
      ),
    );
  }

  Future<void> _epochActiveRecording() async {
    final input = _activeRecording;
    if (input == null || _running) return;
    if (input.isEpoched) {
      setState(() => _selectedModule = _afterEpochs);
      return;
    }
    _cfg.stimEpochs = true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Define ERP trials'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Name each condition and choose its event codes. Set the time window below; existing cleaning is preserved.',
                ),
                ProtocolTools(config: _cfg, onChanged: () => setState(() {})),

                StimEpochPanel(
                  config: _cfg,
                  compact: true,
                  showEnableControl: false,
                  markers: input.markers,
                  onChanged: () => setState(() {}),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save event epochs…'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      final spec = _cfg.stimEpochSpec;
      if (spec == null)
        throw StateError(
          'Enable event-based trials and select locking events.',
        );
      // Use the same selector as preprocessing, including regex and crop rules.
      final events = spec.selectEvents(input.markers);
      if (events.isEmpty) throw StateError('No events match this protocol.');
      final pickedPath = await saveRecordingDialog(
        context,
        dialogTitle: 'Save reusable event epochs',
        fileName: erpOutputName(
          input.path,
          extension: RecordingStorage.extension,
          epoched: true,
          cleaned:
              input.completedStages.contains('preprocessing') ||
              input.path.contains('_clean'),
        ),
      );
      if (pickedPath == null) return;
      final path = RecordingStorage.withExtension(pickedPath);
      setState(() {
        _running = true;
        _stopRequested = false;
        _progress = 0;
      });
      _log('Preparing event epochs…');
      await Future<void>.delayed(Duration.zero);
      final full = await _loader.loadFull(input);
      final selected = full.markers
          .where(
            (m) => events.any((e) => (e.$1 - m.startSeconds).abs() < .000001),
          )
          .toList();
      final epochs = await generateEpochsInWorker(
        recording: full,
        selectedMarkers: selected,
        options: EpochOptions(
          targetEvents: const [],
          markerGroups: spec.markerGroups,
          tmin: spec.tmin,
          tmax: spec.tmax,
          applyBaseline: spec.baseline,
          baselineMin: spec.baselineStart,
          baselineMax: spec.baselineEnd,
        ),
      );
      if (_stopRequested || !mounted) return;
      _log('Saving reusable event epochs…');
      await RecordingTransform.save(
        epochs,
        path,
        sourcePath: input.path,
        operations: {'epoch_protocol': spec.toJson()},
      );
      final saved = await _loadRecordingWithFeedback(path);
      if (!mounted) return;
      setState(() {
        _openedRecordings.add(saved);
        _directInput = saved;
        _selectedModule = _afterEpochs;
      });
      _log(
        '✓ Saved ${saved.epochCount} event trials: $path. ${_cfg.erpEpochFirst ? 'Clean these trials in Preprocess, then average.' : 'Choose condition groups, then average and analyse.'}',
      );
    } catch (e) {
      _log('✗ Epoching: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _prepareRecording() async {
    final recording =
        _selectedModule == _Module.loadRaw ||
            _selectedModule == _Module.preprocess
        ? _raw
        : _activeRecording;
    if (recording == null) return;
    final prepared = await showDialog<EegRecording>(
      context: context,
      builder: (_) => RecordingPreparationDialog(recording: recording),
    );
    if (prepared == null || !mounted) return;
    setState(() {
      _openedRecordings.add(prepared);
    });
    _selectOpenedRecording(prepared);
  }

  Widget _buildLoadRawContent() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_raw != null)
            _loadButton(
              label: 'Crop / subepoch and save…',
              color: _accentBlue,
              onPressed: _running ? null : _prepareRecording,
            ),

          _loadButton(
            label: _openedRecordings.isEmpty
                ? 'Open Recording…'
                : 'Open Another Recording…',
            color: _accentBlue,
            onPressed: _running ? null : _loadRaw,
          ),
          if (_openedRecordings.isNotEmpty) ...[
            const SizedBox(height: 12),
            _subLabel('OPEN RECORDINGS'),
            const SizedBox(height: 4),
            for (final recording in _openedRecordings)
              InkWell(
                onTap: _running
                    ? null
                    : () => _selectOpenedRecording(recording),
                borderRadius: BorderRadius.circular(8),
                child: _recordingChip(
                  recording,
                  active: recording.path == _raw?.path,
                ),
              ),
            const SizedBox(height: 10),
            _infoBox(
              'Open recordings remain available in the waveform header. '
              'Select a file here or there to switch the active input.',
              _accentBlue,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStage1Content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_raw != null)
            _loadButton(
              label: 'Crop / subepoch and save…',
              color: _accentBlue,
              onPressed: _running ? null : _prepareRecording,
            ),

          if (_raw != null)
            _recordingChip(_activeRecording!, active: true)
          else
            _infoBox(
              'Open a raw or preprocessed recording first.',
              _accentPurple,
            ),
          const SizedBox(height: 6),
          _subAccordionHeader(
            'Preprocessing Options',
            _step1OptsExpanded,
            () => setState(() => _step1OptsExpanded = !_step1OptsExpanded),
          ),
          if (_presetKey == 'erp') ...[
            _infoBox(
              _activeRecording?.isEpoched == true
                  ? '${_activeRecording!.epochCount} saved trials · boundaries retained'
                  : _cfg.erpEpochFirst
                  ? 'Epoch → Clean · create trials first'
                  : 'Clean → Epoch · cleaning is optional',
              _accentBlue,
            ),
            TextButton.icon(
              onPressed: _running
                  ? null
                  : () => setState(
                      () =>
                          _selectedModule = _activeRecording?.isEpoched == true
                          ? _Module.erpAnalysis
                          : _Module.epochs,
                    ),
              icon: const Icon(Icons.arrow_forward),
              label: Text(
                _activeRecording?.isEpoched == true
                    ? 'Next: ERP Analysis (skip cleaning)'
                    : 'Next: Epochs (skip cleaning)',
              ),
            ),
          ],
          if (_step1OptsExpanded) _buildPreprocessingOptions(),
          const SizedBox(height: 8),
          if (_presetKey != 'erp' &&
              _cfg.stimEpochs &&
              _activeRecording != null &&
              !_activeRecording!.isEpoched) ...[
            _infoBox(
              'Already cleaned input? Save event trials without running the cleaners again. Additional artifact cleaning can change the ERP.',
              _accentBlue,
            ),
            _stageRunButton(
              label: 'Epoch only (keep existing cleaning)',
              icon: Icons.cut,
              color: _accentBlue,
              enabled: !_running,
              onPressed: _epochActiveRecording,
              tooltip:
                  'Cut and save the shared event groups and trial window. Apply the selected baseline; skip filtering, ICA, ASR and GEDAI.',
            ),
            const SizedBox(height: 8),
          ],
          _stageRunButton(
            label:
                _presetKey != 'erp' &&
                    _cfg.stimEpochs &&
                    !(_activeRecording?.isEpoched ?? false)
                ? 'Clean + epoch (additional cleaning)'
                : 'Run Preprocessing',
            icon: Icons.cleaning_services,
            color: _accentPurple,
            enabled: !_running && _raw != null,
            onPressed: _runPreprocessing,
          ),
        ],
      ),
    );
  }

  // ── Channels card ───────────────────────────────────────────────────────

  /// Per-channel EEG / non-EEG assignment.
  ///
  /// Channel types are auto-detected on load, but detection can only go on
  /// naming conventions and those vary by lab and amplifier.  Anything the user
  /// changes here is what actually reaches the engine, for both preprocessing
  /// (bad-channel detection, interpolation) and extraction (average reference).
  Widget _buildChannelsCard() {
    final labels = _channels.labels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: const Color(0xFF0A1628),
          child: InkWell(
            onTap: () => setState(() => _channelsExpanded = !_channelsExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
              child: Row(
                children: [
                  const SizedBox(width: 29),
                  const Icon(Icons.tune, size: 13, color: _accentPink),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'CHANNEL TYPES',
                      style: TextStyle(
                        color: _accentPink,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  if (labels.isNotEmpty)
                    Text(
                      '${_channels.eegCount}/${labels.length} EEG',
                      style: const TextStyle(color: _textMuted, fontSize: 10),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    _channelsExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: _textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_channelsExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: labels.isEmpty
                ? const Text(
                    'Load a recording to detect channel types.',
                    style: TextStyle(color: _textMuted, fontSize: 11),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _channels.hasOverrides
                                  ? 'Auto-detected, with your overrides'
                                  : 'Auto-detected from channel names',
                              style: const TextStyle(
                                color: _textMuted,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                          if (_channels.hasOverrides)
                            TextButton(
                              onPressed: _running
                                  ? null
                                  : () => setState(
                                      () => _channels = _channels.resetToAuto(),
                                    ),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(46, 24),
                                foregroundColor: _accentAmber,
                              ),
                              child: const Text(
                                'Reset',
                                style: TextStyle(fontSize: 10.5),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: _bgColor,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _borderColor),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: labels.length,
                          itemBuilder: (_, i) {
                            final label = labels[i];
                            final kind = _channels.kindOf(label);
                            final isEeg = kind.isEeg;
                            return InkWell(
                              onTap: _running
                                  ? null
                                  : () => setState(
                                      () => _channels = _channels.toggleEeg(
                                        label,
                                      ),
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isEeg
                                          ? Icons.check_box
                                          : Icons.check_box_outline_blank,
                                      size: 14,
                                      color: isEeg ? _accentGreen : _textMuted,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        label,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: isEeg
                                              ? Colors.white
                                              : _textMuted,
                                        ),
                                      ),
                                    ),
                                    _badge(
                                      kind.label,
                                      isEeg ? _accentGreen : _accentAmber,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Unticked channels are excluded from bad-channel '
                        'detection, interpolation and the average reference.',
                        style: TextStyle(
                          color: _textMuted,
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
          ),
        const Divider(color: _borderColor, height: 1, thickness: 1),
      ],
    );
  }

  // ── Stage 2 ─────────────────────────────────────────────────────────────

  Widget _buildStage2Content() {
    final effectiveInput = _preprocessed ?? _raw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Source-space parameters',
              icon: const Icon(Icons.settings, size: 18),
              onPressed: _running
                  ? null
                  : () async {
                      await showProcessingSettings(
                        context,
                        _cfg,
                        'Source Space',
                      );
                      if (mounted) setState(() {});
                    },
            ),
          ),

          effectiveInput != null
              ? _pipelineBadge(
                  icon: Icons.arrow_right,
                  label: _preprocessed != null
                      ? 'Input: ${_shortName(effectiveInput.path)}'
                      : 'Input (unprocessed): ${_shortName(effectiveInput.path)}',
                  color: _preprocessed != null ? _accentGreen : _accentAmber,
                )
              : _pipelineBadge(
                  icon: Icons.warning_amber,
                  label: 'No input — run Stage 1 or load a preprocessed file',
                  color: _textMuted,
                ),
          const SizedBox(height: 7),
          _loadButton(
            label: 'Load Preprocessed File…',
            color: _accentBlue,
            onPressed: _running ? null : _loadForSourceLocalisation,
          ),
          const SizedBox(height: 8),
          _infoBox(
            'Inverse: ${_cfg.sourceMethod.toUpperCase()}. '
            '${_cfg.sourceModelPath.isEmpty ? 'Bundled fsaverage / 68 Desikan–Killiany regions' : 'Custom forward / atlas: ${_shortName(_cfg.sourceModelPath)}'}. '
            'Fixed source orientations; identity sensor noise covariance.',
            _accentBlue,
          ),
          const SizedBox(height: 8),
          _stageRunButton(
            label: 'Run Source Localisation',
            icon: Icons.psychology,
            color: _accentBlue,
            enabled: !_running && effectiveInput != null,
            onPressed: _runSourceLocalisation,
          ),
        ],
      ),
    );
  }

  // ── Stage 3 ─────────────────────────────────────────────────────────────

  Widget _buildStage3Content() {
    final resolved = _activeRecording;
    final stage = _activeStage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_activeRecording != null)
            _loadButton(
              label: 'Crop / subepoch and save…',
              color: _accentBlue,
              onPressed: _running ? null : _prepareRecording,
            ),

          resolved != null
              ? _pipelineBadge(
                  icon: Icons.play_circle,
                  label: switch (stage!) {
                    _Stage.source => 'Source: ${_shortName(resolved.path)}',
                    _Stage.preprocessed =>
                      'Preprocessed: ${_shortName(resolved.path)}',
                    _Stage.direct =>
                      'Direct load: ${_shortName(resolved.path)}',
                    _Stage.raw =>
                      'Raw (not preprocessed): '
                          '${_shortName(resolved.path)}',
                  },
                  color: switch (stage) {
                    _Stage.source => _accentBlue,
                    _Stage.preprocessed => _accentGreen,
                    _ => _accentAmber,
                  },
                )
              : _pipelineBadge(
                  icon: Icons.warning_amber,
                  label: 'No file — use Stage 1 / 2 or load one directly',
                  color: _textMuted,
                ),
          const SizedBox(height: 6),
          _loadButton(
            label: 'Load File Directly…',
            color: _textMuted,
            onPressed: _running ? null : _loadForExtraction,
          ),
          if (_directInput != null) ...[
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _running
                  ? null
                  : () => setState(() {
                      _directInput = null;
                      final back = _source ?? _preprocessed ?? _raw;
                      if (back != null) {
                        _channels = ChannelTypeMap.autoDetect(back.labels);
                      }
                    }),
              icon: const Icon(Icons.undo, size: 13),
              label: const Text(
                'Back to pipeline output',
                style: TextStyle(fontSize: 11),
              ),
              style: TextButton.styleFrom(
                foregroundColor: _accentAmber,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 26),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildEpochingOptions(),
          const SizedBox(height: 10),
          _subAccordionHeader(
            'Feature Families',
            _step3FeatExpanded,
            () => setState(() => _step3FeatExpanded = !_step3FeatExpanded),
          ),
          if (_step3FeatExpanded) _buildFeatureFamilies(),
          const SizedBox(height: 4),
          _subAccordionHeader(
            'Other Options',
            _step3OtherExpanded,
            () => setState(() => _step3OtherExpanded = !_step3OtherExpanded),
          ),
          if (_step3OtherExpanded) ...[
            const SizedBox(height: 4),
            _check(
              'Remove non-EEG channels (reference in settings)',
              _cfg.removeNonEeg,
              (v) => _cfg.removeNonEeg = v,
            ),
            _check(
              'Write PDF report',
              _cfg.generatePdfReport,
              (v) => _cfg.generatePdfReport = v,
            ),
            _check(
              'Generate plots after extraction',
              _cfg.generatePlots,
              (v) => _cfg.generatePlots = v,
            ),
          ],
          const SizedBox(height: 10),
          _stageRunButton(
            label: 'Run Feature Extraction',
            icon: Icons.analytics,
            color: _accentGreen,
            enabled: !_running && resolved != null && _cfg.anyFeature,
            onPressed: _runFeatureExtraction,
            tooltip: resolved == null
                ? 'Load a file in Stage 1, 2 or 3 first'
                : (!_cfg.anyFeature
                      ? 'Select at least one feature family'
                      : null),
          ),
        ],
      ),
    );
  }

  // ── Stage 4 ─────────────────────────────────────────────────────────────

  // ignore: unused_element
  Widget _buildStage4Content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _featuresCsv != null
              ? _pipelineBadge(
                  icon: Icons.table_chart,
                  label: 'CSV: ${_shortName(_featuresCsv!)}',
                  color: _accentGreen,
                )
              : _pipelineBadge(
                  icon: Icons.warning_amber,
                  label: 'No feature CSV yet — run Stage 3',
                  color: _textMuted,
                ),
          const SizedBox(height: 8),
          _buildPlotOptions(),
          const SizedBox(height: 8),
          _stageRunButton(
            label: 'Run Plot Generation',
            icon: Icons.stacked_line_chart,
            color: _accentAmber,
            enabled: !_running && _featuresCsv != null,
            onPressed: _runPlotsForActive,
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _running ? null : _openPlotDialog,
              icon: const Icon(Icons.image_search, size: 14),
              label: const Text(
                'Browse / Plot Other CSVs…',
                style: TextStyle(fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accentAmber,
                side: BorderSide(color: _accentAmber.withValues(alpha: 0.5)),
                padding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBar() => ProcessingProgress(
    progress: _progress,
    loading: _loadingRecording,
    stopping: _stopRequested,
    message: _loadingRecording
        ? _loadingMessage
        : (_logs.isEmpty ? 'Preparing…' : _logs.last),
    onCancel: _cancel,
  );

  // ══════════════════════════════════════════════════════════════════════
  //  Shared option panels — used identically by both modes
  // ══════════════════════════════════════════════════════════════════════

  Widget _preparationSection(
    String title,
    String summary,
    List<Widget> children, {
    bool open = false,
  }) => ExpansionTile(
    key: ValueKey('prep-$title'),
    initiallyExpanded: open,
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 8),
    title: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      summary,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: _textMuted),
    ),
    children: children,
  );

  Widget _compactCleaner(
    String label,
    String value,
    List<(String, String)> choices,
    void Function(String) update,
    String help, {
    String? section,
  }) => Row(
    children: [
      Expanded(
        child: Tooltip(
          message: help,
          child: DropdownButtonFormField<String>(
            key: ValueKey('$label-$value'),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label, isDense: true),
            items: [
              for (final choice in choices)
                DropdownMenuItem(
                  value: choice.$1,
                  child: Text(choice.$2, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _running ? null : (v) => setState(() => update(v!)),
          ),
        ),
      ),
      IconButton(
        tooltip: help,
        icon: const Icon(Icons.help_outline, size: 16),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(label),
            content: Text(help),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
      if (section != null)
        IconButton(
          tooltip: '$label parameters',
          icon: const Icon(Icons.tune, size: 17),
          onPressed: _running
              ? null
              : () async {
                  await showProcessingSettings(
                    context,
                    _cfg,
                    'Preprocessing',
                    section: section,
                  );
                  if (mounted) setState(() {});
                },
        ),
    ],
  );

  Widget _buildPreprocessingOptions() {
    final steps = <String>[
      if (_cfg.icaMethod != 'none') 'ICA / ICLabel',
      if (_cfg.muscleMethod != 'none') 'Muscle',
      if (_cfg.asrMode != 'off' && !_usesExistingEpochs) 'Output ASR',
      if (_cfg.gedai) 'GEDAI',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _preparationSection(
          'Signal preparation',
          '${_cfg.filter ? '${_cfg.lowHz}–${_cfg.highHz} Hz' : 'Filter off'} · ${_cfg.referenceMode == 'average' ? 'Average reference' : 'Reference: ${_cfg.referenceMode}'}',
          [
            DropdownButtonFormField<String>(
              key: ValueKey('compact-ref-${_cfg.referenceMode}'),
              initialValue: _cfg.referenceMode,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Output reference',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('Keep existing')),
                DropdownMenuItem(
                  value: 'average',
                  child: Text('Common average'),
                ),
                DropdownMenuItem(
                  value: 'channels',
                  child: Text('Selected electrodes'),
                ),
              ],
              onChanged: _running
                  ? null
                  : (v) => setState(() => _cfg.referenceMode = v!),
            ),
            if (_cfg.referenceMode == 'channels')
              TextFormField(
                initialValue: _cfg.referenceChannels.join(', '),
                decoration: const InputDecoration(
                  labelText: 'Reference electrodes',
                ),
                onChanged: (v) => _cfg.referenceChannels = v
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList(),
              ),
            _check('Resample', _cfg.downsample, (v) => _cfg.downsample = v),
            if (_cfg.downsample)
              _field(_preDownsample, 'Target rate', suffix: 'Hz'),
            _check('Bandpass + notch', _cfg.filter, (v) => _cfg.filter = v),
            if (_cfg.filter)
              Row(
                children: [
                  Expanded(child: _field(_preLow, 'High-pass')),
                  const SizedBox(width: 6),
                  Expanded(child: _field(_preHigh, 'Low-pass')),
                  const SizedBox(width: 6),
                  Expanded(child: _field(_preNotch, 'Notch')),
                ],
              ),
            _check(
              'Detect bad channels',
              _cfg.badChannels,
              (v) => _cfg.badChannels = v,
            ),
            _check(
              'Interpolate bad channels',
              _cfg.interpolate,
              (v) => _cfg.interpolate = v,
            ),
          ],
          open: true,
        ),
        _preparationSection(
          'Artifact cleaning',
          steps.isEmpty ? 'Off' : steps.join(' → '),
          [
            _compactCleaner(
              'ICA / ICLabel',
              _cfg.icaMethod,
              const [
                ('none', 'Off'),
                ('runica', 'Infomax'),
                ('picard', 'Picard'),
              ],
              (v) => _cfg.icaMethod = v,
              'Removes classified components. Eye/ECG ICA runs first, followed by general artifact ICA. Saved trial boundaries are retained.',
              section: 'ICA',
            ),
            if (_cfg.icaMethod != 'none')
              Tooltip(
                message:
                    'ASR rejects bad samples from the temporary ICA fit copy only. The fitted ICA projection is then applied to the original samples; this is separate from output ASR below.',
                child: _check(
                  'ASR on ICA fit copy only',
                  _cfg.icaFitAsr,
                  (v) => _cfg.icaFitAsr = v,
                ),
              ),
            _compactCleaner(
              'ASR on output',
              _cfg.asrMode,
              const [
                ('off', 'Off'),
                ('correct', 'Reconstruct bursts'),
                ('reject', 'Remove burst samples'),
              ],
              (v) {
                if (_usesExistingEpochs && v != 'off') {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Output ASR requires continuous EEG. ICA fit-copy ASR supports saved trials.',
                      ),
                    ),
                  );
                } else {
                  _cfg.asrMode = v;
                }
              },
              'Separate output cleaning after ICA. Requires continuous EEG. Reconstruct keeps the time axis; Remove changes it. It is not the ASR used on ICA fitting data.',
            ),
            if (_usesExistingEpochs)
              const Text(
                'Output ASR: continuous input required',
                style: TextStyle(fontSize: 11, color: _textMuted),
              ),
            _check('GEDAI', _cfg.gedai, (v) => _cfg.gedai = v),
            if (_cfg.gedai) _field(_gedaiThreshold, 'GEDAI strength'),
            if (_cfg.gedai && _cfg.icaMethod != 'none')
              const Tooltip(
                message:
                    'ICA and GEDAI both remove artifacts. Using both can be redundant and may remove neural activity; inspect the output.',
                child: Text(
                  'ICA + GEDAI selected · review combined cleaning',
                  style: TextStyle(fontSize: 11, color: _accentAmber),
                ),
              ),
            if (steps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Order: ${steps.join(' → ')}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
          open: true,
        ),
        _preparationSection(
          'Advanced settings & protocols',
          'Reuse settings or configure additional parameters',
          [_buildDetailedPreprocessingOptions()],
        ),
      ],
    );
  }

  Widget _buildDetailedPreprocessingOptions() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ProtocolTools(config: _cfg, onChanged: () => setState(() {})),
      if (!_usesExistingEpochs && _presetKey != 'erp')
        DropdownButtonFormField<String>(
          initialValue: _cfg.stimEpochs
              ? 'events'
              : _cfg.epochBeforeGedai
              ? 'fixed'
              : 'continuous',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Saved data structure'),
          items: const [
            DropdownMenuItem(
              value: 'continuous',
              child: Text('Continuous recording'),
            ),
            DropdownMenuItem(
              value: 'events',
              child: Text('Event-based trials (ERP)'),
            ),
            DropdownMenuItem(
              value: 'fixed',
              child: Text('Fixed-length windows'),
            ),
          ],
          onChanged: _running
              ? null
              : (v) => setState(() {
                  _cfg.stimEpochs = v == 'events';
                  _cfg.epochBeforeGedai = v == 'fixed';
                }),
        ),
      if (!_usesExistingEpochs && _presetKey != 'erp')
        StimEpochPanel(
          showEnableControl: false,
          config: _cfg,
          markers: _raw?.markers ?? const [],
          enabled: !_running,
          onChanged: () => setState(() {}),
        ),
      if (!_usesExistingEpochs &&
          _presetKey != 'erp' &&
          !_cfg.stimEpochs &&
          _cfg.epochBeforeGedai) ...[
        _field(
          _gedaiEpoch,
          'Fixed window length',
          suffix: 's',
          helper:
              'Length of each saved fixed window. Event-based trials use their own event window.',
          error: _gedaiEpochError,
        ),
        _field(_prepOverlap, 'Fixed window overlap', suffix: 's'),
      ],
      TextButton.icon(
        icon: const Icon(Icons.tune, size: 17),
        label: const Text('Additional processing parameters'),
        onPressed: _running
            ? null
            : () async {
                await showProcessingSettings(context, _cfg, 'Preprocessing');
                if (mounted) setState(() {});
              },
      ),
    ],
  );

  Widget _buildEpochingOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subLabel('EPOCH & DURATION'),
        const SizedBox(height: 6),
        _check(
          'Detailed PDF (all channels and feature tables)',
          _cfg.detailedReport,
          (v) => _cfg.detailedReport = v,
        ),
        _field(_epoch, 'Epoch length (s)', suffix: 's'),
        _field(_epochOverlap, 'Epoch overlap (s)', suffix: 's'),
        _check(
          'Subepoch existing trials (keep parent boundaries)',
          _cfg.subepochExisting,
          (v) => _cfg.subepochExisting = v,
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<DurationMode>(
          value: _cfg.mode,
          dropdownColor: _cardColor,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(labelText: 'Duration mode'),
          items: DurationMode.values
              .map(
                (m) =>
                    DropdownMenuItem(value: m, child: Text(_durationLabel(m))),
              )
              .toList(),
          onChanged: _running ? null : (v) => setState(() => _cfg.mode = v!),
        ),
        if (_cfg.mode == DurationMode.interval) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _field(_start, 'Start s')),
              const SizedBox(width: 8),
              Expanded(child: _field(_end, 'End s')),
            ],
          ),
        ],
        if (_cfg.mode == DurationMode.bins) ...[
          const SizedBox(height: 6),
          _field(_bin, 'Bin size (s)', suffix: 's'),
        ],
      ],
    );
  }

  /// The complete feature family list.
  ///
  /// Both modes render this same widget, which is what guarantees Batch mode
  /// can no longer silently omit the connectivity families the way it did when
  /// it kept its own inline copy of a five-checkbox subset.
  Widget _buildFeatureFamilies({EdgeInsets? padding}) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Feature extraction parameters',
              icon: const Icon(Icons.settings, size: 18),
              onPressed: _running
                  ? null
                  : () async {
                      await showProcessingSettings(
                        context,
                        _cfg,
                        'Feature Extraction',
                      );
                      if (mounted) setState(() {});
                    },
            ),
          ),

          _subLabel('SPECTRAL'),
          _check('PSD band power', _cfg.psd, (v) => _cfg.psd = v),
          _check('FOOOF / specparam', _cfg.fooof, (v) => _cfg.fooof = v),
          _check('IRASA', _cfg.irasa, (v) => _cfg.irasa = v),
          const SizedBox(height: 6),
          _subLabel('NONLINEAR'),
          _check(
            'Nonlinear dynamics',
            _cfg.nonlinear,
            (v) => _cfg.nonlinear = v,
          ),
          _check('Autocorrelation window (ACW)', _cfg.acw, (v) => _cfg.acw = v),
          _check(
            'DFA (multi-band) / fE:I',
            _cfg.dfaFei,
            (v) => _cfg.dfaFei = v,
          ),
          if (_cfg.dfaFei)
            _check(
              'Short-epoch verification (exploratory)',
              _cfg.dfaFeiShortEpoch,
              (v) {
                _cfg.dfaFeiShortEpoch = v;
                if (v) _dfaWindow.text = '0';
              },
            ),
          if (_cfg.dfaFeiShortEpoch)
            const Text(
              'Short-scale estimates use _short columns; they do not establish long-range correlations.',
            ),
          if (_cfg.dfaFei)
            _field(
              _dfaWindow,
              'DFA / fE:I context (s; 0 = epoch only)',
              suffix: 's',
            ),
          const SizedBox(height: 6),
          _subLabel('MULTIVARIATE CONNECTIVITY'),
          _check('MIC', _cfg.mic, (v) => _cfg.mic = v),
          _check('MIM', _cfg.mim, (v) => _cfg.mim = v),
          _check('Granger Causality', _cfg.gc, (v) => _cfg.gc = v),
          _check('GC-TR', _cfg.gcTr, (v) => _cfg.gcTr = v),
          _check(
            'GC − GC-TR contrast',
            _cfg.gcContrast,
            (v) => _cfg.gcContrast = v,
          ),
          const SizedBox(height: 6),
          _subLabel('BIVARIATE CONNECTIVITY'),
          _check('Gaussian-copula MI (GCMI)', _cfg.gcmi, (v) => _cfg.gcmi = v),
          _check(
            'Transfer entropy (lagged time samples)',
            _cfg.transferEntropy,
            (v) => _cfg.transferEntropy = v,
          ),
          _check(
            'Pair matrices / graph measures for selected spectral connectivity',
            _cfg.spectralGraph,
            (v) => _cfg.spectralGraph = v,
          ),
          if (_cfg.gcmi || _cfg.transferEntropy || _cfg.spectralGraph) ...[
            const Text(
              'GCMI and TE use broadband signals. TE estimates source-past → target-present information within each epoch, conditioned on target history. Overlapping windows are supported.',
            ),
            DropdownButtonFormField<String>(
              initialValue: _cfg.connectivityOutput,
              decoration: const InputDecoration(
                labelText: 'Pair / graph output selection',
              ),
              items: const [
                DropdownMenuItem(value: 'edges', child: Text('Raw pairs')),
                DropdownMenuItem(
                  value: 'graph',
                  child: Text('Graph summaries'),
                ),
                DropdownMenuItem(
                  value: 'both',
                  child: Text('Pairs and graph summaries'),
                ),
              ],
              onChanged: (v) => setState(() => _cfg.connectivityOutput = v!),
            ),
            DropdownButtonFormField<double>(
              initialValue: _cfg.graphDensity,
              decoration: const InputDecoration(
                labelText: 'Graph edge density (positive weights)',
              ),
              items: [0.1, 0.2, 0.3, 0.5, 1.0]
                  .map(
                    (v) => DropdownMenuItem(
                      value: v,
                      child: Text('${(v * 100).round()}%'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _cfg.graphDensity = v!),
            ),
            if (_cfg.transferEntropy)
              DropdownButtonFormField<int>(
                initialValue: _cfg.teMaxDelay,
                decoration: const InputDecoration(
                  labelText: 'TE source-to-target delay (samples)',
                ),
                items: [1, 2, 3, 5, 10, 20, 30, 50, 100]
                    .map(
                      (v) =>
                          DropdownMenuItem(value: v, child: Text('$v samples')),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  _cfg.teMaxDelay = v!;
                  _cfg.teMinDelay = v - 1;
                }),
              ),
            if (_cfg.transferEntropy) ...[
              for (final source in [true, false])
                DropdownButtonFormField<int>(
                  initialValue: source
                      ? _cfg.teSourceHistory
                      : _cfg.teTargetHistory,
                  decoration: InputDecoration(
                    labelText: source
                        ? 'TE source history (samples)'
                        : 'TE target history (samples)',
                  ),
                  items: [1, 2, 3, 5, 10]
                      .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (source) {
                      _cfg.teSourceHistory = v!;
                    } else {
                      _cfg.teTargetHistory = v!;
                    }
                  }),
                ),
              DropdownButtonFormField<int>(
                initialValue: _cfg.teHistoryStep,
                decoration: const InputDecoration(
                  labelText: 'TE history spacing (samples)',
                ),
                items: [1, 2, 5, 10]
                    .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                    .toList(),
                onChanged: (v) => setState(() => _cfg.teHistoryStep = v!),
              ),
            ],
          ],
          _check('Coherence (COH)', _cfg.coh, (v) => _cfg.coh = v),
          _check('PLV', _cfg.plv, (v) => _cfg.plv = v),
          _check('ciPLV', _cfg.ciplv, (v) => _cfg.ciplv = v),
          _check('PLI', _cfg.pli, (v) => _cfg.pli = v),
          _check('wPLI', _cfg.wpli, (v) => _cfg.wpli = v),
          if (!_cfg.anyFeature)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Select at least one family.',
                style: TextStyle(color: Color(0xFFEF4444), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlotOptions({EdgeInsets? padding}) {
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _field(_topoWindows, 'Window (min)')),
              const SizedBox(width: 8),
              Expanded(child: _field(_smoothing, 'Smoothing (epochs)')),
            ],
          ),
          const SizedBox(height: 4),
          _check(
            'One plots PDF per recording',
            _cfg.topoStatsPdf,
            (v) => _cfg.topoStatsPdf = v,
          ),
          _check(
            'Also export individual plot PNGs',
            _cfg.topoStatsPng,
            (v) => _cfg.topoStatsPng = v,
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  BATCH MODE
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _addBatchPrepFiles() async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _rawExtensions,
      recordingsOnly: true,
    );
    if (pick == null) return;
    setState(() {
      for (final f in pick.files) {
        if (f.path != null && !_batchPrepFiles.contains(f.path!)) {
          _batchPrepFiles.add(f.path!);
        }
      }
    });
  }

  Future<void> _addBatchFolder(
    List<String> destination,
    List<String> extensions,
    String title,
  ) async {
    final controller = TextEditingController(text: '*');
    final pattern = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter folder files'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Filename wildcard',
            hintText: '*Rest*.edf;*Task*.edf',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Choose folder'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (pattern == null) return;
    final path = await FilePicker.getDirectoryPath(dialogTitle: title);
    if (path == null) return;
    final allowed = extensions.map((value) => '.$value').toSet();
    final discovered = await Directory(path)
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .map((entity) => entity.path)
        .where((file) => allowed.any((ext) => file.toLowerCase().endsWith(ext)))
        .where((file) => matchesFilename(file, pattern))
        .where(
          (file) => !extensions.contains('json') || isEegRecordingFile(file),
        )
        .toList();
    discovered.sort();
    final maxSubjects = int.tryParse(_batchSubjectLimit.text) ?? 0;
    if (maxSubjects > 0) {
      final subjects = <String>{};
      discovered.removeWhere((file) {
        final name = _shortName(file);
        final id =
            RegExp(r'sub-([^_]+)').firstMatch(name)?.group(1) ??
            name.split('_').first;
        if (subjects.contains(id)) return false;
        if (subjects.length >= maxSubjects) return true;
        subjects.add(id);
        return false;
      });
    }
    setState(() {
      for (final file in discovered) {
        if (!destination.contains(file)) destination.add(file);
      }
    });
    _log('Added ${discovered.length} supported file(s) from $path.');
  }

  Future<void> _openBatchGroupStatistics() async {
    final csvs = preferSessionFeatureCsvs(_batchFeatOutputs);
    if (csvs.isNotEmpty) {
      final dir = Directory(
        '${File(csvs.first).parent.path}${Platform.pathSeparator}Group_Statistics',
      );
      await dir.create(recursive: true);
      final path =
          '${dir.path}${Platform.pathSeparator}group_input.features.csv';
      await _service.compileCsvFiles(csvs, path);
      _groupInputCsv = path;
    }
    if (!mounted) return;
    setState(() {
      _batchMaximized = false;
      _selectedModule = _Module.groupStatistics;
    });
  }

  Widget _buildBatchBar({bool fillAvailable = false}) => SizedBox(
    height: fillAvailable ? null : 320,
    child: BatchProfilesView(
      profile: _batchProfile,
      onChanged: (v) => setState(() => _batchProfile = v),
      eeg: _buildEegBatchBar(fillAvailable: true),
      erp: ErpWorkbenchView(
        key: const ValueKey('erp-batch-profile'),
        config: _cfg,
      ),
      microstates: const MicrostateAnalysisView(
        key: ValueKey('microstate-batch-profile'),
        batchMode: true,
      ),
    ),
  );

  Widget _buildEegBatchBar({bool fillAvailable = false}) {
    return Container(
      height: fillAvailable ? null : 320,
      decoration: const BoxDecoration(
        color: Color(0xFF060D1A),
        border: Border(top: BorderSide(color: _borderColor)),
      ),
      child: Column(
        children: [
          // Header bar
          SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.queue_play_next,
                    size: 13,
                    color: _accentBlue,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'BATCH QUEUE',
                    style: TextStyle(
                      color: _accentBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(_batchPreprocessedInput ? _batchFeatFiles : _batchPrepFiles).length} files queued',
                    style: const TextStyle(color: _textMuted, fontSize: 11),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _running ? null : _openBatchGroupStatistics,
                    icon: const Icon(Icons.groups, size: 16),
                    label: const Text('Group Statistics'),
                  ),

                  if (!_running && _batchResultCsvs.isNotEmpty) ...[
                    OutlinedButton.icon(
                      onPressed: _viewBatchResults,
                      icon: const Icon(Icons.analytics_outlined, size: 16),
                      label: const Text('View Results'),
                    ),
                    if (_plotsDir != null)
                      TextButton.icon(
                        onPressed: _openBatchResultsFolder,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open Reports Folder'),
                      ),
                    const SizedBox(width: 8),
                  ],
                  if (_running)
                    TextButton.icon(
                      onPressed: _cancel,
                      icon: const Icon(Icons.stop_circle, size: 14),
                      label: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 11),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                    )
                  else ...[
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed:
                          (_batchPreprocessedInput
                                  ? _batchFeatFiles
                                  : _batchPrepFiles)
                              .isEmpty
                          ? null
                          : _runFullBatch,
                      icon: const Icon(Icons.play_circle_filled, size: 14),
                      label: Text(
                        _batchPreprocessedInput
                            ? 'Run feature workflow'
                            : 'Run Full Pipeline',
                        style: TextStyle(fontSize: 11),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _accentGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _cardColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Close batch workspace',
                    icon: const Icon(Icons.close, size: 17, color: _textMuted),
                    onPressed: () => setState(() {
                      _batchMaximized = false;
                    }),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: _borderColor, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _infoBox(
              'Batch parameters are configured inside each stage below. '
              'They are synchronized with the corresponding single-recording '
              'controls, so changing either view updates the same analysis configuration.',
              _accentBlue,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _field(
              _batchSubjectLimit,
              'Folder import: first N subjects (0 = all)',
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Already preprocessed: start with features'),
            value: _batchPreprocessedInput,
            onChanged: _running
                ? null
                : (v) => setState(() {
                    _batchPreprocessedInput = v;
                    _batchFeatUsePrep = !v;
                    _batchPlotUseFeat = true;
                  }),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.groups, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Next: group statistics · choose metadata and subject/state factors',
                  ),
                ),
                TextButton(
                  onPressed: _running ? null : _openBatchGroupStatistics,
                  child: const Text(
                    'Open group statistics with batch features',
                  ),
                ),
              ],
            ),
          ),
          // Batch content: preprocessing is optional.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_batchPreprocessedInput)
                    Expanded(child: _buildBatchStage1Card()),
                  const SizedBox(width: 10),
                  Expanded(child: _buildBatchStage2Card()),
                  const SizedBox(width: 10),
                  Expanded(child: _buildBatchStage3Card()),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _cardColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Stage 4: Group Statistics',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Batch feature CSVs → metadata join → subject/state factors → LMM / GLM. Review the model before running it.',
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Open after batch finishes'),
                            value: _batchOpenGroupAfter,
                            onChanged: _running
                                ? null
                                : (v) =>
                                      setState(() => _batchOpenGroupAfter = v),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _running
                                ? null
                                : _openBatchGroupStatistics,
                            icon: const Icon(Icons.groups),
                            label: const Text('Open group analysis'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchStage1Card() => _batchStageCard(
    title: 'Stage 1: Preprocessing',
    icon: Icons.cleaning_services,
    color: _accentPurple,
    files: _batchPrepFiles,
    outputDir: _batchPrepOutputDir,
    outputLabel: 'Output Directory',
    onSelectOutput: () async {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Output directory for preprocessed files',
      );
      if (path != null) setState(() => _batchPrepOutputDir = path);
    },
    onAdd: _addBatchPrepFiles,
    onAddFolder: () => _addBatchFolder(
      _batchPrepFiles,
      _rawExtensions,
      'Add recording folder to preprocessing queue',
    ),
    onClear: () => setState(() {
      _batchPrepFiles.clear();
      _batchPrepOutputs.clear();
    }),
    onRemove: (i) => setState(() => _batchPrepFiles.removeAt(i)),
    options: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPreprocessingOptions(),
        const SizedBox(height: 8),
        _subLabel('CHANNEL TYPES'),
        const SizedBox(height: 2),
        _infoBox(
          'Non-EEG channels are auto-detected per file from their labels '
          '(ECG, EOG, EMG, GSR, respiration, PPG, motion, references, '
          'triggers). Load a file in Single Recording mode to review and '
          'override the detection before batching.',
          _accentPink,
        ),
        const SizedBox(height: 8),
        _check(
          'Also run source localisation',
          _cfg.sourceLocalization,
          (v) => _cfg.sourceLocalization = v,
        ),
      ],
    ),
    runLabel: 'Run Preprocessing Only',
    onRun: _runBatchPreprocessing,
    runEnabled: _batchPrepFiles.isNotEmpty,
  );

  Widget _buildBatchStage2Card() => _batchStageCard(
    title: 'Stage 2: Feature Extraction',
    icon: Icons.analytics,
    color: _accentGreen,
    files: _batchFeatFiles,
    outputDir: _batchFeatOutputDir,
    outputLabel: 'Output Directory',
    onSelectOutput: () async {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Output directory for feature CSVs',
      );
      if (path != null) setState(() => _batchFeatOutputDir = path);
    },
    usePrevious: _batchFeatUsePrep,
    usePreviousLabel: 'Use Stage 1 outputs (or choose recordings directly)',
    onUsePreviousChanged: (v) => setState(() => _batchFeatUsePrep = v ?? true),
    onAdd: () async {
      final pick = await pickFilteredFiles(
        context,
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: _anyInputExtensions,
        recordingsOnly: true,
      );
      if (pick == null) return;
      setState(() {
        _batchFeatUsePrep = false;
        for (final f in pick.files) {
          if (f.path != null && !_batchFeatFiles.contains(f.path!)) {
            _batchFeatFiles.add(f.path!);
          }
        }
      });
    },
    onAddFolder: () async {
      await _addBatchFolder(
        _batchFeatFiles,
        _anyInputExtensions,
        'Add recording folder to feature extraction queue',
      );
      if (mounted) setState(() => _batchFeatUsePrep = false);
    },
    onClear: () => setState(() {
      _batchFeatFiles.clear();
      _batchFeatOutputs.clear();
    }),
    onRemove: (i) => setState(() => _batchFeatFiles.removeAt(i)),
    options: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEpochingOptions(),
        const SizedBox(height: 10),
        _buildFeatureFamilies(padding: EdgeInsets.zero),
        const SizedBox(height: 8),
        _subLabel('OUTPUTS'),
        _check('One CSV per file', _cfg.perFileCsv, (v) => _cfg.perFileCsv = v),
        _check(
          'Combined CSV across files',
          _cfg.combinedCsv,
          (v) => _cfg.combinedCsv = v,
        ),
        _check(
          'Remove non-EEG channels (reference in settings)',
          _cfg.removeNonEeg,
          (v) => _cfg.removeNonEeg = v,
        ),
        _check(
          'PDF report per file',
          _cfg.generatePdfReport,
          (v) => _cfg.generatePdfReport = v,
        ),
        const SizedBox(height: 4),
        _field(_exclude, 'Filename exclusions', helper: 'Comma-separated'),
      ],
    ),
    runLabel: 'Run Feature Extraction Only',
    onRun: _runBatchExtraction,
    runEnabled:
        (_batchFeatUsePrep
            ? (_batchPrepOutputs.isNotEmpty || _batchPrepFiles.isNotEmpty)
            : _batchFeatFiles.isNotEmpty) &&
        _cfg.anyFeature &&
        (_cfg.perFileCsv || _cfg.combinedCsv),
  );

  Widget _buildBatchStage3Card() => _batchStageCard(
    title: 'Stage 3: Plots',
    icon: Icons.stacked_line_chart,
    color: _accentAmber,
    files: _batchPlotFiles,
    outputDir: _batchPlotOutputDir,
    outputLabel: 'Output Directory',
    onSelectOutput: () async {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Output directory for plots',
      );
      if (path != null) setState(() => _batchPlotOutputDir = path);
    },
    usePrevious: _batchPlotUseFeat,
    usePreviousLabel: 'Use Stage 2 CSVs (or choose feature CSVs directly)',
    onUsePreviousChanged: (v) => setState(() => _batchPlotUseFeat = v ?? true),
    onAdd: () async {
      final pick = await pickFilteredFiles(
        context,
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (pick == null) return;
      setState(() {
        _batchPlotUseFeat = false;
        for (final f in pick.files) {
          if (f.path != null && !_batchPlotFiles.contains(f.path!)) {
            _batchPlotFiles.add(f.path!);
          }
        }
      });
    },
    onAddFolder: () async {
      await _addBatchFolder(_batchPlotFiles, const [
        'csv',
      ], 'Add feature CSV folder to plotting queue');
      if (mounted) setState(() => _batchPlotUseFeat = false);
    },
    onClear: () => setState(() => _batchPlotFiles.clear()),
    onRemove: (i) => setState(() => _batchPlotFiles.removeAt(i)),
    options: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPlotOptions(),
        const SizedBox(height: 8),
        _infoBox(
          'Each recording gets its own plot folder. The group overlay draws '
          'one colour-coded trace per recording on a shared axis, so sessions '
          'and subjects stay distinguishable instead of being averaged '
          'together.',
          _accentAmber,
        ),
      ],
    ),
    runLabel: 'Run Plotting Only',
    onRun: _runBatchPlotting,
    runEnabled: _batchPlotUseFeat
        ? (_batchFeatOutputs.isNotEmpty ||
              _batchPrepFiles.isNotEmpty ||
              _batchFeatFiles.isNotEmpty)
        : _batchPlotFiles.isNotEmpty,
  );

  Widget _batchStageCard({
    required String title,
    required IconData icon,
    required Color color,
    required List<String> files,
    String? outputDir,
    String outputLabel = 'Output Directory',
    required VoidCallback onSelectOutput,
    required VoidCallback onAdd,
    VoidCallback? onAddFolder,
    required VoidCallback onClear,
    required void Function(int) onRemove,
    Widget? options,
    bool? usePrevious,
    String? usePreviousLabel,
    void Function(bool?)? onUsePreviousChanged,
    required String runLabel,
    required VoidCallback onRun,
    bool runEnabled = true,
  }) {
    final linked = usePrevious == true;
    return Material(
      color: _cardColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                border: const Border(bottom: BorderSide(color: _borderColor)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (usePrevious != null && onUsePreviousChanged != null) ...[
                    CheckboxListTile(
                      title: Text(
                        usePreviousLabel ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                      value: usePrevious,
                      onChanged: _running ? null : onUsePreviousChanged,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    outputLabel,
                    style: const TextStyle(
                      color: _textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          outputDir ?? 'Next to source files',
                          style: TextStyle(
                            color: outputDir == null
                                ? _textMuted
                                : Colors.white,
                            fontSize: 11,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.folder_open,
                          size: 16,
                          color: _accentBlue,
                        ),
                        onPressed: _running ? null : onSelectOutput,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!linked) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Files (${files.length})',
                          style: const TextStyle(
                            color: _textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            if (onAddFolder != null)
                              TextButton(
                                onPressed: _running ? null : onAddFolder,
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(52, 24),
                                ),
                                child: const Text(
                                  'Folder',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            TextButton(
                              onPressed: _running ? null : onAdd,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(40, 24),
                              ),
                              child: const Text(
                                'Add',
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                            TextButton(
                              onPressed: _running || files.isEmpty
                                  ? null
                                  : onClear,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(40, 24),
                              ),
                              child: const Text(
                                'Clear',
                                style: TextStyle(
                                  color: Colors.red,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 150,
                      decoration: BoxDecoration(
                        color: _bgColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _borderColor),
                      ),
                      child: files.isEmpty
                          ? const Center(
                              child: Text(
                                'No files selected',
                                style: TextStyle(
                                  color: _textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              itemCount: files.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: _borderColor, height: 1),
                              itemBuilder: (ctx, idx) => Row(
                                children: [
                                  Text(
                                    '${idx + 1}.',
                                    style: const TextStyle(
                                      color: _textMuted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Tooltip(
                                      message: files[idx],
                                      child: Text(
                                        _shortName(files[idx]),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      size: 13,
                                      color: _textMuted,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 20,
                                      minHeight: 20,
                                    ),
                                    onPressed: _running
                                        ? null
                                        : () => onRemove(idx),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ] else
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _bgColor,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _borderColor),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.link, size: 14, color: color),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Using the previous stage’s outputs. Turn this off to choose files or a folder directly.',
                              style: TextStyle(
                                color: _textMuted,
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (options != null) ...[
                    const Text(
                      'BATCH PARAMETERS · SHARED WITH SINGLE RECORDING',
                      style: TextStyle(
                        color: _textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    options,
                  ],
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: _borderColor)),
              ),
              child: FilledButton.icon(
                onPressed: (_running || !runEnabled) ? null : onRun,
                icon: const Icon(Icons.play_arrow, size: 14),
                label: Text(
                  runLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: color,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF334155),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Batch runners ───────────────────────────────────────────────────────

  void _startBatchProgress(String title, List<String> files) {
    _batchRunTitle = title;
    _batchCurrent = 'Preparing…';
    _batchDone = 0;
    _batchTotal = files.length;
    _batchFailed = 0;
    _batchFileProgress = 0;
    _batchProgressFinished = false;
    _batchProgressActive = true;
    _batchCancelRequested = false;
    _batchProgressLog.clear();
    _batchFileStatus
      ..clear()
      ..addEntries(files.map((path) => MapEntry(path, 'Waiting')));
    _batchProgressPulse.value++;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: _batchProgressPulse,
          builder: (_, __) => _buildBatchProgressDialog(dialogContext),
        ),
      ).whenComplete(() => _batchProgressActive = false),
    );
  }

  void _updateBatchFile(
    String path,
    String status, {
    double? progress,
    bool completed = false,
    bool failed = false,
  }) {
    _batchCurrent = '${_shortName(path)} — $status';
    _batchFileStatus[path] = status;
    if (progress != null) _batchFileProgress = progress.clamp(0, 1);
    if (completed) _batchDone++;
    if (failed) _batchFailed++;
    _batchProgressPulse.value++;
  }

  void _finishBatchProgress(String message) {
    _batchCurrent = message;
    _batchFileProgress = 1;
    _batchProgressFinished = true;
    _batchProgressPulse.value++;
  }

  void _resetBatchProgressStage(String title, List<String> files) {
    _batchRunTitle = title;
    _batchCurrent = 'Preparing…';
    _batchDone = 0;
    _batchTotal = files.length;
    _batchFailed = 0;
    _batchFileProgress = 0;
    _batchFileStatus
      ..clear()
      ..addEntries(files.map((path) => MapEntry(path, 'Waiting')));
    _batchProgressPulse.value++;
  }

  Widget _buildBatchProgressDialog(BuildContext dialogContext) {
    final overall = _batchTotal == 0
        ? 1.0
        : ((_batchDone + (_batchProgressFinished ? 0 : _batchFileProgress)) /
                  _batchTotal)
              .clamp(0.0, 1.0);
    Color statusColor(String status) {
      if (status.startsWith('Done')) return _accentGreen;
      if (status.startsWith('Failed')) return Colors.redAccent;
      if (status.startsWith('Running') || status.startsWith('Loading')) {
        return _accentBlue;
      }
      return _textMuted;
    }

    return AlertDialog(
      backgroundColor: _cardColor,
      title: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: _accentBlue),
          const SizedBox(width: 10),
          Expanded(child: Text(_batchRunTitle)),
          Text(
            '$_batchDone / $_batchTotal',
            style: const TextStyle(color: _textMuted, fontSize: 13),
          ),
        ],
      ),
      content: SizedBox(
        width: 920,
        height: 580,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _batchCurrent,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 7),
            LinearProgressIndicator(
              value: _batchProgressFinished ? 1 : overall,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: const Color(0xFF0F172A),
              color: _batchFailed > 0 ? _accentAmber : _accentBlue,
            ),
            const SizedBox(height: 6),
            Text(
              '${(overall * 100).toStringAsFixed(1)}% overall'
              '${_batchFailed > 0 ? ' · $_batchFailed failed' : ''}',
              style: const TextStyle(color: _textMuted, fontSize: 11),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  border: Border.all(color: _borderColor),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ListView.builder(
                  itemCount: _batchFileStatus.length,
                  itemBuilder: (_, index) {
                    final entry = _batchFileStatus.entries.elementAt(index);
                    final color = statusColor(entry.value);
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        entry.value.startsWith('Done')
                            ? Icons.check_circle
                            : entry.value.startsWith('Failed')
                            ? Icons.error
                            : entry.value.startsWith('Running') ||
                                  entry.value.startsWith('Loading')
                            ? Icons.autorenew
                            : Icons.radio_button_unchecked,
                        color: color,
                        size: 16,
                      ),
                      title: Text(
                        _shortName(entry.key),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        entry.value,
                        style: TextStyle(color: color, fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF080D16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ListView.builder(
                  reverse: true,
                  itemCount: _batchProgressLog.length,
                  itemBuilder: (_, index) {
                    final line =
                        _batchProgressLog[_batchProgressLog.length - index - 1];
                    return Text(
                      line,
                      style: TextStyle(
                        color: line.contains('ERROR') || line.contains('Failed')
                            ? Colors.red.shade200
                            : Colors.grey.shade300,
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_batchProgressFinished && _plotsDir != null)
          TextButton.icon(
            onPressed: _openBatchResultsFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Reports Folder'),
          ),
        if (_batchProgressFinished && _batchResultCsvs.isNotEmpty)
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _viewBatchResults();
            },
            icon: const Icon(Icons.analytics_outlined),
            label: const Text('View Results'),
          ),
        if (!_batchProgressFinished)
          TextButton.icon(
            onPressed: _cancel,
            icon: const Icon(Icons.stop_circle),
            label: const Text('Cancel'),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          ),
        FilledButton(
          onPressed: _batchProgressFinished
              ? () => Navigator.of(dialogContext).pop()
              : null,
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// Stage 1 across the queue.  Returns the files actually written.
  Future<List<String>> _runBatchPreprocessing({bool standalone = true}) async {
    if (_batchPrepFiles.isEmpty) return const [];
    if (_gedaiEpochError case final error?) {
      _log(error);
      return const [];
    }
    if (standalone) {
      _startBatchProgress('Batch preprocessing', _batchPrepFiles);
    }
    if (standalone) {
      setState(() {
        _running = true;
        _stopRequested = false;
        _progress = 0;
        _logVisible = true;
      });
    }
    _log('── BATCH PREPROCESSING (${_batchPrepFiles.length} files) ──');
    final written = <String>[];
    for (var i = 0; i < _batchPrepFiles.length; i++) {
      if (_batchCancelRequested) break;
      final path = _batchPrepFiles[i];
      _updateBatchFile(path, 'Loading', progress: 0);
      _log('[${i + 1}/${_batchPrepFiles.length}] ${_shortName(path)}');
      try {
        final dir = _batchPrepOutputDir ?? File(path).parent.path;
        final rec = await _loadRecordingWithFeedback(path);
        if (_batchCancelRequested) break;
        final outPath =
            '$dir${Platform.pathSeparator}${erpOutputName(path, extension: RecordingStorage.extension, epoched: rec.isEpoched || _cfg.stimEpochs || _cfg.epochBeforeGedai, cleaned: true)}';
        // Detect channel types per file — a batch queue can mix montages.
        final channels = ChannelTypeMap.autoDetect(rec.labels);
        if (channels.nonEegCount > 0) {
          _log('  Non-EEG: ${channels.nonEegChannels.join(', ')}');
        }

        var current = await _service.preprocess(
          recording: rec,
          outputPath: outPath,
          selection: const ViewerSelection.empty(),
          options: _cfg.toPreprocessingOptions(
            nonEegChannels: channels.nonEegChannels,
          ),
          outputOverlapSeconds: (_cfg.stimEpochs || !_cfg.epochBeforeGedai)
              ? 0
              : _cfg.preprocessingOverlapSeconds,
          outputWindowSeconds: _cfg.gedaiEpochSeconds,
          onProgress: (p, msg) {
            _updateBatchFile(path, 'Running', progress: p);
            if (standalone) {
              setState(
                () => _progress = (i + p.clamp(0, 1)) / _batchPrepFiles.length,
              );
            }
            if (msg.isNotEmpty) _log('  $msg');
          },
        );

        var finalPath = outPath;
        if (_cfg.sourceLocalization) {
          final srcPath =
              '$dir${Platform.pathSeparator}'
              '${_stem(path)}_source.${RecordingStorage.extension}';
          current = await _service.preprocess(
            recording: current,
            outputPath: srcPath,
            selection: const ViewerSelection.empty(),
            options: _cfg.toPreprocessingOptions(
              nonEegChannels: const [],
              sourceLocalizationOnly: true,
            ),
            onProgress: (p, msg) {
              if (msg.isNotEmpty) _log('  $msg');
            },
          );
          finalPath = srcPath;
          _log('  ✓ Source: ${_shortName(srcPath)}');
        }

        written.add(finalPath);
        _updateBatchFile(path, 'Done', progress: 1, completed: true);
        _log('✓ Saved: $finalPath');
      } catch (e) {
        _updateBatchFile(
          path,
          _batchCancelRequested ? 'Cancelled' : 'Failed',
          progress: 1,
          completed: true,
          failed: !_batchCancelRequested,
        );
        _log('✗ ERROR on ${_shortName(path)}: $e');
      }
    }
    setState(() {
      _batchPrepOutputs
        ..clear()
        ..addAll(written);
      if (standalone) {
        _running = false;
        _progress = 1.0;
      }
    });
    _log(
      '── PREPROCESSING DONE — ${written.length}/'
      '${_batchPrepFiles.length} succeeded ──',
    );
    if (standalone) {
      _finishBatchProgress(
        _batchCancelRequested
            ? 'Batch preprocessing cancelled.'
            : 'Batch preprocessing complete: ${written.length}/${_batchPrepFiles.length} succeeded.',
      );
    }
    return written;
  }

  /// Resolves the file list Stage 2 should consume.
  List<String> _resolveBatchExtractionInputs() {
    if (!_batchFeatUsePrep) return List.of(_batchFeatFiles);
    if (_batchPrepOutputs.isNotEmpty) return List.of(_batchPrepOutputs);
    // Stage 1 has not run in this session — fall back to the expected paths.
    return _batchPrepFiles.map((path) {
      final dir = _batchPrepOutputDir ?? File(path).parent.path;
      final suffix = _cfg.sourceLocalization ? '_source' : '_clean';
      final native =
          '$dir${Platform.pathSeparator}${_stem(path)}$suffix.${RecordingStorage.extension}';
      final legacy = '$native.json';
      return !File(native).existsSync() && File(legacy).existsSync()
          ? legacy
          : native;
    }).toList();
  }

  Future<List<String>> _runBatchExtraction({bool standalone = true}) async {
    final inputs = _resolveBatchExtractionInputs();
    if (inputs.isEmpty) {
      _log('No files to extract from.');
      return const [];
    }
    if (!_cfg.anyFeature) {
      _log('Select at least one feature family.');
      return const [];
    }
    if (standalone) {
      setState(() {
        _running = true;
        _stopRequested = false;
        _progress = 0;
        _logVisible = true;
      });
    }
    _log('── BATCH FEATURE EXTRACTION (${inputs.length} files) ──');

    // Filename exclusions apply to batch queues.
    final kept = inputs
        .where((p) => !_cfg.exclusions.any((x) => p.contains(x)))
        .toList();
    if (kept.length != inputs.length) {
      _log(
        '  Skipped ${inputs.length - kept.length} file(s) by exclusion '
        'pattern (${_cfg.exclusions.join(', ')}).',
      );
    }
    if (kept.isEmpty) {
      _log('✗ Every file was excluded.');
      if (standalone) setState(() => _running = false);
      return const [];
    }

    if (standalone) {
      _startBatchProgress('Batch feature extraction', kept);
    }

    final outDir = _batchFeatOutputDir ?? File(kept.first).parent.path;
    Directory(outDir).createSync(recursive: true);
    final combinedPath = '$outDir${Platform.pathSeparator}Batch_features.csv';
    final scratch = await Directory.systemTemp.createTemp(
      'ccs_batch_features_',
    );
    IOSink? combinedSink;
    var combinedHasHeader = false;
    if (_cfg.combinedCsv) combinedSink = File(combinedPath).openWrite();
    final written = <String>[];
    var succeeded = 0;
    final acknowledgedWarnings = <String>{};
    try {
      for (var i = 0; i < kept.length; i++) {
        if (_batchCancelRequested) break;
        final path = kept[i];
        final perFilePath =
            '$outDir${Platform.pathSeparator}${_stem(path)}.features.csv';
        final jobCsv = _cfg.perFileCsv
            ? perFilePath
            : '${scratch.path}${Platform.pathSeparator}part_$i.csv';
        _updateBatchFile(path, 'Loading', progress: 0);
        _log('[${i + 1}/${kept.length}] Loading ${_shortName(path)}');
        try {
          // Deliberately retain only one recording at a time. The psiconnect
          // corpus is ~20 GB; loading its 482 previews together exhausted RAM.
          final rec = await _loadRecordingWithFeedback(path);
          if (_batchCancelRequested) break;
          final windowAdvice = featureWindowWarnings(_cfg, rec).join('\n');
          if (windowAdvice.isNotEmpty &&
              acknowledgedWarnings.add(windowAdvice)) {
            if (!await _confirmFeatureWindows(rec)) {
              _batchCancelRequested = true;
              _updateBatchFile(
                path,
                'Cancelled',
                progress: 1,
                completed: true,
                failed: true,
              );
              break;
            }
          }
          final nonEeg = ChannelTypeMap.autoDetect(rec.labels).nonEegChannels;
          final options = _cfg.toExtractionOptions(
            nonEegChannels: nonEeg,
            applyExclusions: false,
          );
          _updateBatchFile(path, 'Running', progress: 0);
          await _service.run(
            recordings: [rec],
            outputPath: jobCsv,
            epochSeconds: _cfg.epochSeconds,
            epochOverlapSeconds: _cfg.epochOverlapSeconds,
            subepochExisting: _cfg.subepochExisting,
            selection: const ViewerSelection.empty(),
            writeCombined: true,
            options: options,
            onProgress: (p, msg) {
              final overall = (i + p.clamp(0, 1)) / kept.length;
              if (mounted) setState(() => _progress = overall);
              _updateBatchFile(path, 'Running', progress: p);
              if (msg.isNotEmpty) _log('  $msg');
            },
          );

          if (combinedSink != null) {
            var firstLine = true;
            for (final line in await File(jobCsv).readAsLines()) {
              if (firstLine) {
                firstLine = false;
                if (combinedHasHeader) continue;
                combinedHasHeader = true;
              }
              combinedSink.writeln(line);
            }
          }

          if (_cfg.perFileCsv) written.add(perFilePath);
          if (_cfg.generatePdfReport) {
            await _writeReport(
              jobCsv,
              rec,
              options,
              excludedChannels: nonEeg,
              outputPath:
                  '$outDir${Platform.pathSeparator}${_stem(path)}.analysis_report.pdf',
            );
          }
          succeeded++;
          _updateBatchFile(path, 'Done', progress: 1, completed: true);
          _log('✓ ${_shortName(path)}');
        } catch (e) {
          try {
            final partial = File(jobCsv);
            if (partial.existsSync()) partial.deleteSync();
          } catch (_) {}
          _updateBatchFile(
            path,
            _batchCancelRequested ? 'Cancelled' : 'Failed',
            progress: 1,
            completed: true,
            failed: !_batchCancelRequested,
          );
          _log('✗ Failed ${_shortName(path)}: $e');
        }
      }
      await combinedSink?.flush();
      await combinedSink?.close();
      combinedSink = null;
      if (_cfg.combinedCsv && combinedHasHeader) {
        written.add(combinedPath);
        _log('✓ Combined: $combinedPath');
      } else if (_cfg.combinedCsv) {
        try {
          final emptyCombined = File(combinedPath);
          if (emptyCombined.existsSync()) emptyCombined.deleteSync();
        } catch (_) {}
      }
      setState(() {
        _groupInputCsv = null;
        _batchFeatOutputs
          ..clear()
          ..addAll(written);
        _batchResultCsvs = preferSessionFeatureCsvs(written);
        _plotsDir = null;
      });
      _log(
        '── EXTRACTION DONE — $succeeded/${kept.length} files, '
        '${written.length} CSV output(s) ──',
      );
      return written;
    } finally {
      await combinedSink?.close();
      try {
        await scratch.delete(recursive: true);
      } catch (_) {}
      if (standalone && mounted) {
        setState(() {
          _running = false;
          _progress = _batchCancelRequested ? _progress : 1.0;
        });
        _finishBatchProgress(
          _batchCancelRequested
              ? 'Batch feature extraction cancelled after $succeeded/${kept.length} files.'
              : 'Batch feature extraction complete: $succeeded/${kept.length} succeeded.',
        );
      }
    }
  }

  /// Plot inputs: prefer per-file CSVs so each recording is plotted on its own,
  /// falling back to the combined CSV (which the plotter now splits by its
  /// `filename` column anyway).
  List<String> _resolveBatchPlotInputs() {
    if (!_batchPlotUseFeat) return List.of(_batchPlotFiles);
    if (_batchFeatOutputs.isNotEmpty) {
      final perFile = _batchFeatOutputs.where(
        (p) => !p.endsWith('Batch_features.csv'),
      );
      return perFile.isNotEmpty ? perFile.toList() : List.of(_batchFeatOutputs);
    }
    final source = _batchFeatUsePrep ? _batchPrepFiles : _batchFeatFiles;
    if (source.isEmpty) return const [];
    final dir = _batchFeatOutputDir ?? File(source.first).parent.path;
    return source
        .map((p) => '$dir${Platform.pathSeparator}${_stem(p)}.features.csv')
        .where((p) => File(p).existsSync())
        .toList();
  }

  Future<void> _runBatchPlotting({bool standalone = true}) async {
    final inputs = _resolveBatchPlotInputs();
    if (inputs.isEmpty) {
      _log('No feature CSVs found to plot.');
      return;
    }
    if (standalone) {
      _startBatchProgress('Batch plotting', inputs);
      setState(() {
        _running = true;
        _stopRequested = false;
        _progress = 0;
        _logVisible = true;
      });
    }
    _log('── BATCH PLOTTING (${inputs.length} CSV(s)) ──');
    try {
      final outDir = _batchPlotOutputDir ?? File(inputs.first).parent.path;
      for (final path in inputs) {
        _updateBatchFile(path, 'Running', progress: 0);
      }
      await _runPlotting(csvPaths: inputs, announce: false, outputDir: outDir);
      if (mounted)
        setState(() => _batchResultCsvs = preferSessionFeatureCsvs(inputs));
      for (final path in inputs) {
        _updateBatchFile(path, 'Done', progress: 1, completed: true);
      }
    } finally {
      if (standalone && mounted) {
        setState(() {
          _running = false;
          _progress = 1.0;
        });
      }
      _log('── PLOTTING DONE ──');
      if (standalone) _finishBatchProgress('Batch plotting complete.');
    }
  }

  /// Runs all three stages back to back, feeding each stage the files the
  /// previous one actually produced.
  Future<void> _runFullBatch() async {
    final queue = _batchPreprocessedInput ? _batchFeatFiles : _batchPrepFiles;
    if (queue.isEmpty) {
      _log('Queue is empty — add recordings in the active input stage.');
      return;
    }
    setState(() {
      _running = true;
      _stopRequested = false;
      _progress = 0;
      _logVisible = true;
    });
    _startBatchProgress('Batch workflow', queue);
    _log('══ BATCH WORKFLOW — ${queue.length} files ══');
    try {
      final preprocessed = _batchPreprocessedInput
          ? List<String>.of(_batchFeatFiles)
          : await _runBatchPreprocessing(standalone: false);
      if (preprocessed.isEmpty) {
        _log('✗ Stage 1 produced nothing — aborting.');
        return;
      }
      setState(() => _progress = 1 / 3);

      _batchFeatUsePrep = !_batchPreprocessedInput;
      _resetBatchProgressStage(
        'Full batch pipeline · feature extraction',
        preprocessed,
      );
      final csvs = await _runBatchExtraction(standalone: false);
      if (csvs.isEmpty || _batchCancelRequested) {
        _log('Feature stage stopped or produced no output.');
        return;
      }
      setState(() => _progress = 2 / 3);

      _batchPlotUseFeat = true;
      _resetBatchProgressStage('Full batch pipeline · plotting', csvs);
      await _runBatchPlotting(standalone: false);
      for (final path in csvs) {
        _updateBatchFile(path, 'Done', progress: 1, completed: true);
      }
      _log('══ FULL BATCH PIPELINE COMPLETE ══');
      if (_batchOpenGroupAfter && !_batchCancelRequested) {
        await _openBatchGroupStatistics();
      }
    } catch (e) {
      _log('✗ Pipeline error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _progress = 1.0;
        });
      }
      _finishBatchProgress(
        _batchCancelRequested
            ? 'Full batch pipeline cancelled.'
            : 'Full batch pipeline finished.',
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Shared widgets
  // ══════════════════════════════════════════════════════════════════════

  Widget _loadButton({
    required String label,
    required Color color,
    required VoidCallback? onPressed,
  }) => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.folder_open, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.55)),
        padding: const EdgeInsets.symmetric(vertical: 9),
      ),
    ),
  );

  Widget _stageRunButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool enabled,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 15),
        label: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF243044),
          disabledForegroundColor: _textMuted,
          padding: const EdgeInsets.symmetric(vertical: 11),
        ),
      ),
    );
    return Tooltip(
      message:
          tooltip ??
          '$label using the selected recording and the settings above. Choose an output path before processing starts; the input file is retained.',
      child: button,
    );
  }

  Widget _recordingChip(EegRecording rec, {bool active = false}) => Container(
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: active ? _accentBlue.withValues(alpha: 0.15) : _cardColor,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: active ? _accentBlue : _borderColor),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.graphic_eq,
              color: active ? _accentBlue : _textMuted,
              size: 14,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _shortName(rec.path),
                style: TextStyle(
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  fontSize: 12,
                  color: Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        InkWell(
          onTap: () => showRecordingDetails(context, rec),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(
                  recordingWarnings(rec).isEmpty
                      ? Icons.history
                      : Icons.warning_amber,
                  size: 14,
                  color: recordingWarnings(rec).isEmpty
                      ? _textMuted
                      : _accentAmber,
                ),
                const SizedBox(width: 4),
                Text(
                  recordingWarnings(rec).isEmpty
                      ? 'Processing history'
                      : 'History · warnings',
                  style: const TextStyle(fontSize: 11, color: _textMuted),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _badge('${rec.labels.length} ch', _accentBlue),
            const SizedBox(width: 4),
            _badge('${rec.sampleRate.toStringAsFixed(0)} Hz', _accentAmber),
            const SizedBox(width: 4),
            _badge(
              '${(rec.durationSeconds / 60).toStringAsFixed(1)} min',
              _accentGreen,
            ),
          ],
        ),
      ],
    ),
  );

  Widget _infoBox(String text, Color color) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.25)),
    ),
    child: Text(
      text,
      style: const TextStyle(color: _textMuted, fontSize: 10.5, height: 1.45),
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? suffix,
    String? helper,
    String? error,
  }) => TextField(
    controller: controller,
    enabled: !_running,
    style: const TextStyle(color: Colors.white, fontSize: 12),
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      helperText: helper,
      errorText: error,
      helperStyle: const TextStyle(color: _textMuted, fontSize: 10),
    ),
  );

  Widget _pipelineBadge({
    required IconData icon,
    required String label,
    required Color color,
  }) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 10.5),
          ),
        ),
      ],
    ),
  );

  Widget _subAccordionHeader(String label, bool expanded, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_less : Icons.chevron_right,
                size: 15,
                color: _textMuted,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: _textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _subLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 2),
    child: Text(
      text,
      style: const TextStyle(
        color: _textMuted,
        fontSize: 10,
        letterSpacing: 0.6,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  bool _hasParameterSettings(String label) => [
    'Bandpass + notch filter',
    'Bad channel detection',
    'GEDAI denoising',
    'Interpolate bad channels',
    'PSD band power',
    'FOOOF / specparam',
    'IRASA',
    'Nonlinear dynamics',
    'Autocorrelation window (ACW)',
    'MIC',
    'MIM',
    'Granger Causality',
    'GC-TR',
    'GC − GC-TR contrast',
    'Coherence (COH)',
    'PLV',
    'ciPLV',
    'PLI',
    'wPLI',
  ].contains(label);

  Widget _check(String text, bool value, void Function(bool) set) =>
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        value: value,
        onChanged: _running ? null : (v) => setState(() => set(v!)),
        title: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
            if (_hasParameterSettings(text))
              IconButton(
                tooltip: '$text parameters',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.settings, size: 15),
                onPressed: _running
                    ? null
                    : () async {
                        final stage =
                            [
                              'Bandpass + notch filter',
                              'Bad channel detection',
                              'GEDAI denoising',
                              'Interpolate bad channels',
                            ].contains(text)
                            ? 'Preprocessing'
                            : 'Feature Extraction';
                        await showProcessingSettings(
                          context,
                          _cfg,
                          stage,
                          section: text == 'Bandpass + notch filter'
                              ? 'Filter'
                              : text == 'GEDAI denoising'
                              ? 'GEDAI'
                              : 'Bad channels',
                        );
                        if (mounted) setState(() {});
                      },
              ),
          ],
        ),
      );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );

  // ── Coming-soon tab helpers ──────────────────────────────────────────────

  // Retained for future pipeline modules.
  // ignore: unused_element
  Widget _buildComingSoonTab({
    required IconData icon,
    required String title,
    required Color color,
    required String description,
    required List<String> capabilities,
  }) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color.withValues(alpha: 0.25)),
              ),
              child: Icon(icon, size: 36, color: color.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              child: Text(
                'Coming Soon',
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textMuted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _cardColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Planned capabilities',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final item in capabilities)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.circle,
                            size: 5,
                            color: color.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item,
                              style: const TextStyle(
                                color: _textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Log panel ───────────────────────────────────────────────────────────

  Widget _buildLogPanel() {
    if (!_logVisible) return const SizedBox.shrink();
    return Container(
      height: 170,
      decoration: const BoxDecoration(
        color: Color(0xFF060D1A),
        border: Border(top: BorderSide(color: _borderColor)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 13, color: _accentBlue),
                  const SizedBox(width: 6),
                  const Text(
                    'ACTIVITY LOG',
                    style: TextStyle(
                      color: _accentBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => setState(() => _logs.clear()),
                    icon: const Icon(Icons.clear_all, size: 12),
                    label: const Text('Clear', style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      foregroundColor: _textMuted,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14, color: _textMuted),
                    onPressed: () => setState(() => _logVisible = false),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: _borderColor, height: 1),
          Expanded(
            child: _logs.isEmpty
                ? const Center(
                    child: Text(
                      'No activity yet.',
                      style: TextStyle(color: _textMuted, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    itemCount: _logs.length,
                    itemBuilder: (context, i) {
                      final line = _logs[_logs.length - 1 - i];
                      var color = _textMuted;
                      if (line.startsWith('✗') || line.contains('ERROR')) {
                        color = const Color(0xFFEF4444);
                      } else if (line.startsWith('✓')) {
                        color = _accentGreen;
                      } else if (line.startsWith('⚠')) {
                        color = _accentAmber;
                      } else if (line.startsWith('──') ||
                          line.startsWith('══')) {
                        color = _accentBlue;
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: color,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Path helpers ────────────────────────────────────────────────────────

  String _shortName(String path) => path.split(Platform.pathSeparator).last;

  /// Filename without any known recording extension.
  String _stem(String path) => _shortName(path).replaceAll(
    RegExp(
      r'(?:\.(?:ccseeg|edf|set|fif|mat|vhdr|json|orb|signal|csv))+$',
      caseSensitive: false,
    ),
    '',
  );

  String _durationLabel(DurationMode mode) => switch (mode) {
    DurationMode.full => 'Full recording',
    DurationMode.interval => 'Custom interval',
    DurationMode.bins => 'Fixed-size bins',
    DurationMode.middleTwoMinutes => 'Middle 2 minutes',
  };
}
