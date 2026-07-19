import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'eeg_viewer.dart';
import 'extraction_service.dart';
import 'models.dart';
import 'plot_dialog.dart';
import 'feature_plotter.dart';
import 'recording_loader.dart';

// ── Design tokens (ScoringNidra palette) ──────────────────────────────────
const _bgColor = Color(0xFF0F172A);
const _cardColor = Color(0xFF1E293B);
const _accentBlue = Color(0xFF3B82F6);
const _accentGreen = Color(0xFF22C55E);
const _accentAmber = Color(0xFFF59E0B);
const _accentPurple = Color(0xFF7C3AED);
const _textMuted = Color(0xFF94A3B8);
const _borderColor = Color(0x1FFFFFFF);

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

class FeatureHome extends StatefulWidget {
  const FeatureHome({super.key});
  @override
  State<FeatureHome> createState() => _FeatureHomeState();
}

class _FeatureHomeState extends State<FeatureHome> {
  final _loader = RecordingLoader();
  final _service = ExtractionService();

  // Text controllers
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController(text: '120');
  final _bin = TextEditingController(text: '60');
  final _epoch = TextEditingController(text: '2');
  final _exclude = TextEditingController(text: 'OBD, HRDT, ARSQ');
  final _preDownsample = TextEditingController(text: '250');
  final _preLow = TextEditingController(text: '0.5');
  final _preHigh = TextEditingController(text: '40');
  final _preNotch = TextEditingController(text: '50');

  // ── Pipeline file state ─────────────────────────────────────────────────
  // Each step tracks its own input/output independently so the user can load
  // a preprocessed or source file and start from any stage in the pipeline.

  /// Step 1 — raw EEG recordings loaded by the user.
  List<EegRecording> _recordings = [];

  /// Step 1 output — set after a successful preprocess run (also kept in _recordings[0]).
  EegRecording? _preprocessedRecording;

  /// Step 2 input — if the user loads a preprocessed file explicitly for Step 2
  /// (bypassing Step 1).  null means "use _preprocessedRecording".
  EegRecording? _step2Input;

  /// Step 2 output — set after a successful source localisation run.
  EegRecording? _sourceRecording;

  /// Step 3 input — if the user loads a file explicitly for extraction
  /// (bypassing Steps 1 & 2).  null means auto-resolved from pipeline.
  EegRecording? _step3Input;

  /// Resolved extraction input: step3 override > source > preprocessed > raw[0].
  EegRecording? get _resolvedExtractionInput =>
      _step3Input ?? _sourceRecording ?? _step2Input ?? _preprocessedRecording ?? _recordings.firstOrNull;

  /// Raw recording kept for the viewer's raw/cleaned toggle.
  EegRecording? _rawRecording;

  ViewerSelection _selection = const ViewerSelection.empty();
  DurationMode _mode = DurationMode.full;

  // ── Preprocessing flags ──────────────────────────────────────────────────
  bool _preprocessDownsample = true;
  bool _preprocessFilter = true;
  bool _preprocessBadChannels = true;
  bool _preprocessGedai = true;
  bool _preprocessInterpolate = true;
  bool _preprocessEpochBeforeGedai = true;

  // ── Feature flags ────────────────────────────────────────────────────────
  bool _psd = true, _fooof = true, _irasa = true, _nonlinear = true, _acw = true;
  bool _mic = true, _mim = false, _gc = false, _gcTr = false;
  bool _coh = true, _plv = false, _ciplv = false, _pli = false, _wpli = false;
  bool _removeNonEeg = true;
  bool _generatePlots = true;

  bool _running = false;
  double _progress = 0;

  // ── Batch Tab State ──────────────────────────────────────────────────────
  final List<String> _batchPrepFiles = [];
  final List<String> _batchFeatFiles = [];
  final List<String> _batchPlotFiles = [];
  bool _batchFeatUsePrep = true;
  bool _batchPlotUseFeat = true;
  String? _batchPrepOutputDir;
  String? _batchFeatOutputFile;
  String? _batchPlotOutputDir;

  // ── Step panel accordion state ───────────────────────────────────────────
  bool _step1Expanded = true;
  bool _step1OptsExpanded = false; // preprocessing options sub-panel
  bool _step2Expanded = false;
  bool _step3Expanded = true;
  bool _step3FeatExpanded = true;
  bool _step3OtherExpanded = false;

