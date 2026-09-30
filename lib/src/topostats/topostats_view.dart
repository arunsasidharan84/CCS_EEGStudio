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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'mpl_colormaps.dart';
import 'topo_interp.dart' show isStandard1020Channel;
import 'topostats_engine.dart';
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

class TopoStatsView extends StatefulWidget {
  const TopoStatsView({
    super.key,
    required this.featureFilePaths,
    this.runLabel = 'Run Plot Generation',
    this.title = 'Plots & Report',
  });

  /// Seed files. A single file is expanded to all sibling sessions of the
  /// same recording (`*_{rec_ID}_*.features.csv`), like the script's glob.
  final List<String> featureFilePaths;
  final String runLabel;
  final String title;

  @override
  State<TopoStatsView> createState() => _TopoStatsViewState();
}

class _TopoStatsViewState extends State<TopoStatsView> {
  TopoStatsSettings _s = const TopoStatsSettings();
  List<String> _files = [];
  final Set<String> _disabled = {};
  List<String> _features = [];

  TopoStatsResult? _result;
  TopoFigure? _figure;
  final Map<String, TopoStatsResult> _cache = {};

  bool _running = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  TopoStatsJob? _job;

  bool _fit = true;
  double _ppi = 110;
  TopoHit? _hover;
  Offset _hoverPos = Offset.zero;
  final _hScroll = ScrollController();
  final _vScroll = ScrollController();

  // text fields
  final _recId = TextEditingController();
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

  @override
  void initState() {
    super.initState();
    _syncControllers();
    _setFiles(widget.featureFilePaths, autoRun: true);
  }

  @override
  void didUpdateWidget(TopoStatsView old) {
    super.didUpdateWidget(old);
    if (old.featureFilePaths.join('|') != widget.featureFilePaths.join('|') &&
        widget.featureFilePaths.isNotEmpty) {
      _setFiles(widget.featureFilePaths, autoRun: true);
    }
  }

  @override
  void dispose() {
    _job?.cancel();
    for (final c in [
      _recId,
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
    _recId.text = _s.recId;
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
    return _s.copyWith(
      recId: _recId.text.trim(),
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
      targetTopoWidthIn: d(_topoW, _s.targetTopoWidthIn).clamp(0.2, 3.0),
      dpi: i(_dpi, _s.dpi).clamp(50, 1200),
    );
  }

  List<String> get _activeFiles => [
    for (final f in _files)
      if (!_disabled.contains(f)) f,
  ];

  List<String> get _sessionNames => [
    for (final f in _activeFiles) cleanSegmentName(_base(f), _s.recId),
  ];

  static String _base(String p) => p.split(RegExp(r'[\\/]')).last;
  static String _dir(String p) {
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? '.' : p.substring(0, i);
  }

  void _setFiles(List<String> seed, {bool autoRun = false}) {
    var files = seed.where((p) => File(p).existsSync()).toList();
    var recId = inferRecId(files);
    if (files.length == 1) {
      final sib = discoverSessionFiles(_dir(files.first), recId);
      if (sib.length > 1) files = sib;
      recId = inferRecId(files);
    } else {
      files.sort();
    }
    _files = files;
    _disabled.clear();
    _features = [];
    if (files.isNotEmpty) {
      try {
        final cols = numericFeatureColumns(files.first);
        final ordered = [
          ...kReferenceFeatureList.where(cols.contains),
          ...cols.where((c) => !kReferenceFeatureList.contains(c)),
        ];
        _features = ordered;
      } catch (_) {}
    }
    var s = _s.copyWith(recId: recId);
    if (_features.isNotEmpty && !_features.contains(s.feature)) {
      s = s.copyWith(feature: _features.first);
    }
    final names = [for (final f in files) cleanSegmentName(_base(f), recId)];
    if (names.isNotEmpty && !names.any((n) => n.contains(s.baselineSession))) {
      s = s.copyWith(baselineSession: names.first);
    }
    // Channels: the script's 32-channel cap when the files use it, else the
    // file's own labels that have standard_1020 positions.
    if (files.isNotEmpty) {
      try {
        final det = detectChannels(files.first);
        final known = det.where(isStandard1020Channel).toList();
        s = s.copyWith(channels: known.length >= 3 ? known : det);
        if (s.reprChan != null && !s.channels.contains(s.reprChan)) {
          s = s.copyWith(reprChan: s.channels.contains('Fz') ? 'Fz' : null);
        }
      } catch (_) {}
    }
    setState(() {
      _s = s;
      _result = null;
      _figure = null;
      _error = null;
      _cache.clear();
    });
    _syncControllers();
    if (autoRun && _activeFiles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run();
      });
    }
  }

