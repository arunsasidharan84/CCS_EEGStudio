import 'axis_controls.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models.dart';
import '../group_statistics.dart';
import '../filtered_file_picker.dart';
import 'workbench_service.dart';
import 'workbench_figures.dart';
import 'workbench_report.dart';
import 'stim_epochs.dart' show markerListContains;
import 'task_guides.dart';
import 'protocol_tools.dart';
import 'review_workspace.dart';
import 'review_math.dart';
import 'channel_grid.dart';

class ErpWorkbenchView extends StatefulWidget {
  const ErpWorkbenchView({
    super.key,
    this.activeRecording,
    this.config,
    this.extraFiles = const [],
    this.initialResultPath,
    this.batchMode = true,
    this.onPrepare,
    this.onOpenBatch,
    this.initialInspection,
  });
  final EegRecording? activeRecording;
  final AnalysisConfig? config;
  final List<String> extraFiles;
  final String? initialResultPath;
  final bool batchMode;
  final Map<String, dynamic>? initialInspection;
  final VoidCallback? onPrepare, onOpenBatch;
  @override
  State<ErpWorkbenchView> createState() => _ErpWorkbenchViewState();
}

class _ErpWorkbenchViewState extends State<ErpWorkbenchView>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic> _axisLimits = {};

  final _service = ErpWorkbenchService();
  final _paths = <String>[];
  final _subjects = <String, String>{};
  final _profiles = <String, Map<String, dynamic>>{};
  final _limit = TextEditingController(text: '2'),
      _output = TextEditingController(),
      _bin = TextEditingController(text: '20'),
      _reject = TextEditingController(text: '0'),
      _permutations = TextEditingController(text: '1000'),
      _metadata = TextEditingController(),
      _rtMin = TextEditingController(text: '200'),
      _rtMax = TextEditingController(text: '1000'),
      _folds = TextEditingController(text: '5'),
      _shrinkage = TextEditingController(text: '0.1'),
      _lsqrTolerance = TextEditingController(text: '1e-12'),
      _lsqrIterations = TextEditingController(text: '1000');
  final _a = TextEditingController(),
      _b = TextEditingController(),
      _roi = TextEditingController(),
      _epoch0 = TextEditingController(),
      _epoch1 = TextEditingController(),
      _base0 = TextEditingController(),
      _base1 = TextEditingController(),
      _window0 = TextEditingController(),
      _window1 = TextEditingController(),
      _markerSearch = TextEditingController(),
      _componentLabel = TextEditingController();
  late final TabController _tabs;
  String
  _task = 'Auto',
  _eventSource = 'auto',
  _status =
      'Choose recordings, inspect the markers, then review the proposed analysis.',
  _component = '';
  bool _busy = false,
      _correct = true,
      _regression = false,
      _deconvolution = false,
      _decoding = false,
      _generalization = false,
      _exportTrials = false,
      _negativeUp = true,
      _significantOnly = true;
  double _progress = 0;
  double _displaySmoothing = 0;
  final _hover = ValueNotifier<double?>(null);
  final Map<String, String> _modelChannels = {}, _modelPredictors = {};
  Map<String, dynamic>? _inspection, _result, _profile;
  bool _regroupEpochs = false;
  List<String> _savedA = [], _savedB = [];
  bool get _isPrepared =>
      !widget.batchMode && (widget.activeRecording?.isEpoched ?? false) ||
      _scanFiles.isNotEmpty && _scanFiles.every((f) => f['is_epoched'] == true);
  bool get _canRun =>
      !_busy &&
      _selectedPaths.isNotEmpty &&
      _inspection != null &&
      (widget.batchMode || _isPrepared) &&
      !(_isPrepared &&
          _profile != null &&
          (_savedA.isEmpty || _savedB.isEmpty)) &&
      _timingIssue == null;
  String? get _timingIssue {
    if (!_isPrepared || _profile == null) return null;
    final lo = double.tryParse(_epoch0.text),
        hi = double.tryParse(_epoch1.text);
    final a = double.tryParse(_base0.text),
        b = double.tryParse(_base1.text),
        x = double.tryParse(_window0.text),
        y = double.tryParse(_window1.text);
    if ([lo, hi, a, b, x, y].contains(null))
      return 'Enter valid baseline and measurement times.';
    if (a! < lo! || b! > hi! || x! < lo || y! > hi || a >= b || x >= y)
      return 'Baseline or measurement window exceeds the saved trials. Adjust the window or return to Preprocess for wider epochs.';
    return null;
  }

  List<String> get _savedGroups =>
      {for (final f in _scanFiles) ...erpMap(f['marker_counts']).keys}.toList()
        ..sort();
  String? _file;
  List<Map<String, dynamic>> get _scanFiles =>
      ((_inspection?['files'] as List?) ?? []).map(erpMap).toList();
  List<Map<String, dynamic>> get _groups =>
      ((_result?['groups'] as List?) ?? []).map(erpMap).toList();
  List<Map<String, dynamic>> get _results =>
      ((_result?['files'] as List?) ?? []).map(erpMap).toList();
  String? _taskFromPath(String path) {
    for (final part in path.split(RegExp(r'[/\\]')).reversed) {
      for (final token in part.toUpperCase().split(RegExp(r'[^A-Z0-9]+'))) {
        if ([
          'N170',
          'N2PC',
          'N400',
          'MMN',
          'ERN',
          'LRP',
          'P3',
          'P300',
        ].contains(token))
          return token == 'P300'
              ? 'P3'
              : token == 'N2PC'
              ? 'N2pc'
              : token;
      }
    }
    return null;
  }

  List<String> get _selectedPaths => _paths
      .where(
        (p) =>
            !widget.batchMode ||
            _task == 'Auto' ||
            _task == 'Custom' ||
            _taskFromPath(p) == null ||
            _taskFromPath(p) == _task,
      )
      .toList();
  List<Map<String, dynamic>> get _inputs => [
    for (final p in _selectedPaths) {'path': p, 'subject': _subjects[p] ?? ''},
  ];
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
    _restoreProtocol();
    if (widget.initialResultPath != null) {
      final result = Map<String, dynamic>.from(
        jsonDecode(File(widget.initialResultPath!).readAsStringSync()) as Map,
      );
      _result = result;
      _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
      _output.text = File(widget.initialResultPath!).parent.path;
    }
    final active = widget.activeRecording;
    if (active != null && File(active.path).existsSync())
      _paths.add(active.path);
    for (final path in (widget.batchMode ? widget.extraFiles : <String>[])) {
      if ((path.toLowerCase().endsWith('.edf') ||
              path.toLowerCase().endsWith('.fif') ||
              (path.toLowerCase().endsWith('.ccseeg.json') ||
                  path.toLowerCase().endsWith('.ccseeg'))) &&
          File(path).existsSync() &&
          !_paths.contains(path))
        _paths.add(path);
    }
    if (widget.initialInspection != null) {
      _inspection = widget.initialInspection;
      final profiles = _scanFiles
          .map((f) => erpMap(f['profile']))
          .where((p) => p.isNotEmpty)
          .toList();
      if (profiles.isNotEmpty) _fillProfile(profiles.first);
      _restoreProtocol();
      if (!widget.batchMode)
        _status = 'Choose saved groups A/B and review the ROI/window.';
    }
    if (_paths.isNotEmpty && widget.initialInspection == null)
      WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
  }

  @override
  void didUpdateWidget(covariant ErpWorkbenchView old) {
    super.didUpdateWidget(old);
    if (!widget.batchMode &&
        old.activeRecording?.path != widget.activeRecording?.path) {
      _paths.clear();
      _task = 'Auto';
      _regroupEpochs = false;
      _savedA.clear();
      _savedB.clear();
      _inspection = null;
      _result = null;
      _fillProfile(null);
      final active = widget.activeRecording;
      if (active != null && File(active.path).existsSync()) {
        _paths.add(active.path);
        WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
      }
    }
  }

  @override
  void dispose() {
    _service.cancel();
    for (final c in [
      _limit,
      _output,
      _bin,
      _reject,
      _permutations,
      _metadata,
      _rtMin,
      _rtMax,
      _folds,
      _shrinkage,
      _lsqrTolerance,
      _lsqrIterations,
      _a,
      _b,
      _roi,
      _epoch0,
      _epoch1,
      _base0,
      _base1,
      _window0,
      _window1,
      _markerSearch,
      _componentLabel,
    ]) {
      c.dispose();
    }
    _hover.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Map<String, dynamic> _options({bool inspection = false}) {
    final options = <String, dynamic>{
      'task': _task,
      'regroup_epochs': _regroupEpochs,
      'event_source': _eventSource,
      'correct_only': _correct,
      'bin_ms': double.tryParse(_bin.text) ?? 20,
      'reject_uv': double.tryParse(_reject.text) ?? 0,
      'permutations': int.tryParse(_permutations.text) ?? 1000,
      'regression': _regression,
      'deconvolution': _deconvolution,
      'decoding': _decoding,
      'temporal_generalization': _generalization,
      'export_trial_measurements': _exportTrials,
      'trial_metadata_path': _metadata.text.trim(),
      'profile_overrides': _profiles,
      'response_min': (double.tryParse(_rtMin.text) ?? 200) / 1000,
      'response_max': (double.tryParse(_rtMax.text) ?? 1000) / 1000,
      'folds': int.tryParse(_folds.text) ?? 5,
      'decode_shrinkage': double.tryParse(_shrinkage.text) ?? 0.1,
      'lsqr_tolerance': double.tryParse(_lsqrTolerance.text) ?? 1e-12,
      'lsqr_iterations': int.tryParse(_lsqrIterations.text) ?? 1000,
    };
    if (!inspection && _profile != null) {
      final p = Map<String, dynamic>.from(_profile!);
      List<String> list(TextEditingController c) => c.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      double number(TextEditingController c) => double.parse(c.text) / 1000;
      p['component_name'] = _componentLabel.text.trim();
      p['a_codes'] = _isPrepared ? _savedA : list(_a);
      p['saved_a_groups'] = p['a_codes'];
      if (_isPrepared) p['a_name'] = _savedA.join(' + ');
      p['b_codes'] = _isPrepared ? _savedB : list(_b);
      p['saved_b_groups'] = p['b_codes'];
      if (_isPrepared) p['b_name'] = _savedB.join(' + ');
      p['roi'] = list(_roi);
      p['epoch'] = [number(_epoch0), number(_epoch1)];
      p['baseline'] = [number(_base0), number(_base1)];
      p['window'] = [number(_window0), number(_window1)];
      final epoching = widget.config?.stimEpochSpec;
      if (!_isPrepared && epoching != null) {
        List<String> expand(String key) => [
          for (final code in (p[key] as List).cast<String>())
            ...epoching.markerGroups[code] ?? [code],
        ];
        p['saved_a_groups'] = p['a_codes'];
        p['saved_b_groups'] = p['b_codes'];
        p['a_codes'] = expand('a_codes');
        p['b_codes'] = expand('b_codes');
        p['epoch'] = [epoching.tmin, epoching.tmax];
        if (epoching.baseline)
          p['baseline'] = [epoching.baselineStart, epoching.baselineEnd];
      }
      options['profile_override'] = p;
    }
    if (!inspection && widget.config != null) {
      widget.config!.erpAnalysisProtocol = Map<String, dynamic>.from(options)
        ..remove('trial_metadata_path');
    }
    return options;
  }

  void _restoreProtocol() {
    final options = widget.config?.erpAnalysisProtocol;
    if (options == null || options.isEmpty) return;
    _task = options['task'] as String? ?? 'Auto';
    _eventSource = options['event_source'] as String? ?? 'auto';
    _regroupEpochs = options['regroup_epochs'] == true;
    _correct = options['correct_only'] != false;
    _regression = options['regression'] == true;
    _deconvolution = options['deconvolution'] == true;
    _decoding = options['decoding'] == true;
    _generalization = options['temporal_generalization'] == true;
    _exportTrials = options['export_trial_measurements'] == true;
    for (final pair in <String, TextEditingController>{
      'bin_ms': _bin,
      'reject_uv': _reject,
      'permutations': _permutations,
      'folds': _folds,
      'decode_shrinkage': _shrinkage,
      'lsqr_tolerance': _lsqrTolerance,
      'lsqr_iterations': _lsqrIterations,
    }.entries) {
      if (options[pair.key] != null) pair.value.text = '${options[pair.key]}';
    }
    if (options['response_min'] is num)
      _rtMin.text = '${(options['response_min'] as num) * 1000}';
    if (options['response_max'] is num)
      _rtMax.text = '${(options['response_max'] as num) * 1000}';
    _profiles
      ..clear()
      ..addAll({
        for (final e in (options['profile_overrides'] as Map? ?? {}).entries)
          e.key.toString(): Map<String, dynamic>.from(e.value as Map),
      });
    final profile = options['profile_override'];
    if (profile is Map) _fillProfile(Map<String, dynamic>.from(profile));
  }

  void _fillProfile(Map<String, dynamic>? p) {
    _profile = p;
    if (p == null) return;
    if (_isPrepared) {
      _savedA = _savedGroups
          .where(
            (g) => markerListContains(
              ((p['saved_a_groups'] ?? p['a_codes']) as List).cast<String>(),
              g,
            ),
          )
          .toList();
      _savedB = _savedGroups
          .where(
            (g) => markerListContains(
              ((p['saved_b_groups'] ?? p['b_codes']) as List).cast<String>(),
              g,
            ),
          )
          .toList();
    }
    _componentLabel.text =
        p['component_name'] as String? ?? p['task'] as String;
    _a.text = (p['a_codes'] as List).join(', ');
    _b.text = (p['b_codes'] as List).join(', ');
    _roi.text = (p['roi'] as List).join(', ');
    void pair(String key, TextEditingController a, TextEditingController b) {
      final v = erpNumbers(p[key]);
      a.text = (v[0] * 1000).toStringAsFixed(0);
      b.text = (v[1] * 1000).toStringAsFixed(0);
    }

    pair('epoch', _epoch0, _epoch1);
    pair('baseline', _base0, _base1);
    pair('window', _window0, _window1);
  }

  Future<void> _inspect() async {
    if (_inputs.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Reading markers and task suggestions…';
    });
    try {
      final scan = await _service.execute(
        _inputs,
        _options(inspection: true),
        _output.text,
        inspect: true,
      );
      if (!mounted) return;
      setState(() {
        _inspection = scan;
        for (final f in _scanFiles) {
          if (f['subject'] != null)
            _subjects[f['path'] as String] = f['subject'] as String;
        }
        final profiles = _scanFiles
            .map((f) => erpMap(f['profile']))
            .where((p) => p.isNotEmpty)
            .toList();
        final tasks = profiles.map((p) => p['task']).toSet();
        _fillProfile(tasks.length == 1 ? profiles.first : null);
        _restoreProtocol();
        _status = _isPrepared
            ? 'Choose saved groups A/B, review the ROI/window, then Average & analyse ERP.'
            : 'Review suggested classes and timing before running. ${_scanFiles.where((f) => f['error'] != null).length} input(s) need attention.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Marker inspection failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openResult() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ccserp', 'json'],
    );
    if (picked == null || picked.files.single.path == null || !mounted) return;
    try {
      final path = picked.files.single.path!;
      final value = Map<String, dynamic>.from(
        jsonDecode(await File(path).readAsString()) as Map,
      );
      if (value['schema'] != 'ccs-erp-workbench-v1')
        throw const FormatException(
          'Choose erp_results.ccserp from a workbench run',
        );
      if (!mounted) return;
      setState(() {
        _result = value;
        _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
        _file = null;
        _output.text = File(path).parent.path;
        _status = 'Loaded saved ERP results.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _addFolder() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null || !mounted) return;
    try {
      final files = discoverErpRecordings(
        directory,
        firstSubjects: int.tryParse(_limit.text) ?? 2,
      );
      setState(() {
        _paths
          ..clear()
          ..addAll(files);
        _result = null;
      });
      await _inspect();
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _addFiles() async {
    final picked = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['edf', 'fif', 'ccseeg', 'json'],
      recordingsOnly: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final f in picked.files) {
        if (f.path != null && !_paths.contains(f.path)) _paths.add(f.path!);
      }
      _result = null;
    });
    await _inspect();
  }

  Future<void> _run() async {
    if (_output.text.trim().isEmpty) {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose ERP results folder',
      );
      if (path == null || !mounted) return;
      _output.text = path;
    }
    Map<String, dynamic> options;
    try {
      options = _options();
    } catch (e) {
      setState(() => _status = 'Check timing values: $e');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Running ERP analysis…';
    });
    try {
      final result = await _service.execute(
        _inputs,
        options,
        _output.text.trim(),
        progress: (p, message) {
          if (mounted)
            setState(() {
              _progress = p;
              _status = message;
            });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _file = null;
        _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
        _status = 'Writing the compact report…';
      });
      await writeErpWorkbenchReport(result, _output.text.trim());
      if (mounted)
        setState(
          () => _status =
              'Finished: ${_results.length} recordings; ${(result['failures'] as List).length} need attention. Report and tables saved.',
        );
    } catch (e) {
      if (mounted) setState(() => _status = 'Analysis stopped: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: TextField(
          controller: c,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 3,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
  Widget _pair(
    String label,
    TextEditingController a,
    TextEditingController b,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 5),
      Row(
        children: [
          Expanded(child: _field(a, 'Start (ms)')),
          const SizedBox(width: 8),
          Expanded(child: _field(b, 'End (ms)')),
        ],
      ),
    ],
  );
  Widget _card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: title == '3  Analyses' && !widget.batchMode
        ? ExpansionTile(
            title: const Text(
              'Advanced analyses (optional)',
              style: TextStyle(fontSize: 14),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ],
          )
        : Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                ...children,
              ],
            ),
          ),
  );
  Widget _check(String text, bool value, void Function(bool) set) =>
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(text),
        value: value,
        onChanged: _busy ? null : (v) => setState(() => set(v ?? false)),
      );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final settings = SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (widget.config != null)
              ProtocolTools(
                config: widget.config!,
                beforeSave: () {
                  _options();
                },
                onChanged: () => setState(_restoreProtocol),
              ),
            const Tooltip(
              message:
                  'Trials are averaged separately within each selected condition. B minus A is the difference waveform. ROI and measurement windows control the reported ERP measurements.',
              child: Text(
                'Saved trials → condition groups → averages → measurements / statistics',
              ),
            ),
            _card(widget.batchMode ? '1  Batch inputs' : '1  Active recording', [
              TextButton.icon(
                onPressed: _busy ? null : _openResult,
                icon: const Icon(Icons.history),
                label: const Text('Open saved ERP results…'),
              ),
              if (widget.batchMode) ...[
                const Text(
                  'Start from continuous recordings with events, or reuse saved epoched condition files.',
                ),
                const SizedBox(height: 10),
                _field(
                  _limit,
                  'First N participants on folder import (0 = all)',
                  helper:
                      'Cleaned EDF counterparts are preferred; raw and cleaned copies are not counted twice.',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addFiles,
                      icon: const Icon(Icons.add),
                      label: const Text('Files'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addFolder,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Folder'),
                    ),
                    if (_paths.isNotEmpty)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _paths.clear();
                                _inspection = null;
                                _fillProfile(null);
                              }),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ] else ...[
                Text(
                  widget.activeRecording?.path.split(RegExp(r'[/\\]')).last ??
                      'No recording selected',
                ),
                Text(
                  _isPrepared
                      ? 'Saved trials are reused. Select condition groups below; no marker selection or epoching is repeated.'
                      : 'Prepare event-based trials in Preprocess before comparing ERP groups here.',
                ),
                if (!_isPrepared)
                  OutlinedButton.icon(
                    onPressed: widget.onPrepare,
                    icon: const Icon(Icons.cut),
                    label: const Text('Go to event epoching'),
                  ),
                if (_isPrepared)
                  TextButton(
                    onPressed: widget.onPrepare,
                    child: const Text(
                      'Change epoch locking / window in Preprocess',
                    ),
                  ),
                TextButton(
                  onPressed: widget.onOpenBatch,
                  child: const Text('Multiple recordings → Batch Workspace'),
                ),
              ],
              if (widget.batchMode)
                Text('${_selectedPaths.length} recordings selected'),
              if (widget.batchMode && _paths.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : _reviewInputs,
                  child: const Text('Review files and participant IDs…'),
                ),
            ]),
            _card(
              _isPrepared
                  ? '2  ERP task and condition groups'
                  : '2  Task and event markers',
              [
                if (!_isPrepared)
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _eventSource,
                    decoration: const InputDecoration(
                      labelText: 'Event timing source',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          'Sidecar preferred, otherwise native events',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'sidecar',
                        child: Text('EEGLAB .evt sidecar only'),
                      ),
                      DropdownMenuItem(
                        value: 'native',
                        child: Text('EDF annotations / Status only'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) {
                            setState(() => _eventSource = v!);
                            _inspect();
                          },
                  ),

                DropdownButtonFormField<String>(
                  initialValue: _task,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'ERP to analyse',
                  ),
                  items:
                      [
                            'Auto',
                            'MMN',
                            'N170',
                            'N2pc',
                            'N400',
                            'P3',
                            'LRP',
                            'ERN',
                            'Custom',
                          ]
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              child: Text(
                                v == 'Auto'
                                    ? (widget.batchMode
                                          ? 'Suggest per file (all ERP CORE tasks)'
                                          : 'Suggest from active recording')
                                    : v,
                              ),
                            ),
                          )
                          .toList(),
                  onChanged: _busy
                      ? null
                      : (v) {
                          setState(() {
                            _task = v!;
                            if (v == 'Custom') _regroupEpochs = false;
                          });
                          _inspect();
                        },
                ),
                const SizedBox(height: 10),
                if (_profile != null)
                  Text(
                    erpTaskGuides[_profile!['task']] ??
                        erpTaskGuides['Custom']!,
                  ),
                if (!_isPrepared)
                  const Text(
                    'Continuous-input marker definitions are configured here because no saved trial groups exist yet.',
                  ),
                if (widget.batchMode && _scanFiles.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final task
                      in _scanFiles
                          .map((f) => erpMap(f['profile'])['task'])
                          .whereType<String>()
                          .toSet())
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '$task · ${_scanFiles.where((f) => erpMap(f['profile'])['task'] == task).length} recordings',
                      ),
                      subtitle: Text(() {
                        final p = erpMap(
                          _scanFiles.firstWhere(
                            (f) => erpMap(f['profile'])['task'] == task,
                          )['profile'],
                        );
                        final w = erpNumbers(p['window']);
                        return '${(p['roi'] as List).join(', ')} · ${(w.first * 1000).round()}–${(w.last * 1000).round()} ms';
                      }()),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                setState(() => _task = task);
                                _inspect();
                              },
                        child: const Text('Review'),
                      ),
                    ),
                ],
                if (_isPrepared && _profile == null)
                  _check(
                    'Use each task’s suggested saved-event comparison',
                    _regroupEpochs,
                    (v) {
                      _regroupEpochs = v;
                      _inspect();
                    },
                  ),
                if (_profile != null) ...[
                  const SizedBox(height: 8),
                  _field(_componentLabel, 'Component name'),
                  if (_isPrepared) ...[
                    if (_scanFiles.any((f) => f['can_regroup'] == true) &&
                        _profile!['task'] != 'Custom')
                      _check(
                        'Suggest task groups from saved locking events',
                        _regroupEpochs,
                        (v) {
                          _regroupEpochs = v;
                          _inspect();
                        },
                      ),
                    if (_regroupEpochs)
                      const Text(
                        'Suggested groups are reconstructed from the original saved locking event of each existing trial. No re-epoching is performed.',
                        style: TextStyle(fontSize: 11),
                      ),
                    _savedGroupPicker('A', _savedA, _savedB),
                    _savedGroupPicker('B', _savedB, _savedA),
                    if (_savedA.isEmpty || _savedB.isEmpty)
                      const Text(
                        'Choose at least one saved condition for each group. Arbitrary group names are not assigned to ERP CORE conditions automatically.',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                        ),
                      ),
                  ] else ...[
                    _field(_a, 'Class A: ${_profile!['a_name']} · codes'),
                    _field(_b, 'Class B: ${_profile!['b_name']} · codes'),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _reviewMarkers,
                      icon: const Icon(Icons.flag),
                      label: const Text('Choose from detected markers…'),
                    ),
                  ],
                  _field(
                    _roi,
                    _profile!['lateralized'] == true
                        ? 'Left ROI, right ROI'
                        : 'ROI channel(s), comma separated',
                  ),
                  if (_profile!['lateralized'] == true)
                    const Text(
                      'Conventional traces: ipsilateral vs contralateral. Original side classes are used for models/decoding.',
                    ),
                  if (widget.batchMode)
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () {
                              try {
                                final p = erpMap(
                                  _options()['profile_override'],
                                );
                                setState(() {
                                  _profiles[p['task'] as String] = p;
                                  _status =
                                      'Saved ${p['task']} settings for mixed-task batches.';
                                });
                              } catch (e) {
                                setState(() => _status = 'Check settings: $e');
                              }
                            },
                      icon: const Icon(Icons.save),
                      label: const Text('Keep task settings for mixed batches'),
                    ),
                  if (!_isPrepared)
                    _pair('Epoch', _epoch0, _epoch1)
                  else
                    Text(
                      'Saved trial window: ${_epoch0.text} to ${_epoch1.text} ms (preserved)',
                    ),
                  _pair('Baseline', _base0, _base1),
                  _pair('Measurement window', _window0, _window1),
                  DropdownButtonFormField<double>(
                    initialValue: (_profile!['polarity'] as num).toDouble(),
                    decoration: const InputDecoration(
                      labelText: 'Component polarity',
                    ),
                    items: const [
                      DropdownMenuItem(value: -1, child: Text('Negative')),
                      DropdownMenuItem(value: 1, child: Text('Positive')),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _profile!['polarity'] = v!),
                  ),
                ] else if (_scanFiles.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Mixed-task batch uses each reviewed task preset. Select a task above to edit its event/timing rules.',
                    ),
                  ),
                if (!_isPrepared)
                  _check(
                    'Require correct stimulus responses (where applicable)',
                    _correct,
                    (v) => _correct = v,
                  ),
                if (!_isPrepared)
                  ExpansionTile(
                    title: const Text('Behavior and timing notes'),
                    children: const [
                      Text(
                        'ERP CORE stimulus tasks default to correct responses 200–1000 ms after the event (editable under solver/response parameters). MMN has no response filter. ERN includes correct and error responses; LRP uses correct left/right responses. No LCD-delay adjustment or extra filtering is applied automatically.',
                      ),
                    ],
                  ),
              ],
            ),
            _card('3  Analyses', [
              ExpansionTile(
                title: const Text('Solver, decoding and response parameters'),
                children: [
                  if (!_isPrepared)
                    _pair('Response association window', _rtMin, _rtMax),
                  _field(_folds, 'Blocked decoding folds (2–20)'),
                  _field(_shrinkage, 'LDA shrinkage (0–1)'),
                  if (!_isPrepared)
                    _field(_lsqrTolerance, 'Overlap solver tolerance'),
                  if (!_isPrepared)
                    _field(
                      _lsqrIterations,
                      'Overlap solver maximum iterations',
                    ),
                ],
              ),

              const Text(
                'Always: mean, peak amplitude/latency, signed and positive/negative AUC, fractional-area/peak latency, GFP, paired subject statistics, corrected topography and TANOVA.',
              ),
              _check(
                'Export individual-trial measurements (advanced)',
                _exportTrials,
                (v) => _exportTrials = v,
              ),
              const Text(
                'Standard ERP measurements use participant/condition averages (erp_measurements.csv). Trial exports are optional for trial-level models; individual-trial peaks are noise-sensitive.',
              ),
              const SizedBox(height: 9),
              _field(
                _reject,
                'Amplitude rejection threshold (µV; 0 = off)',
                helper:
                    'Use preprocessed inputs or clean recordings in the Preprocess module first.',
              ),
              _field(_bin, 'Model / statistical time-bin width (ms)'),
              if (widget.batchMode)
                _field(_permutations, 'Group sign-flip permutations'),
              _check(
                'Regression ERP (multichannel OLS)',
                _regression,
                (v) => _regression = v,
              ),
              if (_regression)
                _field(
                  _metadata,
                  'Optional trial predictor CSV path',
                  helper:
                      'file,event_index followed by numeric predictors. Intercept, class and complete RT are included automatically.',
                ),
              if (!_isPrepared)
                _check(
                  'Overlap correction (Unfold-style FIR / LSQR)',
                  _deconvolution,
                  (v) => _deconvolution = v,
                ),
              if (_deconvolution)
                const Text(
                  'Continuous-data model with class and nuisance stimulus/response events. This is the stick-basis subset, not the entire Unfold toolbox; inspect convergence and exclusions separately.',
                ),
              _check(
                'Time-resolved neural decoding (shrinkage LDA)',
                _decoding,
                (v) => _decoding = v,
              ),
              if (_decoding) ...[
                _check(
                  'Temporal generalization (train time × test time)',
                  _generalization,
                  (v) => _generalization = v,
                ),
                const Text(
                  'Contiguous test folds; overlapping epoch samples are purged from training. Scaling is fitted on training data. Descriptive scores are not a significance test.',
                ),
              ],
            ]),
            if (widget.batchMode)
              _card('4  Run and export', [
                if (_timingIssue != null)
                  Text(
                    _timingIssue!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                _field(_output, 'Output folder'),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final path = await FilePicker.getDirectoryPath();
                          if (path != null && mounted)
                            setState(() => _output.text = path);
                        },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose output folder'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _canRun ? _run : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Analyse ${_selectedPaths.length} recording(s)'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                  ),
                  TextButton(
                    onPressed: () => _service.cancel(),
                    child: const Text('Cancel'),
                  ),
                ],
                const SizedBox(height: 8),
                SelectableText(_status),
                if (_result != null)
                  TextButton.icon(
                    onPressed: () => Process.run(
                      Platform.isMacOS
                          ? 'open'
                          : Platform.isWindows
                          ? 'explorer'
                          : 'xdg-open',
                      [_output.text],
                    ),
                    icon: const Icon(Icons.folder),
                    label: const Text('Open results folder'),
                  ),
              ]),
          ],
        ),
      );
      final panel = widget.batchMode
          ? settings
          : Column(
              children: [
                Expanded(child: settings),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_timingIssue != null)
                        Text(
                          _timingIssue!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: _output.text.isEmpty
                                ? 'Choose results folder'
                                : _output.text,
                            icon: const Icon(Icons.folder_open),
                            onPressed: _busy
                                ? null
                                : () async {
                                    final path =
                                        await FilePicker.getDirectoryPath();
                                    if (path != null && mounted)
                                      setState(() => _output.text = path);
                                  },
                          ),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy
                                  ? () => _service.cancel()
                                  : _canRun
                                  ? _run
                                  : null,
                              icon: Icon(
                                _busy ? Icons.stop : Icons.play_arrow,
                                size: 17,
                              ),
                              label: Text(
                                _busy ? 'Cancel' : 'Average & analyse ERP',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_busy) LinearProgressIndicator(value: _progress),
                      Text(
                        _status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            );
      final results = _resultsPane();
      if (constraints.maxWidth < 850)
        return Column(
          children: [
            Expanded(child: panel),
            SizedBox(height: constraints.maxHeight * .45, child: results),
          ],
        );
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 360, child: panel),
          const VerticalDivider(width: 1),
          Expanded(child: results),
        ],
      );
    },
  );
  Future<void> _reviewInputs() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recordings and participant IDs'),
        content: SizedBox(
          width: 780,
          height: 450,
          child: ListView.builder(
            itemCount: _paths.length,
            itemBuilder: (context, i) {
              final path = _paths[i];
              final scan = _scanFiles
                  .where((f) => f['path'] == path)
                  .firstOrNull;
              return ListTile(
                title: Text(path.split(Platform.pathSeparator).last),
                subtitle: Text(
                  scan?['error']?.toString() ??
                      '${scan?['marker_source'] ?? 'Inspect to read markers'} · ${scan?['event_count'] ?? 0} events\nTiming comparison: ${_timingSummary(scan?['timing_audit'])}',
                ),
                trailing: SizedBox(
                  width: 150,
                  child: TextFormField(
                    initialValue: _subjects[path] ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Participant ID',
                    ),
                    onChanged: (v) => _subjects[path] = v.trim(),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _reviewMarkers() async {
    final counts = <String, int>{};
    for (final f in _scanFiles) {
      erpMap(
        f['marker_counts'],
      ).forEach((k, v) => counts[k] = (counts[k] ?? 0) + (v as num).toInt());
    }
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Detected marker assignments'),
          content: SizedBox(
            width: 650,
            height: 470,
            child: Column(
              children: [
                TextField(
                  controller: _markerSearch,
                  decoration: const InputDecoration(labelText: 'Find marker'),
                  onChanged: (_) => update(() {}),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final key in counts.keys.where(
                        (k) => k.toLowerCase().contains(
                          _markerSearch.text.toLowerCase(),
                        ),
                      ))
                        ListTile(
                          title: Text('$key · ${counts[key]} events'),
                          trailing: SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(value: 'A', label: Text('A')),
                              ButtonSegment(value: 'B', label: Text('B')),
                              ButtonSegment(value: '-', label: Text('Ignore')),
                            ],
                            selected: {
                              _a.text
                                      .split(',')
                                      .map((s) => s.trim())
                                      .contains(key)
                                  ? 'A'
                                  : _b.text
                                        .split(',')
                                        .map((s) => s.trim())
                                        .contains(key)
                                  ? 'B'
                                  : '-',
                            },
                            onSelectionChanged: (v) {
                              void remove(TextEditingController c) => c.text = c
                                  .text
                                  .split(',')
                                  .map((s) => s.trim())
                                  .where((s) => s != key && s.isNotEmpty)
                                  .join(', ');
                              remove(_a);
                              remove(_b);
                              final target = v.first == 'A'
                                  ? _a
                                  : v.first == 'B'
                                  ? _b
                                  : null;
                              if (target != null)
                                target.text = [
                                  ...target.text
                                      .split(',')
                                      .map((s) => s.trim())
                                      .where((s) => s.isNotEmpty),
                                  key,
                                ].join(', ');
                              update(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Use these assignments'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Map<String, dynamic> get _display {
    if (_file != null) {
      return _results.firstWhere((f) => f['path'] == _file, orElse: () => {});
    }
    return _groups.firstWhere((g) => g['task'] == _component, orElse: () => {});
  }

  Future<void> _groupModels({bool difference = false}) async {
    if (_result == null || _component.isEmpty) return;
    final path =
        '${_output.text}/Group_Statistics/ERP_${_component}_${difference ? 'difference' : 'conditions'}_group_input.csv';
    final dir = Directory(File(path).parent.path);
    await dir.create(recursive: true);
    String quote(dynamic v) => '"${v.toString().replaceAll('"', '""')}"';
    final lines = <String>[
      'filename,subjid,condn,Chan,Epoch,epoch_label,Condition,mean_amplitude_ERP,signed_auc_ERP,peak_amplitude_ERP,peak_latency_ms_ERP,fractional_area_latency_ms_ERP',
    ];
    for (final file in _results.where((f) => f['task'] == _component)) {
      final profile = erpMap(file['profile']);
      for (final key in (difference ? ['B_minus_A'] : ['A', 'B'])) {
        final m = erpMap(erpMap(file['measurements'])[key]);
        final label = difference
            ? 'B - A'
            : profile['lateralized'] == true
            ? (key == 'A' ? 'Ipsilateral' : 'Contralateral')
            : profile[key == 'A' ? 'a_name' : 'b_name'];
        lines.add(
          [
            quote(file['path']),
            quote(file['subject']),
            quote(file['task']),
            quote((profile['roi'] as List).join('+')),
            '1',
            quote(label),
            quote(label),
            m['mean'] ?? '',
            m['signed_auc'] ?? '',
            m['peak_amplitude'] ?? '',
            m['peak_latency'] is num ? (m['peak_latency'] as num) * 1000 : '',
            m['fractional_area_latency'] is num
                ? (m['fractional_area_latency'] as num) * 1000
                : '',
          ].join(','),
        );
      }
    }
    await File(path).writeAsString('${lines.join('\n')}\n');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text('$_component · metadata and group models'),
          ),
          body: GroupStatisticsWorkbench(initialCsvPath: path),
        ),
      ),
    );
  }

  Widget _savedGroupPicker(
    String label,
    List<String> selected,
    List<String> other,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Group $label · ${selected.isEmpty ? "not selected" : selected.join(" + ")}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final g in _savedGroups)
              FilterChip(
                label: Text(
                  '$g ×${_scanFiles.fold<int>(0, (n, f) => n + (erpMap(f['marker_counts'])[g] as num? ?? 0).toInt())}',
                ),
                selected: selected.contains(g),
                onSelected: _busy
                    ? null
                    : (v) => setState(() {
                        if (v) {
                          selected.add(g);
                          other.remove(g);
                        } else {
                          selected.remove(g);
                        }
                      }),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _resultsPane() {
    if (_groups.isEmpty)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.show_chart, size: 64),
              const SizedBox(height: 16),
              const Text(
                'ERP results',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                widget.batchMode
                    ? 'Choose a task folder, review the input type and task definitions, then run the batch.'
                    : _isPrepared
                    ? '${widget.activeRecording?.epochCount ?? 0} saved trials are ready. No new epoching is required.\n\n1. Choose the ERP task at left.\n2. Select condition groups A and B.\n3. Review the ROI, baseline and measurement window.\n4. Click Average & analyse ERP.\n\nTrials are averaged separately within A and B.\nResults include A, B and B−A waveforms, measurements and statistics.'
                    : '1. Define locking events and named groups using Epoch Events or Preprocess.\n2. Save event epochs (with cleaning if needed).\n3. Select saved groups A/B here, review the task and window, then average.',
                textAlign: TextAlign.center,
              ),
              if ((_result?['failures'] as List? ?? []).isNotEmpty)
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(_result!['failures']),
                ),
            ],
          ),
        ),
      );
    final d = _display;
    final current = _results.where((f) => f['task'] == _component).toList();
    final modelFile = _file == null
        ? (current.isEmpty ? <String, dynamic>{} : current.first)
        : d;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<String>(
                  initialValue: _component,
                  items: _groups
                      .map(
                        (g) => DropdownMenuItem(
                          value: g['task'] as String,
                          child: Text('${g['task']}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() {
                    _component = v!;
                    _file = null;
                  }),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('$_component/$_file'),
                  initialValue: _file ?? 'group',
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: 'group',
                      child: Text('Group (equal participant weights)'),
                    ),
                    for (final f in current)
                      DropdownMenuItem(
                        value: f['path'] as String,
                        child: Text(
                          'Participant ${f['subject']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _file = v == 'group' ? null : v),
                ),
              ),
              if (_file == null) Text('${d['n_subjects']} participant(s)'),
              OutlinedButton.icon(
                onPressed: current.isEmpty
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ErpReviewWorkspace(
                            files: current,
                            task: _component,
                            output: _output.text,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.tune),
                label: const Text('Interactive batch review'),
              ),
              OutlinedButton.icon(
                onPressed: () => _groupModels(),
                icon: const Icon(Icons.groups),
                label: const Text('Condition group models'),
              ),
              TextButton(
                onPressed: () => _groupModels(difference: true),
                child: const Text('Difference-wave group models'),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Waveforms'),
            Tab(text: 'Measurements'),
            Tab(text: 'Group / topography'),
            Tab(text: 'Models'),
            Tab(text: 'Decoding'),
            Tab(text: 'Quality'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    DropdownButton<double>(
                      value: _displaySmoothing,
                      items: [
                        for (final ms in [0.0, 8.0, 16.0, 24.0, 40.0])
                          DropdownMenuItem(
                            value: ms,
                            child: Text(
                              ms == 0
                                  ? 'Smoothing off'
                                  : 'Smooth ${ms.round()} ms · display only',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _displaySmoothing = v!),
                    ),
                    Text(
                      'A: ${erpMap(d['profile'])['a_name']} · B: ${erpMap(d['profile'])['b_name']} · Difference = B − A. Peak polarity selects a measurement; it never flips voltages.',
                    ),
                    ErpAxisControls(
                      onChanged: (v) => setState(() => _axisLimits = v),
                    ),
                    SwitchListTile(
                      dense: true,
                      title: const Text(
                        'Negative up (display orientation only)',
                      ),
                      value: _negativeUp,
                      onChanged: (v) => setState(() => _negativeUp = v),
                    ),
                    SizedBox(
                      height: 350,
                      width: double.infinity,
                      child: MouseRegion(
                        onHover: (e) => _hover.value = e.localPosition.dx,
                        onExit: (_) => _hover.value = null,
                        child: ValueListenableBuilder<double?>(
                          valueListenable: _hover,
                          builder: (context, hover, child) => CustomPaint(
                            painter: ErpWorkbenchWavePainter(
                              {
                                ...d,
                                ..._axisLimits,
                                for (final key in ['a', 'b', 'difference'])
                                  key: smoothErp(
                                    erpNumbers(d[key]),
                                    erpNumbers(d['times']),
                                    _displaySmoothing,
                                  ),
                                if (_displaySmoothing > 0) 'sem_difference': [],
                              },
                              negativeUp: _negativeUp,
                              hoverX: hover,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ErpChannelGrid(
                      files: current
                          .where((f) => _file == null || f['path'] == _file)
                          .toList(),
                      profile: erpMap(d['profile']),
                      negativeUp: _negativeUp,
                      smoothingMs: _displaySmoothing,
                      axisLimits: _axisLimits,
                    ),
                    const Text('Component-window topography (B - A)'),
                    SizedBox(
                      height: 280,
                      width: 360,
                      child: CustomPaint(painter: ErpWorkbenchTopoPainter(d)),
                    ),
                  ],
                ),
              ),
              _table(
                [
                  'Participant',
                  'Condition',
                  'Mean µV',
                  'AUC µV s',
                  'Peak µV',
                  'Peak ms',
                  '50% area ms',
                ],
                [
                  for (final f in current)
                    for (final item in erpMap(f['measurements']).entries)
                      [
                        f['subject'],
                        item.key,
                        erpMap(item.value)['mean'],
                        erpMap(item.value)['signed_auc'],
                        erpMap(item.value)['peak_amplitude'],
                        (erpMap(item.value)['peak_latency'] as num?)
                            ?.toDouble()
                            .times1000,
                        (erpMap(item.value)['fractional_area_latency'] as num?)
                            ?.toDouble()
                            .times1000,
                      ],
                ],
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${d['warning'] ?? 'Participant-level descriptive map; select Group for population statistics.'}',
                    ),
                    if (d['statistics'] is List)
                      _table(
                        ['Measure', 'N', 'Difference', 'p', 'q (FDR)'],
                        [
                          for (final s in (d['statistics'] as List).map(erpMap))
                            [
                              s['metric'],
                              s['n_subjects'],
                              s['mean_difference'],
                              s['p'],
                              s['q_fdr'],
                            ],
                        ],
                        shrink: true,
                      ),
                    Text(
                      'TANOVA GMD ${d['tanova_gmd'] ?? '—'} · p ${d['tanova_p'] ?? '—'}',
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text(
                        'Mask channel-time maps at corrected p ≤ .05',
                      ),
                      value: _significantOnly,
                      onChanged: (v) => setState(() => _significantOnly = v),
                    ),
                    const Text(
                      'Channel × time t statistic. Red = positive, blue = negative; masked points are white.',
                    ),
                    if (erpNumbers(d['spatiotemporal_t']).isNotEmpty)
                      SizedBox(
                        height: 300,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchHeatPainter(
                            _statValues(
                              d,
                              'spatiotemporal_t',
                              'spatiotemporal_p_fwer',
                            ),
                            (d['labels'] as List).length,
                            (d['bin_times'] as List).length,
                          ),
                        ),
                      ),
                    if (d['labels'] is List)
                      Text('Rows: ${(d['labels'] as List).join(', ')}'),
                    if (d['regression_inference'] is Map) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'rERP class beta: participant-level channel × time max-|t| inference',
                      ),
                      SizedBox(
                        height: 300,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchHeatPainter(
                            _statValues(
                              erpMap(d['regression_inference']),
                              't',
                              'p_fwer',
                            ),
                            (erpMap(d['regression_inference'])['channels']
                                    as List)
                                .length,
                            (erpMap(d['regression_inference'])['times'] as List)
                                .length,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _models(modelFile),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Participant ${modelFile['subject'] ?? ''}. ${erpMap(modelFile['decoding'])['method'] ?? 'Enable decoding before running.'}',
                    ),
                    if (modelFile['decoding'] is Map) ...[
                      Text(
                        '${erpMap(modelFile['decoding'])['folds_used']} usable folds; physical event classes. Scores do not establish significance.',
                      ),
                      SizedBox(
                        height: 330,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchWavePainter(
                            erpMap(modelFile['decoding']),
                            decode: true,
                          ),
                        ),
                      ),
                      if (erpMap(modelFile['decoding'])['generalization_auc']
                          is List) ...[
                        const Text(
                          'Temporal generalization: rows=train time, columns=test time; blue < .5, white=.5, red > .5.',
                        ),
                        SizedBox(
                          height: 320,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: ErpWorkbenchHeatPainter(
                              erpNumbers(
                                erpMap(
                                  modelFile['decoding'],
                                )['generalization_auc'],
                              ),
                              (erpMap(modelFile['decoding'])['times'] as List)
                                  .length,
                              (erpMap(modelFile['decoding'])['times'] as List)
                                  .length,
                              probability: true,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in current) ...[
                      Text(
                        'Participant ${f['subject']} · ${f['n_a']}/${f['n_b']} accepted',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Source: ${f['marker_source']}\nExcluded: behavior ${f['rejected_behavior']}, edge ${f['rejected_boundary']}, amplitude ${f['rejected_amplitude']}',
                      ),
                      if (f['timing_audit'] is Map)
                        Text(
                          'Timing comparison: ${_timingSummary(f['timing_audit'])}',
                        ),
                      for (final w in (f['warnings'] as List? ?? []))
                        Text('• $w'),
                      const Divider(),
                    ],
                    for (final fail
                        in (_result?['failures'] as List? ?? []).map(erpMap))
                      Text('${fail['path']}: ${fail['error']}'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _table(
    List<String> headings,
    List<List<dynamic>> rows, {
    bool shrink = false,
  }) {
    final table = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: headings.map((h) => DataColumn(label: Text(h))).toList(),
        rows: rows
            .take(150)
            .map(
              (r) => DataRow(
                cells: r
                    .map(
                      (v) => DataCell(
                        Text(
                          v is num
                              ? v.toStringAsFixed(4)
                              : v?.toString() ?? '—',
                        ),
                      ),
                    )
                    .toList(),
              ),
            )
            .toList(),
      ),
    );
    return shrink
        ? table
        : SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rows.length > 150)
                  const Text(
                    'Showing 150 rows; all measurements are exported.',
                  ),
                table,
              ],
            ),
          );
  }

  String _timingSummary(dynamic audit) {
    final m = erpMap(audit);
    if (m.isEmpty) return 'not available';
    return m.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
  }

  List<double> _statValues(Map<String, dynamic> d, String tKey, String pKey) {
    final t = erpNumbers(d[tKey]), p = erpNumbers(d[pKey]);
    if (!_significantOnly) return t;
    return [
      for (var i = 0; i < t.length; i++)
        i < p.length && p[i] <= .05 ? t[i] : 0.0,
    ];
  }

  Widget _models(Map<String, dynamic> file) => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Participant ${file['subject'] ?? ''}; all channel/time coefficients are in JSON.',
        ),
        for (final key in ['regression', 'deconvolution'])
          if (file[key] is Map) ...[
            const SizedBox(height: 18),
            Text(
              key == 'regression' ? 'Regression ERP' : 'Overlap correction',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text('${erpMap(file[key])['method']}'),
            Text(
              'Predictors: ${(erpMap(file[key])['predictors'] as List).join(' | ')}',
            ),
            if (key == 'deconvolution')
              Text(
                'Events per category: ${erpMap(file[key])['event_counts']}. Solver converged for ${(erpMap(file[key])['solver'] as List).where((s) => erpMap(s)['converged'] == true).length}/${(erpMap(file[key])['solver'] as List).length} channels.',
              ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final m = erpMap(file[key]);
                final coefficients = m['coefficients'] as List;
                final channels = (m['channels'] as List).cast<String>();
                final predictors = (m['predictors'] as List).cast<String>();
                final preferred = (erpMap(file['profile'])['roi'] as List).first
                    .toString();
                final selectedChannel = channels.contains(_modelChannels[key])
                    ? _modelChannels[key]!
                    : channels.firstWhere(
                        (l) => l.toUpperCase() == preferred.toUpperCase(),
                        orElse: () => channels.first,
                      );
                final selectedPredictor =
                    predictors.contains(_modelPredictors[key])
                    ? _modelPredictors[key]!
                    : predictors[1];
                final c = channels.indexOf(selectedChannel);
                final beta = erpNumbers(
                  (coefficients[predictors.indexOf(selectedPredictor)]
                      as List)[c],
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      children: [
                        DropdownButton<String>(
                          value: selectedChannel,
                          items: [
                            for (final l in channels)
                              DropdownMenuItem(value: l, child: Text(l)),
                          ],
                          onChanged: (v) =>
                              setState(() => _modelChannels[key] = v!),
                        ),
                        DropdownButton<String>(
                          value: selectedPredictor,
                          items: [
                            for (final p in predictors)
                              DropdownMenuItem(value: p, child: Text(p)),
                          ],
                          onChanged: (v) =>
                              setState(() => _modelPredictors[key] = v!),
                        ),
                      ],
                    ),
                    const Text(
                      'Model coefficient in µV per predictor unit; all channels and predictors are exported.',
                    ),
                    SizedBox(
                      height: 300,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: ErpWorkbenchWavePainter({
                          'times': m['times'],
                          'a': beta,
                          'b': <double>[],
                          'model_plot': true,
                          'profile': {
                            'a_name': selectedPredictor,
                            'b_name': '',
                          },
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (key == 'deconvolution') Text('${erpMap(file[key])['scope']}'),
          ],
        if (file['regression'] == null && file['deconvolution'] == null)
          const Text(
            'Enable regression ERP or overlap correction before running.',
          ),
      ],
    ),
  );
}

extension on double {
  double get times1000 => this * 1000;
}
