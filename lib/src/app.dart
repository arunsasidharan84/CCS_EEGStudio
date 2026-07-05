import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'eeg_viewer.dart';
import 'extraction_service.dart';
import 'models.dart';
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
    title: 'CCS EEG Feature Studio',
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

  // State
  List<EegRecording> _recordings = [];
  EegRecording? _rawRecording;  // original before preprocessing
  ViewerSelection _selection = const ViewerSelection.empty();
  DurationMode _mode = DurationMode.full;

  // Preprocessing flags
  bool _preprocessDownsample = true;
  bool _preprocessFilter = true;
  bool _preprocessBadChannels = true;
  bool _preprocessGedai = true;
  bool _preprocessInterpolate = true;
  bool _preprocessEpochBeforeGedai = true;

  // Feature flags
  bool _psd = true, _fooof = true, _irasa = true, _nonlinear = true, _acw = true;
  bool _mic = true, _mim = false, _gc = false, _gcTr = false;
  bool _coh = true, _plv = false, _ciplv = false, _pli = false, _wpli = false;
  bool _removeNonEeg = true;

  bool _running = false;
  double _progress = 0;

  // Sidebar accordion state
  bool _prepExpanded = true;
  bool _sourceExpanded = true;
  bool _featExpanded = true;

  // Log panel
  bool _logVisible = false;
  final List<String> _logs = [];

  @override
  void dispose() {
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

  Future<void> _open() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['edf', 'set', 'fif', 'vhdr', 'json'],
    );
    if (pick == null) return;
    final loaded = <EegRecording>[];
    for (final item in pick.files) {
      if (item.path == null) continue;
      try {
        _log('Loading ${item.name}…');
        final rec = await _loader.load(item.path!);
        loaded.add(rec);
        _log('✓ Loaded ${item.name}');
      } catch (e) {
        _log('✗ ERROR ${item.name}: $e');
      }
    }
    if (loaded.isNotEmpty) {
      setState(() {
        _recordings = loaded;
        _rawRecording = null; // fresh load — no raw/processed pair yet
        _selection = const ViewerSelection.empty();
      });
    }
  }

  void _openBatchDialog() {
    final batchFiles = _recordings.map((r) => r.path).toList();
    bool runPrep = true;
    bool runSource = false;
    bool runFeat = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            title: const Row(
              children: [
                Icon(Icons.layers, color: Color(0xFFA855F7), size: 20),
                SizedBox(width: 8),
                Text('Automated Batch Processing Pipeline', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 580,
              height: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${batchFiles.length} files selected for batch', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.w600)),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B)),
                        onPressed: () async {
                          final pick = await FilePicker.pickFiles(
                            allowMultiple: true,
                            type: FileType.custom,
                            allowedExtensions: ['edf', 'set', 'fif', 'vhdr'],
                          );
                          if (pick != null) {
                            setDialogState(() {
                              for (final f in pick.files) {
                                if (f.path != null && !batchFiles.contains(f.path!)) {
                                  batchFiles.add(f.path!);
                                }
                              }
                            });
                          }
                        },
                        icon: const Icon(Icons.add, size: 14, color: Colors.white),
                        label: const Text('Add Files', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: batchFiles.isEmpty
                        ? const Center(child: Text('No files selected. Click Add Files.', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)))
                        : ListView.separated(
                            padding: const EdgeInsets.all(8),
                            itemCount: batchFiles.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0xFF334155), height: 1),
                            itemBuilder: (_, i) => Row(
                              children: [
                                const Icon(Icons.description, size: 14, color: Color(0xFF94A3B8)),
                                const SizedBox(width: 6),
                                Expanded(child: Text(batchFiles[i].split('/').last, style: const TextStyle(color: Colors.white, fontSize: 12))),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 14, color: Color(0xFF64748B)),
                                  onPressed: () => setDialogState(() => batchFiles.removeAt(i)),
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Select Pipeline Stages to Execute:', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    title: const Text('1. Preprocessing & Artifact Cleaning (Notch, Bandpass, Bad Ch, GEDAI)', style: TextStyle(color: Colors.white, fontSize: 12)),
                    value: runPrep,
                    onChanged: (val) => setDialogState(() => runPrep = val ?? true),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  CheckboxListTile(
                    title: const Text('2. Source Reconstruction (eLORETA fsaverage 65 ROIs)', style: TextStyle(color: Colors.white, fontSize: 12)),
                    value: runSource,
                    onChanged: (val) => setDialogState(() => runSource = val ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  CheckboxListTile(
                    title: const Text('3. Feature Extraction & Connectivity Matrix Export', style: TextStyle(color: Colors.white, fontSize: 12)),
                    value: runFeat,
                    onChanged: (val) => setDialogState(() => runFeat = val ?? true),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFA855F7)),
                icon: const Icon(Icons.play_arrow, size: 16, color: Colors.white),
                onPressed: batchFiles.isEmpty ? null : () {
                  Navigator.of(ctx).pop();
                  _runBatchPipeline(batchFiles, runPrep, runSource, runFeat);
                },
                label: const Text('Start Batch Run', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _runBatchPipeline(List<String> files, bool doPrep, bool doSource, bool doFeat) async {
    setState(() { _running = true; _progress = 0; });
    _log('── STARTING BATCH PROCESSING (${files.length} files) ──');
    int count = 0;
    for (final path in files) {
      count++;
      _log('Batch file $count/${files.length}: ${path.split('/').last}');
      try {
        var currentRec = await _loader.load(path);
        if (doPrep) {
          _log('  Running Preprocessing...');
          currentRec = await _service.preprocess(
            recording: currentRec,
            outputPath: '$path.ccseeg.json',
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
              setState(() => _progress = ((count - 1) + p) / files.length);
              if (msg.isNotEmpty) _log('    [Prep] $msg');
            },
          );
        }
        if (doSource) {
          _log('  Running Source Reconstruction...');
          currentRec = await _service.preprocess(
            recording: currentRec,
            outputPath: '$path.source.ccseeg.json',
            selection: const ViewerSelection.empty(),
            options: PreprocessingOptions(
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
            ),
            onProgress: (p, msg) {
              if (msg.isNotEmpty) _log('    [Source] $msg');
            },
          );
        }
        if (doFeat) {
          _log('  Extracting Features...');
          await _service.run(
            recordings: [currentRec],
            outputPath: '$path.features.csv',
            epochSeconds: double.tryParse(_epoch.text) ?? 2,
            selection: const ViewerSelection.empty(),
            options: ExtractionOptions(
              mode: DurationMode.full,
              startSeconds: 0,
              endSeconds: currentRec.durationSeconds,
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
              setState(() => _progress = ((count - 1) + p) / files.length);
              if (msg.isNotEmpty) _log('    [Feat] $msg');
            },
          );
        }
        _log('✓ Finished $path');
      } catch (e) {
        _log('✗ BATCH ERROR on $path: $e');
      }
    }
    setState(() { _running = false; _progress = 1.0; });
    _log('── BATCH PROCESSING COMPLETED ──');
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
      final raw = _recordings.isNotEmpty ? _recordings.first : null;
      setState(() {
        _rawRecording = raw; // remember original for Raw/Processed toggle
        _recordings = [cleaned, ..._recordings];
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
        _recordings = [sourced, ..._recordings];
        _selection = const ViewerSelection.empty();
      });
      _log('✓ Source localization complete: ${sourced.path}');
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
      _selection = const ViewerSelection.empty();
    });
    _log('Cleared all loaded files.');
  }

  // ── Feature extraction ─────────────────────────────────────────────────────

  Future<void> _run() async {
    if (_recordings.isEmpty) { _log('Select at least one recording.'); return; }
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
    final kept = _recordings
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
      // PDF report — separate try so a write failure doesn't shadow the extraction success
      try {
        final reportPath = path.replaceAll(RegExp(r'\.csv$', caseSensitive: false), '_report.pdf');

        // Build ReportContext from current UI state so the PDF has full metadata
        final rec = kept.isNotEmpty ? kept.first : null;
        final rawRec = _rawRecording;
        final ctx = ReportContext(
          fileName: rec != null ? rec.path.split(Platform.pathSeparator).last : path.split(Platform.pathSeparator).last,
          channelCount: rec?.labels.length ?? 0,
          epochCount: rec?.epochCount ?? 0,
          durationSeconds: rec?.durationSeconds ?? 0,
          sampleRate: rec?.sampleRate ?? 0,
          channelLabels: rec?.labels ?? [],
          rawPreview:     rawRec?.preview,
          cleanedPreview: rec?.preview,
          sourceLocalized: rec != null && rec.labels.any((l) => l.contains('lh_') || l.contains('rh_')),
          sourceRoiLabels: rec != null ? rec.labels.where((l) => l.contains('_')).toList() : [],
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopBar(),
          Expanded(
            child: Row(
              children: [
                // ── Left sidebar ───────────────────────────────────────
                SizedBox(
                  width: 290,
                  child: Container(
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
                          recording: _recordings.isEmpty ? null : _recordings.first,
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
                        ),
                      ),
                      // ── Collapsible log panel ──────────────────────
                      _buildLogPanel(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
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
          const Text('Feature Studio', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
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
          // Open file
          OutlinedButton.icon(
            onPressed: _running ? null : _openBatchDialog,
            icon: const Icon(Icons.layers, size: 15, color: Color(0xFFA855F7)),
            label: const Text('Batch Pipeline', style: TextStyle(color: Color(0xFFA855F7))),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFA855F7)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
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

  Widget _buildSidebar() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        // ── Files section ──────────────────────────────────────────
        if (_recordings.isNotEmpty) ...[
          _sidebarSectionHeader('FILES', Icons.insert_drive_file),
          for (final rec in _recordings)
            _fileChip(rec),
          const Divider(color: _borderColor, height: 1),
        ],

        // ── Preprocessing ──────────────────────────────────────────
        _accordionHeader('PREPROCESSING', Icons.cleaning_services, _prepExpanded,
            () => setState(() => _prepExpanded = !_prepExpanded)),
        if (_prepExpanded) _buildPreprocessingSection(),

        // ── Source Reconstruction ──────────────────────────────────
        const Divider(color: _borderColor, height: 1),
        _accordionHeader('SOURCE RECONSTRUCTION', Icons.psychology, _sourceExpanded,
            () => setState(() => _sourceExpanded = !_sourceExpanded)),
        if (_sourceExpanded) _buildSourceSection(),

        // ── Epoch & Duration ────────────────────────────────────────
        const Divider(color: _borderColor, height: 1),
        _sidebarSectionHeader('EPOCH & DURATION', Icons.access_time),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _epoch,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(labelText: 'Epoch length (s)', suffixText: 's'),
              ),
              const SizedBox(height: 8),
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
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: _start, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'Start s'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: _end, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'End s'))),
                ]),
              ],
              if (_mode == DurationMode.bins) ...[
                const SizedBox(height: 8),
                TextField(controller: _bin, style: const TextStyle(color: Colors.white, fontSize: 12), decoration: const InputDecoration(labelText: 'Bin size (s)', suffixText: 's')),
              ],
            ],
          ),
        ),

        // ── Feature Families ──────────────────────────────────────
        const Divider(color: _borderColor, height: 1),
        _accordionHeader('FEATURE FAMILIES', Icons.analytics, _featExpanded,
            () => setState(() => _featExpanded = !_featExpanded)),
        if (_featExpanded) _buildFeaturesSection(),

        // ── Exclusions ────────────────────────────────────────────
        const Divider(color: _borderColor, height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _subLabel('OTHER'),
              const SizedBox(height: 6),
              _sidebarCheck('Remove non-EEG channels + avg ref', _removeNonEeg,
                  (v) => _removeNonEeg = v),
              const SizedBox(height: 6),
              TextField(
                controller: _exclude,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Filename exclusions',
                  helperText: 'Comma-separated',
                  helperStyle: TextStyle(color: _textMuted, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
      ],
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

  Widget _buildPreprocessingSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _running ? null : _preprocessCurrent,
              icon: const Icon(Icons.cleaning_services, size: 14),
              label: const Text('Preprocess Scalp EEG', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accentPurple,
                side: BorderSide(color: _accentPurple.withOpacity(0.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _accentBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _accentBlue.withOpacity(0.3)),
            ),
            child: const Text(
              'Projects scalp potentials to 68 FreeSurfer cortical dipoles via regularized eLORETA inverse solution.',
              style: TextStyle(color: _textMuted, fontSize: 11),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _running ? null : _runSourceLocalization,
              icon: const Icon(Icons.psychology, size: 14),
              label: const Text('Convert to 68 ROIs', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accentBlue,
                side: BorderSide(color: _accentBlue.withOpacity(0.5)),
              ),
            ),
          ),
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

  // ── Run buttons at sidebar bottom ─────────────────────────────────────────

  Widget _buildRunButtons() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFF060D1A),
        border: Border(top: BorderSide(color: _borderColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_running)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 8),
              ],
            ),
          if (_running) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.stop_circle, size: 16),
                label: const Text('Cancel Operation', style: TextStyle(fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _open,
                icon: const Icon(Icons.folder_open, size: 15, color: _accentBlue),
                label: const Text('Load Preprocessed (.json/.fif)', style: TextStyle(color: _accentBlue, fontSize: 12, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _accentBlue),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Run Extraction', style: TextStyle(fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(
                  backgroundColor: _accentGreen,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _running ? null : _compileCsv,
              icon: const Icon(Icons.table_chart, size: 14),
              label: const Text('Compile CSV Batch', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _textMuted,
                side: const BorderSide(color: _borderColor),
              ),
            ),
          ),
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

  // ── Shared helpers ────────────────────────────────────────────────────────

  Widget _sidebarSectionHeader(String label, IconData icon) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
    child: Row(children: [
      Icon(icon, size: 13, color: _accentBlue),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: _accentBlue, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
    ]),
  );

  Widget _accordionHeader(String label, IconData icon, bool expanded, VoidCallback onTap) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(children: [
        Icon(icon, size: 13, color: _accentBlue),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: _accentBlue, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
        const Spacer(),
        Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: _textMuted),
      ]),
    ),
  );

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
}