  // ── Log panel ────────────────────────────────────────────────────────────
  bool _logVisible = false;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _preLow.addListener(_onFilterParamChanged);
    _preHigh.addListener(_onFilterParamChanged);
    _preNotch.addListener(_onFilterParamChanged);
  }

  void _onFilterParamChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _preLow.removeListener(_onFilterParamChanged);
    _preHigh.removeListener(_onFilterParamChanged);
    _preNotch.removeListener(_onFilterParamChanged);
    for (final c in [
      _start, _end, _bin, _epoch, _exclude,
      _preDownsample, _preLow, _preHigh, _preNotch,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _log(String value) {
    setState(() {
      _logs.add(value);
      if (_logs.length > 200) _logs.removeAt(0);
    });
  }

  // ── File loading ──────────────────────────────────────────────────────────

  /// Step 1 — Load raw EEG files (EDF, SET, FIF, VHDR).
  Future<void> _loadRaw() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['edf', 'set', 'fif', 'vhdr', 'orb', 'signal'],
    );
    if (pick == null) return;
    final loaded = <EegRecording>[];
    for (final item in pick.files) {
      if (item.path == null) continue;
      try {
        _log('Loading ${item.name}…');
        loaded.add(await _loader.load(item.path!));
        _log('✓ Loaded ${item.name}');
      } catch (e) {
        _log('✗ ERROR ${item.name}: $e');
      }
    }
    if (loaded.isNotEmpty) {
      setState(() {
        _recordings = loaded;
        _preprocessedRecording = null;
        _rawRecording = null;
        _selection = const ViewerSelection.empty();
      });
    }
  }

  /// Step 2 — Load a preprocessed file (.ccseeg.json / .fif) to use as the
  /// input for source localisation (bypasses Step 1).
  Future<void> _loadPreprocessedForStep2() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['json', 'fif'],
    );
    if (pick == null || pick.files.first.path == null) return;
    try {
      final item = pick.files.first;
      _log('Loading ${item.name} for Step 2…');
      final rec = await _loader.load(item.path!);
      setState(() {
        _step2Input = rec;
        _sourceRecording = null;
        _recordings = [rec, ..._recordings];
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Loaded ${item.name} into Step 2');
    } catch (e) {
      _log('✗ ERROR loading for Step 2: $e');
    }
  }

  /// Step 3 — Load any file (preprocessed or source) to use directly as the
  /// extraction input, bypassing both Steps 1 and 2.
  Future<void> _loadForExtraction() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['json', 'fif', 'edf', 'set', 'vhdr', 'orb', 'signal'],
    );
    if (pick == null) return;
    final loaded = <EegRecording>[];
    for (final item in pick.files) {
      if (item.path == null) continue;
      try {
        _log('Loading ${item.name} for extraction…');
        loaded.add(await _loader.load(item.path!));
        _log('✓ Loaded ${item.name}');
      } catch (e) {
        _log('✗ ERROR ${item.name}: $e');
      }
    }
    if (loaded.isNotEmpty) {
      setState(() {
        _step3Input = loaded.first;
        _recordings = [...loaded, ..._recordings];
        _selection = const ViewerSelection.empty();
      });
    }
  }

  /// Legacy combined open — used by the top-bar button (loads any supported format).
  Future<void> _open() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['edf', 'set', 'fif', 'vhdr', 'json', 'orb', 'signal'],
    );
    if (pick == null) return;
    final loaded = <EegRecording>[];
    for (final item in pick.files) {
      if (item.path == null) continue;
      try {
        _log('Loading ${item.name}…');
        loaded.add(await _loader.load(item.path!));
        _log('✓ Loaded ${item.name}');
      } catch (e) {
        _log('✗ ERROR ${item.name}: $e');
      }
    }
    if (loaded.isNotEmpty) {
      setState(() {
        _recordings = loaded;
        _rawRecording = null;
        _selection = const ViewerSelection.empty();
      });
    }
  }




  // ── Preprocessing ─────────────────────────────────────────────────────────

  Future<void> _preprocessCurrent() async {
    if (_recordings.isEmpty) { _log('Select a recording first.'); return; }
    final input = _recordings.first;
    final defaultName =
        '${input.path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.(edf|set|vhdr|ccseeg\.json)$', caseSensitive: false), '')}_clean.ccseeg.json';
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save cleaned EEG file',
      fileName: defaultName,
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() { _running = true; _progress = 0; });
    try {
      final cleaned = await _service.preprocess(
        recording: input,
        outputPath: path.endsWith('.ccseeg.json') ? path : '$path.ccseeg.json',
        selection: _selection,
        options: PreprocessingOptions(
          downsample: _preprocessDownsample,
          downsampleFreq: double.tryParse(_preDownsample.text) ?? 250,
          filter: _preprocessFilter,
          lowHz: double.tryParse(_preLow.text) ?? 0.5,
          highHz: double.tryParse(_preHigh.text) ?? 40,
          notchHz: double.tryParse(_preNotch.text) ?? 50,
          badchannel: _preprocessBadChannels,
          gedai: _preprocessGedai,
          interpolate: _preprocessInterpolate,
          gedaiEpochSeconds: double.tryParse(_epoch.text) ?? 1,
          gedaiThreshold: 'auto',
          sourceLocalization: false,
          epochBeforeGedai: _preprocessEpochBeforeGedai,
        ),
        onProgress: (p, m) {
          if (m.isNotEmpty) _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() {
        _preprocessedRecording = cleaned;  // track step 1 output
        _recordings = [cleaned, ..._recordings.where((r) => r != cleaned)];
        _rawRecording = _recordings.firstWhere((r) => r != cleaned, orElse: () => cleaned);
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Preprocessed: ${cleaned.path}');
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runSourceLocalization() async {
    if (_recordings.isEmpty) { _log('Select a recording first.'); return; }
    final input = _recordings.first;
    final defaultName =
        '${input.path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.(edf|set|vhdr|ccseeg\.json)$', caseSensitive: false), '')}_source.ccseeg.json';
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save source localized EEG file',
      fileName: defaultName,
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (path == null) return;
    setState(() { _running = true; _progress = 0; });
    try {
      final sourced = await _service.preprocess(
        recording: input,
        outputPath: path.endsWith('.ccseeg.json') ? path : '$path.ccseeg.json',
        selection: _selection,
        options: const PreprocessingOptions(
          downsample: false,
          downsampleFreq: 250,
          filter: false,
          lowHz: 0.5,
          highHz: 40,
          notchHz: 50,
          badchannel: false,
          gedai: false,
          interpolate: false,
          gedaiEpochSeconds: 1,
          gedaiThreshold: 'auto',
          sourceLocalization: true,
          epochBeforeGedai: false,
        ),
        onProgress: (p, m) {
          if (m.isNotEmpty) _log(m);
          setState(() => _progress = p);
        },
      );
      setState(() {
        _sourceRecording = sourced;    // track step 2 output
        _recordings = [sourced, ..._recordings.where((r) => r != sourced)];
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Source localisation complete: ${sourced.path}');
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _cancel() {
    _service.cancel();
    setState(() {
      _running = false;
    });
    _log('Operation cancelled by user.');
  }

  void _clearFiles() {
    if (_running) return;
    setState(() {
      _recordings = [];
      _rawRecording = null;
      _preprocessedRecording = null;
      _step2Input = null;
      _sourceRecording = null;
      _step3Input = null;
      _selection = const ViewerSelection.empty();
    });
    _log('Cleared all pipeline files.');
  }

  // ── Feature extraction ─────────────────────────────────────────────────────

  Future<void> _run() async {
    final input = _resolvedExtractionInput;
    if (input == null) { _log('Load a file before running extraction.'); return; }
    if (![_psd, _fooof, _irasa, _nonlinear, _acw,
          _mic || _mim || _gc || _gcTr || _coh || _plv || _ciplv || _pli || _wpli]
        .any((v) => v)) {
      _log('Select at least one feature family.');
      return;
    }
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save extracted EEG features',
      fileName: 'CCS_EEG_features.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (path == null) return;
    final options = ExtractionOptions(
      mode: _mode,
      startSeconds: double.tryParse(_start.text) ?? 0,
      endSeconds: double.tryParse(_end.text) ?? 120,
      binSeconds: double.tryParse(_bin.text) ?? 60,
      psd: _psd, fooof: _fooof, irasa: _irasa, nonlinear: _nonlinear, acw: _acw,
      connectivity: _mic || _mim || _gc || _gcTr || _coh || _plv || _ciplv || _pli || _wpli,
      mic: _mic, mim: _mim, gc: _gc, gcTr: _gcTr,
      coh: _coh, plv: _plv, ciplv: _ciplv, pli: _pli, wpli: _wpli,
      removeNonEeg: _removeNonEeg,
      exclusions: _exclude.text.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(),
    );
    final kept = [input]
        .where((r) => !options.exclusions.any((x) => r.path.contains(x)))
        .toList();
    setState(() { _running = true; _progress = 0; _logVisible = true; });
    try {
      await _service.run(
        recordings: kept, outputPath: path, options: options,
        epochSeconds: double.tryParse(_epoch.text) ?? 2,
        selection: _selection,
        onProgress: (p, m) {
          if (m.isNotEmpty) _log(m);
          setState(() => _progress = p);
        },
      );
      _log('✓ Extraction complete: $path');
      if (_generatePlots) {
        _log('Generating Topo/Line plots...');
        try {
          final outDir = Directory(path).parent.path;
          final savedPlots = await generateFeaturePlots(
            csvPaths: [path],
            outputDir: outDir,
            options: PlotOptions(
              nTopoWindows: 10,
              smoothingWindow: 25,
              epochSizeSeconds: double.tryParse(_epoch.text) ?? 2.0,
            ),
            onProgress: (p, msg) => _log('  [Plotting] $msg'),
          );
          _log('✓ Generated ${savedPlots.length} feature plots in $outDir');
        } catch (e) {
          _log('⚠ Plotting failed: $e');
        }
      }
      // PDF report — separate try so a write failure doesn't shadow the extraction success
      try {
        final reportPath = path.replaceAll(RegExp(r'\.csv$', caseSensitive: false), '_report.pdf');

        // Build ReportContext from current UI state so the PDF has full metadata
        final rec = kept.isNotEmpty ? kept.first : input;
        final rawRec = _rawRecording;
        final ctx = ReportContext(
          fileName: rec.path.split(Platform.pathSeparator).last,
          channelCount: rec.labels.length,
          epochCount: rec.epochCount,
          durationSeconds: rec.durationSeconds,
          sampleRate: rec.sampleRate,
          channelLabels: rec.labels,
          rawPreview:     rawRec?.preview,
          cleanedPreview: rec.preview,
          sourceLocalized: rec.labels.any((l) => l.contains('lh_') || l.contains('rh_')),
          sourceRoiLabels: rec.labels.where((l) => l.contains('_')).toList(),
          prepOptions: PreprocessingOptions(
            downsample: _preprocessDownsample,
            downsampleFreq: double.tryParse(_preDownsample.text) ?? 250,
            filter: _preprocessFilter,
            lowHz: double.tryParse(_preLow.text) ?? 0.5,
            highHz: double.tryParse(_preHigh.text) ?? 40,
            notchHz: double.tryParse(_preNotch.text) ?? 50,
            badchannel: _preprocessBadChannels,
            gedai: _preprocessGedai,
            interpolate: _preprocessInterpolate,
            gedaiEpochSeconds: double.tryParse(_epoch.text) ?? 1,
            gedaiThreshold: 'auto',
            sourceLocalization: false,
            epochBeforeGedai: _preprocessEpochBeforeGedai,
          ),
          extractOptions: options,
        );

        // We need to re-read the row count from the written CSV
        // (rows variable is not available here; ctx.epochCount is best estimate)
        await _service.writePdfReport(
          outputPath: reportPath,
          title: 'CCS EEG Feature Report',
          csvPath: path,
          ctx: ctx,
          lines: [
            'Feature CSV: ${path.split('/').last}',
            'Files analysed: ${kept.length}',
            'Epoch length: ${_epoch.text} s',
          ],
        );
        _log('✓ PDF report: $reportPath');
      } catch (e) {
        _log('⚠ PDF report skipped: $e');
      }
    } catch (e) {
      _log('✗ ERROR: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _compileCsv() async {
    final pick = await FilePicker.pickFiles(allowMultiple: true, type: FileType.custom, allowedExtensions: ['csv']);
    if (pick == null) return;
    final out = await FilePicker.saveFile(dialogTitle: 'Save compiled CSV', fileName: 'CCS_EEG_compiled_features.csv', allowedExtensions: ['csv'], type: FileType.custom);
    if (out == null) return;
    final inputs = pick.files.map((f) => f.path).whereType<String>().toList();
    await _service.compileCsvFiles(inputs, out);
    _log('✓ Compiled CSV: $out');
  }

  /// Opens the feature plot dialog, pre-populated with any feature CSVs that
  /// exist alongside the currently loaded recording paths.
  void _openPlotDialog() {
    // Try to pre-populate with .features.csv files from the loaded recordings.
    final candidates = <String>[];
    for (final rec in _recordings) {
      final base = rec.path.replaceAll(
          RegExp(r'\.(edf|set|fif|vhdr|fdt|json|orb|signal)$',
              caseSensitive: false),
          '');
      final csv = '$base.features.csv';
      if (File(csv).existsSync()) candidates.add(csv);
    }

    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PlotDialog(initialCsvPaths: candidates),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  // Tab 1: Interactive Analysis
                  Row(
                    children: [
                      // ── Left sidebar ───────────────────────────────────────
                      SizedBox(
                        width: 290,
                        child: Material(
                          color: const Color(0xFF0A1628),
                          child: Column(
                            children: [
                              Expanded(child: _buildSidebar()),
                              _buildRunButtons(),
                            ],
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1, color: _borderColor),
                      // ── Right: EEG Viewer ──────────────────────────────────
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: EegViewer(
                                recording: _resolvedExtractionInput ?? (_recordings.isEmpty ? null : _recordings.first),
                                rawRecording: _rawRecording,
                                allRecordings: _recordings,
                                onSelectRecording: (rec) {
                                  if (_running) return;
                                  setState(() {
                                    _recordings.remove(rec);
                                    _recordings.insert(0, rec);
                                  });
                                },
                                selection: _selection,
                                onSelectionChanged: (v) => setState(() => _selection = v),
                                filterEnabled: _preprocessFilter,
                                lowHz: double.tryParse(_preLow.text) ?? 0.5,
                                highHz: double.tryParse(_preHigh.text) ?? 40.0,
                                notchHz: double.tryParse(_preNotch.text) ?? 50.0,
                              ),
                            ),
                            // ── Collapsible log panel ──────────────────────
                            _buildLogPanel(),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Tab 2: Batch Analysis Tab
                  _buildBatchAnalysisTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Container(
      height: 54,
      color: const Color(0xFF060D1A),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Logo
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _accentBlue.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _accentBlue.withOpacity(0.4)),
            ),
            child: const Text('CCS EEG',
                style: TextStyle(color: _accentBlue, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2)),
          ),
          const SizedBox(width: 10),
          const Text('Studio', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
          const SizedBox(width: 20),
          const SizedBox(
            width: 380,
            child: TabBar(
              dividerColor: Colors.transparent,
              indicatorColor: _accentBlue,
              labelColor: Colors.white,
              unselectedLabelColor: _textMuted,
              labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              unselectedLabelStyle: TextStyle(fontSize: 13),
              tabs: [
                Tab(text: 'Interactive Analysis'),
                Tab(text: 'Batch Analysis'),
              ],
            ),
          ),
          const Spacer(),
          // File status
          if (_recordings.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _accentGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentGreen.withOpacity(0.4)),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle, color: _accentGreen, size: 13),
                const SizedBox(width: 5),
                Text('${_recordings.length} file${_recordings.length > 1 ? 's' : ''} loaded',
                    style: const TextStyle(color: _accentGreen, fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Clear loaded files',
              onPressed: _running ? null : _clearFiles,
              icon: const Icon(Icons.close, size: 16, color: _textMuted),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
            const SizedBox(width: 8),
          ],
          // Log toggle
          _topBarButton(
            icon: Icons.terminal,
            label: 'Log',
            active: _logVisible,
            onTap: () => setState(() => _logVisible = !_logVisible),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _running ? null : _open,
            icon: const Icon(Icons.folder_open, size: 15),
            label: const Text('Open EEG / Processed'),
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
          color: active ? _accentBlue.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? _accentBlue.withOpacity(0.4) : _borderColor),
        ),
        child: Row(children: [
          Icon(icon, size: 14, color: active ? _accentBlue : _textMuted),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: active ? _accentBlue : _textMuted, fontSize: 12)),
        ]),
      ),
    );
  }

  // ── Sidebar ───────────────────────────────────────────────────────────────
  //
  //  The left panel is organised as three numbered workflow steps:
  //
  //    ① PREPROCESSING   — load raw EEG, clean + artefact-reject, save output
  //    ② SOURCE SPACE    — eLORETA projection to 68 cortical ROIs (optional)
  //    ③ FEATURE EXTRACTION — epoch, select features, run Rust engine
  //
  //  Each step has its own "Load" button, so the user can enter the pipeline
  //  at any stage (e.g. load a previously-saved preprocessed file into Step 2
  //  or load a source file directly into Step 3 and skip the earlier steps).
  //
  // ────────────────────────────────────────────────────────────────────────────────

  Widget _buildSidebar() {
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
          completedLabel: _preprocessedRecording != null
              ? '\u2713 ${_shortName(_preprocessedRecording!.path)}'
              : null,
          completedColor: _accentGreen,
          children: [_buildStep1Content()],
        ),
        _buildStepCard(
          step: 2,
          icon: Icons.psychology,
          title: 'SOURCE SPACE',
          color: _accentBlue,
          optional: true,
          expanded: _step2Expanded,
          onToggle: () => setState(() => _step2Expanded = !_step2Expanded),
          completedLabel: _sourceRecording != null
              ? '\u2713 ${_shortName(_sourceRecording!.path)}'
              : null,
          completedColor: _accentBlue,
          children: [_buildStep2Content()],
        ),
        _buildStepCard(
          step: 3,
          icon: Icons.analytics,
          title: 'FEATURE EXTRACTION',
          color: _accentGreen,
          expanded: _step3Expanded,
          onToggle: () => setState(() => _step3Expanded = !_step3Expanded),
          completedLabel: null,
          completedColor: _accentGreen,
          children: [_buildStep3Content()],
        ),
      ],
    );
  }

  // ── Step card builder ──────────────────────────────────────────────────────

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
                    width: 22, height: 22,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      border: Border.all(color: color, width: 1.5),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('$step',
                          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Icon(icon, size: 13, color: color),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: color, fontSize: 11,
                            fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                  ),
                  if (optional) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(color: color.withValues(alpha: 0.45)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text('OPTIONAL',
                          style: TextStyle(
                              color: color.withValues(alpha: 0.7),
                              fontSize: 7.5, letterSpacing: 0.4)),
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

  // ── Step 1 content ─────────────────────────────────────────────────────────

  Widget _buildStep1Content() {
    final rawFiles = _recordings
        .where((r) => r != _preprocessedRecording && r != _sourceRecording && r != _step2Input && r != _step3Input)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _running ? null : _loadRaw,
            icon: const Icon(Icons.folder_open, size: 14),
            label: const Text('Load Raw EEG Files\u2026', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accentPurple,
              side: BorderSide(color: _accentPurple.withValues(alpha: 0.55)),
              padding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
        if (rawFiles.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final rec in rawFiles.take(3)) _fileChip(rec),
          if (rawFiles.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text('+${rawFiles.length - 3} more files',
                  style: const TextStyle(color: _textMuted, fontSize: 11)),
            ),
        ],
        const SizedBox(height: 6),
        _subAccordionHeader(
          'Preprocessing Options',
          _step1OptsExpanded,
          () => setState(() => _step1OptsExpanded = !_step1OptsExpanded),
        ),
        if (_step1OptsExpanded) _buildPreprocessingOptions(),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: (_running || rawFiles.isEmpty) ? null : _preprocessCurrent,
            icon: const Icon(Icons.cleaning_services, size: 14),
            label: const Text('Preprocess & Save\u2026',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accentPurple,
              side: BorderSide(color: _accentPurple.withValues(alpha: 0.7)),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Step 2 content ─────────────────────────────────────────────────────────

  Widget _buildStep2Content() {
    final effectiveInput = _step2Input ?? _preprocessedRecording;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        effectiveInput != null
            ? _pipelineBadge(
                icon: Icons.arrow_right,
                label: _step2Input != null
                    ? 'Loaded: ${_shortName(effectiveInput.path)}'
                    : 'Using Step 1 output: ${_shortName(effectiveInput.path)}',
                color: _step2Input != null ? _accentAmber : _accentGreen,
              )
            : _pipelineBadge(
                icon: Icons.warning_amber,
                label: 'No input \u2014 run Step 1 or load a preprocessed file',
                color: _textMuted,
              ),
        const SizedBox(height: 7),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _running ? null : _loadPreprocessedForStep2,
            icon: const Icon(Icons.upload_file, size: 14),
            label: const Text('Load Preprocessed File\u2026', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accentBlue,
              side: BorderSide(color: _accentBlue.withValues(alpha: 0.55)),
              padding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _accentBlue.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _accentBlue.withValues(alpha: 0.25)),
          ),
          child: const Text(
            'Projects scalp potentials to 68 FreeSurfer cortical dipoles '
            'via regularised eLORETA inverse solution (fsaverage parcellation).',
            style: TextStyle(color: _textMuted, fontSize: 10.5, height: 1.45),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: (_running || effectiveInput == null) ? null : _runSourceLocalization,
            icon: const Icon(Icons.psychology, size: 14),
            label: const Text('Run Source Localisation\u2026',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _accentBlue,
              side: BorderSide(color: _accentBlue.withValues(alpha: 0.7)),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Step 3 content ─────────────────────────────────────────────────────────

  Widget _buildStep3Content() {
    final resolved = _resolvedExtractionInput;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        resolved != null
            ? _pipelineBadge(
                icon: Icons.play_circle,
                label: resolved == _sourceRecording
                    ? 'Source: ${_shortName(resolved.path)}'
                    : resolved == _preprocessedRecording
                        ? 'Preprocessed: ${_shortName(resolved.path)}'
                        : resolved == _step3Input
                            ? 'Direct load: ${_shortName(resolved.path)}'
                            : 'Raw: ${_shortName(resolved.path)}',
                color: resolved == _sourceRecording
                    ? _accentBlue
                    : resolved == _preprocessedRecording
                        ? _accentGreen
                        : _accentAmber,
              )
            : _pipelineBadge(
                icon: Icons.warning_amber,
                label: 'No file loaded \u2014 use Steps 1 / 2 or load directly',
                color: _textMuted,
              ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _running ? null : _loadForExtraction,
            icon: const Icon(Icons.folder_open, size: 14),
            label: const Text('Load File Directly\u2026', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _textMuted,
              side: BorderSide(color: _textMuted.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _subLabel('EPOCH & DURATION'),
        const SizedBox(height: 6),
        TextField(
          controller: _epoch,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(labelText: 'Epoch length (s)', suffixText: 's'),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<DurationMode>(
          value: _mode,
          dropdownColor: _cardColor,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(labelText: 'Duration mode'),
          items: DurationMode.values
              .map((m) => DropdownMenuItem(value: m, child: Text(_durationLabel(m))))
              .toList(),
          onChanged: _running ? null : (v) => setState(() => _mode = v!),
        ),
        if (_mode == DurationMode.interval) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: TextField(controller: _start, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'Start s'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _end, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'End s'))),
          ]),
        ],
        if (_mode == DurationMode.bins) ...[
          const SizedBox(height: 6),
          TextField(controller: _bin, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'Bin size (s)', suffixText: 's')),
        ],
        const SizedBox(height: 10),
        _subAccordionHeader(
          'Feature Families',
          _step3FeatExpanded,
          () => setState(() => _step3FeatExpanded = !_step3FeatExpanded),
        ),
        if (_step3FeatExpanded) _buildFeaturesSection(),
        const SizedBox(height: 4),
        _subAccordionHeader(
          'Other Options',
          _step3OtherExpanded,
          () => setState(() => _step3OtherExpanded = !_step3OtherExpanded),
        ),
        if (_step3OtherExpanded) ...[
          const SizedBox(height: 4),
          _sidebarCheck('Remove non-EEG channels + avg ref', _removeNonEeg,
              (v) => _removeNonEeg = v),
          const SizedBox(height: 4),
          _sidebarCheck('Generate Topo/Line plots', _generatePlots,
              (v) => _generatePlots = v),
          const SizedBox(height: 4),
          TextField(
            controller: _exclude,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'Filename exclusions',
              helperText: 'Comma-separated',
              helperStyle: TextStyle(color: _textMuted, fontSize: 10),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ]),
    );
  }

  Widget _fileChip(EegRecording rec) {
    final name = rec.path.split(Platform.pathSeparator).last;
    final isActive = _recordings.isNotEmpty && _recordings.first == rec;
    return GestureDetector(
      onTap: () {
        if (_running) return;
        setState(() {
          _recordings.remove(rec);
          _recordings.insert(0, rec);
        });
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isActive ? _accentBlue.withOpacity(0.15) : _cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isActive ? _accentBlue : _borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.graphic_eq, color: isActive ? _accentBlue : _textMuted, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(name,
                    style: TextStyle(fontWeight: isActive ? FontWeight.w700 : FontWeight.w600, fontSize: 12, color: Colors.white),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              _badge('${rec.labels.length} ch', _accentBlue),
              const SizedBox(width: 4),
              _badge('${rec.sampleRate.toStringAsFixed(0)} Hz', _accentAmber),
              const SizedBox(width: 4),
              _badge('${(rec.durationSeconds / 60).toStringAsFixed(1)} min', _accentGreen),
            ]),
          ],
        ),
      ),
    );
  }

  /// Inline preprocessing options used inside _buildStep1Content().
  Widget _buildPreprocessingOptions() {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sidebarCheck('Downsample to target rate', _preprocessDownsample, (v) => _preprocessDownsample = v),
          if (_preprocessDownsample)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: TextField(
                controller: _preDownsample,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(labelText: 'Target Hz', suffixText: 'Hz'),
              ),
            ),
          _sidebarCheck('Bandpass + notch filter', _preprocessFilter, (v) => _preprocessFilter = v),
          if (_preprocessFilter)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: Row(children: [
                Expanded(child: TextField(controller: _preLow, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'HP Hz'))),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: _preHigh, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'LP Hz'))),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: _preNotch, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'Notch'))),
              ]),
            ),
          _sidebarCheck('Bad channel detection', _preprocessBadChannels, (v) => _preprocessBadChannels = v),
          _sidebarCheck('GEDAI denoising', _preprocessGedai, (v) => _preprocessGedai = v),
          _sidebarCheck('Epoch before GEDAI (memory safe)', _preprocessEpochBeforeGedai, (v) => _preprocessEpochBeforeGedai = v),
          _sidebarCheck('Interpolate bad channels', _preprocessInterpolate, (v) => _preprocessInterpolate = v),
        ],
      ),
    );
  }

  Widget _buildFeaturesSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _subLabel('SPECTRAL'),
          _sidebarCheck('PSD band power', _psd, (v) => _psd = v),
          _sidebarCheck('FOOOF / specparam', _fooof, (v) => _fooof = v),
          _sidebarCheck('IRASA', _irasa, (v) => _irasa = v),
          const SizedBox(height: 6),
          _subLabel('NONLINEAR'),
          _sidebarCheck('Nonlinear dynamics', _nonlinear, (v) => _nonlinear = v),
          _sidebarCheck('Autocorrelation window (ACW)', _acw, (v) => _acw = v),
          const SizedBox(height: 6),
          _subLabel('MULTIVARIATE CONNECTIVITY'),
          _sidebarCheck('MIC', _mic, (v) => _mic = v),
          _sidebarCheck('MIM', _mim, (v) => _mim = v),
          _sidebarCheck('Granger Causality', _gc, (v) => _gc = v),
          _sidebarCheck('GC-TR', _gcTr, (v) => _gcTr = v),
          const SizedBox(height: 6),
          _subLabel('BIVARIATE CONNECTIVITY'),
          _sidebarCheck('Coherence (COH)', _coh, (v) => _coh = v),
          _sidebarCheck('PLV', _plv, (v) => _plv = v),
          _sidebarCheck('ciPLV', _ciplv, (v) => _ciplv = v),
          _sidebarCheck('PLI', _pli, (v) => _pli = v),
          _sidebarCheck('wPLI', _wpli, (v) => _wpli = v),
        ],
      ),
    );
  }

  // ── Run buttons (sidebar bottom bar) ───────────────────────────────────────


  Widget _buildRunButtons() {
    final hasInput = _resolvedExtractionInput != null;
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
            // Progress bar
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
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle, size: 16),
                label: const Text('Cancel Operation', style: TextStyle(fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ] else ...[
            // Compile CSVs
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _compileCsv,
                icon: const Icon(Icons.table_chart, size: 14, color: Color(0xFFA855F7)),
                label: const Text('Compile CSV Batch', style: TextStyle(color: Color(0xFFA855F7), fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFA855F7)),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Generate Plots
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _running ? null : _openPlotDialog,
                icon: const Icon(Icons.stacked_line_chart, size: 14, color: Color(0xFF22C55E)),
                label: const Text('Generate Plots…', style: TextStyle(color: Color(0xFF22C55E), fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF22C55E)),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Run extraction
            Tooltip(
              message: hasInput ? '' : 'Load a file in Step 1, 2, or 3 to enable extraction',
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: hasInput ? _run : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('▶  Run Extraction',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  style: FilledButton.styleFrom(
                    backgroundColor: hasInput ? _accentGreen : const Color(0xFF1E293B),
                    foregroundColor: hasInput ? Colors.black : _textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Log panel ─────────────────────────────────────────────────────────────

  Widget _buildLogPanel() {
    if (!_logVisible) return const SizedBox.shrink();
    return Container(
      height: 160,
      decoration: const BoxDecoration(
        color: Color(0xFF060D1A),
        border: Border(top: BorderSide(color: _borderColor)),
      ),
      child: Column(
        children: [
          // Log header
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 13, color: _accentBlue),
                const SizedBox(width: 6),
                const Text('ACTIVITY LOG',
                    style: TextStyle(color: _accentBlue, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _logs.clear()),
                  icon: const Icon(Icons.clear_all, size: 12),
                  label: const Text('Clear', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(foregroundColor: _textMuted, minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 14, color: _textMuted),
                  onPressed: () => setState(() => _logVisible = false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
          const Divider(color: _borderColor, height: 1),
          Expanded(
            child: _logs.isEmpty
                ? const Center(child: Text('No activity yet.', style: TextStyle(color: _textMuted, fontSize: 12)))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemCount: _logs.length,
                    itemBuilder: (context, i) {
                      final line = _logs[_logs.length - 1 - i];
                      Color color = const Color(0xFF94A3B8);
                      if (line.startsWith('✗') || line.contains('ERROR')) color = const Color(0xFFEF4444);
                      else if (line.startsWith('✓')) color = _accentGreen;
                      else if (line.startsWith('⚠')) color = _accentAmber;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(line,
                            style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Shared helpers ───────────────────────────────────────────────────────────────

  /// Short display name from a full path.
  String _shortName(String path) => path.split(Platform.pathSeparator).last;

  /// Coloured status badge shown inside step cards (e.g. "Using Step 1 output").
  Widget _pipelineBadge({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
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
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 10.5)),
          ),
        ],
      ),
    );
  }

  /// Small toggle row used for sub-sections inside step cards.
  Widget _subAccordionHeader(String label, bool expanded, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
                expanded ? Icons.expand_less : Icons.chevron_right,
                size: 15,
                color: _textMuted),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    color: _textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }



  Widget _subLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 2),
    child: Text(text, style: const TextStyle(color: _textMuted, fontSize: 10, letterSpacing: 0.6, fontWeight: FontWeight.bold)),
  );

  Widget _sidebarCheck(String text, bool value, void Function(bool) set) =>
      CheckboxListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 0),
        visualDensity: VisualDensity.compact,
        value: value,
        onChanged: _running ? null : (v) => setState(() => set(v!)),
        title: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
      );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );

  String _durationLabel(DurationMode mode) => switch (mode) {
    DurationMode.full => 'Full recording',
    DurationMode.interval => 'Custom interval',
    DurationMode.bins => 'Fixed-size bins',
    DurationMode.middleTwoMinutes => 'Middle 2 minutes',
  };

  // ── Batch Tab Implementation ──────────────────────────────────────────────

  Widget _buildBatchAnalysisTab() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Batch Analysis Pipeline',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Configure and run preprocessing, feature extraction, and plotting in stages or in sequence.',
                      style: TextStyle(color: _textMuted, fontSize: 12)),
                ],
              ),
              FilledButton.icon(
                onPressed: _running ? null : _runUnifiedSequentialPipeline,
                icon: const Icon(Icons.play_circle_filled, size: 18),
                label: const Text('Run Stages 1-3 in Sequence',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                style: FilledButton.styleFrom(
                  backgroundColor: _accentBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_running) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: const Color(0xFF1E293B),
                color: _accentGreen,
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 4),
            Text('${(_progress * 100).toStringAsFixed(0)}% complete',
                style: const TextStyle(color: _textMuted, fontSize: 11)),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildBatchStageCard(
                    title: 'Stage 1: Preprocessing',
                    icon: Icons.cleaning_services,
                    color: _accentPurple,
                    files: _batchPrepFiles,
                    outputDir: _batchPrepOutputDir,
                    onSelectOutputDir: () async {
                      final path = await FilePicker.getDirectoryPath(dialogTitle: 'Select Output Directory for Preprocessing');
                      if (path != null) setState(() => _batchPrepOutputDir = path);
                    },
                    onAdd: () async {
                      final pick = await FilePicker.pickFiles(
                        allowMultiple: true,
                        type: FileType.custom,
                        allowedExtensions: ['edf', 'set', 'fif', 'vhdr', 'orb', 'signal'],
                      );
                      if (pick != null) {
                        setState(() {
                          for (final f in pick.files) {
                            if (f.path != null && !_batchPrepFiles.contains(f.path!)) {
                              _batchPrepFiles.add(f.path!);
                            }
                          }
                        });
                      }
                    },
                    onClear: () => setState(() => _batchPrepFiles.clear()),
                    onRemove: (idx) => setState(() => _batchPrepFiles.removeAt(idx)),
                    optionsChild: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sidebarCheck('Downsample to target rate', _preprocessDownsample, (v) => _preprocessDownsample = v),
                        _sidebarCheck('Bandpass + notch filter', _preprocessFilter, (v) => _preprocessFilter = v),
                        _sidebarCheck('Bad channel detection', _preprocessBadChannels, (v) => _preprocessBadChannels = v),
                        _sidebarCheck('GEDAI denoising', _preprocessGedai, (v) => _preprocessGedai = v),
                        _sidebarCheck('Interpolate bad channels', _preprocessInterpolate, (v) => _preprocessInterpolate = v),
                      ],
                    ),
                    runLabel: 'Run Preprocessing Only',
                    onRun: () => _runBatchPreprocessingOnly(),
                    runEnabled: _batchPrepFiles.isNotEmpty,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildBatchStageCard(
                    title: 'Stage 2: Feature Extraction',
                    icon: Icons.analytics,
                    color: _accentAmber,
                    files: _batchFeatUsePrep ? [] : _batchFeatFiles,
                    outputDir: _batchFeatOutputFile,
                    outputDirLabel: 'Output CSV File',
                    onSelectOutputDir: () async {
                      final path = await FilePicker.saveFile(
                        dialogTitle: 'Select Output CSV File',
                        fileName: 'Batch_EEG_features.csv',
                        allowedExtensions: ['csv'],
                        type: FileType.custom,
                      );
                      if (path != null) setState(() => _batchFeatOutputFile = path);
                    },
                    usePreviousOutput: _batchFeatUsePrep,
                    usePreviousLabel: 'Use Stage 1 preprocessed outputs',
                    onUsePreviousChanged: (v) => setState(() => _batchFeatUsePrep = v ?? true),
                    onAdd: () async {
                      final pick = await FilePicker.pickFiles(
                        allowMultiple: true,
                        type: FileType.custom,
                        allowedExtensions: ['json', 'fif', 'edf', 'set', 'vhdr', 'orb', 'signal'],
                      );
                      if (pick != null) {
                        setState(() {
                          for (final f in pick.files) {
                            if (f.path != null && !_batchFeatFiles.contains(f.path!)) {
                              _batchFeatFiles.add(f.path!);
                            }
                          }
                        });
                      }
                    },
                    onClear: () => setState(() => _batchFeatFiles.clear()),
                    onRemove: (idx) => setState(() => _batchFeatFiles.removeAt(idx)),
                    optionsChild: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sidebarCheck('PSD band power', _psd, (v) => _psd = v),
                        _sidebarCheck('FOOOF / specparam', _fooof, (v) => _fooof = v),
                        _sidebarCheck('IRASA', _irasa, (v) => _irasa = v),
                        _sidebarCheck('Nonlinear dynamics', _nonlinear, (v) => _nonlinear = v),
                        _sidebarCheck('Autocorrelation window (ACW)', _acw, (v) => _acw = v),
                      ],
                    ),
                    runLabel: 'Run Extraction Only',
                    onRun: () => _runBatchFeatureExtractionOnly(),
                    runEnabled: _batchFeatUsePrep ? _batchPrepFiles.isNotEmpty : _batchFeatFiles.isNotEmpty,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildBatchStageCard(
                    title: 'Stage 3: Plot Generation',
                    icon: Icons.legend_toggle,
                    color: _accentGreen,
                    files: _batchPlotUseFeat ? [] : _batchPlotFiles,
                    outputDir: _batchPlotOutputDir,
                    onSelectOutputDir: () async {
                      final path = await FilePicker.getDirectoryPath(dialogTitle: 'Select Output Directory for Plots');
                      if (path != null) setState(() => _batchPlotOutputDir = path);
                    },
                    usePreviousOutput: _batchPlotUseFeat,
                    usePreviousLabel: 'Use Stage 2 extracted CSV',
                    onUsePreviousChanged: (v) => setState(() => _batchPlotUseFeat = v ?? true),
                    onAdd: () async {
                      final pick = await FilePicker.pickFiles(
                        allowMultiple: true,
                        type: FileType.custom,
                        allowedExtensions: ['csv'],
                      );
                      if (pick != null) {
                        setState(() {
                          for (final f in pick.files) {
                            if (f.path != null && !_batchPlotFiles.contains(f.path!)) {
                              _batchPlotFiles.add(f.path!);
                            }
                          }
                        });
                      }
                    },
                    onClear: () => setState(() => _batchPlotFiles.clear()),
                    onRemove: (idx) => setState(() => _batchPlotFiles.removeAt(idx)),
                    optionsChild: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Topoplot Windows (N): 10', style: TextStyle(color: Colors.white, fontSize: 12)),
                        SizedBox(height: 6),
                        Text('Smoothing Window (epochs): 25', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                    runLabel: 'Run Plotting Only',
                    onRun: () => _runBatchPlottingOnly(),
                    runEnabled: _batchPlotUseFeat 
                        ? (_batchFeatUsePrep ? _batchPrepFiles.isNotEmpty : _batchFeatOutputFile != null) 
                        : _batchPlotFiles.isNotEmpty,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchStageCard({
    required String title,
    required IconData icon,
    required Color color,
    required List<String> files,
    String? outputDir,
    String outputDirLabel = 'Output Directory',
    required VoidCallback onSelectOutputDir,
    required VoidCallback onAdd,
    required VoidCallback onClear,
    required void Function(int) onRemove,
    Widget? optionsChild,
    bool? usePreviousOutput,
    String? usePreviousLabel,
    void Function(bool?)? onUsePreviousChanged,
    required String runLabel,
    required VoidCallback onRun,
    bool runEnabled = true,
  }) {
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
              color: color.withOpacity(0.08),
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
              border: Border(bottom: BorderSide(color: _borderColor)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Text(title, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (usePreviousOutput != null && onUsePreviousChanged != null) ...[
                  CheckboxListTile(
                    title: Text(usePreviousLabel ?? '', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    value: usePreviousOutput,
                    onChanged: _running ? null : onUsePreviousChanged,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  const SizedBox(height: 8),
                ],
                Text(outputDirLabel, style: const TextStyle(color: _textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        outputDir ?? 'Next to source files',
                        style: TextStyle(color: outputDir == null ? _textMuted : Colors.white, fontSize: 11),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open, size: 16, color: _accentBlue),
                      onPressed: _running ? null : onSelectOutputDir,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (usePreviousOutput != true) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Selected Files (${files.length})', style: const TextStyle(color: _textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _running ? null : onAdd,
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 24)),
                            child: const Text('Add', style: TextStyle(fontSize: 11)),
                          ),
                          TextButton(
                            onPressed: _running || files.isEmpty ? null : onClear,
                            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 24)),
                            child: const Text('Clear', style: TextStyle(color: Colors.red, fontSize: 11)),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 140,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _borderColor),
                    ),
                    child: files.isEmpty
                        ? const Center(child: Text('No files selected', style: TextStyle(color: _textMuted, fontSize: 11)))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            itemCount: files.length,
                            separatorBuilder: (_, __) => const Divider(color: _borderColor, height: 1),
                            itemBuilder: (ctx, idx) {
                              final path = files[idx];
                              return Row(
                                children: [
                                  Expanded(
                                    child: Text(path.split(Platform.pathSeparator).last,
                                        style: const TextStyle(color: Colors.white, fontSize: 11),
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 13, color: _textMuted),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                                    onPressed: _running ? null : () => onRemove(idx),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _borderColor),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.link, size: 14, color: color),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Linked to previous stage outputs.',
                            style: TextStyle(color: _textMuted, fontSize: 11, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (optionsChild != null) ...[
                  const Text('Stage Options', style: TextStyle(color: _textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  optionsChild,
                ],
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: _borderColor)),
            ),
            child: FilledButton.icon(
              onPressed: (_running || !runEnabled) ? null : onRun,
              icon: const Icon(Icons.play_arrow, size: 14),
              label: Text(runLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

  Future<void> _runBatchPreprocessingOnly() async {
    if (_batchPrepFiles.isEmpty) return;
    setState(() { _running = true; _progress = 0; _logVisible = true; });
    _log('── BATCH PREPROCESSING ONLY (${_batchPrepFiles.length} files) ──');
    int count = 0;
    for (final path in _batchPrepFiles) {
      count++;
      _log('File $count/${_batchPrepFiles.length}: ${path.split(Platform.pathSeparator).last}');
      try {
        final dir = _batchPrepOutputDir ?? Directory(path).parent.path;
        final base = path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.(edf|set|fif|vhdr|orb|signal)$', caseSensitive: false), '');
        final outPath = '$dir/$base.ccseeg.json';

        var rec = await _loader.load(path);
        await _service.preprocess(
          recording: rec,
          outputPath: outPath,
          selection: const ViewerSelection.empty(),
          options: PreprocessingOptions(
            downsample: _preprocessDownsample,
            downsampleFreq: double.tryParse(_preDownsample.text) ?? 250,
            filter: _preprocessFilter,
            lowHz: double.tryParse(_preLow.text) ?? 0.5,
            highHz: double.tryParse(_preHigh.text) ?? 40,
            notchHz: double.tryParse(_preNotch.text) ?? 50,
            badchannel: _preprocessBadChannels,
            gedai: _preprocessGedai,
            interpolate: _preprocessInterpolate,
            gedaiEpochSeconds: double.tryParse(_epoch.text) ?? 1,
            gedaiThreshold: 'auto',
            sourceLocalization: false,
          ),
          onProgress: (p, msg) {
            setState(() => _progress = ((count - 1) + p) / _batchPrepFiles.length);
            if (msg.isNotEmpty) _log('  $msg');
          },
        );
        _log('✓ Saved: $outPath');
      } catch (e) {
        _log('✗ ERROR on $path: $e');
      }
    }
    setState(() { _running = false; _progress = 1.0; });
    _log('── BATCH PREPROCESSING COMPLETED ──');
  }

  Future<void> _runBatchFeatureExtractionOnly() async {
    List<String> inputs;
    if (_batchFeatUsePrep) {
      inputs = _batchPrepFiles.map((path) {
        final dir = _batchPrepOutputDir ?? Directory(path).parent.path;
        final base = path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.(edf|set|fif|vhdr|orb|signal)$', caseSensitive: false), '');
        return '$dir/$base.ccseeg.json';
      }).toList();
    } else {
      inputs = _batchFeatFiles;
    }
    if (inputs.isEmpty) {
      _log('No preprocessed/raw files selected for feature extraction.');
      return;
    }
    setState(() { _running = true; _progress = 0; _logVisible = true; });
    _log('── BATCH FEATURE EXTRACTION ONLY ──');
    
    String? outCsv = _batchFeatOutputFile;
    if (outCsv == null) {
      final firstDir = Directory(inputs.first).parent.path;
      outCsv = '$firstDir/Batch_extracted_features.csv';
      _log('Saving output CSV to default: $outCsv');
    }

    final loadedRecs = <EegRecording>[];
    int count = 0;
    for (final path in inputs) {
      count++;
      _log('Loading $count/${inputs.length}: ${path.split(Platform.pathSeparator).last}');
      try {
        final rec = await _loader.load(path);
        loadedRecs.add(rec);
      } catch (e) {
        _log('✗ Failed to load $path: $e');
      }
    }

    if (loadedRecs.isEmpty) {
      _log('No recordings successfully loaded.');
      setState(() { _running = false; });
      return;
    }

    try {
      _log('Running extraction for all loaded files...');
      await _service.run(
        recordings: loadedRecs,
        outputPath: outCsv,
        epochSeconds: double.tryParse(_epoch.text) ?? 2,
        selection: const ViewerSelection.empty(),
        options: ExtractionOptions(
          mode: DurationMode.full,
          startSeconds: 0,
          endSeconds: 120,
          binSeconds: double.tryParse(_bin.text) ?? 60,
          psd: _psd,
          fooof: _fooof,
          irasa: _irasa,
          nonlinear: _nonlinear,
          acw: _acw,
          connectivity: _mic || _mim || _gc || _gcTr || _coh || _plv || _ciplv || _pli || _wpli,
          mic: _mic,
          mim: _mim,
          gc: _gc,
          gcTr: _gcTr,
          coh: _coh,
          plv: _plv,
          ciplv: _ciplv,
          pli: _pli,
          wpli: _wpli,
          removeNonEeg: _removeNonEeg,
          exclusions: const [],
        ),
        onProgress: (p, msg) {
          setState(() => _progress = p);
          if (msg.isNotEmpty) _log('  $msg');
        },
      );
      _log('✓ Saved features to: $outCsv');
    } catch (e) {
      _log('✗ Extraction error: $e');
    } finally {
      setState(() { _running = false; _progress = 1.0; });
      _log('── BATCH FEATURE EXTRACTION COMPLETED ──');
    }
  }

  Future<void> _runBatchPlottingOnly() async {
    List<String> inputs;
    if (_batchPlotUseFeat) {
      if (_batchFeatOutputFile != null) {
        inputs = [_batchFeatOutputFile!];
      } else {
        final firstInput = _batchFeatUsePrep ? _batchPrepFiles.firstOrNull : _batchFeatFiles.firstOrNull;
        if (firstInput != null) {
          final dir = _batchPrepOutputDir ?? Directory(firstInput).parent.path;
          inputs = ['$dir/Batch_extracted_features.csv'];
        } else {
          inputs = [];
        }
      }
    } else {
      inputs = _batchPlotFiles;
    }

    if (inputs.isEmpty) {
      _log('No CSV files selected for plotting.');
      return;
    }

    setState(() { _running = true; _progress = 0; _logVisible = true; });
    _log('── BATCH PLOT GENERATION ONLY ──');
    try {
      final outDir = _batchPlotOutputDir ?? Directory(inputs.first).parent.path;
      _log('Saving plots into: $outDir');
      
      final savedPlots = await generateFeaturePlots(
        csvPaths: inputs,
        outputDir: outDir,
        options: PlotOptions(
          nTopoWindows: 10,
          smoothingWindow: 25,
          epochSizeSeconds: double.tryParse(_epoch.text) ?? 2.0,
        ),
        onProgress: (p, msg) {
          setState(() => _progress = p);
          if (msg.isNotEmpty) _log('  $msg');
        },
      );
      _log('✓ Generated ${savedPlots.length} feature plots in $outDir');
    } catch (e) {
      _log('✗ Plotting failed: $e');
    } finally {
      setState(() { _running = false; _progress = 1.0; });
      _log('── BATCH PLOT GENERATION COMPLETED ──');
    }
  }

  Future<void> _runUnifiedSequentialPipeline() async {
    if (_batchPrepFiles.isEmpty) {
      _log('Staging list is empty. Select files in Stage 1.');
      return;
    }
    setState(() { _running = true; _progress = 0; _logVisible = true; });
    _log('── STARTING UNIFIED SEQUENTIAL PIPELINE (STAGES 1-3) ──');
    
    final preprocessedPaths = <String>[];
    int count = 0;
    for (final path in _batchPrepFiles) {
      count++;
      _log('[Stage 1/3] Preprocessing $count/${_batchPrepFiles.length}: ${path.split(Platform.pathSeparator).last}');
      try {
        final dir = _batchPrepOutputDir ?? Directory(path).parent.path;
        final base = path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.(edf|set|fif|vhdr|orb|signal)$', caseSensitive: false), '');
        final outPath = '$dir/$base.ccseeg.json';

        var rec = await _loader.load(path);
        await _service.preprocess(
          recording: rec,
          outputPath: outPath,
          selection: const ViewerSelection.empty(),
          options: PreprocessingOptions(
            downsample: _preprocessDownsample,
            downsampleFreq: double.tryParse(_preDownsample.text) ?? 250,
            filter: _preprocessFilter,
            lowHz: double.tryParse(_preLow.text) ?? 0.5,
            highHz: double.tryParse(_preHigh.text) ?? 40,
            notchHz: double.tryParse(_preNotch.text) ?? 50,
            badchannel: _preprocessBadChannels,
            gedai: _preprocessGedai,
            interpolate: _preprocessInterpolate,
            gedaiEpochSeconds: double.tryParse(_epoch.text) ?? 1,
            gedaiThreshold: 'auto',
            sourceLocalization: false,
          ),
          onProgress: (p, msg) {
            setState(() => _progress = (0.0 + ((count - 1) + p) / _batchPrepFiles.length) / 3.0);
            if (msg.isNotEmpty) _log('  $msg');
          },
        );
        preprocessedPaths.add(outPath);
      } catch (e) {
        _log('✗ Stage 1 error on $path: $e');
      }
    }

    if (preprocessedPaths.isEmpty) {
      _log('Stage 1 did not yield files. Aborting.');
      setState(() { _running = false; });
      return;
    }

    _log('[Stage 2/3] Extracting Features...');
    String? outCsv = _batchFeatOutputFile;
    if (outCsv == null) {
      final firstDir = Directory(preprocessedPaths.first).parent.path;
      outCsv = '$firstDir/Batch_extracted_features.csv';
    }

    final loadedRecs = <EegRecording>[];
    count = 0;
    for (final path in preprocessedPaths) {
      count++;
      try {
        final rec = await _loader.load(path);
        loadedRecs.add(rec);
      } catch (e) {
        _log('✗ Failed to load $path: $e');
      }
    }

    if (loadedRecs.isEmpty) {
      _log('Stage 2 did not load any recordings. Aborting.');
      setState(() { _running = false; });
      return;
    }

    try {
      await _service.run(
        recordings: loadedRecs,
        outputPath: outCsv,
        epochSeconds: double.tryParse(_epoch.text) ?? 2,
        selection: const ViewerSelection.empty(),
        options: ExtractionOptions(
          mode: DurationMode.full,
          startSeconds: 0,
          endSeconds: 120,
          binSeconds: double.tryParse(_bin.text) ?? 60,
          psd: _psd,
          fooof: _fooof,
          irasa: _irasa,
          nonlinear: _nonlinear,
          acw: _acw,
          connectivity: _mic || _mim || _gc || _gcTr || _coh || _plv || _ciplv || _pli || _wpli,
          mic: _mic,
          mim: _mim,
          gc: _gc,
          gcTr: _gcTr,
          coh: _coh,
          plv: _plv,
          ciplv: _ciplv,
          pli: _pli,
          wpli: _wpli,
          removeNonEeg: _removeNonEeg,
          exclusions: const [],
        ),
        onProgress: (p, msg) {
          setState(() => _progress = (1.0 + p) / 3.0);
          if (msg.isNotEmpty) _log('  $msg');
        },
      );
      _log('✓ Stage 2 completed. Saved to: $outCsv');
    } catch (e) {
      _log('✗ Stage 2 Feature Extraction failed: $e');
      setState(() { _running = false; });
      return;
    }

    _log('[Stage 3/3] Generating Topo/Line plots...');
    try {
      final outDir = _batchPlotOutputDir ?? Directory(outCsv).parent.path;
      final savedPlots = await generateFeaturePlots(
        csvPaths: [outCsv],
        outputDir: outDir,
        options: PlotOptions(
          nTopoWindows: 10,
          smoothingWindow: 25,
          epochSizeSeconds: double.tryParse(_epoch.text) ?? 2.0,
        ),
        onProgress: (p, msg) {
          setState(() => _progress = (2.0 + p) / 3.0);
          if (msg.isNotEmpty) _log('  $msg');
        },
      );
      _log('✓ Stage 3 completed. Generated ${savedPlots.length} plots in $outDir');
    } catch (e) {
      _log('✗ Stage 3 Plotting failed: $e');
    } finally {
      setState(() { _running = false; _progress = 1.0; });
      _log('── PIPELINE SEQUENTIAL PROCESSING COMPLETED ──');
    }
  }
}
