import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'workbench_figures.dart';
import 'review_math.dart';
import '../topostats/topo_interp.dart';
import '../topostats/topo_paint.dart';
import '../group_statistics.dart';

/// Preset component definitions matching cognitive ERP literature (e.g. Cahn & Polich 2009).
class ErpComponentDef {
  ErpComponentDef({
    required this.name,
    required this.startMs,
    required this.endMs,
    this.polarity = 1.0,
    this.calloutElectrode = 'Cz',
  });

  String name;
  double startMs;
  double endMs;
  double polarity; // 1.0 for positive (P2, P3a, P300), -1.0 for negative (N1, N2pc, N400)
  String calloutElectrode;
}

/// Interactive publication plotting studio providing journal-ready figures
/// matching Cahn & Polich (2009) style (Fig 1 Waveform Grid, Fig 2 Topo Grid, Fig 3/5 Interaction Plots).
class ErpPublicationPlotsView extends StatefulWidget {
  const ErpPublicationPlotsView({
    super.key,
    required this.files,
    required this.groupData,
    required this.profile,
    required this.participantGroups,
    required this.onGroupsChanged,
    this.outputDir,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, dynamic> groupData;
  final Map<String, dynamic> profile;
  final Map<String, String> participantGroups;
  final ValueChanged<Map<String, String>> onGroupsChanged;
  final String? outputDir;

  @override
  State<ErpPublicationPlotsView> createState() => _ErpPublicationPlotsViewState();
}

class _ErpPublicationPlotsViewState extends State<ErpPublicationPlotsView> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();

  int _figureMode = 0; // 0: Fig 1 Waveform Grid, 1: Fig 2 Topo Grid, 2: Fig 3/5 Interaction Plot
  List<String> _selectedElectrodes = ['Fz', 'Cz', 'Pz'];
  String _interactionMetric = 'mean'; // 'mean', 'peak_amp', 'peak_lat'
  int _selectedComponentIndex = 0; // For Fig 3/5 interaction plot
  bool _negativeUp = true;
  bool _academicMonochrome = true; // Cahn & Polich 2009 black & white line/dot styling
  bool _showSemBands = false;
  bool _showPeakCallouts = true;

  final List<ErpComponentDef> _components = [
    ErpComponentDef(name: 'N1', startMs: 80, endMs: 140, polarity: -1.0, calloutElectrode: 'Cz'),
    ErpComponentDef(name: 'P2', startMs: 160, endMs: 240, polarity: 1.0, calloutElectrode: 'Cz'),
    ErpComponentDef(name: 'P3a', startMs: 250, endMs: 380, polarity: 1.0, calloutElectrode: 'Cz'),
  ];

  List<String> get _conditions {
    final names = (widget.groupData['condition_names'] as List?)?.cast<String>() ?? [];
    if (names.isNotEmpty) return names;
    final f = widget.files.isNotEmpty ? widget.files.first : null;
    if (f != null && f['condition_names'] is List) {
      return (f['condition_names'] as List).cast<String>();
    }
    return ['Standard', 'Oddball', 'Distracter'];
  }

  List<String> get _groups {
    final gSet = widget.participantGroups.values.where((g) => g.isNotEmpty).toSet().toList();
    if (gSet.isEmpty) return ['CONTROL', 'MEDITATION'];
    gSet.sort();
    return gSet;
  }

  List<String> get _availableChannels {
    if (widget.files.isEmpty) return ['Fz', 'Cz', 'Pz'];
    final labels = (widget.files.first['labels'] as List? ?? []).cast<String>();
    return labels;
  }

  @override
  void initState() {
    super.initState();
    final chans = _availableChannels;
    _selectedElectrodes = ['Fz', 'Cz', 'Pz'].where(chans.contains).toList();
    if (_selectedElectrodes.isEmpty && chans.isNotEmpty) {
      _selectedElectrodes = chans.take(3).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildControlHeader(),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildConfigSidebar(),
              const VerticalDivider(width: 1),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: RepaintBoundary(
                      key: _repaintBoundaryKey,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _buildCurrentFigure(),
                      ),
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

  Widget _buildControlHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey.shade50,
      child: Row(
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('Fig 1: Waveforms Grid'),
                icon: Icon(Icons.show_chart),
              ),
              ButtonSegment(
                value: 1,
                label: Text('Fig 2: Voltage Topomaps'),
                icon: Icon(Icons.map),
              ),
              ButtonSegment(
                value: 2,
                label: Text('Fig 3/5: Interaction Plots'),
                icon: Icon(Icons.stacked_line_chart),
              ),
            ],
            selected: {_figureMode},
            onSelectionChanged: (s) => setState(() => _figureMode = s.first),
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: _openGroupLabelDialog,
            icon: const Icon(Icons.label, size: 18),
            label: Text('Label Groups (${widget.participantGroups.length}/${widget.files.length})'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _exportSvg,
            icon: const Icon(Icons.code, size: 18),
            label: const Text('Export Vector SVG'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _exportPng,
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Export 300 DPI PNG'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _launchAdvancedStats,
            icon: const Icon(Icons.auto_graph, size: 18),
            label: const Text('LMM / GLM Stats & eTFCE'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF047857),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigSidebar() {
    return SizedBox(
      width: 280,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'FIGURE SETTINGS',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            title: const Text('Academic B&W (Cahn & Polich 2009)'),
            subtitle: const Text('Solid + open circle vs Dotted + filled circle'),
            value: _academicMonochrome,
            onChanged: (v) => setState(() => _academicMonochrome = v),
          ),
          if (_figureMode == 0) ...[
            SwitchListTile(
              dense: true,
              title: const Text('Negative Up'),
              value: _negativeUp,
              onChanged: (v) => setState(() => _negativeUp = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Shaded SEM bands'),
              value: _showSemBands,
              onChanged: (v) => setState(() => _showSemBands = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Peak callout labels (N1, P2, P3a)'),
              value: _showPeakCallouts,
              onChanged: (v) => setState(() => _showPeakCallouts = v),
            ),
          ],
          if (_figureMode == 2) ...[
            const SizedBox(height: 8),
            const Text('Interaction Measure:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            DropdownButton<String>(
              isExpanded: true,
              value: _interactionMetric,
              items: const [
                DropdownMenuItem(value: 'mean', child: Text('Mean Amplitude (µV)')),
                DropdownMenuItem(value: 'peak_amp', child: Text('Peak Amplitude (µV)')),
                DropdownMenuItem(value: 'peak_lat', child: Text('Peak Latency (ms)')),
              ],
              onChanged: (v) => setState(() => _interactionMetric = v!),
            ),
            const SizedBox(height: 8),
            const Text('Component:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            DropdownButton<int>(
              isExpanded: true,
              value: _selectedComponentIndex,
              items: [
                for (var i = 0; i < _components.length; i++)
                  DropdownMenuItem(value: i, child: Text('${_components[i].name} (${_components[i].startMs.round()}–${_components[i].endMs.round()} ms)')),
              ],
              onChanged: (v) => setState(() => _selectedComponentIndex = v!),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'ELECTRODES (ROWS)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final ch in _availableChannels)
                FilterChip(
                  label: Text(ch),
                  selected: _selectedElectrodes.contains(ch),
                  onSelected: (sel) {
                    setState(() {
                      if (sel) {
                        _selectedElectrodes.add(ch);
                      } else if (_selectedElectrodes.length > 1) {
                        _selectedElectrodes.remove(ch);
                      }
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'COMPONENT WINDOWS',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueGrey),
          ),
          for (final comp in _components)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 45,
                    child: Text(comp.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Expanded(
                    child: Text(
                      '${comp.startMs.round()}–${comp.endMs.round()} ms (${comp.polarity > 0 ? "+" : "−"})',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _openComponentEditor,
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Edit Component Windows'),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentFigure() {
    switch (_figureMode) {
      case 0:
        return SizedBox(
          width: 820,
          height: 180.0 * _selectedElectrodes.length + 80.0,
          child: CustomPaint(
            painter: PublicationWaveformGridPainter(
              files: widget.files,
              groups: _groups,
              participantGroups: widget.participantGroups,
              conditions: _conditions,
              electrodes: _selectedElectrodes,
              components: _components,
              negativeUp: _negativeUp,
              monochrome: _academicMonochrome,
              showSem: _showSemBands,
              showCallouts: _showPeakCallouts,
            ),
          ),
        );
      case 1:
        return SizedBox(
          width: 820,
          height: 150.0 * _components.length + 90.0,
          child: CustomPaint(
            painter: PublicationTopomapGridPainter(
              files: widget.files,
              groups: _groups,
              participantGroups: widget.participantGroups,
              conditions: _conditions,
              components: _components,
            ),
          ),
        );
      case 2:
      default:
        final comp = _components[_selectedComponentIndex.clamp(0, _components.length - 1)];
        return SizedBox(
          width: 820,
          height: 380,
          child: CustomPaint(
            painter: PublicationInteractionPlotPainter(
              files: widget.files,
              groups: _groups,
              participantGroups: widget.participantGroups,
              conditions: _conditions,
              electrodes: _selectedElectrodes,
              component: comp,
              metric: _interactionMetric,
              monochrome: _academicMonochrome,
            ),
          ),
        );
    }
  }

  void _openGroupLabelDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ErpGroupLabelDialog(
        files: widget.files,
        initialGroups: widget.participantGroups,
        onSaved: (newGroups) {
          widget.onGroupsChanged(newGroups);
          setState(() {});
          if (widget.outputDir != null) {
            _saveGroupsCsv(newGroups);
          }
        },
      ),
    );
  }

  Future<void> _saveGroupsCsv(Map<String, String> groups) async {
    try {
      final file = File('${widget.outputDir}/participant_groups.csv');
      final buf = StringBuffer('subject,group\n');
      for (final e in groups.entries) {
        buf.writeln('"${e.key}","${e.value}"');
      }
      await file.writeAsString(buf.toString());
    } catch (_) {}
  }

  void _openComponentEditor() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit ERP Component Windows'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final comp in _components)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(width: 50, child: Text(comp.name, style: const TextStyle(fontWeight: FontWeight.bold))),
                      Expanded(
                        child: Text('${comp.startMs.round()} to ${comp.endMs.round()} ms'),
                      ),
                      DropdownButton<double>(
                        value: comp.polarity,
                        items: const [
                          DropdownMenuItem(value: 1.0, child: Text('Positive (+)')),
                          DropdownMenuItem(value: -1.0, child: Text('Negative (−)')),
                        ],
                        onChanged: (v) => setState(() => comp.polarity = v!),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _exportSvg() async {
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Publication Figure as SVG',
      fileName: 'erp_figure_${_figureMode == 0 ? "1_waveforms" : _figureMode == 1 ? "2_topomaps" : "3_interaction"}.svg',
      type: FileType.custom,
      allowedExtensions: ['svg'],
    );
    if (savePath == null) return;

    String svgContent;
    if (_figureMode == 0) {
      svgContent = generateWaveformGridSvg(
        files: widget.files,
        groups: _groups,
        participantGroups: widget.participantGroups,
        conditions: _conditions,
        electrodes: _selectedElectrodes,
        components: _components,
        negativeUp: _negativeUp,
        monochrome: _academicMonochrome,
        showSem: _showSemBands,
        showCallouts: _showPeakCallouts,
      );
    } else if (_figureMode == 2) {
      final comp = _components[_selectedComponentIndex.clamp(0, _components.length - 1)];
      svgContent = generateInteractionPlotSvg(
        files: widget.files,
        groups: _groups,
        participantGroups: widget.participantGroups,
        conditions: _conditions,
        electrodes: _selectedElectrodes,
        component: comp,
        metric: _interactionMetric,
        monochrome: _academicMonochrome,
      );
    } else {
      svgContent = '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600"><text x="40" y="50" font-family="Arial" font-size="16">Topographic map grid export is available in high-resolution PNG.</text></svg>';
    }

    await File(savePath).writeAsString(svgContent);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved vector SVG to $savePath')),
      );
    }
  }

  Future<void> _exportPng() async {
    try {
      final boundary = _repaintBoundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0); // 300 DPI equivalent
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Save High-Res 300 DPI PNG',
        fileName: 'erp_figure_${_figureMode == 0 ? "1_waveforms" : _figureMode == 1 ? "2_topomaps" : "3_interaction"}.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (savePath == null) return;

      await File(savePath).writeAsBytes(byteData.buffer.asUint8List());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved 300 DPI PNG to $savePath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export PNG: $e')),
        );
      }
    }
  }

  Future<void> _launchAdvancedStats() async {
    final comp = _components[_selectedComponentIndex.clamp(0, _components.length - 1)];
    final outDir = widget.outputDir ?? Directory.systemTemp.path;
    final csvPath = '$outDir/ERP_${comp.name}_lmm_input.csv';

    final buf = StringBuffer();
    buf.writeln('subjid,group,condition,electrode,mean_amplitude_ERP,peak_amplitude_ERP,peak_latency_ms_ERP');

    final times = erpNumbers(widget.files.first['times']);
    for (final f in widget.files) {
      final subjid = f['subject'] as String? ?? 'unknown';
      final group = widget.participantGroups[subjid] ?? 'Unknown';
      final labels = (f['labels'] as List? ?? []).cast<String>();
      final chans = f['channel_conditions'] as Map?;

      for (final cond in _conditions) {
        for (final el in _selectedElectrodes) {
          final cIdx = labels.indexOf(el);
          if (cIdx < 0) continue;
          List<double>? wave;
          if (chans != null && chans.containsKey(cond)) {
            final rows = chans[cond] as List?;
            if (rows != null && cIdx < rows.length) wave = erpNumbers(rows[cIdx]);
          } else if (f['channel_a'] != null) {
            final rows = f['channel_a'] as List?;
            if (rows != null && cIdx < rows.length) wave = erpNumbers(rows[cIdx]);
          }
          if (wave != null && wave.length == times.length) {
            final m = reviewMeasures(times, wave, comp.startMs / 1000, comp.endMs / 1000, comp.polarity);
            buf.writeln('"$subjid","$group","$cond","$el",${m['mean']?.toStringAsFixed(4) ?? 0},${m['peak_amplitude']?.toStringAsFixed(4) ?? 0},${((m['peak_latency'] ?? 0) * 1000).toStringAsFixed(1)}');
          }
        }
      }
    }

    await File(csvPath).writeAsString(buf.toString());
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text('${comp.name} · LMM, Repeated-Measures ANOVA & eTFCE Stats')),
          body: GroupStatisticsWorkbench(initialCsvPath: csvPath),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DIALOG: PARTICIPANT GROUP LABELING
// ─────────────────────────────────────────────────────────────────────────────

class ErpGroupLabelDialog extends StatefulWidget {
  const ErpGroupLabelDialog({
    super.key,
    required this.files,
    required this.initialGroups,
    required this.onSaved,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, String> initialGroups;
  final ValueChanged<Map<String, String>> onSaved;

  @override
  State<ErpGroupLabelDialog> createState() => _ErpGroupLabelDialogState();
}

class _ErpGroupLabelDialogState extends State<ErpGroupLabelDialog> {
  late Map<String, String> _groups;
  final TextEditingController _group1Ctrl = TextEditingController(text: 'CONTROL');
  final TextEditingController _group2Ctrl = TextEditingController(text: 'MEDITATION');
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _groups = Map<String, String>.from(widget.initialGroups);
    final subjects = widget.files.map((f) => f['subject'].toString()).toSet().toList();
    for (final s in subjects) {
      if (!_groups.containsKey(s) || _groups[s]!.isEmpty) {
        // Auto-guess based on subject ID prefix
        final lower = s.toLowerCase();
        if (lower.contains('med') || lower.contains('vip') || lower.contains('exp')) {
          _groups[s] = 'MEDITATION';
        } else if (lower.contains('con') || lower.contains('ctl') || lower.contains('ctrl')) {
          _groups[s] = 'CONTROL';
        } else {
          _groups[s] = 'CONTROL';
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final subjects = widget.files.map((f) => f['subject'].toString()).toSet().toList()..sort();
    final filter = _searchCtrl.text.trim().toLowerCase();
    final visible = filter.isEmpty ? subjects : subjects.where((s) => s.toLowerCase().contains(filter)).toList();

    final g1 = _group1Ctrl.text.trim();
    final g2 = _group2Ctrl.text.trim();

    return AlertDialog(
      title: const Text('Assign Participant Groups'),
      content: SizedBox(
        width: 550,
        height: 500,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _group1Ctrl,
                    decoration: const InputDecoration(labelText: 'Group 1 Name', isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _group2Ctrl,
                    decoration: const InputDecoration(labelText: 'Group 2 Name', isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Search subjects…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final half = (subjects.length / 2).ceil();
                    setState(() {
                      for (var i = 0; i < subjects.length; i++) {
                        _groups[subjects[i]] = i < half ? g1 : g2;
                      }
                    });
                  },
                  child: const Text('Split 50/50'),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      for (final s in subjects) {
                        final lower = s.toLowerCase();
                        if (lower.contains('med') || lower.contains('vip')) {
                          _groups[s] = g2;
                        } else {
                          _groups[s] = g1;
                        }
                      }
                    });
                  },
                  child: const Text('Auto-Prefix'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  final s = visible[i];
                  final cur = _groups[s] ?? g1;
                  return ListTile(
                    dense: true,
                    title: Text(s, style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: g1, label: Text(g1, style: const TextStyle(fontSize: 11))),
                        ButtonSegment(value: g2, label: Text(g2, style: const TextStyle(fontSize: 11))),
                      ],
                      selected: {cur},
                      onSelectionChanged: (val) => setState(() => _groups[s] = val.first),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            widget.onSaved(_groups);
            Navigator.pop(context);
          },
          child: const Text('Apply Groups'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 1: GRAND-AVERAGED WAVEFORM GRID PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class PublicationWaveformGridPainter extends CustomPainter {
  PublicationWaveformGridPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    required this.conditions,
    required this.electrodes,
    required this.components,
    required this.negativeUp,
    required this.monochrome,
    required this.showSem,
    required this.showCallouts,
  });

  final List<Map<String, dynamic>> files;
  final List<String> groups;
  final Map<String, String> participantGroups;
  final List<String> conditions;
  final List<String> electrodes;
  final List<ErpComponentDef> components;
  final bool negativeUp, monochrome, showSem, showCallouts;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty || conditions.isEmpty || electrodes.isEmpty) return;

    final times = erpNumbers(files.first['times']);
    if (times.length < 2) return;

    final nCols = conditions.length;
    final nRows = electrodes.length;

    const leftMargin = 60.0;
    const topMargin = 50.0;
    const rightMargin = 20.0;
    const bottomMargin = 40.0;

    final cellWidth = (size.width - leftMargin - rightMargin) / nCols;
    final cellHeight = (size.height - topMargin - bottomMargin) / nRows;

    // Draw Column Headers (Conditions: STANDARD, ODDBALL, DISTRACTER)
    for (var c = 0; c < nCols; c++) {
      final headerRect = Rect.fromLTWH(leftMargin + c * cellWidth, 12, cellWidth, 24);
      erpText(
        canvas,
        conditions[c].toUpperCase(),
        Offset(headerRect.center.dx - (conditions[c].length * 4.5), 16),
        size: 13,
        color: Colors.black,
      );
    }

    // Legend on the top-left cell
    _drawLegend(canvas, Offset(leftMargin + 60, topMargin - 28));

    // Global Y-limits (-6 to +6 uV)
    final yMin = negativeUp ? 6.0 : -6.0;
    final yMax = negativeUp ? -6.0 : 6.0;
    final tMin = times.first;
    final tMax = times.last;

    for (var r = 0; r < nRows; r++) {
      final el = electrodes[r];
      for (var c = 0; c < nCols; c++) {
        final cond = conditions[c];
        final cellAx = Rect.fromLTWH(
          leftMargin + c * cellWidth + 24,
          topMargin + r * cellHeight + 16,
          cellWidth - 36,
          cellHeight - 32,
        );

        _drawCellAxes(canvas, cellAx, tMin, tMax, yMin, yMax, el, c == 0, r == nRows - 1);

        // Compute group grand averages for this cell
        for (var gIdx = 0; gIdx < groups.length; gIdx++) {
          final groupName = groups[gIdx];
          final groupFiles = files.where((f) {
            final s = f['subject'].toString();
            final g = participantGroups[s] ?? (groups.isNotEmpty ? groups.first : '');
            return g.toUpperCase() == groupName.toUpperCase();
          }).toList();

          final waves = _extractWaves(groupFiles, el, cond, times);
          if (waves.isEmpty) continue;

          final meanWave = reviewAverage(waves);
          final semWave = reviewSem(waves);

          _drawWave(
            canvas,
            cellAx,
            times,
            meanWave,
            semWave,
            tMin,
            tMax,
            yMin,
            yMax,
            gIdx,
          );
        }

        // Peak callouts (N1, P2, P3a) in target condition (Oddball or Distracter)
        if (showCallouts && r == 1 && (cond.toLowerCase().contains('odd') || cond.toLowerCase().contains('dist'))) {
          _drawPeakCallouts(canvas, cellAx, tMin, tMax, yMin, yMax);
        }
      }
    }

    // Figure Caption at bottom
    erpText(
      canvas,
      'Fig. 1. Grand averaged event-related potentials for each experimental condition and midline electrode (N=${files.length}).',
      Offset(size.width / 2 - 250, size.height - 20),
      size: 11,
      color: Colors.black87,
    );
  }

  void _drawLegend(Canvas canvas, Offset at) {
    for (var i = 0; i < groups.length && i < 2; i++) {
      final g = groups[i];
      final lineY = at.dy + i * 16.0;

      final paint = Paint()
        ..color = Colors.black
        ..strokeWidth = (i == 0 ? 1.0 : 1.5)
        ..style = PaintingStyle.stroke;

      if (i == 1 && monochrome) {
        // Dotted
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.0, Paint()..color = Colors.black);
      } else {
        // Open circle
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.0, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.0, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.0);
      }

      canvas.drawLine(Offset(at.dx - 30, lineY), Offset(at.dx - 6, lineY), paint);
      erpText(canvas, g.toUpperCase(), Offset(at.dx + 2, lineY - 6), size: 10, color: Colors.black);
    }
  }

  void _drawCellAxes(
    Canvas canvas,
    Rect ax,
    double tMin,
    double tMax,
    double yMin,
    double yMax,
    String electrode,
    bool showYAxis,
    bool showXAxis,
  ) {
    double x(double t) => ax.left + (t - tMin) / (tMax - tMin) * ax.width;
    double y(double v) => ax.top + (v - yMin) / (yMax - yMin) * ax.height;

    // 0 uV baseline line
    final zeroY = y(0);
    canvas.drawLine(Offset(ax.left, zeroY), Offset(ax.right, zeroY), Paint()..color = const Color(0xFF475569)..strokeWidth = 1.0);

    // 0 ms event vertical tick / dashed line
    if (tMin <= 0 && tMax >= 0) {
      final zeroX = x(0);
      canvas.drawLine(Offset(zeroX, ax.top), Offset(zeroX, ax.bottom), Paint()..color = const Color(0xFFCBD5E1)..strokeWidth = 0.8);
    }

    // Electrode label in top-left of each row's first column (or all columns)
    erpText(canvas, electrode, Offset(ax.left - 2, ax.top - 12), size: 11, color: Colors.black);

    // Y axis tick marks & labels
    if (showYAxis) {
      canvas.drawLine(Offset(ax.left, ax.top), Offset(ax.left, ax.bottom), Paint()..color = Colors.black..strokeWidth = 1.0);
      for (final v in [-5.0, 0.0, 5.0]) {
        final tickY = y(v);
        canvas.drawLine(Offset(ax.left - 3, tickY), Offset(ax.left, tickY), Paint()..color = Colors.black);
        erpText(canvas, '${v.round()}', Offset(ax.left - 18, tickY - 5), size: 9, color: Colors.black);
      }
      erpText(canvas, 'AMPLITUDE (µV)', Offset(ax.left - 32, ax.center.dy - 35), size: 9, color: Colors.black);
    }

    // X axis ticks & labels (200, 400, 600 ms)
    for (final t in [0.2, 0.4, 0.6]) {
      if (t >= tMin && t <= tMax) {
        final tickX = x(t);
        canvas.drawLine(Offset(tickX, zeroY - 2), Offset(tickX, zeroY + 2), Paint()..color = Colors.black);
        erpText(canvas, '${(t * 1000).round()}', Offset(tickX - 8, zeroY + 4), size: 9, color: Colors.black87);
      }
    }
    if (showXAxis) {
      erpText(canvas, 'TIME (ms)', Offset(ax.center.dx - 22, ax.bottom + 6), size: 9, color: Colors.black);
    }
  }

  void _drawWave(
    Canvas canvas,
    Rect ax,
    List<double> times,
    List<double> wave,
    List<double> sem,
    double tMin,
    double tMax,
    double yMin,
    double yMax,
    int groupIndex,
  ) {
    double x(double t) => ax.left + (t - tMin) / (tMax - tMin) * ax.width;
    double y(double v) => ax.top + (v - yMin) / (yMax - yMin) * ax.height;

    // Optional SEM band
    if (showSem && sem.length == times.length) {
      final semPath = Path();
      semPath.moveTo(x(times.first), y(wave.first - sem.first));
      for (var i = 1; i < times.length; i++) {
        semPath.lineTo(x(times[i]), y(wave[i] - sem[i]));
      }
      for (var i = times.length - 1; i >= 0; i--) {
        semPath.lineTo(x(times[i]), y(wave[i] + sem[i]));
      }
      semPath.close();
      canvas.drawPath(semPath, Paint()..color = (groupIndex == 0 ? Colors.blue.withOpacity(0.12) : Colors.red.withOpacity(0.12)));
    }

    // Waveform line
    final path = Path();
    var started = false;
    for (var i = 0; i < times.length; i++) {
      final v = wave[i];
      if (!v.isFinite) continue;
      if (!started) {
        path.moveTo(x(times[i]), y(v));
        started = true;
      } else {
        path.lineTo(x(times[i]), y(v));
      }
    }

    final paint = Paint()
      ..color = monochrome ? Colors.black : (groupIndex == 0 ? const Color(0xFF2563EB) : const Color(0xFFDC2626))
      ..strokeWidth = (groupIndex == 0 ? 1.0 : 1.5)
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, paint);
  }

  void _drawPeakCallouts(Canvas canvas, Rect ax, double tMin, double tMax, double yMin, double yMax) {
    double x(double t) => ax.left + (t - tMin) / (tMax - tMin) * ax.width;
    double y(double v) => ax.top + (v - yMin) / (yMax - yMin) * ax.height;

    // N1 arrow (~100 ms, negative peak)
    final n1X = x(0.11);
    final n1Y = y(-3.8);
    canvas.drawLine(Offset(n1X - 10, n1Y + 14), Offset(n1X, n1Y + 2), Paint()..color = Colors.black..strokeWidth = 1.0);
    erpText(canvas, 'N1', Offset(n1X + 4, n1Y + 12), size: 10, color: Colors.black);

    // P2 arrow (~200 ms, positive peak)
    final p2X = x(0.20);
    final p2Y = y(3.8);
    canvas.drawLine(Offset(p2X + 10, p2Y - 12), Offset(p2X, p2Y - 2), Paint()..color = Colors.black..strokeWidth = 1.0);
    erpText(canvas, 'P2', Offset(p2X + 12, p2Y - 16), size: 10, color: Colors.black);

    // P3a arrow (~280 ms, positive peak)
    final p3X = x(0.28);
    final p3Y = y(4.5);
    canvas.drawLine(Offset(p3X + 12, p3Y - 10), Offset(p3X, p3Y - 2), Paint()..color = Colors.black..strokeWidth = 1.0);
    erpText(canvas, 'P3a', Offset(p3X + 14, p3Y - 16), size: 10, color: Colors.black);
  }

  List<List<double>> _extractWaves(List<Map<String, dynamic>> gFiles, String electrode, String cond, List<double> times) {
    final waves = <List<double>>[];
    for (final f in gFiles) {
      final labels = (f['labels'] as List? ?? []).cast<String>();
      final cIdx = labels.indexOf(electrode);
      if (cIdx < 0) continue;
      final chans = f['channel_conditions'] as Map?;
      if (chans != null && chans.containsKey(cond)) {
        final rows = chans[cond] as List?;
        if (rows != null && cIdx < rows.length) {
          final w = erpNumbers(rows[cIdx]);
          if (w.length == times.length) waves.add(w);
        }
      } else if (f['channel_a'] != null) {
        final rows = f['channel_a'] as List?;
        if (rows != null && cIdx < rows.length) {
          final w = erpNumbers(rows[cIdx]);
          if (w.length == times.length) waves.add(w);
        }
      }
    }
    return waves;
  }

  @override
  bool shouldRepaint(covariant PublicationWaveformGridPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 2: TOPOGRAPHIC VOLTAGE MAPS GRID PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class PublicationTopomapGridPainter extends CustomPainter {
  PublicationTopomapGridPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    required this.conditions,
    required this.components,
  });

  final List<Map<String, dynamic>> files;
  final List<String> groups;
  final Map<String, String> participantGroups;
  final List<String> conditions;
  final List<ErpComponentDef> components;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty) return;

    final labels = (files.first['labels'] as List? ?? []).cast<String>();
    final times = erpNumbers(files.first['times']);

    // Check suitability
    final topoChans = labels.where(isStandard1020Channel).toList();
    if (topoChans.length < 4) {
      erpText(canvas, 'Need at least 4 standard 10-20 channels for scalp topoplots.', const Offset(40, 40));
      return;
    }
    final interp = TopoInterpolator.forChannels(topoChans, res: 48);

    const leftMargin = 50.0;
    const topMargin = 40.0;
    final totalW = size.width - leftMargin - 40;
    final groupW = totalW / 2;

    // Headers for Groups (Control vs Meditation)
    for (var g = 0; g < 2 && g < groups.length; g++) {
      final grpX = leftMargin + g * groupW + groupW / 2 - 30;
      erpText(canvas, groups[g], Offset(grpX, 10), size: 14, color: Colors.black);

      // Sub-headers for conditions
      final condW = (groupW - 40) / conditions.length;
      for (var c = 0; c < conditions.length; c++) {
        final cX = leftMargin + g * groupW + c * condW + condW / 2 - 20;
        erpText(canvas, conditions[c], Offset(cX, 28), size: 11, color: Colors.black87);
      }
    }

    // Rows for Components (N1, P2, P3a)
    final rowH = (size.height - topMargin - 40) / components.length;

    for (var r = 0; r < components.length; r++) {
      final comp = components[r];
      final rowY = topMargin + r * rowH;

      // Component label
      erpText(canvas, comp.name, Offset(16, rowY + rowH / 2 - 8), size: 13, color: Colors.black);

      final vmin = comp.polarity < 0 ? -3.0 : 0.0;
      final vmax = comp.polarity < 0 ? 0.0 : (comp.name == 'P2' ? 8.0 : 5.0);

      // Render topomaps across groups & conditions
      for (var g = 0; g < 2 && g < groups.length; g++) {
        final gFiles = files.where((f) {
          final s = f['subject'].toString();
          final grp = participantGroups[s] ?? groups.first;
          return grp.toUpperCase() == groups[g].toUpperCase();
        }).toList();

        final condW = (groupW - 40) / conditions.length;
        for (var c = 0; c < conditions.length; c++) {
          final cond = conditions[c];
          final mapBox = Rect.fromLTWH(
            leftMargin + g * groupW + c * condW + 6,
            rowY + 6,
            condW - 12,
            rowH - 12,
          );

          // Mean amplitude across subjects in this group/condition for each channel
          final chanVals = <double>[];
          for (final ch in topoChans) {
            final cIdx = labels.indexOf(ch);
            final subjVals = <double>[];
            for (final f in gFiles) {
              final chans = f['channel_conditions'] as Map?;
              if (chans != null && chans.containsKey(cond)) {
                final rows = chans[cond] as List?;
                if (rows != null && cIdx < rows.length) {
                  final w = erpNumbers(rows[cIdx]);
                  if (w.length == times.length) {
                    final m = reviewMeasures(times, w, comp.startMs / 1000, comp.endMs / 1000, comp.polarity);
                    subjVals.add(m['mean'] ?? 0.0);
                  }
                }
              }
            }
            chanVals.add(subjVals.isEmpty ? 0.0 : subjVals.reduce((a, b) => a + b) / subjVals.length);
          }

          paintTopomap(
            canvas,
            mapBox,
            interp,
            chanVals,
            vmin: vmin,
            vmax: vmax,
            cmap: 'spectral',
            fittedHead: true,
          );
        }
      }

      // Center colorbar between groups
      final cbarX = leftMargin + groupW - 16;
      final cbarY = rowY + 12;
      final cbarH = rowH - 24;
      _drawColorbar(canvas, Rect.fromLTWH(cbarX, cbarY, 10, cbarH), vmin, vmax);
    }

    erpText(
      canvas,
      'Fig. 2. Topographic voltage maps for each experimental condition, stimulus type, and major component.',
      Offset(size.width / 2 - 270, size.height - 18),
      size: 11,
      color: Colors.black87,
    );
  }

  void _drawColorbar(Canvas canvas, Rect box, double vmin, double vmax) {
    // 2-point vertical gradient
    final gradient = ui.Gradient.linear(
      Offset(box.left, box.top),
      Offset(box.left, box.bottom),
      [Colors.red, Colors.yellow, Colors.cyan, Colors.blue],
    );
    canvas.drawRect(box, Paint()..shader = gradient);
    canvas.drawRect(box, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 0.5);

    erpText(canvas, '${vmax.round()} µV', Offset(box.right + 2, box.top - 4), size: 8, color: Colors.black);
    erpText(canvas, '${vmin.round()} µV', Offset(box.right + 2, box.bottom - 6), size: 8, color: Colors.black);
  }

  @override
  bool shouldRepaint(covariant PublicationTopomapGridPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 3 & 5: COMPONENT INTERACTION LINE PLOT PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class PublicationInteractionPlotPainter extends CustomPainter {
  PublicationInteractionPlotPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    required this.conditions,
    required this.electrodes,
    required this.component,
    required this.metric,
    required this.monochrome,
  });

  final List<Map<String, dynamic>> files;
  final List<String> groups;
  final Map<String, String> participantGroups;
  final List<String> conditions;
  final List<String> electrodes;
  final ErpComponentDef component;
  final String metric;
  final bool monochrome;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty || conditions.isEmpty || electrodes.isEmpty) return;

    final times = erpNumbers(files.first['times']);
    final nCols = conditions.length;

    const leftMargin = 60.0;
    const topMargin = 50.0;
    const rightMargin = 20.0;
    const bottomMargin = 50.0;

    final panelWidth = (size.width - leftMargin - rightMargin) / nCols;
    final panelHeight = size.height - topMargin - bottomMargin;

    // Y-axis range
    final yMin = metric == 'peak_lat' ? 50.0 : (component.polarity < 0 ? 0.0 : -2.0);
    final yMax = metric == 'peak_lat' ? 400.0 : (component.polarity < 0 ? 6.0 : 8.0);

    // Legend on first panel
    _drawLegend(canvas, const Offset(leftMargin + 60, 24));

    for (var c = 0; c < nCols; c++) {
      final cond = conditions[c];
      final ax = Rect.fromLTWH(
        leftMargin + c * panelWidth + 20,
        topMargin,
        panelWidth - 30,
        panelHeight,
      );

      // Panel Header (Condition name)
      erpText(
        canvas,
        cond.toUpperCase(),
        Offset(ax.center.dx - (cond.length * 4.5), topMargin - 28),
        size: 13,
        color: Colors.black,
      );

      _drawPanelAxes(canvas, ax, yMin, yMax, c == 0);

      // Draw Group Interaction Lines
      for (var gIdx = 0; gIdx < 2 && gIdx < groups.length; gIdx++) {
        final groupName = groups[gIdx];
        final gFiles = files.where((f) {
          final s = f['subject'].toString();
          final g = participantGroups[s] ?? groups.first;
          return g.toUpperCase() == groupName.toUpperCase();
        }).toList();

        final points = <Offset>[];
        final sems = <double>[];

        for (var elIdx = 0; elIdx < electrodes.length; elIdx++) {
          final el = electrodes[elIdx];
          final elVals = <double>[];

          for (final f in gFiles) {
            final labels = (f['labels'] as List? ?? []).cast<String>();
            final cIdx = labels.indexOf(el);
            if (cIdx < 0) continue;
            final chans = f['channel_conditions'] as Map?;
            if (chans != null && chans.containsKey(cond)) {
              final rows = chans[cond] as List?;
              if (rows != null && cIdx < rows.length) {
                final w = erpNumbers(rows[cIdx]);
                if (w.length == times.length) {
                  final m = reviewMeasures(times, w, component.startMs / 1000, component.endMs / 1000, component.polarity);
                  if (metric == 'peak_lat') {
                    elVals.add((m['peak_latency'] ?? 0.0) * 1000);
                  } else if (metric == 'peak_amp') {
                    elVals.add(m['peak_amplitude'] ?? 0.0);
                  } else {
                    elVals.add(m['mean'] ?? 0.0);
                  }
                }
              }
            }
          }

          final meanVal = elVals.isEmpty ? 0.0 : elVals.reduce((a, b) => a + b) / elVals.length;
          final semVal = elVals.length > 1 ? (elVals.map((v) => math.pow(v - meanVal, 2)).reduce((a, b) => a + b) / (elVals.length * (elVals.length - 1))) : 0.0;

          final ptX = ax.left + (elIdx + 0.5) / electrodes.length * ax.width;
          final ptY = ax.bottom - (meanVal - yMin) / (yMax - yMin) * ax.height;

          points.add(Offset(ptX, ptY));
          sems.add(math.sqrt(semVal));
        }

        // Draw connecting line & error bars
        _drawLineAndPoints(canvas, points, sems, ax, yMin, yMax, gIdx);
      }
    }

    // Caption
    final metricLabel = metric == 'peak_lat' ? 'peak latency (ms)' : (metric == 'peak_amp' ? 'peak amplitude (µV)' : 'mean amplitude (µV)');
    erpText(
      canvas,
      'Fig. 5. ${component.name} component $metricLabel for each experimental condition as a function of midline electrode.',
      Offset(size.width / 2 - 280, size.height - 18),
      size: 11,
      color: Colors.black87,
    );
  }

  void _drawLegend(Canvas canvas, Offset at) {
    for (var i = 0; i < groups.length && i < 2; i++) {
      final g = groups[i];
      final lineY = at.dy + i * 16.0;

      final paint = Paint()
        ..color = Colors.black
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      if (i == 1 && monochrome) {
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.5, Paint()..color = Colors.black);
      } else {
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.5, Paint()..color = Colors.white);
        canvas.drawCircle(Offset(at.dx - 18, lineY), 3.5, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.0);
      }

      canvas.drawLine(Offset(at.dx - 30, lineY), Offset(at.dx - 6, lineY), paint);
      erpText(canvas, g.toUpperCase(), Offset(at.dx + 2, lineY - 6), size: 10, color: Colors.black);
    }
  }

  void _drawPanelAxes(Canvas canvas, Rect ax, double yMin, double yMax, bool showYAxis) {
    double y(double v) => ax.bottom - (v - yMin) / (yMax - yMin) * ax.height;

    // X baseline
    canvas.drawLine(Offset(ax.left, ax.bottom), Offset(ax.right, ax.bottom), Paint()..color = Colors.black..strokeWidth = 1.0);

    // X electrode ticks
    for (var i = 0; i < electrodes.length; i++) {
      final tickX = ax.left + (i + 0.5) / electrodes.length * ax.width;
      canvas.drawLine(Offset(tickX, ax.bottom), Offset(tickX, ax.bottom + 4), Paint()..color = Colors.black);
      erpText(canvas, electrodes[i], Offset(tickX - 8, ax.bottom + 6), size: 10, color: Colors.black);
    }
    erpText(canvas, 'Electrode', Offset(ax.center.dx - 22, ax.bottom + 22), size: 10, color: Colors.black);

    // Y ticks
    if (showYAxis) {
      canvas.drawLine(Offset(ax.left, ax.top), Offset(ax.left, ax.bottom), Paint()..color = Colors.black..strokeWidth = 1.0);
      final step = (yMax - yMin) <= 10 ? 2.0 : 50.0;
      for (var v = yMin; v <= yMax; v += step) {
        final tickY = y(v);
        canvas.drawLine(Offset(ax.left - 4, tickY), Offset(ax.left, tickY), Paint()..color = Colors.black);
        erpText(canvas, '${v.round()}', Offset(ax.left - 20, tickY - 5), size: 10, color: Colors.black);
      }
      erpText(
        canvas,
        '${component.name} MEAN AMPLITUDE (µV)',
        Offset(ax.left - 36, ax.center.dy - 60),
        size: 10,
        color: Colors.black,
      );
    }
  }

  void _drawLineAndPoints(
    Canvas canvas,
    List<Offset> points,
    List<double> sems,
    Rect ax,
    double yMin,
    double yMax,
    int groupIndex,
  ) {
    if (points.isEmpty) return;

    final paint = Paint()
      ..color = monochrome ? Colors.black : (groupIndex == 0 ? Colors.blue : Colors.red)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    // Line connecting points
    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], paint);
    }

    // Points & Error Bars
    for (var i = 0; i < points.length; i++) {
      final pt = points[i];
      final semPx = (sems[i] / (yMax - yMin)) * ax.height;

      // Error bar vertical line + caps
      canvas.drawLine(Offset(pt.dx, pt.dy - semPx), Offset(pt.dx, pt.dy + semPx), Paint()..color = Colors.black..strokeWidth = 1.0);
      canvas.drawLine(Offset(pt.dx - 3, pt.dy - semPx), Offset(pt.dx + 3, pt.dy - semPx), Paint()..color = Colors.black..strokeWidth = 1.0);
      canvas.drawLine(Offset(pt.dx - 3, pt.dy + semPx), Offset(pt.dx + 3, pt.dy + semPx), Paint()..color = Colors.black..strokeWidth = 1.0);

      // Marker
      if (groupIndex == 0 || !monochrome) {
        // Open circle
        canvas.drawCircle(pt, 4.0, Paint()..color = Colors.white);
        canvas.drawCircle(pt, 4.0, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.2);
      } else {
        // Filled circle
        canvas.drawCircle(pt, 4.0, Paint()..color = Colors.black);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PublicationInteractionPlotPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// W3C VECTOR SVG GENERATORS
// ─────────────────────────────────────────────────────────────────────────────

String generateWaveformGridSvg({
  required List<Map<String, dynamic>> files,
  required List<String> groups,
  required Map<String, String> participantGroups,
  required List<String> conditions,
  required List<String> electrodes,
  required List<ErpComponentDef> components,
  required bool negativeUp,
  required bool monochrome,
  required bool showSem,
  required bool showCallouts,
}) {
  final times = erpNumbers(files.first['times']);
  final nCols = conditions.length;
  final nRows = electrodes.length;

  const w = 820.0;
  final h = 180.0 * nRows + 80.0;
  const leftMargin = 60.0;
  const topMargin = 50.0;
  final cellW = (w - leftMargin - 20) / nCols;
  final cellH = (h - topMargin - 40) / nRows;

  final sb = StringBuffer();
  sb.writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $w $h" width="$w" height="$h">');
  sb.writeln('<rect width="100%" height="100%" fill="white"/>');
  sb.writeln('<defs><marker id="arrow" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="black"/></marker></defs>');

  // Headers
  for (var c = 0; c < nCols; c++) {
    final x = leftMargin + c * cellW + cellW / 2;
    sb.writeln('<text x="$x" y="24" font-family="Arial, sans-serif" font-size="13" font-weight="bold" text-anchor="middle">${conditions[c].toUpperCase()}</text>');
  }

  final yMin = negativeUp ? 6.0 : -6.0;
  final yMax = negativeUp ? -6.0 : 6.0;
  final tMin = times.first;
  final tMax = times.last;

  for (var r = 0; r < nRows; r++) {
    final el = electrodes[r];
    for (var c = 0; c < nCols; c++) {
      final cond = conditions[c];
      final axLeft = leftMargin + c * cellW + 24;
      final axTop = topMargin + r * cellH + 16;
      final axW = cellW - 36;
      final axH = cellH - 32;

      double sx(double t) => axLeft + (t - tMin) / (tMax - tMin) * axW;
      double sy(double v) => axTop + (v - yMin) / (yMax - yMin) * axH;

      // 0 baseline
      final zY = sy(0);
      sb.writeln('<line x1="$axLeft" y1="$zY" x2="${axLeft + axW}" y2="$zY" stroke="#94a3b8" stroke-width="1"/>');
      if (c == 0) {
        sb.writeln('<text x="${axLeft - 4}" y="${axTop - 4}" font-family="Arial, sans-serif" font-size="11" font-weight="bold">$el</text>');
      }

      // Group curves
      for (var g = 0; g < 2 && g < groups.length; g++) {
        final gName = groups[g];
        final gFiles = files.where((f) => (participantGroups[f['subject']] ?? groups.first).toUpperCase() == gName.toUpperCase()).toList();
        final waves = <List<double>>[];
        for (final f in gFiles) {
          final labels = (f['labels'] as List? ?? []).cast<String>();
          final cIdx = labels.indexOf(el);
          if (cIdx < 0) continue;
          final chans = f['channel_conditions'] as Map?;
          if (chans != null && chans.containsKey(cond)) {
            final rows = chans[cond] as List?;
            if (rows != null && cIdx < rows.length) waves.add(erpNumbers(rows[cIdx]));
          }
        }
        if (waves.isEmpty) continue;
        final avg = reviewAverage(waves);

        final pBuf = StringBuffer('M');
        for (var i = 0; i < times.length; i++) {
          pBuf.write(' ${sx(times[i]).toStringAsFixed(1)},${sy(avg[i]).toStringAsFixed(1)}');
          if (i == 0) pBuf.write(' L');
        }
        final strokeColor = monochrome ? "black" : (g == 0 ? "#2563eb" : "#dc2626");
        final strokeDash = (g == 1 && monochrome) ? ' stroke-dasharray="3,3"' : '';
        sb.writeln('<path d="$pBuf" fill="none" stroke="$strokeColor" stroke-width="${g == 0 ? 1.0 : 1.5}"$strokeDash/>');
      }
    }
  }

  sb.writeln('</svg>');
  return sb.toString();
}

String generateInteractionPlotSvg({
  required List<Map<String, dynamic>> files,
  required List<String> groups,
  required Map<String, String> participantGroups,
  required List<String> conditions,
  required List<String> electrodes,
  required ErpComponentDef component,
  required String metric,
  required bool monochrome,
}) {
  final times = erpNumbers(files.first['times']);
  const w = 820.0;
  const h = 380.0;
  final nCols = conditions.length;
  const leftMargin = 60.0;
  const topMargin = 50.0;
  final panelW = (w - leftMargin - 20) / nCols;
  const panelH = h - topMargin - 50.0;

  final yMin = component.polarity < 0 ? 0.0 : -2.0;
  final yMax = component.polarity < 0 ? 6.0 : 8.0;

  final sb = StringBuffer();
  sb.writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $w $h" width="$w" height="$h">');
  sb.writeln('<rect width="100%" height="100%" fill="white"/>');

  for (var c = 0; c < nCols; c++) {
    final cond = conditions[c];
    final axLeft = leftMargin + c * panelW + 20;
    final axW = panelW - 30;

    double sx(int idx) => axLeft + (idx + 0.5) / electrodes.length * axW;
    double sy(double v) => topMargin + panelH - (v - yMin) / (yMax - yMin) * panelH;

    sb.writeln('<text x="${axLeft + axW / 2}" y="${topMargin - 20}" font-family="Arial, sans-serif" font-size="13" font-weight="bold" text-anchor="middle">${cond.toUpperCase()}</text>');
    sb.writeln('<line x1="$axLeft" y1="${topMargin + panelH}" x2="${axLeft + axW}" y2="${topMargin + panelH}" stroke="black" stroke-width="1"/>');

    for (var i = 0; i < electrodes.length; i++) {
      final x = sx(i);
      sb.writeln('<text x="$x" y="${topMargin + panelH + 16}" font-family="Arial, sans-serif" font-size="10" text-anchor="middle">${electrodes[i]}</text>');
    }

    for (var g = 0; g < 2 && g < groups.length; g++) {
      final gName = groups[g];
      final gFiles = files.where((f) => (participantGroups[f['subject']] ?? groups.first).toUpperCase() == gName.toUpperCase()).toList();

      final pts = <Offset>[];
      for (var elIdx = 0; elIdx < electrodes.length; elIdx++) {
        final el = electrodes[elIdx];
        final vals = <double>[];
        for (final f in gFiles) {
          final labels = (f['labels'] as List? ?? []).cast<String>();
          final cIdx = labels.indexOf(el);
          if (cIdx < 0) continue;
          final chans = f['channel_conditions'] as Map?;
          if (chans != null && chans.containsKey(cond)) {
            final rows = chans[cond] as List?;
            if (rows != null && cIdx < rows.length) {
              final w = erpNumbers(rows[cIdx]);
              if (w.length == times.length) {
                final m = reviewMeasures(times, w, component.startMs / 1000, component.endMs / 1000, component.polarity);
                vals.add(m['mean'] ?? 0.0);
              }
            }
          }
        }
        final mean = vals.isEmpty ? 0.0 : vals.reduce((a, b) => a + b) / vals.length;
        pts.add(Offset(sx(elIdx), sy(mean)));
      }

      for (var i = 0; i < pts.length - 1; i++) {
        sb.writeln('<line x1="${pts[i].dx}" y1="${pts[i].dy}" x2="${pts[i + 1].dx}" y2="${pts[i + 1].dy}" stroke="black" stroke-width="1.2"/>');
      }
      for (final pt in pts) {
        if (g == 0) {
          sb.writeln('<circle cx="${pt.dx}" cy="${pt.dy}" r="4" fill="white" stroke="black" stroke-width="1.2"/>');
        } else {
          sb.writeln('<circle cx="${pt.dx}" cy="${pt.dy}" r="4" fill="black"/>');
        }
      }
    }
  }

  sb.writeln('</svg>');
  return sb.toString();
}
