// lib/src/topostats/topostats_view.dart
//
// Interactive "Plots & Report" / TopoStats workspace: settings that mirror
// the USER SETTINGS block of PlotFeaturesTopoStats_20260801.py, a zoomable
// figure rendered exactly like the script's PNGs, hover read-outs, click-to-
// inspect topomaps, and PNG / PDF / stats-CSV export (single feature or the
// script's whole feature list).

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import '../filtered_file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'mpl_colormaps.dart';
import 'topo_interp.dart' show isStandard1020Channel;
import 'topostats_engine.dart';
import 'topostats_batch.dart' show prepareSessionFeatureCsvs, groupByRecording;
import 'topostats_figure.dart';
import 'topostats_runner.dart';

// Design tokens (match app.dart)
const _bg = Color(0xFF0F172A);
const _panel = Color(0xFF0A1628);
const _card = Color(0xFF1E293B);
const _border = Color(0x1FFFFFFF);
const _amber = Color(0xFFF59E0B);
const _muted = Color(0xFF94A3B8);
const _text = Color(0xFFE2E8F0);
const _green = Color(0xFF22C55E);

/// Represents a distinct recording or dataset group within TopoStats.
class TopoPlotGroup {
  TopoPlotGroup({
    required this.id,
    required this.recId,
    required this.files,
    this.baselineSession,
    Set<String>? disabled,
    this.result,
    this.figure,
  }) : disabled = disabled ?? <String>{};

  final String id;
  String recId;
  String? baselineSession;
  List<String> files;
  final Set<String> disabled;
  TopoStatsResult? result;
  TopoFigure? figure;

  List<String> get activeFiles => [
    for (final f in files)
      if (!disabled.contains(f)) f,
  ];

  List<String> get sessionNames => [
    for (final f in activeFiles) cleanSegmentName(TopoStatsView.baseName(f), recId),
  ];
}

class TopoStatsView extends StatefulWidget {
  const TopoStatsView({
    super.key,
    required this.featureFilePaths,
    this.runLabel = 'Run Plot Generation',
    this.title = 'Plots & Report',
    this.initialSettings = const TopoStatsSettings(),
  });

  /// Seed files. A single file is expanded to all sibling sessions of the
  /// same recording (`*_{rec_ID}_*.features.csv`), like the script's glob.
  final List<String> featureFilePaths;
  final String runLabel;
  final String title;
  final TopoStatsSettings initialSettings;

  static String baseName(String p) => p.split(RegExp(r'[\\/]')).last;

  @override
  State<TopoStatsView> createState() => _TopoStatsViewState();
}

class _TopoStatsViewState extends State<TopoStatsView> {
  TopoStatsSettings _s = const TopoStatsSettings();
  final List<TopoPlotGroup> _groups = [];
  int _selectedGroupIndex = 0;
  bool _showAllGroups = true;

  Directory? _sessionScratch;
  String? _sourceDir;
  List<String> _features = [];

  final Map<String, TopoStatsResult> _cache = {};

  bool _running = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  TopoStatsJob? _job;

  bool _fit = true;
  double _ppi = 110;
  TopoPlotGroup? _hoverGroup;
  TopoHit? _hoverHit;
  Offset _hoverPos = Offset.zero;
  final _hScroll = ScrollController();
  final _vScroll = ScrollController();

  // text fields
  final _recId = TextEditingController();
  final _sessionSearch = TextEditingController();
  final _bTmin = TextEditingController();
  final _bDur = TextEditingController();
  final _seg = TextEditingController();
  final _epoch = TextEditingController();
  final _smooth = TextEditingController();
  final _nPerm = TextEditingController();
  final _seed = TextEditingController();
  final _tfceStart = TextEditingController();
  final _tfceStep = TextEditingController();
  final _alpha = TextEditingController();
  final _vabs = TextEditingController();
  final _topoW = TextEditingController();
  final _dpi = TextEditingController();

  TopoPlotGroup? get _currentGroup {
    if (_groups.isEmpty) return null;
    if (_selectedGroupIndex < 0 || _selectedGroupIndex >= _groups.length) {
      return _groups.first;
    }
    return _groups[_selectedGroupIndex];
  }

  List<String> get _files => _currentGroup?.files ?? const [];
  Set<String> get _disabled => _currentGroup?.disabled ?? const {};
  List<String> get _activeFiles => _currentGroup?.activeFiles ?? const [];
  List<String> get _sessionNames => _currentGroup?.sessionNames ?? const [];
  TopoStatsResult? get _result => _currentGroup?.result;
  TopoFigure? get _figure => _currentGroup?.figure;

  @override
  void initState() {
    super.initState();
    _s = widget.initialSettings;
    _syncControllers();
    _setFiles(widget.featureFilePaths, autoRun: true);
  }

  @override
  void didUpdateWidget(TopoStatsView old) {
    super.didUpdateWidget(old);
    if (old.featureFilePaths.join('|') != widget.featureFilePaths.join('|')) {
      _setFiles(widget.featureFilePaths, autoRun: true);
    }
  }

