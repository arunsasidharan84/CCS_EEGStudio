import 'axis_controls.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../group_statistics.dart';
import 'workbench_figures.dart';
import 'review_math.dart';
import 'channel_grid.dart';

class ErpReviewWorkspace extends StatefulWidget {
  const ErpReviewWorkspace({
    super.key,
    required this.files,
    required this.task,
    required this.output,
  });
  final List<Map<String, dynamic>> files;
  final String task, output;
  @override
  State<ErpReviewWorkspace> createState() => _ErpReviewWorkspaceState();
}

class _ErpReviewWorkspaceState extends State<ErpReviewWorkspace> {
  Map<String, dynamic> _axisLimits = {};

  final _selected = <String>{},
      _metrics = <String>{
        'mean',
        'signed_auc',
        'peak_amplitude',
        'peak_latency_ms',
      };
  final _groups = <String, String>{};
  final _search = TextEditingController();
  late List<Map<String, dynamic>> _files;
  late RangeValues _window;
  late TextEditingController _lo, _hi;
  String _view = 'Grand average', _group = 'All groups';
  double _smooth = 0;
  bool _negativeUp = true, _overlay = false;
  static const _names = {
    'mean': 'Mean amplitude (µV)',
    'signed_auc': 'Signed AUC (µV·s)',
    'positive_auc': 'Positive AUC (µV·s)',
    'negative_auc': 'Negative AUC (µV·s)',
    'peak_amplitude': 'Peak amplitude (µV)',
    'peak_latency_ms': 'Peak latency (ms)',
    'fractional_area_latency_ms': '50% area latency (ms)',
    'fractional_peak_latency_ms': '50% peak latency (ms)',
  };
  @override
  void initState() {
    super.initState();
    final first = widget.files.first;
    final time = erpNumbers(first['times']);
    // Do not silently combine recordings on different temporal grids or condition definitions.
    final reference = erpMap(first['profile']);
    _files = widget.files.where((f) {
      final t = erpNumbers(f['times']), p = erpMap(f['profile']);
      return t.length == time.length &&
          List.generate(
            t.length,
            (i) => (t[i] - time[i]).abs() < 1e-8,
          ).every((v) => v) &&
          p['a_name'] == reference['a_name'] &&
          p['b_name'] == reference['b_name'] &&
          jsonEncode(p['roi']) == jsonEncode(reference['roi']) &&
          jsonEncode(p['baseline']) == jsonEncode(reference['baseline']) &&
          p['lateralized'] == reference['lateralized'];
    }).toList();
    _selected.addAll(_files.map((f) => '${f['subject']}'));
    final w = erpNumbers(reference['window']);
    _window = RangeValues(w[0], w[1]);
    _lo = TextEditingController(text: '${(w[0] * 1000).round()}');
    _hi = TextEditingController(text: '${(w[1] * 1000).round()}');
  }

