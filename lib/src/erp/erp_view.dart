// lib/src/erp/erp_view.dart
//
// ERP Analysis module: the compute_mmn_erp.py workflow as an interactive view.
//   1. Epoched files (sessions): stimulus-locked *-epo*.ccseeg.json from
//      Preprocess (or any epoched file with epoch labels).
//   2. Conditions A/B come from the markers found in those files (chips)
//      and/or a regular expression. Templates (MMN/P300/N170/N400) only
//      pre-fill the fields.
//   3. Electrode, epoch times, baseline, component window, permutations,
//      bootstrap and smoothing.
//   4. Output: waveform figure, effect-size figure and statistics table.
//      Hover the waveforms to read values; export PNG / PDF / CSV.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models.dart';
import 'ccseeg_reader.dart';
import 'erp_engine.dart';
import 'erp_figure.dart';
import 'stim_epochs.dart' show markerShortName, markerListContains;
import '../topostats/mne_constants.dart' show kStandard1020Topo;

const _bg = Color(0xFF0F172A);
const _card = Color(0xFF1E293B);
const _muted = Color(0xFF94A3B8);
const _border = Color(0x1FFFFFFF);
const _accent = Color(0xFF3B82F6);
const _blueC = Color(0xFF1F77B4);
const _redC = Color(0xFFD62728);

/// Summary of one epoched file (read without its channel data).
class ErpFileInfo {
  ErpFileInfo({
    required this.path,
    required this.label,
    required this.epochs,
    required this.samplesPerEpoch,
    required this.sampleRate,
    required this.channels,
    required this.markerCounts,
    this.tmin,
    this.tmax,
    this.error,
  });
  final String path, label;
  final int epochs, samplesPerEpoch;
  final double sampleRate;
  final List<String> channels;
  final Map<String, int> markerCounts;
  final double? tmin, tmax;
  final String? error;

  bool get isEpoched => error == null && epochs > 1 && samplesPerEpoch > 0;
}

List<ErpFileInfo> _scanFiles(List<String> paths) => [
  for (final p in paths) _scanFile(p),
];

ErpFileInfo _scanFile(String path) {
  try {
    final d = CcsEegData.read(path, keepChannel: (_) => false);
    final labels = d.epochLabels ?? const <String>[];
    final counts = <String, int>{};
    for (final l in labels) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
    return ErpFileInfo(
      path: path,
      label: d.fileLabel,
      epochs: labels.length,
      samplesPerEpoch: d.sourceEpochSamples ?? 0,
      sampleRate: d.sampleRate,
      channels: d.labels,
      markerCounts: counts,
      tmin: d.epochTmin,
      tmax: d.epochTmax,
      error: labels.isEmpty || (d.sourceEpochSamples ?? 0) <= 0
          ? 'continuous (no stimulus epochs)'
          : null,
    );
  } catch (e) {
    return ErpFileInfo(
      path: path,
      label: path.split(RegExp(r'[\\/]')).last,
      epochs: 0,
      samplesPerEpoch: 0,
      sampleRate: 0,
      channels: const [],
      markerCounts: const {},
      error: '$e',
    );
  }
}

// ── background worker ────────────────────────────────────────────────────

void _erpWorker(List<Object?> args) {
  final port = args[0] as SendPort;
  final paths = (args[1] as List).cast<String>();
  final settings = ErpSettings.fromJson(
    (jsonDecode(args[2] as String) as Map).cast<String, dynamic>(),
  );
  final topoPointSeconds = args[3] as double?;
  try {
    final files = <CcsEegData>[];
    for (var i = 0; i < paths.length; i++) {
      port.send([
        'progress',
        0.02 + 0.08 * i / paths.length,
        'Loading ${paths[i].split(RegExp(r'[\\/]')).last}',
      ]);
      files.add(ErpEngine.load(paths[i]));
    }
    final an = ErpEngine.analyzeFiles(
      files,
      settings,
      onProgress: (p, m) => port.send(['progress', 0.1 + 0.65 * p, m]),
    );
    final topo = ErpEngine.analyzeTopography(
      files,
      settings,
      pointSeconds: topoPointSeconds,
      onProgress: (p, m) => port.send(['progress', 0.75 + 0.25 * p, m]),
    );
    port.send(['done', an, topo]);
  } catch (e) {
    port.send(['error', '$e']);
  }
}

// ── templates ────────────────────────────────────────────────────────────

class _Template {
  const _Template(
    this.name,
    this.component,
    this.a,
    this.b,
    this.w0,
    this.w1, {
    this.tmin = -0.2,
    this.tmax = 0.8,
  });
  final String name, component;
  final ErpCondition a, b;
  final double w0, w1, tmin, tmax;
}

const _templates = <_Template>[
  _Template(
    'MMN (Standard S51 vs Deviant S52)',
    'MMN',
    ErpCondition(name: 'Standard (S51)', markers: ['S 51']),
    ErpCondition(name: 'Deviant (S52)', markers: ['S 52']),
    0.10,
    0.25,
    tmin: -0.5,
    tmax: 1.2,
  ),
  _Template(
    'P300 (Standard vs Target)',
    'P300',
    ErpCondition(name: 'Standard', markers: ['S 10']),
    ErpCondition(name: 'Target', markers: ['S 20']),
    0.25,
    0.50,
  ),
  _Template(
    'N170 (Non-face vs Face)',
    'N170',
    ErpCondition(name: 'Non-Face', markers: ['S 200']),
    ErpCondition(name: 'Face', markers: ['S 100']),
    0.13,
    0.20,
    tmin: -0.2,
    tmax: 0.6,
  ),
  _Template(
    'N400 (Congruent vs Incongruent)',
    'N400',
    ErpCondition(name: 'Congruent', markers: ['S 30']),
    ErpCondition(name: 'Incongruent', markers: ['S 40']),
    0.30,
    0.50,
    tmin: -0.2,
    tmax: 0.9,
  ),
];

// ═══════════════════════════════════════════════════════════════════════