  Future<void> _pickFiles() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Select *.features.csv session files',
    );
    final paths =
        pick?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isNotEmpty) _setFiles(paths, autoRun: true);
  }

  Future<void> _pickFolder() async {
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
    _setFiles(all, autoRun: true);
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Run
  // ───────────────────────────────────────────────────────────────────────

  Future<void> _run() async {
    if (_running) return;
    final files = _activeFiles;
    if (files.isEmpty) {
      setState(() => _error = 'Select at least one *.features.csv file.');
      return;
    }
    final s = _readSettings();
    setState(() => _s = s);
    final key = s.statsKey(files);
    final cached = _cache[key];
    if (cached != null) {
      _show(cached.withDisplay(s));
      return;
    }
    setState(() {
      _running = true;
      _progress = 0;
      _status = 'Starting…';
      _error = null;
    });
    final sw = Stopwatch()..start();
    try {
      final job = await startTopoStatsJob(
        files: files,
        settings: s,
        features: [s.feature],
        onProgress: (p, m) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _status = m;
          });
        },
      );
      _job = job;
      final r = await job.results.first;
      _cache[key] = r;
      if (!mounted) return;
      _show(r);
      setState(
        () => _status =
            '${r.log.last}  ·  ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _job = null;
      if (mounted) setState(() => _running = false);
    }
  }

  void _show(TopoStatsResult r) {
    setState(() {
      _result = r;
      _figure = TopoFigure(r);
      _hover = null;
    });
  }

  /// Display-only settings changed -> rebuild the figure without re-running
  /// the permutation statistics.
  void _redisplay() {
    final r = _result;
    if (r == null) return;
    final s = _readSettings();
    if (s.statsKey(_activeFiles) != r.settings.statsKey(_activeFiles)) return;
    _show(r.withDisplay(s));
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
    if (_activeFiles.isEmpty) return Directory.current.path;
    return '${_dir(_activeFiles.first)}${Platform.pathSeparator}Figures_TopoStats';
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
    final fig = _figure;
    if (fig == null) return;
    final path = await _savePath(fig.result.outputFileName, 'png');
    if (path == null) return;
    final bytes = await fig.toPng(dpi: _s.dpi.toDouble());
    await File(path).writeAsBytes(bytes);
    _snack(
      'Saved ${_base(path)} (${(fig.widthIn * _s.dpi).round()}×${(fig.heightIn * _s.dpi).round()} px)',
    );
  }

  Future<Uint8List> _pdfBytes(TopoFigure fig) async {
    final png = await fig.toPng(dpi: math.max(300, _s.dpi).toDouble());
    final doc = pw.Document(
      title: fig.result.outputFileName,
      creator: 'CCS EEG Studio',
    );
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
    return doc.save();
  }

  Future<void> _exportPdf() async {
    final fig = _figure;
    if (fig == null) return;
    final path = await _savePath(fig.result.outputFileName, 'pdf');
    if (path == null) return;
    await File(path).writeAsBytes(await _pdfBytes(fig));
    _snack('Saved ${_base(path)}');
  }

  Future<void> _exportCsv() async {
    final r = _result;
    if (r == null) return;
    final path = await _savePath('${r.outputFileName}_stats', 'csv');
    if (path == null) return;
    await File(path).writeAsString(r.toCsv());
    _snack('Saved ${_base(path)}');
  }

  Future<void> _copyPng() async {
    final fig = _figure;
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
    final files = _activeFiles;
    if (files.isEmpty) return;
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Output folder for all feature figures',
      initialDirectory: _dir(files.first),
    );
    if (dir == null) return;
    final s = _readSettings();
    final features = kReferenceFeatureList.where(_features.contains).toList();
    if (features.isEmpty) features.add(s.feature);
    setState(() {
      _running = true;
      _progress = 0;
      _status = 'Exporting ${features.length} features…';
      _error = null;
    });
    var saved = 0;
    final errors = <String>[];
    try {
      final job = await startTopoStatsJob(
        files: files,
        settings: s,
        features: features,
        onProgress: (p, m) {
          if (mounted) {
            setState(() {
              _progress = p;
              _status = m;
            });
          }
        },
        onFeatureError: (f, e) => errors.add('$f: $e'),
      );
      _job = job;
      await for (final r in job.results) {
        _cache[r.settings.statsKey(files)] = r;
        final fig = TopoFigure(r);
        final out = '$dir${Platform.pathSeparator}${r.outputFileName}';
        await File(
          '$out.png',
        ).writeAsBytes(await fig.toPng(dpi: s.dpi.toDouble()));
        await File('${out}_stats.csv').writeAsString(r.toCsv());
        saved++;
        if (mounted && r.settings.feature == s.feature) _show(r);
      }
      _snack(
        'Saved $saved figure${saved == 1 ? '' : 's'} to $dir'
        '${errors.isEmpty ? '' : ' (${errors.length} skipped)'}',
      );
      if (errors.isNotEmpty && mounted)
        setState(() => _error = errors.join('\n'));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _job = null;
      if (mounted) {
        setState(() {
          _running = false;
          _status = 'Exported $saved / ${features.length} features → $dir';
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
  }) {
    final f = TextField(
      controller: c,
      style: const TextStyle(color: _text, fontSize: 12),
      decoration: _dec(label, suffix: suffix, hint: hint),
      onSubmitted: (_) => _run(),
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
        _section('SESSIONS', icon: Icons.folder_copy_outlined, [
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
            for (final f in _files)
              InkWell(
                onTap: _running
                    ? null
                    : () => setState(() {
                        if (!_disabled.remove(f)) _disabled.add(f);
                      }),
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
                            : (v) => setState(
                                () => v == true
                                    ? _disabled.remove(f)
                                    : _disabled.add(f),
                              ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Tooltip(
                        message: f,
                        child: Text(
                          cleanSegmentName(_base(f), s.recId),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _disabled.contains(f) ? _muted : _text,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : _pickFiles,
                  icon: const Icon(Icons.image_search, size: 14),
                  label: const Text(
                    'Browse / Plot Other CSVs…',
                    style: TextStyle(fontSize: 11),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _amber,
                    side: BorderSide(color: _amber.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Use every *.features.csv in a folder',
                child: IconButton(
                  onPressed: _running ? null : _pickFolder,
                  icon: const Icon(Icons.folder_open, size: 18, color: _amber),
                ),
              ),
            ],
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
              (v) => setState(() => _s = _s.copyWith(baselineSession: v)),
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
              tip: 'TARGET_TOPO_WIDTH_IN',
            ),
            _num(_dpi, 'Export', suffix: 'dpi'),
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
    final hasFig = _figure != null && !_running;
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
            _figure == null ? null : () => _zoomBy(1 / 1.25),
          ),
          TextButton(
            onPressed: _figure == null
                ? null
                : () => setState(() => _fit = true),
            child: Text(
              _fit ? 'Fit' : '${(_ppi / 72 * 100).round()}%',
              style: TextStyle(color: _fit ? _amber : _text, fontSize: 12),
            ),
          ),
          _tbButton(
            Icons.zoom_in,
            'Zoom in',
            _figure == null ? null : () => _zoomBy(1.25),
          ),
          const SizedBox(width: 8),
          const SizedBox(height: 24, child: VerticalDivider(color: _border)),
          _tbButton(
            Icons.image_outlined,
            'Export PNG (${_s.dpi} dpi, like the script)',
            hasFig ? _exportPng : null,
          ),
          _tbButton(
            Icons.picture_as_pdf_outlined,
            'Export PDF',
            hasFig ? _exportPdf : null,
          ),
          _tbButton(
            Icons.table_view_outlined,
            'Export statistics CSV (t, p, q, significance)',
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

  double _fitPpi(BoxConstraints c) {
    final fig = _figure!;
    final h = math.max(100.0, c.maxHeight - 24);
    return h / fig.heightIn;
  }

  double _currentPpi(BoxConstraints c) => _fit ? _fitPpi(c) : _ppi;
  BoxConstraints? _lastConstraints;

  void _zoomBy(double f, {Offset? focus}) {
    final c = _lastConstraints;
    if (c == null || _figure == null) return;
    final old = _currentPpi(c);
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

  Widget _buildCanvas() {
    if (_error != null && _figure == null) {
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
    final fig = _figure;
    if (fig == null) {
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
                  : (_activeFiles.isEmpty
                        ? 'Run feature extraction first, then generate plots.'
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
        final ppi = _currentPpi(c);
        final w = fig.widthIn * ppi, h = fig.heightIn * ppi;
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
          child: MouseRegion(
            cursor: _hover?.isTopo == true
                ? SystemMouseCursors.click
                : SystemMouseCursors.precise,
            onHover: (e) {
              final hit = fig.hitTest(e.localPosition / ppi);
              if (hit != _hover || hit != null) {
                setState(() {
                  _hover = hit;
                  _hoverPos = e.localPosition;
                });
              }
            },
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              onTapUp: (d) {
                final hit = fig.hitTest(d.localPosition / ppi);
                if (hit != null && hit.isTopo) _openTopoDetail(fig, hit);
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
                    if (_hover != null)
                      CustomPaint(
                        size: Size(w, h),
                        painter: _HoverPainter(fig, ppi, _hover!),
                      ),
                    if (_hover != null) _tooltip(fig, w, h),
                  ],
                ),
              ),
            ),
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
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    boxShadow: [
                      BoxShadow(color: Colors.black54, blurRadius: 8),
                    ],
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tooltip(TopoFigure fig, double w, double h) {
    final text = fig.describe(_hover!);
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
    final r = _result;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: _panel,
      child: Row(
        children: [
          if (_error != null && _figure != null)
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
              _error != null && _figure != null
                  ? _error!.split('\n').first
                  : (_status.isNotEmpty
                        ? _status
                        : (r == null
                              ? ''
                              : '${r.sessions.length} sessions · ${r.totalWindows} windows')),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _error != null && _figure != null
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
                '  ·  ${_figure == null ? '' : '${_figure!.widthIn.toStringAsFixed(1)} × ${_figure!.heightIn.toStringAsFixed(1)} in'}',
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