  @override
  void dispose() {
    _search.dispose();
    _lo.dispose();
    _hi.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _chosen => _files
      .where(
        (f) =>
            _selected.contains('${f['subject']}') &&
            (_group == 'All groups' ||
                (_groups['${f['subject']}'] ?? 'Unlabelled') == _group),
      )
      .toList();
  void _setWindow(RangeValues value) => setState(() {
    _window = value;
    _lo.text = '${(value.start * 1000).round()}';
    _hi.text = '${(value.end * 1000).round()}';
  });
  void _textWindow() {
    final a = double.tryParse(_lo.text),
        b = double.tryParse(_hi.text),
        t = erpNumbers(_files.first['times']);
    if (a != null &&
        b != null &&
        a < b &&
        a / 1000 >= t.first &&
        b / 1000 <= t.last)
      setState(() => _window = RangeValues(a / 1000, b / 1000));
  }

  Future<void> _labelGroups() async {
    final controllers = {
      for (final id
          in (_files.map((f) => '${f['subject']}').toSet().toList()..sort()))
        id: TextEditingController(text: _groups[id] ?? ''),
    };
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Participant group labels'),
        content: SizedBox(
          width: 440,
          height: 400,
          child: ListView(
            children: [
              const Text(
                'Assign between-participant groups, for example Control or Treatment. A/B remain within-participant conditions.',
              ),
              for (final e in controllers.entries)
                TextField(
                  controller: e.value,
                  decoration: InputDecoration(labelText: e.key),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply labels'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted)
      setState(() {
        for (final e in controllers.entries) {
          _groups[e.key] = e.value.text.trim().isEmpty
              ? 'Unlabelled'
              : e.value.text.trim();
        }
        _group = 'All groups';
      });
    // Dialog route finishes its disposal on the next frame.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final c in controllers.values) {
      c.dispose();
    }
  }

  Future<void> _export({bool stats = false}) async {
    if (_chosen.isEmpty || _metrics.isEmpty) return;
    try {
      final path = stats
          ? '${widget.output}/Group_Statistics/ERP_${widget.task}_review.csv'
          : await FilePicker.saveFile(
              dialogTitle: 'Export selected participant ERP measurements',
              fileName: 'ERP_${widget.task}_review.csv',
            );
      if (path == null) return;
      await Directory(File(path).parent.path).create(recursive: true);
      await File(path).writeAsString(
        reviewCsv(_chosen, _groups, _metrics, _window.start, _window.end),
      );
      if (!mounted) return;
      if (stats) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('ERP group statistics')),
              body: GroupStatisticsWorkbench(initialCsvPath: path),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved participant measurements: $path')),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen, people = reviewParticipants(chosen);
    final times = erpNumbers(_files.first['times']);
    final recording = chosen
        .where((f) => 'recording:${f['path']}' == _view)
        .firstOrNull;
    final individual =
        recording ??
        (_view == 'Grand average'
            ? null
            : people.where((p) => p['subject'] == _view).firstOrNull);
    final shown = individual == null ? people : [individual];
    final profile = {
      ...erpMap(_files.first['profile']),
      'window': [_window.start, _window.end],
    };
    final data = <String, dynamic>{'times': times, 'profile': profile};
    for (final key in ['a', 'b', 'difference']) {
      final arrays = [
        for (final p in shown) smoothErp(erpNumbers(p[key]), times, _smooth),
      ];
      data[key] = reviewAverage(arrays);
      data['sem_$key'] = reviewSem(arrays);
    }
    if (_overlay)
      data['overlays'] = [
        for (final p in people)
          smoothErp(erpNumbers(p['difference']), times, _smooth),
      ];
    // Align channel labels and weight each participant equally, including repeated files.
    final selectedFiles = recording != null
        ? [recording]
        : individual == null
        ? chosen
        : chosen.where((f) => f['subject'] == individual['subject']).toList();
    final labels =
        (selectedFiles.isEmpty
                ? <dynamic>[]
                : selectedFiles.first['labels'] as List)
            .cast<String>()
            .where(
              (l) =>
                  selectedFiles.every((f) => (f['labels'] as List).contains(l)),
            )
            .toList();
    final maps = <String, List<List<double>>>{};
    var mapAvailable = selectedFiles.isNotEmpty;
    for (final f in selectedFiles) {
      final values = reviewTopo(f, _window.start, _window.end);
      if (values == null) {
        mapAvailable = false;
        break;
      }
      final own = (f['labels'] as List).cast<String>();
      maps.putIfAbsent('${f['subject']}', () => []).add([
        for (final label in labels) values[own.indexOf(label)],
      ]);
    }
    if (mapAvailable) {
      data['labels'] = labels;
      data['topo_difference'] = reviewAverage([
        for (final rows in maps.values) reviewAverage(rows),
      ]);
    }
    final ids = _files.map((f) => '${f['subject']}').toSet().toList()..sort();
    final groupOptions = {
      'All groups',
      ...ids.map((id) => _groups[id] ?? 'Unlabelled'),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.task} · interactive ERP review'),
        actions: [
          TextButton.icon(
            onPressed: _labelGroups,
            icon: const Icon(Icons.groups),
            label: const Text('Label groups'),
          ),
          TextButton.icon(
            onPressed: people.isEmpty ? null : () => _export(),
            icon: const Icon(Icons.download),
            label: const Text('Export CSV'),
          ),
          TextButton(
            onPressed: people.length < 2 ? null : () => _export(stats: true),
            child: const Text('Group statistics'),
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 250,
            child: Column(
              children: [
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Find participant',
                  ),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _selected.addAll(ids)),
                      child: const Text('Select all'),
                    ),
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final id in ids.where(
                        (id) => id.toLowerCase().contains(
                          _search.text.toLowerCase(),
                        ),
                      ))
                        CheckboxListTile(
                          dense: true,
                          title: Text(id),
                          subtitle: Text(_groups[id] ?? 'Unlabelled'),
                          value: _selected.contains(id),
                          onChanged: (v) => setState(() {
                            if (v == true)
                              _selected.add(id);
                            else
                              _selected.remove(id);
                          }),
                        ),
                    ],
                  ),
                ),
                ExpansionTile(
                  title: const Text('CSV parameters'),
                  children: [
                    for (final e in _names.entries)
                      CheckboxListTile(
                        dense: true,
                        title: Text(e.value),
                        value: _metrics.contains(e.key),
                        onChanged: (v) => setState(() {
                          if (v == true)
                            _metrics.add(e.key);
                          else
                            _metrics.remove(e.key);
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_files.length != widget.files.length)
                    Text(
                      '${widget.files.length - _files.length} incompatible recording(s) excluded: time grid, baseline, ROI or A/B definitions differ.',
                      style: const TextStyle(color: Colors.orange),
                    ),
                  Wrap(
                    spacing: 14,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<String>(
                        value: groupOptions.contains(_group)
                            ? _group
                            : 'All groups',
                        items: [
                          for (final g in groupOptions)
                            DropdownMenuItem(value: g, child: Text(g)),
                        ],
                        onChanged: (v) => setState(() => _group = v!),
                      ),
                      DropdownButton<String>(
                        value:
                            (people.any((p) => p['subject'] == _view) ||
                                recording != null)
                            ? _view
                            : 'Grand average',
                        items: [
                          const DropdownMenuItem(
                            value: 'Grand average',
                            child: Text('Grand average'),
                          ),
                          for (final p in people)
                            DropdownMenuItem(
                              value: '${p['subject']}',
                              child: Text('Participant ${p['subject']}'),
                            ),
                          for (final f in chosen)
                            DropdownMenuItem(
                              value: 'recording:${f['path']}',
                              child: Text(
                                'File: ${f['subject']} · ${f['path'].toString().split('/').last}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _view = v!),
                      ),
                      DropdownButton<double>(
                        value: _smooth,
                        items: [
                          for (final ms in [0.0, 8.0, 16.0, 24.0, 40.0])
                            DropdownMenuItem(
                              value: ms,
                              child: Text(
                                ms == 0
                                    ? 'Smoothing off'
                                    : 'Smooth ${ms.round()} ms (display)',
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _smooth = v!),
                      ),
                      FilterChip(
                        label: const Text('Negative up'),
                        selected: _negativeUp,
                        onSelected: (v) => setState(() => _negativeUp = v),
                      ),
                      FilterChip(
                        label: const Text('Participant differences'),
                        selected: _overlay,
                        onSelected: (v) => setState(() => _overlay = v),
                      ),
                    ],
                  ),
                  ErpAxisControls(
                    onChanged: (v) => setState(() => _axisLimits = v),
                  ),
                  Text(
                    '${people.length} participants · ${chosen.length} recordings · equal participant weighting · ${shown.length < 2 ? 'SEM unavailable for a single participant' : 'shadows = ±1 SEM across participants'}. Smoothing affects display only.',
                  ),
                  Text(
                    'A: ${profile['a_name']}   B: ${profile['b_name']}   Difference: ${profile['b_name']} − ${profile['a_name']}',
                  ),
                  if (people.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Select participants to view their waveforms.',
                      ),
                    )
                  else
                    SizedBox(
                      height: 350,
                      child: CustomPaint(
                        painter: ErpWorkbenchWavePainter({
                          ...data,
                          ..._axisLimits,
                        }, negativeUp: _negativeUp),
                      ),
                    ),
                  ErpChannelGrid(
                    files: selectedFiles,
                    profile: profile,
                    negativeUp: _negativeUp,
                    smoothingMs: _smooth,
                    axisLimits: _axisLimits,
                  ),
                  Row(
                    children: [
                      const Text('Measurement window (ms)  '),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: _lo,
                          onChanged: (_) => _textWindow(),
                          decoration: const InputDecoration(labelText: 'Start'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: _hi,
                          onChanged: (_) => _textWindow(),
                          decoration: const InputDecoration(labelText: 'End'),
                        ),
                      ),
                    ],
                  ),
                  RangeSlider(
                    values: _window,
                    min: times.first,
                    max: times.last,
                    labels: RangeLabels(
                      '${(_window.start * 1000).round()} ms',
                      '${(_window.end * 1000).round()} ms',
                    ),
                    onChanged: (v) {
                      if (v.end - v.start >= times[1] - times[0]) _setWindow(v);
                    },
                  ),
                  const Text(
                    'Window changes update descriptive measurements and scalp maps immediately. Existing inferential p-values are not recalculated; export the reviewed window to group statistics.',
                  ),
                  if (mapAvailable)
                    SizedBox(
                      height: 300,
                      child: CustomPaint(
                        painter: ErpWorkbenchTopoPainter(data),
                      ),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'Full-resolution scalp data unavailable in this older result. Rerun averaging to enable maps for arbitrary windows.',
                      ),
                    ),
                  if (people.isNotEmpty)
                    Wrap(
                      spacing: 18,
                      children: [
                        for (final key in ['a', 'b', 'difference'])
                          Text(
                            '$key: mean ${reviewMeasures(times, reviewAverage([for (final p in shown) erpNumbers(p[key])]), _window.start, _window.end, (profile['polarity'] as num?)?.toDouble() ?? -1)['mean']?.toStringAsFixed(3) ?? "unavailable"} µV',
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