  @override
  void dispose() {
    _job?.cancel();
    _sessionScratch?.deleteSync(recursive: true);
    for (final c in [
      _recId,
      _sessionSearch,
      _bTmin,
      _bDur,
      _seg,
      _epoch,
      _smooth,
      _nPerm,
      _seed,
      _tfceStart,
      _tfceStep,
      _alpha,
      _vabs,
      _topoW,
      _dpi,
    ]) {
      c.dispose();
    }
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  void _syncControllers() {
    String n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(1) : '$v';
    _recId.text = _currentGroup?.recId ?? _s.recId;
    _bTmin.text = n(_s.baselineTmin);
    _bDur.text = n(_s.baselineDurationMin);
    _seg.text = n(_s.segmentDurationMin);
    _epoch.text = n(_s.epochSize);
    _smooth.text = '${_s.windowSize}';
    _nPerm.text = '${_s.nPermutations}';
    _seed.text = '${_s.randomSeed}';
    _tfceStart.text = n(_s.tfceStart);
    _tfceStep.text = '${_s.tfceStep}';
    _alpha.text = '${_s.alpha}';
    _vabs.text = _s.topoVabs?.toString() ?? '';
    _topoW.text = '${_s.targetTopoWidthIn}';
    _dpi.text = '${_s.dpi}';
  }

  /// Reads the text fields back into the settings.
  TopoStatsSettings _readSettings() {
    double d(TextEditingController c, double fb) =>
        double.tryParse(c.text.trim()) ?? fb;
    int i(TextEditingController c, int fb) => int.tryParse(c.text.trim()) ?? fb;
    final vabsText = _vabs.text.trim();
    final rec = _recId.text.trim();
    if (_currentGroup != null && rec.isNotEmpty) {
      _currentGroup!.recId = rec;
    }
    return _s.copyWith(
      recId: rec,
      baselineTmin: d(_bTmin, _s.baselineTmin),
      baselineDurationMin: math.max(1e-6, d(_bDur, _s.baselineDurationMin)),
      segmentDurationMin: math.max(0.05, d(_seg, _s.segmentDurationMin)),
      epochSize: math.max(1e-6, d(_epoch, _s.epochSize)),
      windowSize: math.max(1, i(_smooth, _s.windowSize)),
      nPermutations: math.max(2, i(_nPerm, _s.nPermutations)),
      randomSeed: i(_seed, _s.randomSeed),
      tfceStart: d(_tfceStart, _s.tfceStart),
      tfceStep: math.max(1e-4, d(_tfceStep, _s.tfceStep)),
      alpha: d(_alpha, _s.alpha),
      topoVabs: vabsText.isEmpty ? null : double.tryParse(vabsText),
      targetTopoWidthIn: d(_topoW, _s.targetTopoWidthIn).clamp(0.15, 3.0),
      dpi: i(_dpi, _s.dpi).clamp(50, 1200),
    );
  }

  static String _base(String p) => TopoStatsView.baseName(p);
  static String _dir(String p) {
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? '.' : p.substring(0, i);
  }

  void _setFiles(List<String> seed, {bool autoRun = false, bool append = false}) {
    if (seed.isEmpty && !append) {
      setState(() {
        _groups.clear();
        _selectedGroupIndex = 0;
        _hoverHit = null;
        _hoverGroup = null;
      });
      return;
    }
    _sessionScratch ??= Directory.systemTemp.createTempSync(
      'ccs_plot_sessions_',
    );
    if (!append) {
      _sourceDir = seed.isEmpty ? null : _dir(seed.first);
      _groups.clear();
      _cache.clear();
    }
    final prep = prepareSessionFeatureCsvs(seed, _sessionScratch!.path);
    final grouped = groupByRecording(prep);

    if (grouped.isEmpty && prep.isNotEmpty) {
      final rid = inferRecId(prep);
      final g = TopoPlotGroup(
        id: rid.isNotEmpty ? rid : 'group_${_groups.length + 1}',
        recId: rid,
        files: List<String>.from(prep),
      );
      if (g.files.length > 8) g.disabled.addAll(g.files.skip(8));
      _groups.add(g);
    } else {
      grouped.forEach((rid, gFiles) {
        if (gFiles.isEmpty) return;
        final existingIdx = _groups.indexWhere(
          (g) => g.recId == rid || (rid.isNotEmpty && g.id == rid),
        );
        if (existingIdx >= 0 && append) {
          final existing = _groups[existingIdx];
          final combined = {...existing.files, ...gFiles}.toList()..sort();
          existing.files = combined;
        } else {
          final g = TopoPlotGroup(
            id: rid.isNotEmpty ? rid : 'group_${_groups.length + 1}',
            recId: rid,
            files: List<String>.from(gFiles),
          );
          if (g.files.length > 8) g.disabled.addAll(g.files.skip(8));
          _groups.add(g);
        }
      });
    }

    if (_selectedGroupIndex >= _groups.length) {
      _selectedGroupIndex = math.max(0, _groups.length - 1);
    }

    final allFiles = [for (final g in _groups) ...g.files];
    if (allFiles.isNotEmpty) {
      try {
        final cols = numericFeatureColumns(allFiles.first);
        final ordered = [
          ...kReferenceFeatureList.where(cols.contains),
          ...cols.where((c) => !kReferenceFeatureList.contains(c)),
        ];
        _features = ordered;
      } catch (_) {}
    }

    var s = _s;
    if (_features.isNotEmpty && !_features.contains(s.feature)) {
      s = s.copyWith(feature: _features.first);
    }

    if (allFiles.isNotEmpty) {
      try {
        final det = detectChannels(allFiles.first);
        final known = det.where(isStandard1020Channel).toList();
        s = s.copyWith(channels: known.length >= 3 ? known : det);
        if (s.reprChan != null && !s.channels.contains(s.reprChan)) {
          s = s.copyWith(reprChan: s.channels.contains('Fz') ? 'Fz' : null);
        }
      } catch (_) {}
    }

    for (final g in _groups) {
      final names = g.sessionNames;
      if (names.isNotEmpty &&
          (g.baselineSession == null ||
              !names.any((n) => n.contains(g.baselineSession!)))) {
        g.baselineSession = names.first;
      }
    }
    if (_currentGroup != null) {
      s = s.copyWith(
        recId: _currentGroup!.recId,
        baselineSession: _currentGroup!.baselineSession ??
            (_sessionNames.isEmpty ? '' : _sessionNames.first),
      );
    }

    setState(() {
      _s = s;
      _error = null;
      _hoverHit = null;
      _hoverGroup = null;
    });
    _syncControllers();
    if (autoRun && _groups.any((g) => g.activeFiles.isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run();
      });
    }
  }