class ErpAnalysisView extends StatefulWidget {
  const ErpAnalysisView({
    super.key,
    this.activeRecording,
    this.extraFiles = const [],
  });

  /// The recording selected in the pipeline. Used when it is an epoched
  /// file on disk.
  final EegRecording? activeRecording;

  /// Other candidate files, e.g. batch preprocessing outputs.
  final List<String> extraFiles;

  @override
  State<ErpAnalysisView> createState() => _ErpAnalysisViewState();
}

class _ErpAnalysisViewState extends State<ErpAnalysisView>
    with SingleTickerProviderStateMixin {
  final List<ErpFileInfo> _files = [];
  final Set<String> _selected = {};
  bool _scanning = false;

  // settings
  final _nameA = TextEditingController(text: 'Standard (S51)');
  final _nameB = TextEditingController(text: 'Deviant (S52)');
  final _regexA = TextEditingController();
  final _regexB = TextEditingController();
  List<String> _markersA = ['S 51'];
  List<String> _markersB = ['S 52'];
  final _component = TextEditingController(text: 'MMN');
  final _tmin = TextEditingController(text: '-0.5');
  final _tmax = TextEditingController(text: '1.2');
  bool _useFileTimes = true;
  final _b0 = TextEditingController(text: '-200');
  final _b1 = TextEditingController(text: '0');
  final _w0 = TextEditingController(text: '100');
  final _w1 = TextEditingController(text: '250');
  final _topoPoint = TextEditingController(text: '175');
  final _nPerm = TextEditingController(text: '1000');
  final _nBoot = TextEditingController(text: '2000');
  final _seed = TextEditingController(text: '42');
  bool _smooth = true;
  String _electrode = 'Fz';

  // results
  ErpAnalysis? _an;
  ErpWaveformFigure? _wave;
  ErpEffectFigure? _effect;
  ErpTopoResult? _topo;
  bool _topoPointMode = false;
  bool _running = false;
  double _progress = 0;
  String _status = '';
  final List<String> _warnings = [];
  late final TabController _tabs = TabController(length: 4, vsync: this);
  double _zoom = 1;
  ErpHit? _hover;
  Isolate? _iso;

  @override
  void initState() {
    super.initState();
    _addDefaults();
  }

  @override
  void didUpdateWidget(ErpAnalysisView old) {
    super.didUpdateWidget(old);
    if (old.activeRecording?.path != widget.activeRecording?.path)
      _addDefaults();
  }

  @override
  void dispose() {
    _iso?.kill(priority: Isolate.immediate);
    for (final c in [
      _nameA,
      _nameB,
      _regexA,
      _regexB,
      _component,
      _tmin,
      _tmax,
      _b0,
      _b1,
      _w0,
      _w1,
      _topoPoint,
      _nPerm,
      _nBoot,
      _seed,
    ]) {
      c.dispose();
    }
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _addDefaults() async {
    final r = widget.activeRecording;
    final cands = <String>[
      if (r != null &&
          File(r.path).existsSync() &&
          r.path.toLowerCase().endsWith('.json'))
        r.path,
      ...widget.extraFiles,
    ];
    if (cands.isNotEmpty) await _addPaths(cands, quiet: true);
  }

  Future<void> _addPaths(List<String> paths, {bool quiet = false}) async {
    final fresh = paths.where((p) => !_files.any((f) => f.path == p)).toList();
    if (fresh.isEmpty) return;
    setState(() => _scanning = true);
    final infos = await compute(_scanFiles, fresh);
    if (!mounted) return;
    setState(() {
      _scanning = false;
      for (final i in infos) {
        if (!i.isEpoched && quiet) continue;
        _files.add(i);
        if (i.isEpoched) _selected.add(i.path);
      }
      _files.sort((a, b) => a.label.compareTo(b.label));
      final chans = _channels;
      if (chans.isNotEmpty && !chans.contains(_electrode)) {
        _electrode = chans.contains('Fz') ? 'Fz' : chans.first;
      }
      final first = _selectedInfos.isEmpty ? null : _selectedInfos.first;
      if (first?.tmin != null) {
        _tmin.text = _fmt(first!.tmin!);
        _tmax.text = _fmt(
          first.tmax ??
              first.tmin! + (first.samplesPerEpoch - 1) / first.sampleRate,
        );
      }
    });
    final bad = infos.where((i) => !i.isEpoched).toList();
    if (bad.isNotEmpty && !quiet && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${bad.length} file(s) are not stimulus-epoched and cannot be used: '
            '${bad.map((b) => b.label).join(', ')}. Enable "Stimulus-locked epochs" in Preprocess.',
          ),
        ),
      );
    }
  }

  String _fmt(double v) =>
      v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

  List<ErpFileInfo> get _selectedInfos => [
    for (final f in _files)
      if (_selected.contains(f.path) && f.isEpoched) f,
  ];

  List<String> get _channels {
    final s = <String>[];
    for (final f in _selectedInfos) {
      for (final c in f.channels) {
        if (!s.contains(c)) s.add(c);
      }
    }
    return s;
  }

  Map<String, int> get _markerCounts {
    final m = <String, int>{};
    for (final f in _selectedInfos) {
      f.markerCounts.forEach((k, v) => m[k] = (m[k] ?? 0) + v);
    }
    return m;
  }

  ErpSettings _settings() {
    double p(TextEditingController c, double d) =>
        double.tryParse(c.text.trim()) ?? d;
    int pi(TextEditingController c, int d) => int.tryParse(c.text.trim()) ?? d;
    return ErpSettings(
      electrode: _electrode,
      condA: ErpCondition(
        name: _nameA.text.trim(),
        markers: _markersA,
        pattern: _regexA.text.trim(),
      ),
      condB: ErpCondition(
        name: _nameB.text.trim(),
        markers: _markersB,
        pattern: _regexB.text.trim(),
      ),
      tmin: p(_tmin, -0.5),
      tmax: p(_tmax, 1.2),
      useFileEpochTimes: _useFileTimes,
      baselineStart: p(_b0, -200) / 1000,
      baselineEnd: p(_b1, 0) / 1000,
      winStart: p(_w0, 100) / 1000,
      winEnd: p(_w1, 250) / 1000,
      nPerm: pi(_nPerm, 1000),
      nBoot: pi(_nBoot, 2000),
      seed: pi(_seed, 42),
      smooth: _smooth,
      componentName: _component.text.trim().isEmpty
          ? 'ERP'
          : _component.text.trim(),
    );
  }

  int _countFor(List<String> markers, String regex) {
    final c = ErpCondition(name: '', markers: markers, pattern: regex);
    var n = 0;
    _markerCounts.forEach((k, v) {
      if (c.matches(k)) n += v;
    });
    return n;
  }

  Future<void> _compute() async {
    final files = _selectedInfos;
    if (files.isEmpty) {
      setState(() => _status = 'Add at least one stimulus-epoched file.');
      return;
    }
    final s = _settings();
    if (_countFor(_markersA, _regexA.text) == 0 ||
        _countFor(_markersB, _regexB.text) == 0) {
      setState(
        () => _status = 'Each condition needs at least one matching marker.',
      );
      return;
    }
    setState(() {
      _running = true;
      _progress = 0;
      _status = 'Starting…';
      _warnings.clear();
    });
    final rp = ReceivePort();
    final done = Completer<void>();
    rp.listen((msg) {
      final m = msg as List;
      switch (m[0]) {
        case 'progress':
          if (mounted) {
            setState(() {
              _progress = (m[1] as double).clamp(0, 1);
              if ((m[2] as String).isNotEmpty) _status = m[2] as String;
            });
          }
        case 'done':
          final an = m[1] as ErpAnalysis;
          final topo = m[2] as ErpTopoResult;
          if (mounted) {
            setState(() {
              _an = an;
              _wave = ErpWaveformFigure(an);
              _effect = ErpEffectFigure(an);
              _topo = topo;
              _warnings
                ..clear()
                ..addAll([for (final r in an.results) ...r.warnings]);
              _status =
                  'Done: ${an.results.length} session(s) at ${an.settings.electrode}.';
            });
          }
          done.complete();
        case 'error':
          if (mounted) setState(() => _status = 'Error: ${m[1]}');
          done.complete();
      }
    });
    _iso = await Isolate.spawn(_erpWorker, [
      rp.sendPort,
      [for (final f in files) f.path],
      jsonEncode(s.toJson()),
      (double.tryParse(_topoPoint.text.trim()) ??
              (s.winStart + s.winEnd) * 500) /
          1000,
    ]);
    await done.future;
    rp.close();
    _iso = null;
    if (mounted) setState(() => _running = false);
  }

  void _cancel() {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    setState(() {
      _running = false;
      _status = 'Cancelled.';
    });
  }

  // ── export ────────────────────────────────────────────────────────────

  Future<void> _export() async {
    final an = _an;
    if (an == null) return;
    final first = an.results.isEmpty ? null : an.results.first.path;
    final defDir = first == null ? null : File(first).parent.path;
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Folder for ERP_analysis_${an.settings.electrode}',
      initialDirectory: defDir,
    );
    if (dir == null) return;
    final out =
        '$dir${Platform.pathSeparator}ERP_analysis_${an.settings.electrode}';
    setState(() => _status = 'Exporting to $out …');
    try {
      final written = await exportErpOutputs(an, out);
      if (mounted)
        setState(() => _status = 'Saved ${written.length} files to $out');
    } catch (e) {
      if (mounted) setState(() => _status = 'Export failed: $e');
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 340, child: _settingsPane()),
          const VerticalDivider(width: 1, color: _border),
          Expanded(child: _resultsPane()),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? trailing}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      );

  Widget _tf(
    TextEditingController c,
    String label, {
    String? suffix,
    bool number = true,
  }) => TextField(
    controller: c,
    enabled: !_running,
    onChanged: (_) => setState(() {}),
    keyboardType: number
        ? const TextInputType.numberWithOptions(signed: true, decimal: true)
        : null,
    style: const TextStyle(color: Colors.white, fontSize: 12),
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      isDense: true,
    ),
  );

  Widget _settingsPane() {
    final counts = _markerCounts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final chans = _channels;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              _section('EPOCHED FILES (SESSIONS)', [
                if (_files.isEmpty)
                  const Text(
                    'Add stimulus-epoched files (*-epo*.ccseeg.json). To make them, enable '
                    '"Stimulus-locked epochs (ERP)" in Preprocess: epochs are cut after '
                    'filtering and before GEDAI.',
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                for (final f in _files)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: _selected.contains(f.path),
                    onChanged: !f.isEpoched || _running
                        ? null
                        : (v) => setState(
                            () => v == true
                                ? _selected.add(f.path)
                                : _selected.remove(f.path),
                          ),
                    title: Text(
                      f.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: f.isEpoched ? Colors.white : _muted,
                      ),
                    ),
                    subtitle: Text(
                      f.isEpoched
                          ? '${f.epochs} epochs · ${f.samplesPerEpoch} samples @ ${f.sampleRate.toStringAsFixed(0)} Hz'
                                '${f.tmin != null ? ' · ${_fmt(f.tmin!)}..${_fmt(f.tmax ?? 0)} s' : ''}'
                          : f.error ?? '',
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.close, size: 14, color: _muted),
                      onPressed: _running
                          ? null
                          : () => setState(() {
                              _files.remove(f);
                              _selected.remove(f.path);
                            }),
                    ),
                  ),
                if (_scanning) const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text(
                        'Files',
                        style: TextStyle(fontSize: 11),
                      ),
                      onPressed: _running
                          ? null
                          : () async {
                              final r = await FilePicker.pickFiles(
                                allowMultiple: true,
                                type: FileType.custom,
                                allowedExtensions: ['json'],
                              );
                              final ps =
                                  r?.files
                                      .map((f) => f.path)
                                      .whereType<String>()
                                      .toList() ??
                                  [];
                              if (ps.isNotEmpty) await _addPaths(ps);
                            },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open, size: 14),
                      label: const Text(
                        'Folder',
                        style: TextStyle(fontSize: 11),
                      ),
                      onPressed: _running
                          ? null
                          : () async {
                              final d = await FilePicker.getDirectoryPath();
                              if (d == null) return;
                              final ps =
                                  Directory(d)
                                      .listSync()
                                      .whereType<File>()
                                      .map((f) => f.path)
                                      .where(
                                        (p) =>
                                            p.endsWith('.ccseeg.json') &&
                                            p.contains('-epo'),
                                      )
                                      .toList()
                                    ..sort();
                              if (ps.isEmpty) {
                                if (mounted) {
                                  setState(
                                    () => _status =
                                        'No *-epo*.ccseeg.json files in $d',
                                  );
                                }
                                return;
                              }
                              await _addPaths(ps);
                            },
                    ),
                  ],
                ),
              ]),
              _section('CONDITIONS', [
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  dropdownColor: _card,
                  decoration: const InputDecoration(
                    labelText: 'Fill from template',
                    isDense: true,
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: [
                    for (var i = 0; i < _templates.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          _templates[i].name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _running
                      ? null
                      : (i) {
                          if (i == null) return;
                          final t = _templates[i];
                          setState(() {
                            _nameA.text = t.a.name;
                            _nameB.text = t.b.name;
                            _markersA = [...t.a.markers];
                            _markersB = [...t.b.markers];
                            _regexA.clear();
                            _regexB.clear();
                            _component.text = t.component;
                            _w0.text = _fmt(t.w0 * 1000);
                            _w1.text = _fmt(t.w1 * 1000);
                            _topoPoint.text = _fmt((t.w0 + t.w1) * 500);
                            if (!_useFileTimes ||
                                _selectedInfos.every((f) => f.tmin == null)) {
                              _tmin.text = _fmt(t.tmin);
                              _tmax.text = _fmt(t.tmax);
                            }
                          });
                        },
                ),
                const SizedBox(height: 8),
                _conditionEditor(
                  'A',
                  _nameA,
                  _regexA,
                  _markersA,
                  _blueC,
                  (m) => setState(() => _markersA = m),
                  counts,
                ),
                const SizedBox(height: 8),
                _conditionEditor(
                  'B',
                  _nameB,
                  _regexB,
                  _markersB,
                  _redC,
                  (m) => setState(() => _markersB = m),
                  counts,
                ),
              ]),
              _section('ELECTRODE & TIMES', [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: chans.contains(_electrode) ? _electrode : null,
                  dropdownColor: _card,
                  decoration: const InputDecoration(
                    labelText: 'Electrode',
                    isDense: true,
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  items: [
                    for (final c in chans)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _electrode = v ?? _electrode),
                ),
                const SizedBox(height: 6),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  value: _useFileTimes,
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _useFileTimes = v ?? true),
                  title: const Text(
                    'Use the epoch times stored in the files',
                    style: TextStyle(fontSize: 11, color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Otherwise (or for files without them) use tmin/tmax below',
                    style: TextStyle(fontSize: 10, color: _muted),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: _tf(_tmin, 'Epoch tmin', suffix: 's')),
                    const SizedBox(width: 6),
                    Expanded(child: _tf(_tmax, 'Epoch tmax', suffix: 's')),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _tf(_b0, 'Baseline from', suffix: 'ms')),
                    const SizedBox(width: 6),
                    Expanded(child: _tf(_b1, 'to', suffix: 'ms')),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _tf(_component, 'Component', number: false),
                    ),
                    const SizedBox(width: 6),
                    Expanded(flex: 2, child: _tf(_w0, 'Window', suffix: 'ms')),
                    const SizedBox(width: 6),
                    Expanded(flex: 2, child: _tf(_w1, 'to', suffix: 'ms')),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    SizedBox(
                      width: 145,
                      child: _tf(_topoPoint, 'Scalp-map point', suffix: 'ms'),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'The Scalp maps tab switches between this point and the component-window average.',
                        style: TextStyle(fontSize: 10, color: _muted),
                      ),
                    ),
                  ],
                ),
              ]),
              _section('STATISTICS', [
                Row(
                  children: [
                    Expanded(child: _tf(_nPerm, 'Permutations')),
                    const SizedBox(width: 6),
                    Expanded(child: _tf(_nBoot, 'Bootstrap')),
                    const SizedBox(width: 6),
                    Expanded(child: _tf(_seed, 'Seed')),
                  ],
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  value: _smooth,
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _smooth = v ?? true),
                  title: const Text(
                    'Savitzky–Golay smoothing of plotted mean/SEM (31, 3)',
                    style: TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ),
                const Text(
                  'Cluster permutation test on the full waveform (Welch t, |t| > t(0.975, nA+nB−2)); '
                  'window Welch t-test + Cohen\'s d with bootstrap 95% CI; between-session d of the '
                  'bootstrapped mismatch. Same RNG (numpy default_rng) as compute_mmn_erp.py.',
                  style: TextStyle(fontSize: 10, color: _muted),
                ),
              ]),
            ],
          ),
        ),
        // The run button stays visible however far the settings are scrolled.
        Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            color: _card,
            border: Border(top: BorderSide(color: _border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(_running ? 'Computing…' : 'Compute'),
                  onPressed: _running ? null : _compute,
                ),
              ),
              if (_running) ...[
                const SizedBox(width: 6),
                OutlinedButton(onPressed: _cancel, child: const Text('Cancel')),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _conditionEditor(
    String id,
    TextEditingController name,
    TextEditingController regex,
    List<String> markers,
    Color color,
    void Function(List<String>) set,
    List<MapEntry<String, int>> counts,
  ) {
    final n = _countFor(markers, regex.text);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
        color: Colors.white.withValues(alpha: 0.02),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _tf(name, 'Condition $id name', number: false)),
              const SizedBox(width: 8),
              Text(
                '$n epochs',
                style: TextStyle(
                  fontSize: 11,
                  color: n == 0 ? Colors.orangeAccent : _muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (counts.isEmpty)
            Text(
              'Markers: ${markers.join(', ')}',
              style: const TextStyle(fontSize: 10, color: _muted),
            )
          else
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final e in counts)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    label: Text(
                      '${markerShortName(e.key)}  ×${e.value}',
                      style: const TextStyle(fontSize: 10),
                    ),
                    selected: markerListContains(markers, e.key),
                    selectedColor: color.withValues(alpha: 0.35),
                    onSelected: _running
                        ? null
                        : (sel) {
                            final short = markerShortName(e.key);
                            set(
                              sel
                                  ? [...markers, short]
                                  : [
                                      for (final m in markers)
                                        if (!markerListContains([m], e.key)) m,
                                    ],
                            );
                          },
                  ),
              ],
            ),
          const SizedBox(height: 4),
          _tf(regex, 'or regular expression (optional)', number: false),
        ],
      ),
    );
  }

  Widget _resultsPane() {
    final an = _an;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: _card,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.show_chart, color: _accent, size: 18),
              const SizedBox(width: 8),
              const Text(
                'ERP Analysis',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.zoom_out, size: 18, color: _muted),
                onPressed: an == null
                    ? null
                    : () =>
                          setState(() => _zoom = (_zoom / 1.25).clamp(0.5, 4)),
              ),
              IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.zoom_in, size: 18, color: _muted),
                onPressed: an == null
                    ? null
                    : () =>
                          setState(() => _zoom = (_zoom * 1.25).clamp(0.5, 4)),
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                icon: const Icon(Icons.save_alt, size: 16),
                label: const Text('Export PNG / PDF / CSV'),
                onPressed: an == null || _running ? null : _export,
              ),
            ],
          ),
        ),
        if (_running) LinearProgressIndicator(value: _progress, minHeight: 3),
        if (_warnings.isNotEmpty)
          Container(
            color: const Color(0x33F59E0B),
            padding: const EdgeInsets.all(6),
            child: Text(
              _warnings.join('\n'),
              style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 11),
            ),
          ),
        TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: _muted,
          tabs: const [
            Tab(text: 'Waveforms'),
            Tab(text: 'Scalp maps'),
            Tab(text: 'Effect sizes'),
            Tab(text: 'Statistics'),
          ],
        ),
        Expanded(
          child: an == null
              ? const Center(
                  child: Text(
                    'Pick the files and conditions, then Compute.',
                    style: TextStyle(color: _muted),
                  ),
                )
              : TabBarView(
                  controller: _tabs,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _figureView(_wave!, hover: true),
                    _topographyView(an, _topo!),
                    _figureView(_effect!),
                    _statsTable(an),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _figureView(ErpFigure fig, {bool hover = false}) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final wIn = fig.widthIn, hIn = fig.heightIn;
        final fitW = (cons.maxWidth - 24).clamp(200.0, 4000.0);
        final dpi = fitW * _zoom / wIn;
        final size = Size(wIn * dpi, hIn * dpi);
        Widget paint = CustomPaint(
          size: size,
          painter: _FigurePainter(fig, dpi, hover ? _hover : null),
        );
        if (hover && fig is ErpWaveformFigure) {
          paint = MouseRegion(
            onHover: (e) {
              final h = fig.hitTest(e.localPosition, dpi);
              if (h?.panel != _hover?.panel || h?.sample != _hover?.sample)
                setState(() => _hover = h);
            },
            onExit: (_) => setState(() => _hover = null),
            child: paint,
          );
        }
        return Scrollbar(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: paint,
            ),
          ),
        );
      },
    );
  }

  Widget _topographyView(ErpAnalysis an, ErpTopoResult topo) {
    final point = _topoPointMode;
    final labels = <String>[];
    final indices = <int>[];
    final upper = {
      for (final key in kStandard1020Topo.keys) key.toUpperCase(): key,
    };
    for (var i = 0; i < topo.labels.length; i++) {
      if (upper.containsKey(topo.labels[i].toUpperCase())) {
        labels.add(upper[topo.labels[i].toUpperCase()]!);
        indices.add(i);
      }
    }
    List<double> take(List<double> values) => [
      for (final i in indices) values[i],
    ];
    final a = take(point ? topo.pointA : topo.windowA);
    final b = take(point ? topo.pointB : topo.windowB);
    final t = take(point ? topo.pointT : topo.windowT);
    final p = take(point ? topo.pointP : topo.windowP);
    final q = _benjaminiHochberg(p);
    final diff = [for (var i = 0; i < a.length; i++) b[i] - a[i]];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Window average')),
                  ButtonSegment(value: true, label: Text('Selected point')),
                ],
                selected: {point},
                onSelectionChanged: (value) =>
                    setState(() => _topoPointMode = value.first),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  point
                      ? 'Nearest acquired sample: ${(topo.pointSeconds * 1000).toStringAsFixed(1)} ms'
                      : 'Average: ${(an.settings.winStart * 1000).toStringAsFixed(0)}–${(an.settings.winEnd * 1000).toStringAsFixed(0)} ms',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Condition statistics are Welch independent-samples tests across epochs. Rings mark electrodes surviving Benjamini–Hochberg FDR q < 0.05.',
              style: TextStyle(color: _muted, fontSize: 10),
            ),
          ),
        ),
        Expanded(
          child: labels.length < 3
              ? const Center(
                  child: Text(
                    'At least 3 standard 10–20 scalp channels are required.',
                    style: TextStyle(color: _muted),
                  ),
                )
              : CustomPaint(
                  painter: _ErpTopoPainter(
                    labels: labels,
                    maps: [a, b, diff, t],
                    pValues: q,
                    titles: [
                      an.settings.condA.name,
                      an.settings.condB.name,
                      'B − A (µV)',
                      'Welch t (A − B)',
                    ],
                  ),
                  size: Size.infinite,
                ),
        ),
      ],
    );
  }

  Widget _statsTable(ErpAnalysis an) {
    final s = an.settings;
    String f(double v, [int d = 3]) => v.toStringAsFixed(d);
    const hs = TextStyle(
      color: _muted,
      fontSize: 11,
      fontWeight: FontWeight.bold,
    );
    const cs = TextStyle(color: Colors.white, fontSize: 11);
    final names = shortSessionNames([for (final r in an.results) r.fileLabel]);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          '${s.electrode} · ${s.condA.name} vs ${s.condB.name} · baseline '
          '${(s.baselineStart * 1000).round()}–${(s.baselineEnd * 1000).round()} ms · '
          '${s.componentName} window ${(s.winStart * 1000).round()}–${(s.winEnd * 1000).round()} ms · '
          '${s.nPerm} permutations · ${s.nBoot} bootstrap · seed ${s.seed}',
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 32,
            dataRowMinHeight: 28,
            dataRowMaxHeight: 44,
            columnSpacing: 16,
            columns: [
              for (final c in [
                'Session',
                'n A',
                'n B',
                'A win µV',
                'B win µV',
                't',
                'df',
                'p',
                'd',
                'd 95% CI',
                'B−A µV',
                'B−A 95% CI',
                'Sig. clusters (s)',
              ])
                DataColumn(label: Text(c, style: hs)),
            ],
            rows: [
              for (var i = 0; i < an.results.length; i++)
                () {
                  final r = an.results[i];
                  final sig = r.significant(0.05);
                  return DataRow(
                    cells: [
                      DataCell(Text(names[i], style: cs)),
                      DataCell(Text('${r.nA}', style: cs)),
                      DataCell(Text('${r.nB}', style: cs)),
                      DataCell(Text(f(r.aWindowMean), style: cs)),
                      DataCell(Text(f(r.bWindowMean), style: cs)),
                      DataCell(Text(f(r.tWindow), style: cs)),
                      DataCell(Text(f(r.dfWindow, 1), style: cs)),
                      DataCell(
                        Text(
                          r.pWindow.toStringAsFixed(4),
                          style: cs.copyWith(
                            color: r.pWindow < s.alpha
                                ? const Color(0xFF4ADE80)
                                : Colors.white,
                          ),
                        ),
                      ),
                      DataCell(Text(f(r.dWindow), style: cs)),
                      DataCell(
                        Text('[${f(r.dBootLo)}, ${f(r.dBootHi)}]', style: cs),
                      ),
                      DataCell(Text(f(r.mismatchMean), style: cs)),
                      DataCell(
                        Text(
                          '[${f(r.mismatchLo)}, ${f(r.mismatchHi)}]',
                          style: cs,
                        ),
                      ),
                      DataCell(
                        Text(
                          sig.isEmpty
                              ? '—'
                              : sig
                                    .map(
                                      (c) =>
                                          '${f(r.times[c.startIdx])}–${f(r.times[c.endIdx.clamp(0, r.times.length - 1)])} (p=${c.pValue.toStringAsFixed(3)})',
                                    )
                                    .join('\n'),
                          style: cs,
                        ),
                      ),
                    ],
                  );
                }(),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (an.between.isNotEmpty) ...[
          const Text(
            "Between-session Cohen's d of the mismatch (B − A)",
            style: hs,
          ),
          const SizedBox(height: 4),
          for (final b in an.between)
            Text(
              '${names[b.i]}  vs  ${names[b.j]}:  d = ${b.d.toStringAsFixed(2)}',
              style: cs,
            ),
        ],
        const SizedBox(height: 14),
        const Text('All clusters (any p)', style: hs),
        for (var i = 0; i < an.results.length; i++)
          Text(
            '${names[i]}: ${an.results[i].clusters.isEmpty ? 'none above threshold' : an.results[i].clusters.map((c) => '${f(an.results[i].times[c.startIdx])}–${f(an.results[i].times[c.endIdx.clamp(0, an.results[i].times.length - 1)])} s (mass ${c.mass.toStringAsFixed(1)}, p=${c.pValue.toStringAsFixed(3)})').join('; ')}',
            style: const TextStyle(color: _muted, fontSize: 10),
          ),
      ],
    );
  }
}

