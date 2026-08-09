import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'channel_types.dart';
import 'eeg_viewer.dart';
import 'extraction_service.dart';
import 'models.dart';
import 'plot_dialog.dart';
import 'feature_plotter.dart';
import 'recording_loader.dart';
import 'erp_analysis.dart';
import 'topostats_analysis.dart';

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

const _rawExtensions = ['edf', 'set', 'fif', 'vhdr', 'json', 'orb', 'signal'];
const _processedExtensions = ['json', 'fif'];
const _anyInputExtensions = [
  'edf', 'set', 'fif', 'vhdr', 'json', 'orb', 'signal',
];

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
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _borderColor)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: _accentBlue)),
        labelStyle: TextStyle(color: _textMuted),
        isDense: true,
        filled: true,
        fillColor: _bgColor,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? _accentBlue : Colors.transparent,
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
//  The app has exactly two modes, and the split between them is now strict:
//
//    SINGLE RECORDING  — one file at a time, with the waveform viewer.  Every
//                        pipeline stage (Preprocess → Source → Extract → Plot)
//                        has its own Run button so you can stop, inspect the
//                        result in the viewer, and continue.  This is the mode
//                        for exploring data and dialling in settings.
//
//    BATCH             — a queue of many files, no viewer.  Runs the same
//                        stages with the same settings across every file
//                        unattended, and writes per-file outputs plus a pooled
//                        summary.  This is the mode for production runs.
//
//  Both modes bind to a single shared `AnalysisConfig`, so the option sets can
//  never drift apart and settings you tune on one recording carry straight
//  over to the batch queue.
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

  late final TabController _tabs;

  // ── Text controllers (bound to _cfg on change) ──────────────────────────
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController(text: '120');
  final _bin = TextEditingController(text: '60');
  final _epoch = TextEditingController(text: '2');
  final _exclude = TextEditingController(text: 'OBD, HRDT, ARSQ');
  final _preDownsample = TextEditingController(text: '250');
  final _preLow = TextEditingController(text: '0.5');
  final _preHigh = TextEditingController(text: '40');
  final _preNotch = TextEditingController(text: '50');
  final _topoWindows = TextEditingController(text: '10');
  final _smoothing = TextEditingController(text: '25');

  // ══ SINGLE-RECORDING MODE STATE ═════════════════════════════════════════
  //
  // Exactly one recording is under analysis at a time.  Each stage keeps its
  // own output so the viewer can flip between them, but there is no list of
  // unrelated files — that is what Batch mode is for.

  /// Stage 1 input — the raw recording as loaded from disk.
  EegRecording? _raw;

  /// Stage 1 output.
  EegRecording? _preprocessed;

  /// Stage 2 output (eLORETA source projection).
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
  List<EegRecording> get _stageRecordings => [
    for (final r in [_directInput, _source, _preprocessed, _raw])
      ?r,
  ];

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
  double _progress = 0;

  // ── Accordion state ─────────────────────────────────────────────────────
  bool _step1Expanded = true;
  bool _step1OptsExpanded = false;
  bool _step2Expanded = false;
  bool _step3Expanded = true;
  bool _step3FeatExpanded = true;
  bool _step3OtherExpanded = false;
  bool _step4Expanded = false;
  bool _channelsExpanded = false;

  // ── Log panel ───────────────────────────────────────────────────────────
  bool _logVisible = false;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(() => setState(() {}));
    _preLow.addListener(_syncConfigFromControllers);
    _preHigh.addListener(_syncConfigFromControllers);
    _preNotch.addListener(_syncConfigFromControllers);
    _preDownsample.addListener(_syncConfigFromControllers);
    _epoch.addListener(_syncConfigFromControllers);
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
    _cfg
      ..lowHz = double.tryParse(_preLow.text) ?? _cfg.lowHz
      ..highHz = double.tryParse(_preHigh.text) ?? _cfg.highHz
      ..notchHz = double.tryParse(_preNotch.text) ?? _cfg.notchHz
      ..downsampleFreq =
          double.tryParse(_preDownsample.text) ?? _cfg.downsampleFreq
      ..epochSeconds = double.tryParse(_epoch.text) ?? _cfg.epochSeconds
      ..gedaiEpochSeconds = double.tryParse(_epoch.text) ?? _cfg.gedaiEpochSeconds
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

  @override
  void dispose() {
    _tabs.dispose();
    for (final c in [
      _start, _end, _bin, _epoch, _exclude,
      _preDownsample, _preLow, _preHigh, _preNotch,
      _topoWindows, _smoothing,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _log(String value) {
    if (value.isEmpty) return;
    setState(() {
      _logs.add(value);
      if (_logs.length > 400) _logs.removeAt(0);
    });
  }

  PlotOptions get _plotOptions => PlotOptions(
    nTopoWindows: _cfg.nTopoWindows,
    smoothingWindow: _cfg.smoothingWindow,
    epochSizeSeconds: _cfg.epochSeconds,
    segmentByFile: true,
    perFilePlots: _cfg.perFilePlots,
    groupOverlay: _cfg.groupOverlayPlots,
  );

  // ══════════════════════════════════════════════════════════════════════
  //  SINGLE-RECORDING MODE — file loading
  // ══════════════════════════════════════════════════════════════════════

  /// Loads one raw recording and resets the whole pipeline.
  ///
  /// Single-recording mode is deliberately single: picking a new file clears
  /// the previous stage outputs rather than accumulating them, so what the
  /// viewer shows and what the Run buttons operate on are always the same
  /// recording.
  Future<void> _loadRaw() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _rawExtensions,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    try {
      _log('Loading ${_shortName(path)}…');
      final rec = await _loader.load(path);
      setState(() {
        _raw = rec;
        _preprocessed = null;
        _source = null;
        _directInput = null;
        _featuresCsv = null;
        _plotsDir = null;
        _selection = const ViewerSelection.empty();
        _channels = ChannelTypeMap.autoDetect(rec.labels);
      });
      _logChannelDetection();
      _log('✓ Loaded ${_shortName(path)}');
    } catch (e) {
      _log('✗ ERROR ${_shortName(path)}: $e');
    }
  }

  /// Loads a preprocessed file as the Stage 2 input, bypassing Stage 1.
  Future<void> _loadForSourceLocalisation() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _processedExtensions,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    try {
      _log('Loading ${_shortName(path)} into Stage 2…');
      final rec = await _loader.load(path);
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
    final pick = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: _anyInputExtensions,
    );
    if (pick == null || pick.files.isEmpty) return;
    final path = pick.files.first.path;
    if (path == null) return;
    try {
      _log('Loading ${_shortName(path)} into Stage 3…');
      final rec = await _loader.load(path);
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
      _log('  ${_channels.eegCount} EEG, ${nonEeg.length} non-EEG '
          '(${nonEeg.take(8).join(', ')}${nonEeg.length > 8 ? '…' : ''})');
    }
  }

  void _cancel() {
    _service.cancel();
    setState(() => _running = false);
    _log('Operation cancelled by user.');
  }

  void _clearPipeline() {
    if (_running) return;
    setState(() {
      _raw = null;
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
    final input = _raw;
    if (input == null) {
      _log('Load a raw recording first.');
      return;
    }
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save cleaned EEG file',
      fileName: '${_stem(input.path)}_clean.ccseeg.json',
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() {
      _running = true;
      _progress = 0;
      _logVisible = true;
    });
    try {
      final cleaned = await _service.preprocess(
        recording: input,
        outputPath: path.endsWith('.ccseeg.json') ? path : '$path.ccseeg.json',
        selection: _selection,
        options: _cfg.toPreprocessingOptions(
          nonEegChannels: _channels.nonEegChannels,
        ),
        onProgress: (p, m) {
          _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() {
        _preprocessed = cleaned;
        _source = null;
        _directInput = null;
        _channels = _channels.rebaseOnto(cleaned.labels);
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Preprocessed: ${cleaned.path}');
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
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save source localized EEG file',
      fileName: '${_stem(input.path)}_source.ccseeg.json',
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() {
      _running = true;
      _progress = 0;
      _logVisible = true;
    });
    try {
      final sourced = await _service.preprocess(
        recording: input,
        outputPath: path.endsWith('.ccseeg.json') ? path : '$path.ccseeg.json',
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
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save extracted EEG features',
      fileName: '${_stem(input.path)}.features.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (path == null) return;

    setState(() {
      _running = true;
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
        selection: _selection,
        onProgress: (p, m) {
          _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() => _featuresCsv = path);
      _log('✓ Extraction complete: $path');

      if (_cfg.generatePdfReport) {
        await _writeReport(path, input, options);
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
      _log('Run feature extraction first, or use Generate Plots… to pick a CSV.');
      return;
    }
    setState(() {
      _running = true;
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
    if (announce) _log('Generating Topo/Line plots…');
    try {
      final dir = outputDir ?? Directory(csvPaths.first).parent.path;
      final results = await generateFeaturePlotsDetailed(
        csvPaths: csvPaths,
        outputDir: dir,
        options: _plotOptions,
        onProgress: (p, msg) {
          if (msg.isNotEmpty) _log('  [Plots] $msg');
          if (mounted) setState(() => _progress = p);
        },
      );
      final scopes = results.map((r) => r.scope).toSet();
      setState(() => _plotsDir = dir);
      _log('✓ ${results.length} plots across ${scopes.length} '
          '${scopes.length == 1 ? 'recording' : 'recordings'} → $dir');
    } catch (e) {
      _log('⚠ Plotting failed: $e');
    }
  }

  Future<void> _writeReport(
    String csvPath,
    EegRecording rec,
    ExtractionOptions options,
  ) async {
    try {
      final reportPath =
          csvPath.replaceAll(RegExp(r'\.csv$', caseSensitive: false), '_report.pdf');
      final ctx = ReportContext(
        fileName: _shortName(rec.path),
        channelCount: rec.labels.length,
        epochCount: rec.epochCount,
        durationSeconds: rec.durationSeconds,
        sampleRate: rec.sampleRate,
        channelLabels: rec.labels,
        rawPreview: _raw?.preview,
        cleanedPreview: rec.preview,
        sourceLocalized:
            rec.labels.any((l) => l.contains('lh_') || l.contains('rh_')),
        sourceRoiLabels: rec.labels.where((l) => l.contains('_')).toList(),
        prepOptions: _cfg.toPreprocessingOptions(
          nonEegChannels: _channels.nonEegChannels,
        ),
        extractOptions: options,
      );
      await _service.writePdfReport(
        outputPath: reportPath,
        title: 'CCS EEG Feature Report',
        csvPath: csvPath,
        ctx: ctx,
        lines: [
          'Feature CSV: ${_shortName(csvPath)}',
          'Epoch length: ${_cfg.epochSeconds} s',
          'EEG channels: ${_channels.eegCount}',
          if (_channels.nonEegCount > 0)
            'Excluded non-EEG: ${_channels.nonEegChannels.join(', ')}',
        ],
      );
      _log('✓ PDF report: $reportPath');
    } catch (e) {
      _log('⚠ PDF report skipped: $e');
    }
  }

  Future<void> _compileCsv() async {
    final pick = await FilePicker.pickFiles(
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
    final candidates = <String>[
      if (_featuresCsv != null && File(_featuresCsv!).existsSync()) _featuresCsv!,
    ];
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PlotDialog(initialCsvPaths: candidates),
    ));
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
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildSingleRecordingTab(),
                ErpAnalysisView(activeRecording: _activeRecording),
                TopoStatsView(featureFilePaths: _featureFilesForTopoStats),
                _buildBatchTab(),
              ],
            ),
          ),
          _buildLogPanel(),
        ],
      ),
    );
  }

  List<String> get _featureFilesForTopoStats {
    if (_batchFeatOutputs.isNotEmpty) return _batchFeatOutputs;
    if (_featuresCsv != null && File(_featuresCsv!).existsSync()) return [_featuresCsv!];
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

  Widget _buildSingleRecordingTab() {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: Material(
            color: const Color(0xFF0A1628),
            child: Column(
              children: [
                Expanded(child: _buildSingleSidebar()),
                _buildSidebarFooter(),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, color: _borderColor),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: EegViewer(
                  recording: _activeRecording,
                  rawRecording: _raw,
                  allRecordings: _stageRecordings,
                  onSelectRecording: (rec) {
                    if (_running) return;
                    // Stage switching only — the selected recording becomes the
                    // direct analysis input without disturbing stage outputs.
                    setState(() => _directInput = rec == _raw ? null : rec);
                  },
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
            ],
          ),
        ),
      ],
    );
  }

  // ── Top bar ─────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    final onBatch = _tabs.index == 3;
    return Container(
      height: 54,
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
            child: const Text('CCS EEG',
                style: TextStyle(
                    color: _accentBlue,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.2)),
          ),
          const SizedBox(width: 10),
          const Text('Studio',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
          const SizedBox(width: 20),
          SizedBox(
            width: 720,
            child: TabBar(
              controller: _tabs,
              labelPadding: EdgeInsets.zero,
              dividerColor: Colors.transparent,
              indicatorColor: _accentBlue,
              labelColor: Colors.white,
              unselectedLabelColor: _textMuted,
              labelStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              unselectedLabelStyle: const TextStyle(fontSize: 13),
              tabs: const [
                Tab(
                  height: 60,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('1. Preprocess & View'),
                      Text('Raw → Clean Waveforms',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.normal,
                              color: _textMuted)),
                    ],
                  ),
                ),
                Tab(
                  height: 60,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('2. Epoch & ERP Analysis'),
                      Text('Event Waveforms & Stats',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.normal,
                              color: _textMuted)),
                    ],
                  ),
                ),
                Tab(
                  height: 60,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('3. Features & TopoStats'),
                      Text('e-TFCE & FDR Topomaps',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.normal,
                              color: _textMuted)),
                    ],
                  ),
                ),
                Tab(
                  height: 60,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Batch Queue Mode'),
                      Text('Many Files · Unattended',
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.normal,
                              color: _textMuted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (onBatch)
            Text('${_batchPrepFiles.length} queued',
                style: const TextStyle(color: _textMuted, fontSize: 12))
          else if (_activeRecording != null) ...[
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
            icon: Icons.terminal,
            label: 'Log',
            active: _logVisible,
            onTap: () => setState(() => _logVisible = !_logVisible),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _running
                ? null
                : (onBatch ? _addBatchPrepFiles : _loadRaw),
            icon: const Icon(Icons.folder_open, size: 15),
            label: Text(onBatch ? 'Add Files to Queue' : 'Open Recording'),
            style: FilledButton.styleFrom(
              backgroundColor: _accentBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
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
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.check_circle, color: color, size: 13),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: color, fontSize: 12)),
    ]),
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
          color: active ? _accentBlue.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: active ? _accentBlue.withValues(alpha: 0.4) : _borderColor),
        ),
        child: Row(children: [
          Icon(icon, size: 14, color: active ? _accentBlue : _textMuted),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: active ? _accentBlue : _textMuted, fontSize: 12)),
        ]),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Single-recording sidebar
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildSingleSidebar() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 4),
      children: [
        _buildStepCard(
          step: 1,
          icon: Icons.cleaning_services,
          title: 'PREPROCESSING',
          color: _accentPurple,
          expanded: _step1Expanded,
          onToggle: () => setState(() => _step1Expanded = !_step1Expanded),
          completedLabel:
              _preprocessed != null ? '✓ ${_shortName(_preprocessed!.path)}' : null,
          completedColor: _accentGreen,
          children: [_buildStage1Content()],
        ),
        _buildChannelsCard(),
        _buildStepCard(
          step: 2,
          icon: Icons.psychology,
          title: 'SOURCE SPACE',
          color: _accentBlue,
          optional: true,
          expanded: _step2Expanded,
          onToggle: () => setState(() => _step2Expanded = !_step2Expanded),
          completedLabel:
              _source != null ? '✓ ${_shortName(_source!.path)}' : null,
          completedColor: _accentBlue,
          children: [_buildStage2Content()],
        ),
        _buildStepCard(
          step: 3,
          icon: Icons.analytics,
          title: 'FEATURE EXTRACTION',
          color: _accentGreen,
          expanded: _step3Expanded,
          onToggle: () => setState(() => _step3Expanded = !_step3Expanded),
          completedLabel:
              _featuresCsv != null ? '✓ ${_shortName(_featuresCsv!)}' : null,
          completedColor: _accentGreen,
          children: [_buildStage3Content()],
        ),
        _buildStepCard(
          step: 4,
          icon: Icons.stacked_line_chart,
          title: 'PLOTS & REPORT',
          color: _accentAmber,
          expanded: _step4Expanded,
          onToggle: () => setState(() => _step4Expanded = !_step4Expanded),
          completedLabel: _plotsDir != null ? '✓ ${_shortName(_plotsDir!)}/' : null,
          completedColor: _accentAmber,
          children: [_buildStage4Content()],
        ),
      ],
    );
  }

  // ── Stage 1 ─────────────────────────────────────────────────────────────

  Widget _buildStage1Content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _loadButton(
          label: 'Load Raw Recording…',
          color: _accentPurple,
          onPressed: _running ? null : _loadRaw,
        ),
        if (_raw != null) ...[
          const SizedBox(height: 6),
          _recordingChip(_raw!, active: _activeStage == _Stage.raw),
        ],
        const SizedBox(height: 6),
        _subAccordionHeader(
          'Preprocessing Options',
          _step1OptsExpanded,
          () => setState(() => _step1OptsExpanded = !_step1OptsExpanded),
        ),
        if (_step1OptsExpanded) _buildPreprocessingOptions(),
        const SizedBox(height: 8),
        _stageRunButton(
          label: 'Run Preprocessing',
          icon: Icons.cleaning_services,
          color: _accentPurple,
          enabled: !_running && _raw != null,
          onPressed: _runPreprocessing,
        ),
      ]),
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
              child: Row(children: [
                const SizedBox(width: 29),
                const Icon(Icons.tune, size: 13, color: _accentPink),
                const SizedBox(width: 4),
                const Expanded(
                  child: Text('CHANNEL TYPES',
                      style: TextStyle(
                          color: _accentPink,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8)),
                ),
                if (labels.isNotEmpty)
                  Text('${_channels.eegCount}/${labels.length} EEG',
                      style: const TextStyle(color: _textMuted, fontSize: 10)),
                const SizedBox(width: 6),
                Icon(_channelsExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: _textMuted),
              ]),
            ),
          ),
        ),
        if (_channelsExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: labels.isEmpty
                ? const Text('Load a recording to detect channel types.',
                    style: TextStyle(color: _textMuted, fontSize: 11))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                            _channels.hasOverrides
                                ? 'Auto-detected, with your overrides'
                                : 'Auto-detected from channel names',
                            style: const TextStyle(
                                color: _textMuted, fontSize: 10.5),
                          ),
                        ),
                        if (_channels.hasOverrides)
                          TextButton(
                            onPressed: _running
                                ? null
                                : () => setState(
                                    () => _channels = _channels.resetToAuto()),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(46, 24),
                              foregroundColor: _accentAmber,
                            ),
                            child: const Text('Reset',
                                style: TextStyle(fontSize: 10.5)),
                          ),
                      ]),
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
                                  : () => setState(() =>
                                      _channels = _channels.toggleEeg(label)),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                child: Row(children: [
                                  Icon(
                                    isEeg
                                        ? Icons.check_box
                                        : Icons.check_box_outline_blank,
                                    size: 14,
                                    color: isEeg ? _accentGreen : _textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(label,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 11.5,
                                            color: isEeg
                                                ? Colors.white
                                                : _textMuted)),
                                  ),
                                  _badge(kind.label,
                                      isEeg ? _accentGreen : _accentAmber),
                                ]),
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
                            color: _textMuted, fontSize: 10, height: 1.4),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          'Projects scalp potentials to 68 FreeSurfer cortical dipoles via a '
          'regularised eLORETA inverse solution (fsaverage parcellation).',
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
      ]),
    );
  }

  // ── Stage 3 ─────────────────────────────────────────────────────────────

  Widget _buildStage3Content() {
    final resolved = _activeRecording;
    final stage = _activeStage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        resolved != null
            ? _pipelineBadge(
                icon: Icons.play_circle,
                label: switch (stage!) {
                  _Stage.source => 'Source: ${_shortName(resolved.path)}',
                  _Stage.preprocessed =>
                    'Preprocessed: ${_shortName(resolved.path)}',
                  _Stage.direct => 'Direct load: ${_shortName(resolved.path)}',
                  _Stage.raw => 'Raw (not preprocessed): '
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
            label: const Text('Back to pipeline output',
                style: TextStyle(fontSize: 11)),
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
          _check('Remove non-EEG channels + avg ref', _cfg.removeNonEeg,
              (v) => _cfg.removeNonEeg = v),
          _check('Write PDF report', _cfg.generatePdfReport,
              (v) => _cfg.generatePdfReport = v),
          _check('Generate plots after extraction', _cfg.generatePlots,
              (v) => _cfg.generatePlots = v),
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
              : (!_cfg.anyFeature ? 'Select at least one feature family' : null),
        ),
      ]),
    );
  }

  // ── Stage 4 ─────────────────────────────────────────────────────────────

  Widget _buildStage4Content() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            label: const Text('Browse / Plot Other CSVs…',
                style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accentAmber,
              side: BorderSide(color: _accentAmber.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildSidebarFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF060D1A),
        border: Border(top: BorderSide(color: _borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_running) ...[
            _progressBar(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle, size: 16),
                label: const Text('Cancel Operation',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _compileCsv,
                icon: const Icon(Icons.table_chart, size: 14, color: _accentPink),
                label: const Text('Compile CSVs…',
                    style: TextStyle(color: _accentPink, fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accentPink),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _progressBar() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: _progress,
          backgroundColor: const Color(0xFF1E293B),
          color: _accentGreen,
          minHeight: 5,
        ),
      ),
      const SizedBox(height: 4),
      Text('${(_progress * 100).toStringAsFixed(0)}% complete',
          style: const TextStyle(color: _textMuted, fontSize: 11)),
    ],
  );

  // ══════════════════════════════════════════════════════════════════════
  //  Shared option panels — used identically by both modes
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildPreprocessingOptions() {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _check('Downsample to target rate', _cfg.downsample,
              (v) => _cfg.downsample = v),
          if (_cfg.downsample)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: _field(_preDownsample, 'Target Hz', suffix: 'Hz'),
            ),
          _check('Bandpass + notch filter', _cfg.filter, (v) => _cfg.filter = v),
          if (_cfg.filter)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: Row(children: [
                Expanded(child: _field(_preLow, 'HP Hz')),
                const SizedBox(width: 6),
                Expanded(child: _field(_preHigh, 'LP Hz')),
                const SizedBox(width: 6),
                Expanded(child: _field(_preNotch, 'Notch')),
              ]),
            ),
          _check('Bad channel detection', _cfg.badChannels,
              (v) => _cfg.badChannels = v),
          _check('GEDAI denoising', _cfg.gedai, (v) => _cfg.gedai = v),
          _check('Epoch before GEDAI (memory safe)', _cfg.epochBeforeGedai,
              (v) => _cfg.epochBeforeGedai = v),
          _check('Interpolate bad channels', _cfg.interpolate,
              (v) => _cfg.interpolate = v),
        ],
      ),
    );
  }

  Widget _buildEpochingOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subLabel('EPOCH & DURATION'),
        const SizedBox(height: 6),
        _field(_epoch, 'Epoch length (s)', suffix: 's'),
        const SizedBox(height: 6),
        DropdownButtonFormField<DurationMode>(
          value: _cfg.mode,
          dropdownColor: _cardColor,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(labelText: 'Duration mode'),
          items: DurationMode.values
              .map((m) =>
                  DropdownMenuItem(value: m, child: Text(_durationLabel(m))))
              .toList(),
          onChanged: _running ? null : (v) => setState(() => _cfg.mode = v!),
        ),
        if (_cfg.mode == DurationMode.interval) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _field(_start, 'Start s')),
            const SizedBox(width: 8),
            Expanded(child: _field(_end, 'End s')),
          ]),
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
          _subLabel('SPECTRAL'),
          _check('PSD band power', _cfg.psd, (v) => _cfg.psd = v),
          _check('FOOOF / specparam', _cfg.fooof, (v) => _cfg.fooof = v),
          _check('IRASA', _cfg.irasa, (v) => _cfg.irasa = v),
          const SizedBox(height: 6),
          _subLabel('NONLINEAR'),
          _check('Nonlinear dynamics', _cfg.nonlinear, (v) => _cfg.nonlinear = v),
          _check('Autocorrelation window (ACW)', _cfg.acw, (v) => _cfg.acw = v),
          const SizedBox(height: 6),
          _subLabel('MULTIVARIATE CONNECTIVITY'),
          _check('MIC', _cfg.mic, (v) => _cfg.mic = v),
          _check('MIM', _cfg.mim, (v) => _cfg.mim = v),
          _check('Granger Causality', _cfg.gc, (v) => _cfg.gc = v),
          _check('GC-TR', _cfg.gcTr, (v) => _cfg.gcTr = v),
          const SizedBox(height: 6),
          _subLabel('BIVARIATE CONNECTIVITY'),
          _check('Coherence (COH)', _cfg.coh, (v) => _cfg.coh = v),
          _check('PLV', _cfg.plv, (v) => _cfg.plv = v),
          _check('ciPLV', _cfg.ciplv, (v) => _cfg.ciplv = v),
          _check('PLI', _cfg.pli, (v) => _cfg.pli = v),
          _check('wPLI', _cfg.wpli, (v) => _cfg.wpli = v),
          if (!_cfg.anyFeature)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Select at least one family.',
                  style: TextStyle(color: Color(0xFFEF4444), fontSize: 11)),
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
          Row(children: [
            Expanded(child: _field(_topoWindows, 'Topo windows')),
            const SizedBox(width: 8),
            Expanded(child: _field(_smoothing, 'Smoothing (epochs)')),
          ]),
          const SizedBox(height: 4),
          _check('Plot each recording separately', _cfg.perFilePlots,
              (v) => _cfg.perFilePlots = v),
          _check('Group overlay across recordings', _cfg.groupOverlayPlots,
              (v) => _cfg.groupOverlayPlots = v),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  BATCH MODE
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _addBatchPrepFiles() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _rawExtensions,
    );
    if (pick == null) return;
    setState(() {
      for (final f in pick.files) {
        if (f.path != null && !_batchPrepFiles.contains(f.path!)) {
          _batchPrepFiles.add(f.path!);
        }
      }
    });
    _tabs.animateTo(1);
  }

  Widget _buildBatchTab() {
    return Column(
      children: [
        Expanded(
          child: Container(
            color: _bgColor,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Batch Pipeline',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text(
                            'Runs the same settings as Single Recording mode '
                            'across every queued file, unattended. Each file '
                            'gets its own outputs; a pooled summary is written '
                            'alongside.',
                            style: TextStyle(color: _textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (_running)
                      FilledButton.icon(
                        onPressed: _cancel,
                        icon: const Icon(Icons.stop_circle, size: 18),
                        label: const Text('Cancel',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed:
                            _batchPrepFiles.isEmpty ? null : _runFullBatch,
                        icon: const Icon(Icons.play_circle_filled, size: 18),
                        label: const Text('Run All Stages',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13)),
                        style: FilledButton.styleFrom(
                          backgroundColor: _accentBlue,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: _cardColor,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                if (_running) ...[
                  _progressBar(),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildBatchStage1Card()),
                      const SizedBox(width: 12),
                      Expanded(child: _buildBatchStage2Card()),
                      const SizedBox(width: 12),
                      Expanded(child: _buildBatchStage3Card()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildLogPanel(),
      ],
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
          dialogTitle: 'Output directory for preprocessed files');
      if (path != null) setState(() => _batchPrepOutputDir = path);
    },
    onAdd: _addBatchPrepFiles,
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
        _check('Also run source localisation', _cfg.sourceLocalization,
            (v) => _cfg.sourceLocalization = v),
      ],
    ),
    runLabel: 'Run Preprocessing',
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
          dialogTitle: 'Output directory for feature CSVs');
      if (path != null) setState(() => _batchFeatOutputDir = path);
    },
    usePrevious: _batchFeatUsePrep,
    usePreviousLabel: 'Use Stage 1 outputs',
    onUsePreviousChanged: (v) => setState(() => _batchFeatUsePrep = v ?? true),
    onAdd: () async {
      final pick = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: _anyInputExtensions,
      );
      if (pick == null) return;
      setState(() {
        for (final f in pick.files) {
          if (f.path != null && !_batchFeatFiles.contains(f.path!)) {
            _batchFeatFiles.add(f.path!);
          }
        }
      });
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
        _check('Combined CSV across files', _cfg.combinedCsv,
            (v) => _cfg.combinedCsv = v),
        _check('Remove non-EEG channels + avg ref', _cfg.removeNonEeg,
            (v) => _cfg.removeNonEeg = v),
        _check('PDF report per file', _cfg.generatePdfReport,
            (v) => _cfg.generatePdfReport = v),
        const SizedBox(height: 4),
        _field(_exclude, 'Filename exclusions', helper: 'Comma-separated'),
      ],
    ),
    runLabel: 'Run Extraction',
    onRun: _runBatchExtraction,
    runEnabled: (_batchFeatUsePrep
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
          dialogTitle: 'Output directory for plots');
      if (path != null) setState(() => _batchPlotOutputDir = path);
    },
    usePrevious: _batchPlotUseFeat,
    usePreviousLabel: 'Use Stage 2 CSVs',
    onUsePreviousChanged: (v) => setState(() => _batchPlotUseFeat = v ?? true),
    onAdd: () async {
      final pick = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (pick == null) return;
      setState(() {
        for (final f in pick.files) {
          if (f.path != null && !_batchPlotFiles.contains(f.path!)) {
            _batchPlotFiles.add(f.path!);
          }
        }
      });
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
    runLabel: 'Run Plotting',
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
              child: Row(children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (usePrevious != null && onUsePreviousChanged != null) ...[
                    CheckboxListTile(
                      title: Text(usePreviousLabel ?? '',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11)),
                      value: usePrevious,
                      onChanged: _running ? null : onUsePreviousChanged,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(outputLabel,
                      style: const TextStyle(
                          color: _textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Expanded(
                      child: Text(
                        outputDir ?? 'Next to source files',
                        style: TextStyle(
                            color: outputDir == null ? _textMuted : Colors.white,
                            fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open,
                          size: 16, color: _accentBlue),
                      onPressed: _running ? null : onSelectOutput,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                    ),
                  ]),
                  const SizedBox(height: 12),
                  if (!linked) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Files (${files.length})',
                            style: const TextStyle(
                                color: _textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                        Row(children: [
                          TextButton(
                            onPressed: _running ? null : onAdd,
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(40, 24)),
                            child:
                                const Text('Add', style: TextStyle(fontSize: 11)),
                          ),
                          TextButton(
                            onPressed:
                                _running || files.isEmpty ? null : onClear,
                            style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(40, 24)),
                            child: const Text('Clear',
                                style:
                                    TextStyle(color: Colors.red, fontSize: 11)),
                          ),
                        ]),
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
                              child: Text('No files selected',
                                  style: TextStyle(
                                      color: _textMuted, fontSize: 11)))
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              itemCount: files.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(color: _borderColor, height: 1),
                              itemBuilder: (ctx, idx) => Row(children: [
                                Text('${idx + 1}.',
                                    style: const TextStyle(
                                        color: _textMuted, fontSize: 10)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Tooltip(
                                    message: files[idx],
                                    child: Text(_shortName(files[idx]),
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 11),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close,
                                      size: 13, color: _textMuted),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                      minWidth: 20, minHeight: 20),
                                  onPressed:
                                      _running ? null : () => onRemove(idx),
                                ),
                              ]),
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
                      child: Row(children: [
                        Icon(Icons.link, size: 14, color: color),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Uses the previous stage’s outputs.',
                              style: TextStyle(
                                  color: _textMuted,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic)),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  if (options != null) ...[
                    const Text('Stage Options',
                        style: TextStyle(
                            color: _textMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
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
                label: Text(runLabel,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 12)),
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

  /// Stage 1 across the queue.  Returns the files actually written.
  Future<List<String>> _runBatchPreprocessing({bool standalone = true}) async {
    if (_batchPrepFiles.isEmpty) return const [];
    if (standalone) {
      setState(() {
        _running = true;
        _progress = 0;
        _logVisible = true;
      });
    }
    _log('── BATCH PREPROCESSING (${_batchPrepFiles.length} files) ──');
    final written = <String>[];
    for (var i = 0; i < _batchPrepFiles.length; i++) {
      final path = _batchPrepFiles[i];
      _log('[${i + 1}/${_batchPrepFiles.length}] ${_shortName(path)}');
      try {
        final dir = _batchPrepOutputDir ?? File(path).parent.path;
        final outPath = '$dir${Platform.pathSeparator}'
            '${_stem(path)}_clean.ccseeg.json';

        final rec = await _loader.load(path);
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
          onProgress: (p, msg) {
            if (standalone) {
              setState(() =>
                  _progress = (i + p.clamp(0, 1)) / _batchPrepFiles.length);
            }
            if (msg.isNotEmpty) _log('  $msg');
          },
        );

        var finalPath = outPath;
        if (_cfg.sourceLocalization) {
          final srcPath = '$dir${Platform.pathSeparator}'
              '${_stem(path)}_source.ccseeg.json';
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
        _log('✓ Saved: $finalPath');
      } catch (e) {
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
    _log('── PREPROCESSING DONE — ${written.length}/'
        '${_batchPrepFiles.length} succeeded ──');
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
      return '$dir${Platform.pathSeparator}${_stem(path)}$suffix.ccseeg.json';
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
      _log('  Skipped ${inputs.length - kept.length} file(s) by exclusion '
          'pattern (${_cfg.exclusions.join(', ')}).');
    }
    if (kept.isEmpty) {
      _log('✗ Every file was excluded.');
      if (standalone) setState(() => _running = false);
      return const [];
    }

    final outDir = _batchFeatOutputDir ?? File(kept.first).parent.path;
    Directory(outDir).createSync(recursive: true);

    final loaded = <EegRecording>[];
    final perFile = <String, String>{};
    final nonEeg = <String>{};
    for (final path in kept) {
      try {
        final rec = await _loader.load(path);
        loaded.add(rec);
        if (_cfg.perFileCsv) {
          perFile[rec.path] =
              '$outDir${Platform.pathSeparator}${_stem(path)}.features.csv';
        }
        nonEeg.addAll(ChannelTypeMap.autoDetect(rec.labels).nonEegChannels);
      } catch (e) {
        _log('✗ Failed to load ${_shortName(path)}: $e');
      }
    }
    if (loaded.isEmpty) {
      _log('✗ No recordings loaded.');
      if (standalone) setState(() => _running = false);
      return const [];
    }
    if (nonEeg.isNotEmpty) {
      _log('  Non-EEG channels across queue: ${nonEeg.join(', ')}');
    }

    final combinedPath =
        '$outDir${Platform.pathSeparator}Batch_features.csv';

    try {
      final outputs = await _service.run(
        recordings: loaded,
        outputPath: combinedPath,
        epochSeconds: _cfg.epochSeconds,
        selection: const ViewerSelection.empty(),
        perFilePaths: _cfg.perFileCsv ? perFile : null,
        writeCombined: _cfg.combinedCsv,
        options: _cfg.toExtractionOptions(
          nonEegChannels: nonEeg.toList(),
          // Already applied to the input list above.
          applyExclusions: false,
        ),
        onProgress: (p, msg) {
          if (standalone) setState(() => _progress = p);
          if (msg.isNotEmpty) _log('  $msg');
        },
      );

      for (final p in outputs.perFileCsvs) {
        _log('✓ ${_shortName(p)}');
      }
      if (outputs.combinedCsv != null) {
        _log('✓ Combined: ${outputs.combinedCsv}');
      }

      if (_cfg.generatePdfReport) {
        for (var i = 0; i < loaded.length; i++) {
          final csv = i < outputs.perFileCsvs.length
              ? outputs.perFileCsvs[i]
              : outputs.combinedCsv;
          if (csv == null) break;
          await _writeReport(
            csv,
            loaded[i],
            _cfg.toExtractionOptions(nonEegChannels: nonEeg.toList()),
          );
        }
      }

      setState(() {
        _batchFeatOutputs
          ..clear()
          ..addAll(outputs.all);
      });
      _log('── EXTRACTION DONE — ${outputs.all.length} CSV(s) ──');
      return outputs.all;
    } catch (e) {
      _log('✗ Extraction error: $e');
      return const [];
    } finally {
      if (standalone && mounted) {
        setState(() {
          _running = false;
          _progress = 1.0;
        });
      }
    }
  }

  /// Plot inputs: prefer per-file CSVs so each recording is plotted on its own,
  /// falling back to the combined CSV (which the plotter now splits by its
  /// `filename` column anyway).
  List<String> _resolveBatchPlotInputs() {
    if (!_batchPlotUseFeat) return List.of(_batchPlotFiles);
    if (_batchFeatOutputs.isNotEmpty) {
      final perFile =
          _batchFeatOutputs.where((p) => !p.endsWith('Batch_features.csv'));
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
      setState(() {
        _running = true;
        _progress = 0;
        _logVisible = true;
      });
    }
    _log('── BATCH PLOTTING (${inputs.length} CSV(s)) ──');
    try {
      final outDir = _batchPlotOutputDir ?? File(inputs.first).parent.path;
      await _runPlotting(
        csvPaths: inputs,
        announce: false,
        outputDir: outDir,
      );
    } finally {
      if (standalone && mounted) {
        setState(() {
          _running = false;
          _progress = 1.0;
        });
      }
      _log('── PLOTTING DONE ──');
    }
  }

  /// Runs all three stages back to back, feeding each stage the files the
  /// previous one actually produced.
  Future<void> _runFullBatch() async {
    if (_batchPrepFiles.isEmpty) {
      _log('Queue is empty — add files in Stage 1.');
      return;
    }
    setState(() {
      _running = true;
      _progress = 0;
      _logVisible = true;
    });
    _log('══ FULL BATCH PIPELINE — ${_batchPrepFiles.length} files ══');
    try {
      final preprocessed = await _runBatchPreprocessing(standalone: false);
      if (preprocessed.isEmpty) {
        _log('✗ Stage 1 produced nothing — aborting.');
        return;
      }
      setState(() => _progress = 1 / 3);

      _batchFeatUsePrep = true;
      final csvs = await _runBatchExtraction(standalone: false);
      if (csvs.isEmpty) {
        _log('✗ Stage 2 produced nothing — aborting.');
        return;
      }
      setState(() => _progress = 2 / 3);

      _batchPlotUseFeat = true;
      await _runBatchPlotting(standalone: false);
      _log('══ FULL BATCH PIPELINE COMPLETE ══');
    } catch (e) {
      _log('✗ Pipeline error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _progress = 1.0;
        });
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Shared widgets
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildStepCard({
    required int step,
    required IconData icon,
    required String title,
    required Color color,
    bool optional = false,
    required bool expanded,
    required VoidCallback onToggle,
    String? completedLabel,
    required Color completedColor,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: const Color(0xFF0A1628),
          child: InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      border: Border.all(color: color, width: 1.5),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('$step',
                          style: TextStyle(
                              color: color,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Icon(icon, size: 13, color: color),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8)),
                  ),
                  if (optional) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        border:
                            Border.all(color: color.withValues(alpha: 0.45)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text('OPTIONAL',
                          style: TextStyle(
                              color: color.withValues(alpha: 0.7),
                              fontSize: 7.5,
                              letterSpacing: 0.4)),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: _textMuted),
                ],
              ),
            ),
          ),
        ),
        if (completedLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(42, 0, 12, 5),
            child: Row(children: [
              Icon(Icons.check_circle, size: 12, color: completedColor),
              const SizedBox(width: 4),
              Expanded(
                child: Text(completedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: completedColor, fontSize: 10.5)),
              ),
            ]),
          ),
        if (expanded) ...children,
        const Divider(color: _borderColor, height: 1, thickness: 1),
      ],
    );
  }

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
        label: Text(label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF243044),
          disabledForegroundColor: _textMuted,
          padding: const EdgeInsets.symmetric(vertical: 11),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
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
        Row(children: [
          Icon(Icons.graphic_eq,
              color: active ? _accentBlue : _textMuted, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(_shortName(rec.path),
                style: TextStyle(
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    fontSize: 12,
                    color: Colors.white),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          _badge('${rec.labels.length} ch', _accentBlue),
          const SizedBox(width: 4),
          _badge('${rec.sampleRate.toStringAsFixed(0)} Hz', _accentAmber),
          const SizedBox(width: 4),
          _badge('${(rec.durationSeconds / 60).toStringAsFixed(1)} min',
              _accentGreen),
        ]),
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
    child: Text(text,
        style: const TextStyle(color: _textMuted, fontSize: 10.5, height: 1.45)),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? suffix,
    String? helper,
  }) => TextField(
    controller: controller,
    enabled: !_running,
    style: const TextStyle(color: Colors.white, fontSize: 12),
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      helperText: helper,
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
    child: Row(children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 6),
      Expanded(
        child: Text(label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 10.5)),
      ),
    ]),
  );

  Widget _subAccordionHeader(String label, bool expanded, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(expanded ? Icons.expand_less : Icons.chevron_right,
                size: 15, color: _textMuted),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    color: _textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  Widget _subLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 2),
    child: Text(text,
        style: const TextStyle(
            color: _textMuted,
            fontSize: 10,
            letterSpacing: 0.6,
            fontWeight: FontWeight.bold)),
  );

  Widget _check(String text, bool value, void Function(bool) set) =>
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        value: value,
        onChanged: _running ? null : (v) => setState(() => set(v!)),
        title: Text(text,
            style: const TextStyle(fontSize: 12, color: Colors.white)),
      );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(label,
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );

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
              child: Row(children: [
                const Icon(Icons.terminal, size: 13, color: _accentBlue),
                const SizedBox(width: 6),
                const Text('ACTIVITY LOG',
                    style: TextStyle(
                        color: _accentBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _logs.clear()),
                  icon: const Icon(Icons.clear_all, size: 12),
                  label: const Text('Clear', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                      foregroundColor: _textMuted,
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14, color: _textMuted),
                  onPressed: () => setState(() => _logVisible = false),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ]),
            ),
          ),
          const Divider(color: _borderColor, height: 1),
          Expanded(
            child: _logs.isEmpty
                ? const Center(
                    child: Text('No activity yet.',
                        style: TextStyle(color: _textMuted, fontSize: 12)))
                : ListView.builder(
                    reverse: true,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                        child: Text(line,
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: color)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Path helpers ────────────────────────────────────────────────────────

  String _shortName(String path) =>
      path.split(Platform.pathSeparator).last;

  /// Filename without any known recording extension.
  String _stem(String path) => _shortName(path).replaceAll(
        RegExp(r'\.(ccseeg\.json|edf|set|fif|vhdr|json|orb|signal|csv)$',
            caseSensitive: false),
        '',
      );

  String _durationLabel(DurationMode mode) => switch (mode) {
    DurationMode.full => 'Full recording',
    DurationMode.interval => 'Custom interval',
    DurationMode.bins => 'Fixed-size bins',
    DurationMode.middleTwoMinutes => 'Middle 2 minutes',
  };
}