  void _moveSession(String file, int delta) {
    final g = _currentGroup;
    if (g == null || _running) return;
    final from = g.files.indexOf(file);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= g.files.length) return;
    setState(() {
      g.files.removeAt(from);
      g.files.insert(to, file);
    });
    final result = g.result;
    if (result != null) {
      final reordered = result
          .withSessionOrder(g.activeFiles)
          .withDisplay(_s.copyWith(recId: g.recId));
      _cache[reordered.settings.statsKey(g.activeFiles)] = reordered;
      _show(reordered);
    }
  }

  Future<void> _chooseSessionColor(String file) async {
    final controller = TextEditingController(
      text:
          '#${(_s.sessionColors[file] ?? 0xFFD62728).toRadixString(16).substring(2).toUpperCase()}',
    );
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Line color'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Hex color (#RRGGBB)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.replaceFirst('#', '');
              if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text))
                Navigator.pop(context, 0xFF000000 | int.parse(text, radix: 16));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (selected == null || !mounted) return;
    setState(
      () => _s = _s.copyWith(
        sessionColors: {..._s.sessionColors, file: selected},
      ),
    );
    _redisplay();
  }

  void _toggleSession(String file, bool selected) {
    final g = _currentGroup;
    if (g == null) return;
    setState(() {
      if (selected) {
        g.disabled.remove(file);
      } else {
        g.disabled.add(file);
      }
      _s = settingsForSessions(_s, g.sessionNames);
      g.result = null;
      g.figure = null;
      _hoverHit = null;
      _hoverGroup = null;
      _error = null;
    });
    if (g.activeFiles.isNotEmpty) _run();
  }

  void _removeGroup(TopoPlotGroup group) {
    if (_groups.length <= 1) return;
    setState(() {
      _groups.remove(group);
      if (_selectedGroupIndex >= _groups.length) {
        _selectedGroupIndex = _groups.length - 1;
      }
      _syncControllers();
    });
  }

  Future<void> _pickFiles({bool append = false}) async {
    final pick = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Select *.features.csv session files',
    );
    final paths =
        pick?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isNotEmpty) _setFiles(paths, autoRun: true, append: append);
  }

  Future<void> _pickFolder({bool append = false}) async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Folder with *.features.csv files',
    );
    if (dir == null) return;
    final all =
        Directory(dir)
            .listSync()
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.endsWith('.features.csv'))
            .toList()
          ..sort();
    if (all.isEmpty) {
      _snack('No *.features.csv files in $dir');
      return;
    }
    _setFiles(all, autoRun: true, append: append);
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Run
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _run() async {
    if (_running) return;
    if (_groups.isEmpty) {
      setState(() => _error = 'Select at least one *.features.csv file.');
      return;
    }
    final targets = _showAllGroups
        ? _groups
        : (_currentGroup != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    final runnableTargets = targets.where((g) => g.activeFiles.isNotEmpty).toList();
    if (runnableTargets.isEmpty) {
      setState(() => _error = 'Select at least one active file in the plot group.');
      return;
    }

    var baseSettings = _readSettings();
    if (_features.isNotEmpty && !_features.contains(baseSettings.feature)) {
      baseSettings = baseSettings.copyWith(feature: _features.first);
    }
    setState(() {
      _s = baseSettings;
      _running = true;
      _progress = 0;
      _status = 'Starting…';
      _error = null;
    });

    final sw = Stopwatch()..start();
    try {
      for (var i = 0; i < runnableTargets.length; i++) {
        final g = runnableTargets[i];
        final groupRecId = g.recId.isNotEmpty ? g.recId : _s.recId;
        var groupSettings = _s.copyWith(recId: groupRecId);
        final sNames = g.sessionNames;
        if (g.baselineSession != null &&
            sNames.any((n) => n.contains(g.baselineSession!))) {
          groupSettings = groupSettings.copyWith(baselineSession: g.baselineSession!);
        }
        groupSettings = settingsForSessions(groupSettings, sNames);

        final key = groupSettings.statsKey(g.activeFiles);
        final cached = _cache[key];
        if (cached != null) {
          final res = cached.withDisplay(groupSettings);
          g.result = res;
          g.figure = TopoFigure(res);
          continue;
        }

        final groupLabel = groupRecId.isNotEmpty ? groupRecId : 'Group ${i + 1}';
        setState(() {
          _status = runnableTargets.length > 1
              ? 'Computing [$groupLabel] (${i + 1}/${runnableTargets.length})…'
              : 'Computing $groupLabel…';
          _progress = i / runnableTargets.length;
        });

        final job = await startTopoStatsJob(
          files: g.activeFiles,
          settings: groupSettings,
          features: [groupSettings.feature],
          onProgress: (p, m) {
            if (!mounted) return;
            setState(() {
              _progress = (i + p) / runnableTargets.length;
              _status = runnableTargets.length > 1 ? '[$groupLabel] $m' : m;
            });
          },
        );
        _job = job;
        final r = await job.results.first;
        _cache[key] = r;
        g.result = r;
        g.figure = TopoFigure(r);
      }
      if (!mounted) return;
      setState(() {
        _hoverHit = null;
        _hoverGroup = null;
        _status =
            'Computed ${runnableTargets.length} group${runnableTargets.length == 1 ? '' : 's'}  ·  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _job = null;
      if (mounted) setState(() => _running = false);
    }
  }

  void _show(TopoStatsResult r) {
    setState(() {
      if (_currentGroup != null) {
        _currentGroup!.result = r;
        _currentGroup!.figure = TopoFigure(r);
      }
      _hoverHit = null;
      _hoverGroup = null;
    });
  }

  /// Display-only settings changed -> rebuild the figures without re-running
  /// the permutation statistics.
  void _redisplay() {
    final s = _readSettings();
    setState(() {
      _s = s;
      for (final g in _groups) {
        final r = g.result;
        if (r != null) {
          final updated = r.withDisplay(s.copyWith(recId: g.recId));
          g.result = updated;
          g.figure = TopoFigure(updated);
        }
      }
    });
  }

  void _stepFeature(int d) {
    if (_features.isEmpty) return;
    final i = _features.indexOf(_s.feature);
    final n = (i + d) % _features.length;
    setState(
      () => _s = _s.copyWith(
        feature: _features[n < 0 ? n + _features.length : n],
      ),
    );
    _run();
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Export
  // ───────────────────────────────────────────────────────────────────────

  String get _defaultOutDir {
    final dir = _sourceDir ?? Directory.current.path;
    return '$dir${Platform.pathSeparator}Figures_TopoStats';
  }

  Future<String?> _savePath(String name, String ext) async {
    final out = _defaultOutDir;
    try {
      Directory(out).createSync(recursive: true);
    } catch (_) {}
    return FilePicker.saveFile(
      dialogTitle: 'Save $ext',
      fileName: '$name.$ext',
      initialDirectory: out,
      type: FileType.custom,
      allowedExtensions: [ext],
    );
  }

  Future<void> _exportPng() async {
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    if (active.isEmpty) return;
    if (active.length == 1) {
      final fig = active.first.figure!;
      final path = await _savePath(fig.result.outputFileName, 'png');
      if (path == null) return;
      final bytes = await fig.toPng(dpi: _s.dpi.toDouble());
      await File(path).writeAsBytes(bytes);
      _snack(
        'Saved ${_base(path)} (${(fig.widthIn * _s.dpi).round()}×${(fig.heightIn * _s.dpi).round()} px)',
      );
    } else {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select folder for group figures',
        initialDirectory: _defaultOutDir,
      );
      if (dir == null) return;
      for (final g in active) {
        final fig = g.figure!;
        final p = '$dir${Platform.pathSeparator}${fig.result.outputFileName}.png';
        await File(p).writeAsBytes(await fig.toPng(dpi: _s.dpi.toDouble()));
      }
      _snack('Saved ${active.length} figure PNGs to ${_base(dir)}');
    }
  }

  Future<void> _exportPdf() async {
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    if (active.isEmpty) return;

    final firstFig = active.first.figure!;
    final defaultName = active.length == 1
        ? firstFig.result.outputFileName
        : '${_s.feature}_multi_group_report';
    final path = await _savePath(defaultName, 'pdf');
    if (path == null) return;

    final doc = pw.Document(
      title: defaultName,
      creator: 'CCS EEG Studio',
    );
    for (final g in active) {
      final fig = g.figure!;
      final png = await fig.toPng(dpi: math.max(300, _s.dpi).toDouble());
      final fmt = PdfPageFormat(
        fig.widthIn * PdfPageFormat.inch,
        fig.heightIn * PdfPageFormat.inch,
      );
      doc.addPage(
        pw.Page(
          pageFormat: fmt,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
        ),
      );
    }
    await File(path).writeAsBytes(await doc.save());
    _snack('Saved ${_base(path)} (${active.length} page${active.length == 1 ? '' : 's'})');
  }

  Future<void> _exportCsv() async {
    final active = _showAllGroups
        ? _groups.where((g) => g.result != null).toList()
        : (_currentGroup?.result != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    if (active.isEmpty) return;
    if (active.length == 1) {
      final r = active.first.result!;
      final path = await _savePath('${r.outputFileName}_stats', 'csv');
      if (path == null) return;
      await File(path).writeAsString(r.toCsv());
      _snack('Saved ${_base(path)}');
    } else {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select folder for group statistics CSVs',
        initialDirectory: _defaultOutDir,
      );
      if (dir == null) return;
      for (final g in active) {
        final r = g.result!;
        final p = '$dir${Platform.pathSeparator}${r.outputFileName}_stats.csv';
        await File(p).writeAsString(r.toCsv());
      }
      _snack('Saved ${active.length} stats CSVs to ${_base(dir)}');
    }
  }

  Future<void> _copyPng() async {
    final fig = _currentGroup?.figure ?? _figure;
    if (fig == null) return;
    final tmp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}${fig.result.outputFileName}.png',
    );
    await tmp.writeAsBytes(await fig.toPng(dpi: _s.dpi.toDouble()));
    await Clipboard.setData(ClipboardData(text: tmp.path));
    _snack('PNG written to ${tmp.path} (path copied)');
  }

  Future<void> _exportAll() async {
    if (_running) return;
    final active = _showAllGroups
        ? _groups.where((g) => g.activeFiles.isNotEmpty).toList()
        : (_currentGroup?.activeFiles.isNotEmpty == true ? [_currentGroup!] : <TopoPlotGroup>[]);
    if (active.isEmpty) return;
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Output folder for all feature figures',
      initialDirectory: _dir(active.first.activeFiles.first),
    );
    if (dir == null) return;
    final s = _readSettings();
    final features = kReferenceFeatureList.where(_features.contains).toList();
    if (features.isEmpty) features.add(s.feature);
    setState(() {
      _running = true;
      _progress = 0;
      _status = 'Exporting ${features.length} features across ${active.length} groups…';
      _error = null;
    });
    var saved = 0;
    final errors = <String>[];
    try {
      final totalSteps = features.length * active.length;
      var step = 0;
      for (final g in active) {
        final groupRecId = g.recId.isNotEmpty ? g.recId : s.recId;
        var groupSettings = s.copyWith(recId: groupRecId);
        final sNames = g.sessionNames;
        if (g.baselineSession != null &&
            sNames.any((n) => n.contains(g.baselineSession!))) {
          groupSettings = groupSettings.copyWith(baselineSession: g.baselineSession!);
        }
        groupSettings = settingsForSessions(groupSettings, sNames);

        final job = await startTopoStatsJob(
          files: g.activeFiles,
          settings: groupSettings,
          features: features,
          onProgress: (p, m) {
            if (mounted) {
              setState(() {
                _progress = (step + p) / totalSteps;
                _status = '[$groupRecId] $m';
              });
            }
          },
          onFeatureError: (f, e) => errors.add('[$groupRecId] $f: $e'),
        );
        _job = job;
        await for (final r in job.results) {
          _cache[r.settings.statsKey(g.activeFiles)] = r;
          final fig = TopoFigure(r);
          final out = '$dir${Platform.pathSeparator}${r.outputFileName}';
          await File(
            '$out.png',
          ).writeAsBytes(await fig.toPng(dpi: s.dpi.toDouble()));
          await File('${out}_stats.csv').writeAsString(r.toCsv());
          saved++;
          step++;
          if (mounted && r.settings.feature == s.feature) {
            g.result = r;
            g.figure = fig;
          }
        }
      }
      _snack(
        'Saved $saved figure${saved == 1 ? '' : 's'} to $dir'
        '${errors.isEmpty ? '' : ' (${errors.length} skipped)'}',
      );
      if (errors.isNotEmpty && mounted) {
        setState(() => _error = errors.join('\n'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _job = null;
      if (mounted) {
        setState(() {
          _running = false;
          _status = 'Exported $saved / ${features.length * active.length} figures → $dir';
        });
      }
    }
  }

  void _cancel() {
    _job?.cancel();
    _job = null;
    setState(() {
      _running = false;
      _status = 'Cancelled';
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(m)));
  }

  // ───────────────────────────────────────────────────────────────────────
  //  UI
  // ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: Material(color: _panel, child: _buildSettings()),
        ),
        const VerticalDivider(width: 1, color: _border),
        Expanded(
          child: Material(
            color: _bg,
            child: Column(
              children: [
                _buildToolbar(),
                if (_running)
                  LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress,
                    minHeight: 3,
                    color: _amber,
                    backgroundColor: _card,
                  ),
                Expanded(child: _buildCanvas()),
                _buildStatusBar(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: _amber),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _amber,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  InputDecoration _dec(String label, {String? suffix, String? hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
        isDense: true,
        labelStyle: const TextStyle(color: _muted, fontSize: 11),
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
        suffixStyle: const TextStyle(color: _muted, fontSize: 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _border),
          borderRadius: BorderRadius.circular(6),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: _amber),
          borderRadius: BorderRadius.circular(6),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      );

  Widget _num(
    TextEditingController c,
    String label, {
    String? suffix,
    String? hint,
    String? tip,
    ValueChanged<String>? onSubmitted,
    ValueChanged<String>? onChanged,
  }) {
    final f = TextField(
      controller: c,
      style: const TextStyle(color: _text, fontSize: 12),
      decoration: _dec(label, suffix: suffix, hint: hint),
      onSubmitted: onSubmitted ?? (_) => _run(),
      onChanged: onChanged,
    );
    return tip == null ? f : Tooltip(message: tip, child: f);
  }

  Widget _drop<T>(
    String label,
    T value,
    Map<T, String> items,
    ValueChanged<T> onChanged, {
    String? tip,
  }) {
    if (items.isEmpty) {
      return InputDecorator(
        decoration: _dec(label),
        child: const Text('—', style: TextStyle(color: _muted, fontSize: 12)),
      );
    }
    final w = InputDecorator(
      decoration: _dec(label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: items.containsKey(value) ? value : items.keys.first,
          isDense: true,
          isExpanded: true,
          dropdownColor: _card,
          style: const TextStyle(color: _text, fontSize: 12),
          items: [
            for (final e in items.entries)
              DropdownMenuItem<T>(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _running
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
        ),
      ),
    );
    return tip == null ? w : Tooltip(message: tip, child: w);
  }

  Widget _pair(Widget a, Widget b) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 8),
        Expanded(child: b),
      ],
    ),
  );

  Widget _one(Widget a) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: a);

  Widget _buildSettings() {
    final names = _sessionNames;
    final s = _s;
    final baselineValue = names.firstWhere(
      (n) => n.contains(s.baselineSession),
      orElse: () => names.isEmpty ? '' : names.first,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _section('RECORDINGS', icon: Icons.folder_copy_outlined, [
          if (_groups.length > 1) ...[
            _drop<int>(
              'Active plot group (edit below)',
              _selectedGroupIndex,
              {
                for (var i = 0; i < _groups.length; i++)
                  i: '${i + 1}: ${_groups[i].recId.isEmpty ? "Group ${i + 1}" : _groups[i].recId} (${_groups[i].activeFiles.length} files)',
              },
              (idx) {
                setState(() {
                  _selectedGroupIndex = idx;
                  if (_currentGroup != null) {
                    _s = _s.copyWith(
                      recId: _currentGroup!.recId,
                      baselineSession: _currentGroup!.baselineSession ?? '',
                    );
                  }
                });
                _syncControllers();
              },
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _showAllGroups,
                    visualDensity: VisualDensity.compact,
                    activeColor: _amber,
                    onChanged: (v) => setState(() => _showAllGroups = v ?? true),
                  ),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Display all groups stacked',
                    style: TextStyle(color: _text, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : () => _pickFolder(append: false),
                  icon: const Icon(Icons.folder_open, size: 14),
                  label: const Text('Open folder', style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : () => _pickFolder(append: true),
                  icon: const Icon(Icons.add_to_photos_outlined, size: 14),
                  label: const Text('Add group', style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : () => _pickFiles(append: false),
                  icon: const Icon(Icons.description_outlined, size: 14),
                  label: const Text('Choose CSVs', style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : () => _pickFiles(append: true),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add CSVs', style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_activeFiles.length} selected / ${_files.length} available'
            '${_currentGroup != null && _currentGroup!.recId.isNotEmpty ? " (${_currentGroup!.recId})" : ""}',
            style: const TextStyle(
              color: _text,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _sessionSearch,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: _text, fontSize: 12),
            decoration: _dec('Search session in active group'),
          ),
          Wrap(
            children: [
              TextButton(
                onPressed: _running || _files.isEmpty
                    ? null
                    : () {
                        final g = _currentGroup;
                        if (g == null) return;
                        setState(() {
                          g.disabled.clear();
                          for (final f in g.files) {
                            if (!_base(f).toLowerCase().contains(
                              _sessionSearch.text.toLowerCase(),
                            )) {
                              g.disabled.add(f);
                            }
                          }
                        });
                        _run();
                      },
                child: const Text('Compare matching', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running || _files.isEmpty
                    ? null
                    : () {
                        final g = _currentGroup;
                        if (g == null) return;
                        setState(() => g.disabled.clear());
                        _run();
                      },
                child: const Text('Select all', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: _running || _files.isEmpty
                    ? null
                    : () {
                        final g = _currentGroup;
                        if (g == null) return;
                        setState(() => g.disabled.addAll(g.files));
                        _run();
                      },
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          if (_files.length > 8)
            const Text(
              'Initially select up to 8 recordings for readability. Search and compare matching to change the subset.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
          if (_files.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Select recordings to compare. Plots update automatically; '
                'the baseline stays within your selection.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ),
          if (_files.isEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: _border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, size: 14, color: _muted),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'No feature CSV yet — run Feature Extraction or pick files',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            )
          else
            SizedBox(
              height: math.min(
                240,
                50.0 *
                    _files
                        .where(
                          (f) => _base(f).toLowerCase().contains(
                            _sessionSearch.text.toLowerCase(),
                          ),
                        )
                        .length,
              ),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final f in _files.where(
                    (f) => _base(
                      f,
                    ).toLowerCase().contains(_sessionSearch.text.toLowerCase()),
                  ))
                    InkWell(
                      onTap: _running
                          ? null
                          : () => _toggleSession(f, _disabled.contains(f)),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 26,
                            height: 26,
                            child: Checkbox(
                              value: !_disabled.contains(f),
                              visualDensity: VisualDensity.compact,
                              activeColor: _amber,
                              onChanged: _running
                                  ? null
                                  : (v) => _toggleSession(f, v == true),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Tooltip(
                              message: f,
                              child: Text(
                                cleanSegmentName(
                                  _base(f),
                                  _currentGroup?.recId ?? s.recId,
                                ),
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _disabled.contains(f) ? _muted : _text,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Move earlier',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.arrow_upward, size: 14),
                            onPressed: _running
                                ? null
                                : () => _moveSession(f, -1),
                          ),
                          IconButton(
                            tooltip: 'Move later',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.arrow_downward, size: 14),
                            onPressed: _running
                                ? null
                                : () => _moveSession(f, 1),
                          ),
                          IconButton(
                            tooltip: 'Line color',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.circle,
                              size: 14,
                              color: Color(_s.sessionColors[f] ?? 0xFFD62728),
                            ),
                            onPressed: _running
                                ? null
                                : () => _chooseSessionColor(f),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          _one(
            _num(
              _recId,
              'Recording ID (rec_ID)',
              tip:
                  'Stripped from file names to get session labels, e.g. '
                  '1_<rec_ID>_EO_EC_AT_VP.features.csv → EO_EC_AT_VP',
            ),
          ),
        ]),
        _section('FEATURE', icon: Icons.analytics_outlined, [
          _one(
            _features.isEmpty
                ? Text(
                    s.feature,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  )
                : _drop<String>(
                    'Feature',
                    s.feature,
                    {for (final f in _features) f: f},
                    (v) {
                      setState(() => _s = _s.copyWith(feature: v));
                      _run();
                    },
                  ),
          ),
        ]),
        _section('BASELINE', icon: Icons.flag_outlined, [
          _one(
            _drop<String>(
              'Baseline session',
              baselineValue,
              {for (final n in names) n: n},
              (v) {
                if (_currentGroup != null) {
                  _currentGroup!.baselineSession = v;
                }
                setState(() => _s = _s.copyWith(baselineSession: v));
                _run();
              },
              tip: 'BASELINE_SESSION (substring match on the session name)',
            ),
          ),
          _pair(
            _num(_bTmin, 'Start', suffix: 'min'),
            _num(_bDur, 'Duration', suffix: 'min'),
          ),
        ]),
        _section('WINDOWS & LINE PLOT', icon: Icons.stacked_line_chart, [
          _pair(
            _num(_seg, 'Window', suffix: 'min', tip: 'SEGMENT_DURATION_MIN'),
            _num(_epoch, 'Epoch', suffix: 's', tip: 'epoch_size'),
          ),
          _pair(
            _num(
              _smooth,
              'Smoothing',
              suffix: 'ep',
              tip: 'window_size (rolling mean, epochs)',
            ),
            _drop<String>(
              'Band',
              s.shadeMetric,
              const {'ci95': '95% CI', 'sem': 'SEM', 'sd': 'SD'},
              (v) => setState(() => _s = _s.copyWith(shadeMetric: v)),
            ),
          ),
          _one(
            _drop<String>(
              'Representative channel',
              s.reprChan ?? '—',
              {'—': 'None', for (final c in s.channels) c: c},
              (v) => setState(
                () => _s = _s.copyWith(reprChan: v == '—' ? null : v),
              ),
            ),
          ),
        ]),
        _section('STATISTICS (e-TFCE + BH-FDR)', icon: Icons.functions, [
          _pair(_num(_nPerm, 'Permutations'), _num(_seed, 'Seed')),
          _pair(_num(_tfceStart, 'TFCE start'), _num(_tfceStep, 'TFCE step')),
          _one(
            _drop<TfceFormula>(
              'TFCE height term',
              s.tfceFormula,
              const {
                TfceFormula.legacy: 'MNE ≤ 1.12  (h = dh²)',
                TfceFormula.riemann: 'MNE ≥ 1.13  (h = t²·dh)',
              },
              (v) => setState(() => _s = _s.copyWith(tfceFormula: v)),
              tip:
                  'MNE 1.13 changed the TFCE integral. Your reference figures were '
                  'produced with the ≤ 1.12 formula.',
            ),
          ),
          _pair(
            _drop<String>(
              'FDR scope',
              s.fdrScope,
              const {
                'feature': 'feature',
                'session': 'session',
                'none': 'none',
              },
              (v) => setState(() => _s = _s.copyWith(fdrScope: v)),
            ),
            _num(_alpha, 'α'),
          ),
        ]),
        _section('TOPOMAPS', icon: Icons.bubble_chart_outlined, [
          _one(
            _drop<TopoValue>(
              'Colour by',
              s.topoValue,
              const {
                TopoValue.tfce: 'e-TFCE statistic (as script)',
                TopoValue.rawT: 'Welch t (raw)',
              },
              (v) {
                setState(() => _s = _s.copyWith(topoValue: v));
                _redisplay();
              },
              tip:
                  'The script plots MNE\'s returned t_obs, which for a TFCE '
                  'threshold is the TFCE-enhanced statistic.',
            ),
          ),
          _pair(
            _drop<String>(
              'Colormap',
              s.topoCmap,
              {for (final k in kMplColormaps.keys) k: k},
              (v) {
                setState(() => _s = _s.copyWith(topoCmap: v));
                _redisplay();
              },
            ),
            _num(
              _vabs,
              '± limit',
              hint: 'auto',
              tip: 'TOPO_VABS (empty = auto from data)',
            ),
          ),
          _pair(
            _num(
              _topoW,
              'Topo width',
              suffix: 'in',
              tip: 'TARGET_TOPO_WIDTH_IN: reduce (e.g. 0.35 in) to decrease lateral spread for long sessions',
              onSubmitted: (_) {
                final w = double.tryParse(_topoW.text.trim());
                if (w != null) {
                  setState(() => _s = _s.copyWith(targetTopoWidthIn: w.clamp(0.15, 3.0)));
                  _redisplay();
                }
              },
            ),
            _num(_dpi, 'Export', suffix: 'dpi'),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const Text('Width:', style: TextStyle(color: _muted, fontSize: 10)),
                const SizedBox(width: 4),
                for (final (label, val) in [
                  ('Compact', 0.35),
                  ('Medium', 0.5),
                  ('Wide', 0.8),
                ]) ...[
                  InkWell(
                    onTap: _running
                        ? null
                        : () {
                            _topoW.text = '$val';
                            setState(() => _s = _s.copyWith(targetTopoWidthIn: val));
                            _redisplay();
                          },
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: _panel,
                        border: Border.all(
                          color: (_s.targetTopoWidthIn - val).abs() < 0.05
                              ? _amber
                              : _border,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$label ($val")',
                        style: TextStyle(
                          color: (_s.targetTopoWidthIn - val).abs() < 0.05
                              ? _amber
                              : _muted,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _running || _activeFiles.isEmpty ? null : _run,
                  icon: const Icon(Icons.stacked_line_chart, size: 16),
                  label: Text(widget.runLabel),
                  style: FilledButton.styleFrom(
                    backgroundColor: _amber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _running || _activeFiles.isEmpty
                      ? null
                      : _exportAll,
                  icon: const Icon(Icons.collections_outlined, size: 15),
                  label: const Text(
                    'Export all features…',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _text,
                    side: const BorderSide(color: _border),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              if (_running) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    size: 15,
                    color: Colors.redAccent,
                  ),
                  label: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _tbButton(IconData icon, String tip, VoidCallback? onTap) =>
      IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        color: _text,
        disabledColor: Colors.white24,
        visualDensity: VisualDensity.compact,
      );

  Widget _buildToolbar() {
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    final hasFig = active.isNotEmpty && !_running;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: _card,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.stacked_line_chart, size: 16, color: _amber),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _text,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          if (_groups.length > 1) ...[
            const SizedBox(width: 8),
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                _showAllGroups ? Icons.view_agenda : Icons.crop_square,
                size: 13,
                color: _amber,
              ),
              label: Text(
                _showAllGroups
                    ? 'Stacked (${_groups.length} groups)'
                    : 'Single group',
                style: const TextStyle(color: _text, fontSize: 11),
              ),
              backgroundColor: _panel,
              side: const BorderSide(color: _border),
              onPressed: () => setState(() => _showAllGroups = !_showAllGroups),
            ),
          ],
          const SizedBox(width: 10),
          _tbButton(
            Icons.chevron_left,
            'Previous feature',
            _running ? null : () => _stepFeature(-1),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              _s.feature,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _amber,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _tbButton(
            Icons.chevron_right,
            'Next feature',
            _running ? null : () => _stepFeature(1),
          ),
          const Spacer(),
          _tbButton(
            Icons.zoom_out,
            'Zoom out',
            active.isEmpty ? null : () => _zoomBy(1 / 1.25),
          ),
          TextButton(
            onPressed: active.isEmpty ? null : () => setState(() => _fit = true),
            child: Text(
              _fit ? 'Fit' : '${(_ppi / 72 * 100).round()}%',
              style: TextStyle(color: _fit ? _amber : _text, fontSize: 12),
            ),
          ),
          _tbButton(
            Icons.zoom_in,
            'Zoom in',
            active.isEmpty ? null : () => _zoomBy(1.25),
          ),
          const SizedBox(width: 8),
          const SizedBox(height: 24, child: VerticalDivider(color: _border)),
          _tbButton(
            Icons.image_outlined,
            active.length > 1 ? 'Export PNGs for all groups' : 'Export PNG (${_s.dpi} dpi)',
            hasFig ? _exportPng : null,
          ),
          _tbButton(
            Icons.picture_as_pdf_outlined,
            active.length > 1 ? 'Export multi-page PDF (all groups)' : 'Export PDF',
            hasFig ? _exportPdf : null,
          ),
          _tbButton(
            Icons.table_view_outlined,
            active.length > 1 ? 'Export statistics CSVs for all groups' : 'Export statistics CSV',
            hasFig ? _exportCsv : null,
          ),
          _tbButton(
            Icons.copy_outlined,
            'Write PNG to a temp file and copy its path',
            hasFig ? _copyPng : null,
          ),
        ],
      ),
    );
  }

  double _fitPpi(BoxConstraints c, List<TopoPlotGroup> active) {
    if (active.isEmpty) return 110.0;
    if (active.length == 1) {
      final h = math.max(100.0, c.maxHeight - 24);
      return h / active.first.figure!.heightIn;
    }
    final maxWIn = active.fold<double>(
      0.0,
      (m, g) => math.max(m, g.figure!.widthIn),
    );
    return math.max(60.0, (c.maxWidth - 56) / math.max(1.0, maxWIn));
  }

  BoxConstraints? _lastConstraints;

  void _zoomBy(double f, {Offset? focus}) {
    final c = _lastConstraints;
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    if (c == null || active.isEmpty) return;
    final old = _fit ? _fitPpi(c, active) : _ppi;
    final next = (old * f).clamp(20.0, 1200.0);
    setState(() {
      _fit = false;
      _ppi = next;
    });
    // keep the focus point stationary
    if (focus != null && _hScroll.hasClients) {
      final dx = (_hScroll.offset + focus.dx) * (next / old) - focus.dx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_hScroll.hasClients) {
          _hScroll.jumpTo(dx.clamp(0.0, _hScroll.position.maxScrollExtent));
        }
      });
    }
  }

  Widget _buildGroupCard(TopoPlotGroup g, double ppi, bool showHeader) {
    final fig = g.figure!;
    final w = fig.widthIn * ppi;
    final h = fig.heightIn * ppi;
    final isHovered = _hoverGroup == g && _hoverHit != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showHeader)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: const BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                border: Border(bottom: BorderSide(color: _border)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers_outlined, size: 15, color: _amber),
                  const SizedBox(width: 8),
                  Text(
                    g.recId.isEmpty ? 'Plot Group' : g.recId,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${g.activeFiles.length} sessions · baseline: ${g.result?.baselineName ?? g.baselineSession ?? "first"}',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                  const Spacer(),
                  if (_groups.length > 1)
                    IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      tooltip: 'Remove plot group',
                      visualDensity: VisualDensity.compact,
                      onPressed: _running ? null : () => _removeGroup(g),
                    ),
                ],
              ),
            ),
          MouseRegion(
            cursor: isHovered && _hoverHit!.isTopo
                ? SystemMouseCursors.click
                : SystemMouseCursors.precise,
            onHover: (e) {
              final hit = fig.hitTest(e.localPosition / ppi);
              setState(() {
                _hoverGroup = g;
                _hoverHit = hit;
                _hoverPos = e.localPosition;
              });
            },
            onExit: (_) {
              if (_hoverGroup == g) {
                setState(() {
                  _hoverGroup = null;
                  _hoverHit = null;
                });
              }
            },
            child: GestureDetector(
              onTapUp: (d) {
                final hit = fig.hitTest(d.localPosition / ppi);
                if (hit != null && hit.isTopo) {
                  _openTopoDetail(fig, hit);
                }
              },
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        size: Size(w, h),
                        painter: _FigurePainter(fig, ppi),
                      ),
                    ),
                    if (isHovered)
                      CustomPaint(
                        size: Size(w, h),
                        painter: _HoverPainter(fig, ppi, _hoverHit!),
                      ),
                    if (isHovered) _tooltip(fig, _hoverHit!, w, h),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);

    if (_error != null && active.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }
    if (active.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.stacked_line_chart,
              size: 48,
              color: _amber.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              _running
                  ? _status
                  : (_groups.isEmpty
                      ? 'Run feature extraction first, then view results.'
                      : 'Press "${widget.runLabel}" to compute the figure.'),
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        _lastConstraints = c;
        final ppi = _fit ? _fitPpi(c, active) : _ppi;

        final content = Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed || keys.isMetaPressed) {
                _zoomBy(
                  e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1,
                  focus: e.localPosition,
                );
              }
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final g in active)
                _buildGroupCard(g, ppi, active.length > 1),
            ],
          ),
        );

        return Scrollbar(
          controller: _hScroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _hScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Scrollbar(
              controller: _vScroll,
              child: SingleChildScrollView(
                controller: _vScroll,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tooltip(TopoFigure fig, TopoHit hit, double w, double h) {
    final text = fig.describe(hit);
    const tw = 230.0;
    var left = _hoverPos.dx + 14;
    var top = _hoverPos.dy + 14;
    if (left + tw > w) left = _hoverPos.dx - tw - 14;
    if (top + 110 > h) top = math.max(0, _hoverPos.dy - 110);
    return Positioned(
      left: math.max(0, left),
      top: top,
      child: IgnorePointer(
        child: Container(
          width: tw,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xF01E293B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _amber.withValues(alpha: 0.6)),
          ),
          child: Text(
            text,
            style: const TextStyle(color: _text, fontSize: 11, height: 1.35),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    final active = _showAllGroups
        ? _groups.where((g) => g.figure != null).toList()
        : (_currentGroup?.figure != null ? [_currentGroup!] : <TopoPlotGroup>[]);
    final r = _result;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: _panel,
      child: Row(
        children: [
          if (_error != null && active.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(
                Icons.error_outline,
                size: 13,
                color: Colors.redAccent,
              ),
            ),
          Expanded(
            child: Text(
              _error != null && active.isNotEmpty
                  ? _error!.split('\n').first
                  : (_status.isNotEmpty
                        ? _status
                        : (active.isEmpty
                              ? ''
                              : (active.length > 1
                                    ? '${active.length} plot groups stacked · ${_s.feature}'
                                    : '${r?.sessions.length ?? 0} sessions · ${r?.totalWindows ?? 0} windows'))),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _error != null && active.isNotEmpty
                    ? Colors.redAccent
                    : _muted,
                fontSize: 11,
              ),
            ),
          ),
          if (r != null)
            Flexible(
              child: Text(
                overflow: TextOverflow.ellipsis,
                'baseline ${r.baselineName} [${pyFloat(r.baselineTmin)}–${pyFloat(r.baselineTmax)} min]'
                '  ·  ${_groups.length > 1 ? '${active.length} groups' : (_figure == null ? '' : '${_figure!.widthIn.toStringAsFixed(1)} × ${_figure!.heightIn.toStringAsFixed(1)} in')}',
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  void _openTopoDetail(TopoFigure fig, TopoHit hit) {
    showDialog<void>(
      context: context,
      builder: (ctx) =>
          _TopoDetailDialog(fig: fig, session: hit.session, window: hit.window),
    );
  }
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.fig, this.ppi);
  final TopoFigure fig;
  final double ppi;
  @override
  void paint(Canvas canvas, Size size) => fig.paint(canvas, ppi);
  @override
  bool shouldRepaint(_FigurePainter old) => old.fig != fig || old.ppi != ppi;
}

class _HoverPainter extends CustomPainter {
  _HoverPainter(this.fig, this.ppi, this.hit);
  final TopoFigure fig;
  final double ppi;
  final TopoHit hit;
  @override
  void paint(Canvas canvas, Size size) => fig.paintHover(canvas, ppi, hit);
  @override
  bool shouldRepaint(_HoverPainter old) =>
      old.hit != hit || old.ppi != ppi || old.fig != fig;
}

class _TopoDetailDialog extends StatelessWidget {
  const _TopoDetailDialog({
    required this.fig,
    required this.session,
    required this.window,
  });
  final TopoFigure fig;
  final int session;
  final int window;

  @override
  Widget build(BuildContext context) {
    final r = fig.result;
    final s = r.settings;
    final sess = r.sessions[session];
    final w = sess.windows[window];
    final rows = <int>[for (var c = 0; c < s.channels.length; c++) c];
    if (w.hasStats) {
      rows.sort((a, b) => w.tObs![b].abs().compareTo(w.tObs![a].abs()));
    }
    String f(Float64List? v, int c, [int d = 3]) =>
        v == null || v[c].isNaN ? '–' : v[c].toStringAsFixed(d);
    return Dialog(
      backgroundColor: _card,
      child: SizedBox(
        width: 820,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${sess.name}  ·  ${w.tStart.toStringAsFixed(0)}–${w.tEnd.toStringAsFixed(0)} min',
                    style: const TextStyle(
                      color: _text,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: _muted),
                  ),
                ],
              ),
              Text(
                '${s.feature} vs ${r.baselineName} [${pyFloat(r.baselineTmin)}–${pyFloat(r.baselineTmax)} min]  ·  '
                'n = ${w.nTest} epochs  ·  colour ±${fig.vmax.toStringAsFixed(2)}',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 380,
                      height: 420,
                      color: Colors.white,
                      child: CustomPaint(
                        painter: _SingleTopoPainter(fig, session, window),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: w.hasStats
                          ? SingleChildScrollView(
                              child: DataTable(
                                headingRowHeight: 30,
                                dataRowMinHeight: 24,
                                dataRowMaxHeight: 26,
                                columnSpacing: 14,
                                headingTextStyle: const TextStyle(
                                  color: _amber,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                                dataTextStyle: const TextStyle(
                                  color: _text,
                                  fontSize: 11,
                                ),
                                columns: const [
                                  DataColumn(label: Text('Ch')),
                                  DataColumn(
                                    label: Text('e-TFCE'),
                                    numeric: true,
                                  ),
                                  DataColumn(label: Text('t'), numeric: true),
                                  DataColumn(label: Text('p'), numeric: true),
                                  DataColumn(label: Text('q'), numeric: true),
                                  DataColumn(label: Text('sig')),
                                ],
                                rows: [
                                  for (final c in rows)
                                    DataRow(
                                      cells: [
                                        DataCell(Text(s.channels[c])),
                                        DataCell(Text(f(w.tObs, c, 2))),
                                        DataCell(Text(f(w.rawT, c, 2))),
                                        DataCell(Text(f(w.pValues, c))),
                                        DataCell(Text(f(w.qValues, c))),
                                        DataCell(
                                          w.significant != null &&
                                                  w.significant![c]
                                              ? const Icon(
                                                  Icons.check_circle,
                                                  size: 14,
                                                  color: _green,
                                                )
                                              : const Text(''),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            )
                          : Center(
                              child: Text(
                                w.isBaseline
                                    ? 'Baseline window'
                                    : 'Not enough data (n/a)',
                                style: const TextStyle(color: _muted),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SingleTopoPainter extends CustomPainter {
  _SingleTopoPainter(this.fig, this.session, this.window);
  final TopoFigure fig;
  final int session, window;
  @override
  void paint(Canvas canvas, Size size) =>
      fig.paintSingleTopo(canvas, Offset.zero & size, session, window);
  @override
  bool shouldRepaint(_SingleTopoPainter old) => false;
}