List<double> _benjaminiHochberg(List<double> pValues) {
  final valid = [
    for (var i = 0; i < pValues.length; i++)
      if (pValues[i].isFinite) (index: i, p: pValues[i].clamp(0.0, 1.0)),
  ]..sort((a, b) => a.p.compareTo(b.p));
  final out = List<double>.filled(pValues.length, double.nan);
  var running = 1.0;
  for (var rank = valid.length; rank >= 1; rank--) {
    final item = valid[rank - 1];
    running = math.min(running, item.p * valid.length / rank);
    out[item.index] = running.clamp(0.0, 1.0);
  }
  return out;
}

class _ErpTopoPainter extends CustomPainter {
  const _ErpTopoPainter({
    required this.labels,
    required this.maps,
    required this.pValues,
    required this.titles,
  });

  final List<String> labels;
  final List<List<double>> maps;
  final List<double> pValues;
  final List<String> titles;

  @override
  void paint(Canvas canvas, Size size) {
    final columns = size.width >= 760 ? 4 : 2;
    final rows = (maps.length / columns).ceil();
    final cellW = size.width / columns;
    final cellH = size.height / rows;
    final positions = [
      for (final label in labels)
        Offset(
          kStandard1020Topo[label]![0] / .105,
          -kStandard1020Topo[label]![1] / .105,
        ),
    ];
    for (var mapIndex = 0; mapIndex < maps.length; mapIndex++) {
      final col = mapIndex % columns;
      final row = mapIndex ~/ columns;
      final cell = Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH);
      final radius = math.min(cellW * .40, cellH * .34);
      final center = Offset(cell.center.dx, cell.top + cellH * .51);
      final values = maps[mapIndex];
      var scale = 1e-12;
      for (final value in values) {
        if (value.isFinite) scale = math.max(scale, value.abs());
      }
      const resolution = 54;
      final tile = radius * 2 / resolution;
      for (var iy = 0; iy < resolution; iy++) {
        final y = -1 + (iy + .5) * 2 / resolution;
        for (var ix = 0; ix < resolution; ix++) {
          final x = -1 + (ix + .5) * 2 / resolution;
          if (x * x + y * y > 1) continue;
          var weighted = 0.0;
          var weights = 0.0;
          for (var i = 0; i < positions.length; i++) {
            if (!values[i].isFinite) continue;
            final dx = x - positions[i].dx;
            final dy = y - positions[i].dy;
            final d2 = dx * dx + dy * dy;
            final weight = d2 < 1e-6 ? 1e9 : 1 / math.pow(d2, 1.5);
            weighted += values[i] * weight;
            weights += weight;
          }
          final v = weights == 0 ? 0.0 : weighted / weights / scale;
          canvas.drawRect(
            Rect.fromLTWH(
              center.dx + x * radius - tile / 2,
              center.dy + y * radius - tile / 2,
              tile + .6,
              tile + .6,
            ),
            Paint()..color = _erpDiverging(v),
          );
        }
      }
      final outline = Paint()
        ..color = const Color(0xFFE2E8F0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      canvas.drawCircle(center, radius, outline);
      canvas.drawPath(
        Path()
          ..moveTo(center.dx - radius * .12, center.dy - radius * .98)
          ..lineTo(center.dx, center.dy - radius * 1.13)
          ..lineTo(center.dx + radius * .12, center.dy - radius * .98),
        outline,
      );
      for (var i = 0; i < positions.length; i++) {
        final point = Offset(
          center.dx + positions[i].dx * radius,
          center.dy + positions[i].dy * radius,
        );
        canvas.drawCircle(point, 1.6, Paint()..color = Colors.white);
        if (i < pValues.length && pValues[i].isFinite && pValues[i] < .05) {
          canvas.drawCircle(
            point,
            4.0,
            Paint()
              ..color = const Color(0xFF111827)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
      }
      final title = TextPainter(
        text: TextSpan(
          text: titles[mapIndex],
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: cellW - 20);
      title.paint(
        canvas,
        Offset(cell.center.dx - title.width / 2, cell.top + 8),
      );
      final range = TextPainter(
        text: TextSpan(
          text:
              '−${scale.toStringAsFixed(2)}    0    +${scale.toStringAsFixed(2)}',
          style: const TextStyle(color: _muted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      range.paint(
        canvas,
        Offset(cell.center.dx - range.width / 2, center.dy + radius + 8),
      );
    }
  }

  Color _erpDiverging(double value) {
    final v = value.clamp(-1.0, 1.0);
    return v < 0
        ? Color.lerp(const Color(0xFF2563EB), Colors.white, v + 1)!
        : Color.lerp(Colors.white, const Color(0xFFDC2626), v)!;
  }

  @override
  bool shouldRepaint(covariant _ErpTopoPainter old) =>
      old.maps != maps || old.pValues != pValues || old.labels != labels;
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.fig, this.dpi, this.hover);
  final ErpFigure fig;
  final double dpi;
  final ErpHit? hover;

  @override
  void paint(Canvas canvas, Size size) {
    fig.paint(canvas, dpi);
    final h = hover;
    final w = fig;
    if (h == null || w is! ErpWaveformFigure) return;
    final r = w.an.results[h.panel];
    final ax = w.panelPx(h.panel, dpi);
    final x = w.xOf(ax, r.times[h.sample]);
    canvas.drawLine(
      Offset(x, ax.top),
      Offset(x, ax.bottom),
      Paint()
        ..color = const Color(0x99000000)
        ..strokeWidth = 1,
    );
    for (final (m, c) in [(r.aMean, _blueC), (r.bMean, _redC)]) {
      canvas.drawCircle(
        Offset(x, w.yOf(ax, m[h.sample])),
        3.5,
        Paint()..color = c,
      );
    }
    final s = w.an.settings;
    final k = h.sample;
    final text =
        't = ${(r.times[k] * 1000).toStringAsFixed(0)} ms\n'
        '${shortConditionName(s.condA.name)}: ${r.aMean[k].toStringAsFixed(2)} ± ${r.aSem[k].toStringAsFixed(2)} µV\n'
        '${shortConditionName(s.condB.name)}: ${r.bMean[k].toStringAsFixed(2)} ± ${r.bSem[k].toStringAsFixed(2)} µV\n'
        'B − A: ${(r.bMean[k] - r.aMean[k]).toStringAsFixed(2)} µV   t = ${r.tObs[k].toStringAsFixed(2)}';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.3),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var bx = x + 10;
    if (bx + tp.width + 12 > ax.right) bx = x - tp.width - 22;
    final box = Rect.fromLTWH(bx, ax.top + 8, tp.width + 12, tp.height + 10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(4)),
      Paint()..color = const Color(0xE61E293B),
    );
    tp.paint(canvas, box.topLeft + const Offset(6, 5));
  }

  @override
  bool shouldRepaint(_FigurePainter old) =>
      old.fig != fig || old.dpi != dpi || old.hover != hover;
}

/// Writes erp_waveforms_<el>.png, effect_size_summary_<el>.png,
/// stats_summary_<el>.csv, erp_waveforms_<el>.csv, erp_report_<el>.pdf and
/// erp_settings_<el>.json into [outDir]. Returns the paths.
Future<List<String>> exportErpOutputs(
  ErpAnalysis an,
  String outDir, {
  bool pdf = true,
}) async {
  await Directory(outDir).create(recursive: true);
  final e = an.settings.electrode;
  final sep = Platform.pathSeparator;
  final wave = ErpWaveformFigure(an);
  final eff = ErpEffectFigure(an);
  final wavePng = await wave.toPng(dpi: 150);
  final effPng = await eff.toPng(dpi: 150);
  final paths = <String>[
    '$outDir${sep}erp_waveforms_$e.png',
    '$outDir${sep}effect_size_summary_$e.png',
    '$outDir${sep}stats_summary_$e.csv',
    '$outDir${sep}erp_waveforms_$e.csv',
    '$outDir${sep}erp_settings_$e.json',
  ];
  await File(paths[0]).writeAsBytes(wavePng);
  await File(paths[1]).writeAsBytes(effPng);
  await File(paths[2]).writeAsString(ErpEngine.statsCsv(an));
  await File(paths[3]).writeAsString(ErpEngine.waveformsCsv(an));
  await File(paths[4]).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      ...an.settings.toJson(),
      'files': [for (final r in an.results) r.path],
    }),
  );
  if (pdf) {
    final p = '$outDir${sep}erp_report_$e.pdf';
    await File(p).writeAsBytes(await _erpPdf(an, wave, eff, wavePng, effPng));
    paths.add(p);
  }
  return paths;
}

Future<Uint8List> _erpPdf(
  ErpAnalysis an,
  ErpWaveformFigure wave,
  ErpEffectFigure eff,
  Uint8List wavePng,
  Uint8List effPng,
) async {
  pw.ThemeData theme;
  try {
    final f = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    theme = pw.ThemeData.withFont(base: f, bold: f);
  } catch (_) {
    theme = pw.ThemeData.base();
  }
  final s = an.settings;
  final doc = pw.Document(
    title: 'ERP ${s.electrode}',
    creator: 'CCS EEG Studio',
    theme: theme,
  );
  const ink = PdfColor.fromInt(0xFF111827);
  const muted = PdfColor.fromInt(0xFF4B5563);
  const accent = PdfColor.fromInt(0xFF1D4ED8);
  String f(double v, [int d = 3]) => v.toStringAsFixed(d);
  final names = shortSessionNames([for (final r in an.results) r.fileLabel]);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape.copyWith(
        marginLeft: 36,
        marginRight: 36,
        marginTop: 30,
        marginBottom: 30,
      ),
      build: (ctx) => [
        pw.Text(
          '${s.componentName} ERP · ${s.electrode} · ${s.condA.name} vs ${s.condB.name}',
          style: pw.TextStyle(
            fontSize: 17,
            color: ink,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Baseline ${(s.baselineStart * 1000).round()}–${(s.baselineEnd * 1000).round()} ms · '
          '${s.componentName} window ${(s.winStart * 1000).round()}–${(s.winEnd * 1000).round()} ms · '
          'cluster permutation test (${s.nPerm} permutations) · bootstrap ${s.nBoot} · seed ${s.seed}'
          '${s.smooth ? ' · plotted waveforms Savitzky–Golay (31, 3)' : ''}',
          style: const pw.TextStyle(fontSize: 9, color: muted),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Condition A markers: ${[...s.condA.markers, if (s.condA.pattern.isNotEmpty) '/${s.condA.pattern}/'].join(', ')} · '
          'Condition B markers: ${[...s.condB.markers, if (s.condB.pattern.isNotEmpty) '/${s.condB.pattern}/'].join(', ')}',
          style: const pw.TextStyle(fontSize: 9, color: muted),
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: [
            'Session',
            'n A',
            'n B',
            'A µV',
            'B µV',
            't',
            'df',
            'p',
            'd',
            'd 95% CI',
            'B−A µV',
            'B−A 95% CI',
            'Sig. clusters',
          ],
          data: [
            for (var i = 0; i < an.results.length; i++)
              () {
                final r = an.results[i];
                return [
                  names[i],
                  '${r.nA}',
                  '${r.nB}',
                  f(r.aWindowMean),
                  f(r.bWindowMean),
                  f(r.tWindow, 2),
                  f(r.dfWindow, 1),
                  r.pWindow.toStringAsFixed(4),
                  f(r.dWindow),
                  '[${f(r.dBootLo, 2)}, ${f(r.dBootHi, 2)}]',
                  f(r.mismatchMean),
                  '[${f(r.mismatchLo, 2)}, ${f(r.mismatchHi, 2)}]',
                  r.significant(0.05).isEmpty
                      ? '—'
                      : r
                            .significant(0.05)
                            .map(
                              (c) =>
                                  '${f(r.times[c.startIdx], 2)}–${f(r.times[c.endIdx.clamp(0, r.times.length - 1)], 2)} s',
                            )
                            .join(', '),
                ];
              }(),
          ],
          headerStyle: pw.TextStyle(
            fontSize: 8,
            color: PdfColors.white,
            fontWeight: pw.FontWeight.bold,
          ),
          headerDecoration: const pw.BoxDecoration(color: accent),
          cellStyle: const pw.TextStyle(fontSize: 8, color: ink),
          oddRowDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFF3F4F6),
          ),
          cellAlignment: pw.Alignment.centerRight,
          cellAlignments: {
            0: pw.Alignment.centerLeft,
            12: pw.Alignment.centerLeft,
          },
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2.5,
          ),
          border: null,
        ),
        pw.SizedBox(height: 10),
        if (an.between.isNotEmpty) ...[
          pw.Text(
            "Between-session Cohen's d of the mismatch (B − A)",
            style: pw.TextStyle(
              fontSize: 10,
              color: accent,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 3),
          for (final b in an.between)
            pw.Text(
              '${names[b.i]} vs ${names[b.j]}: d = ${b.d.toStringAsFixed(2)}',
              style: const pw.TextStyle(fontSize: 9, color: ink),
            ),
        ],
        pw.SizedBox(height: 8),
        pw.Text(
          'Files: ${an.results.map((r) => r.path).join('; ')}',
          style: const pw.TextStyle(fontSize: 7, color: muted),
        ),
      ],
    ),
  );
  for (final (png, w, h) in [
    (wavePng, wave.widthIn, wave.heightIn),
    (effPng, eff.widthIn, eff.heightIn),
  ]) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(w * 72, h * 72, marginAll: 0),
        build: (ctx) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
      ),
    );
  }
  return doc.save();
}
