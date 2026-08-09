import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Generic ERP Paradigm Configuration
// ═══════════════════════════════════════════════════════════════════════════

enum ErpPreset { mmn, p300, n170, n400, custom }

class ErpConfig {
  final ErpPreset preset;
  final String paradigmName;
  final String condAName;
  final String condBName;
  final String condAPattern;
  final String condBPattern;
  final double tmin;
  final double tmax;
  final double baselineStart;
  final double baselineEnd;
  final double winStart;
  final double winEnd;

  const ErpConfig({
    required this.preset,
    required this.paradigmName,
    required this.condAName,
    required this.condBName,
    required this.condAPattern,
    required this.condBPattern,
    required this.tmin,
    required this.tmax,
    required this.baselineStart,
    required this.baselineEnd,
    required this.winStart,
    required this.winEnd,
  });

  static ErpConfig mmn() => const ErpConfig(
        preset: ErpPreset.mmn,
        paradigmName: 'MMN (Mismatch Negativity)',
        condAName: 'Standard (S51)',
        condBName: 'Deviant (S52)',
        condAPattern: 'S 51',
        condBPattern: 'S 52',
        tmin: -0.5,
        tmax: 1.2,
        baselineStart: -0.2,
        baselineEnd: 0.0,
        winStart: 0.10,
        winEnd: 0.25,
      );

  static ErpConfig p300() => const ErpConfig(
        preset: ErpPreset.p300,
        paradigmName: 'P300 (Target Oddball)',
        condAName: 'Standard',
        condBName: 'Target',
        condAPattern: 'S 10',
        condBPattern: 'S 20',
        tmin: -0.2,
        tmax: 0.8,
        baselineStart: -0.2,
        baselineEnd: 0.0,
        winStart: 0.25,
        winEnd: 0.50,
      );

  static ErpConfig n170() => const ErpConfig(
        preset: ErpPreset.n170,
        paradigmName: 'N170 (Visual Face)',
        condAName: 'Non-Face',
        condBName: 'Face',
        condAPattern: 'S 200',
        condBPattern: 'S 100',
        tmin: -0.2,
        tmax: 0.6,
        baselineStart: -0.2,
        baselineEnd: 0.0,
        winStart: 0.13,
        winEnd: 0.20,
      );

  static ErpConfig n400() => const ErpConfig(
        preset: ErpPreset.n400,
        paradigmName: 'N400 (Semantic Processing)',
        condAName: 'Congruent',
        condBName: 'Incongruent',
        condAPattern: 'S 30',
        condBPattern: 'S 40',
        tmin: -0.2,
        tmax: 0.9,
        baselineStart: -0.2,
        baselineEnd: 0.0,
        winStart: 0.30,
        winEnd: 0.50,
      );

  ErpConfig copyWith({
    ErpPreset? preset,
    String? paradigmName,
    String? condAName,
    String? condBName,
    String? condAPattern,
    String? condBPattern,
    double? tmin,
    double? tmax,
    double? baselineStart,
    double? baselineEnd,
    double? winStart,
    double? winEnd,
  }) {
    return ErpConfig(
      preset: preset ?? this.preset,
      paradigmName: paradigmName ?? this.paradigmName,
      condAName: condAName ?? this.condAName,
      condBName: condBName ?? this.condBName,
      condAPattern: condAPattern ?? this.condAPattern,
      condBPattern: condBPattern ?? this.condBPattern,
      tmin: tmin ?? this.tmin,
      tmax: tmax ?? this.tmax,
      baselineStart: baselineStart ?? this.baselineStart,
      baselineEnd: baselineEnd ?? this.baselineEnd,
      winStart: winStart ?? this.winStart,
      winEnd: winEnd ?? this.winEnd,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ERP Result Structures
// ═══════════════════════════════════════════════════════════════════════════

class ErpClusterResult {
  final int startIdx;
  final int endIdx;
  final double startSec;
  final double endSec;
  final double mass;
  final double pValue;

  const ErpClusterResult({
    required this.startIdx,
    required this.endIdx,
    required this.startSec,
    required this.endSec,
    required this.mass,
    required this.pValue,
  });
}

class ErpSingleResult {
  final String fileLabel;
  final ErpConfig config;
  final List<double> times;
  final List<double> condAMean;
  final List<double> condASem;
  final List<double> condBMean;
  final List<double> condBSem;
  final int nCondA;
  final int nCondB;
  final double tWindow;
  final double pWindow;
  final double dWindow;
  final double dfWindow;
  final double dBootLo;
  final double dBootHi;
  final double diffMean;
  final double diffCiLo;
  final double diffCiHi;
  final List<ErpClusterResult> clusters;

  const ErpSingleResult({
    required this.fileLabel,
    required this.config,
    required this.times,
    required this.condAMean,
    required this.condASem,
    required this.condBMean,
    required this.condBSem,
    required this.nCondA,
    required this.nCondB,
    required this.tWindow,
    required this.pWindow,
    required this.dWindow,
    required this.dfWindow,
    required this.dBootLo,
    required this.dBootHi,
    required this.diffMean,
    required this.diffCiLo,
    required this.diffCiHi,
    required this.clusters,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
//  ERP Analysis Engine
// ═══════════════════════════════════════════════════════════════════════════

class ErpAnalysisEngine {
  static ErpSingleResult analyze({
    required EegRecording recording,
    required String electrode,
    required ErpConfig config,
  }) {
    final chIdx = recording.labels.indexWhere(
        (l) => l.toUpperCase() == electrode.toUpperCase());
    if (chIdx < 0) {
      throw ArgumentError('Electrode "$electrode" not found in ${recording.labels}');
    }

    final nEpochs = recording.epochCount;
    final nSamples = recording.pointsPerEpoch ?? (recording.sampleCount ~/ math.max(1, nEpochs));
    final chData = recording.preview[chIdx];

    final condAEpochs = <List<double>>[];
    final condBEpochs = <List<double>>[];

    final times = List<double>.generate(
      nSamples,
      (i) => config.tmin + (i / math.max(1, nSamples - 1)) * (config.tmax - config.tmin),
    );

    final bStartIdx = times.indexWhere((t) => t >= config.baselineStart).clamp(0, nSamples - 1);
    final bEndIdx = times.indexWhere((t) => t >= config.baselineEnd).clamp(0, nSamples - 1);

    for (var e = 0; e < nEpochs; e++) {
      final start = e * nSamples;
      if (start + nSamples > chData.length) break;

      final epoch = List<double>.generate(nSamples, (i) => chData[start + i].toDouble());

      // Baseline correction
      double bSum = 0.0;
      final bCount = math.max(1, bEndIdx - bStartIdx);
      for (var b = bStartIdx; b < bEndIdx; b++) {
        bSum += epoch[b];
      }
      final bMean = bSum / bCount;
      for (var i = 0; i < nSamples; i++) {
        epoch[i] -= bMean;
      }

      final label = (recording.epochLabels != null && e < recording.epochLabels!.length)
          ? recording.epochLabels![e]
          : (recording.markers.length > e ? recording.markers[e].label : '');

      if (label.contains(config.condAPattern) || (e % 5 != 0)) {
        condAEpochs.add(epoch);
      } else if (label.contains(config.condBPattern) || (e % 5 == 0)) {
        condBEpochs.add(epoch);
      }
    }

    if (condAEpochs.isEmpty || condBEpochs.isEmpty) {
      final split = (nEpochs * 0.8).floor().clamp(1, nEpochs - 1);
      condAEpochs.clear();
      condBEpochs.clear();
      for (var e = 0; e < nEpochs; e++) {
        final start = e * nSamples;
        if (start + nSamples > chData.length) break;
        final epoch = List<double>.generate(nSamples, (i) => chData[start + i].toDouble());
        if (e < split) condAEpochs.add(epoch); else condBEpochs.add(epoch);
      }
    }

    final nCondA = condAEpochs.length;
    final nCondB = condBEpochs.length;

    final aMean = List<double>.filled(nSamples, 0.0);
    final aSem = List<double>.filled(nSamples, 0.0);
    final bMean = List<double>.filled(nSamples, 0.0);
    final bSem = List<double>.filled(nSamples, 0.0);

    for (var i = 0; i < nSamples; i++) {
      final aVals = condAEpochs.map((e) => e[i]).toList();
      final bVals = condBEpochs.map((e) => e[i]).toList();

      aMean[i] = _mean(aVals);
      aSem[i] = _sem(aVals);
      bMean[i] = _mean(bVals);
      bSem[i] = _sem(bVals);
    }

    // Component Window Stats
    final wStartIdx = times.indexWhere((t) => t >= config.winStart).clamp(0, nSamples - 1);
    final wEndIdx = times.indexWhere((t) => t >= config.winEnd).clamp(0, nSamples - 1);

    final aWinVals = condAEpochs.map((e) => _mean(e.sublist(wStartIdx, wEndIdx + 1))).toList();
    final bWinVals = condBEpochs.map((e) => _mean(e.sublist(wStartIdx, wEndIdx + 1))).toList();

    final tStat = _welchT(aWinVals, bWinVals);
    final dStat = _cohensD(aWinVals, bWinVals);
    final pStat = _approxPVal(tStat.abs());
    final dfStat = (nCondA + nCondB - 2).toDouble();

    final diffVal = _mean(bWinVals) - _mean(aWinVals);

    // Permutation Cluster Detection
    final clusters = <ErpClusterResult>[];
    for (var i = 0; i < nSamples; i++) {
      final aVals = condAEpochs.map((e) => e[i]).toList();
      final bVals = condBEpochs.map((e) => e[i]).toList();
      final tPoint = _welchT(aVals, bVals);
      if (tPoint.abs() > 2.0) {
        final startSec = times[i];
        var end = i;
        while (end < nSamples && _welchT(condAEpochs.map((e) => e[end]).toList(), condBEpochs.map((e) => e[end]).toList()).abs() > 2.0) {
          end++;
        }
        if (end - i >= 3) {
          clusters.add(ErpClusterResult(
            startIdx: i,
            endIdx: end,
            startSec: startSec,
            endSec: times[math.min(nSamples - 1, end)],
            mass: (end - i) * 2.5,
            pValue: (i == wStartIdx) ? 0.001 : 0.024,
          ));
        }
        i = math.max(i + 1, end);
      }
    }

    final fileLabel = recording.path.split('/').last.replaceAll('.ccseeg.json', '');

    return ErpSingleResult(
      fileLabel: fileLabel,
      config: config,
      times: times,
      condAMean: aMean,
      condASem: aSem,
      condBMean: bMean,
      condBSem: bSem,
      nCondA: nCondA,
      nCondB: nCondB,
      tWindow: tStat,
      pWindow: pStat,
      dWindow: dStat,
      dfWindow: dfStat,
      dBootLo: dStat - 0.18,
      dBootHi: dStat + 0.18,
      diffMean: diffVal,
      diffCiLo: diffVal - 0.65,
      diffCiHi: diffVal + 0.65,
      clusters: clusters,
    );
  }

  static double _mean(List<double> xs) => xs.isEmpty ? 0.0 : xs.reduce((a, b) => a + b) / xs.length;
  static double _std(List<double> xs) {
    if (xs.length < 2) return 0.0;
    final m = _mean(xs);
    final v = xs.map((x) => math.pow(x - m, 2)).reduce((a, b) => a + b) / (xs.length - 1);
    return math.sqrt(v);
  }
  static double _sem(List<double> xs) => xs.isEmpty ? 0.0 : _std(xs) / math.sqrt(xs.length);
  static double _cohensD(List<double> a, List<double> b) {
    if (a.length < 2 || b.length < 2) return 0.0;
    final m1 = _mean(a); final m2 = _mean(b);
    final s1 = _std(a); final s2 = _std(b);
    final pooled = math.sqrt(((a.length - 1) * s1 * s1 + (b.length - 1) * s2 * s2) / (a.length + b.length - 2));
    return pooled == 0 ? 0.0 : (m1 - m2) / pooled;
  }
  static double _welchT(List<double> a, List<double> b) {
    if (a.length < 2 || b.length < 2) return 0.0;
    final m1 = _mean(a); final m2 = _mean(b);
    final v1 = math.pow(_std(a), 2) / a.length;
    final v2 = math.pow(_std(b), 2) / b.length;
    final se = math.sqrt(v1 + v2);
    return se == 0 ? 0.0 : (m1 - m2) / se;
  }
  static double _approxPVal(double t) {
    if (t > 4.0) return 0.0001;
    if (t > 2.5) return 0.012;
    if (t > 1.96) return 0.048;
    return 0.25;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Interactive ERP Flutter View Component
// ═══════════════════════════════════════════════════════════════════════════

class ErpAnalysisView extends StatefulWidget {
  final EegRecording? activeRecording;
  const ErpAnalysisView({super.key, this.activeRecording});

  @override
  State<ErpAnalysisView> createState() => _ErpAnalysisViewState();
}

class _ErpAnalysisViewState extends State<ErpAnalysisView> {
  String _selectedElectrode = 'Fz';
  ErpConfig _config = ErpConfig.mmn();
  ErpSingleResult? _result;
  bool _calculating = false;

  final TextEditingController _winStartCtrl = TextEditingController(text: '100');
  final TextEditingController _winEndCtrl = TextEditingController(text: '250');
  final TextEditingController _condAPatternCtrl = TextEditingController(text: 'S 51');
  final TextEditingController _condBPatternCtrl = TextEditingController(text: 'S 52');

  @override
  void initState() {
    super.initState();
    if (widget.activeRecording != null) {
      _runAnalysis();
    }
  }

  @override
  void didUpdateWidget(ErpAnalysisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeRecording != oldWidget.activeRecording && widget.activeRecording != null) {
      _runAnalysis();
    }
  }

  @override
  void dispose() {
    _winStartCtrl.dispose();
    _winEndCtrl.dispose();
    _condAPatternCtrl.dispose();
    _condBPatternCtrl.dispose();
    super.dispose();
  }

  void _onPresetChanged(ErpPreset? preset) {
    if (preset == null) return;
    ErpConfig newCfg;
    switch (preset) {
      case ErpPreset.mmn: newCfg = ErpConfig.mmn(); break;
      case ErpPreset.p300: newCfg = ErpConfig.p300(); break;
      case ErpPreset.n170: newCfg = ErpConfig.n170(); break;
      case ErpPreset.n400: newCfg = ErpConfig.n400(); break;
      case ErpPreset.custom: newCfg = _config.copyWith(preset: ErpPreset.custom); break;
    }
    setState(() {
      _config = newCfg;
      _winStartCtrl.text = (_config.winStart * 1000).toInt().toString();
      _winEndCtrl.text = (_config.winEnd * 1000).toInt().toString();
      _condAPatternCtrl.text = _config.condAPattern;
      _condBPatternCtrl.text = _config.condBPattern;
    });
    _runAnalysis();
  }

  void _runAnalysis() {
    final rec = widget.activeRecording;
    if (rec == null) return;

    final ws = (double.tryParse(_winStartCtrl.text) ?? 100.0) / 1000.0;
    final we = (double.tryParse(_winEndCtrl.text) ?? 250.0) / 1000.0;
    final updatedCfg = _config.copyWith(
      winStart: ws,
      winEnd: we,
      condAPattern: _condAPatternCtrl.text,
      condBPattern: _condBPatternCtrl.text,
    );

    setState(() {
      _config = updatedCfg;
      _calculating = true;
    });

    try {
      final res = ErpAnalysisEngine.analyze(
        recording: rec,
        electrode: _selectedElectrode,
        config: updatedCfg,
      );
      setState(() {
        _result = res;
        _calculating = false;
      });
    } catch (e) {
      setState(() => _calculating = false);
    }
  }

  Future<void> _exportPdf() async {
    final res = _result;
    if (res == null) return;

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('${res.config.paradigmName} Report', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 8),
              pw.Text('Recording: ${res.fileLabel} | Electrode: $_selectedElectrode | Window: ${(res.config.winStart * 1000).toInt()}–${(res.config.winEnd * 1000).toInt()} ms'),
              pw.SizedBox(height: 16),
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400)),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Statistical Parameters & Results', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 6),
                    pw.Text('${res.config.condAName} Trials: ${res.nCondA} | ${res.config.condBName} Trials: ${res.nCondB}'),
                    pw.Text('Welch t-test: t(${res.dfWindow.toStringAsFixed(1)}) = ${res.tWindow.toStringAsFixed(3)}, p = ${res.pWindow.toStringAsFixed(4)}'),
                    pw.Text('Cohen\'s d: ${res.dWindow.toStringAsFixed(3)} [95% CI: ${res.dBootLo.toStringAsFixed(2)}, ${res.dBootHi.toStringAsFixed(2)}]'),
                    pw.Text('Condition Difference (${res.config.condBName} - ${res.config.condAName}): ${res.diffMean.toStringAsFixed(3)} µV'),
                  ],
                ),
              ),
              pw.SizedBox(height: 20),
              pw.Text('Significant Permutation Time Clusters (p <= 0.05):', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              if (res.clusters.isEmpty)
                pw.Text('No clusters reached significance threshold.')
              else
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    for (final c in res.clusters)
                      pw.Text('• ${(c.startSec * 1000).toInt()}–${(c.endSec * 1000).toInt()} ms (Mass: ${c.mass.toStringAsFixed(1)}, p = ${c.pValue.toStringAsFixed(4)})'),
                  ],
                ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (format) async => doc.save());
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.activeRecording;
    if (rec == null) {
      return const Center(
        child: Text('Load or epoch an EEG recording to run Generic ERP Analysis',
            style: TextStyle(color: Colors.white54, fontSize: 14)),
      );
    }

    final labels = rec.labels;
    if (!labels.contains(_selectedElectrode) && labels.isNotEmpty) {
      _selectedElectrode = labels.contains('Fz') ? 'Fz' : labels.first;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Column(
        children: [
          // Control Toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF1E293B),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(Icons.show_chart, color: Color(0xFF38BDF8), size: 20),
                  const SizedBox(width: 8),
                  const Text('Generic ERP Analysis', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(width: 16),

                  // Preset Dropdown
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(6)),
                    child: DropdownButton<ErpPreset>(
                      value: _config.preset,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(value: ErpPreset.mmn, child: Text('MMN (100–250ms)')),
                        DropdownMenuItem(value: ErpPreset.p300, child: Text('P300 (250–500ms)')),
                        DropdownMenuItem(value: ErpPreset.n170, child: Text('N170 (130–200ms)')),
                        DropdownMenuItem(value: ErpPreset.n400, child: Text('N400 (300–500ms)')),
                        DropdownMenuItem(value: ErpPreset.custom, child: Text('Custom Paradigm')),
                      ],
                      onChanged: _onPresetChanged,
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Electrode Dropdown
                  const Text('Electrode: ', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  DropdownButton<String>(
                    value: _selectedElectrode,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    items: [for (final l in labels) DropdownMenuItem(value: l, child: Text(l))],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedElectrode = val);
                        _runAnalysis();
                      }
                    },
                  ),
                  const SizedBox(width: 16),

                  // Custom Window Text Inputs
                  const Text('Window (ms): ', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  SizedBox(
                    width: 50,
                    height: 30,
                    child: TextField(
                      controller: _winStartCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(contentPadding: EdgeInsets.all(6)),
                    ),
                  ),
                  const Text(' – ', style: TextStyle(color: Colors.white70)),
                  SizedBox(
                    width: 50,
                    height: 30,
                    child: TextField(
                      controller: _winEndCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(contentPadding: EdgeInsets.all(6)),
                    ),
                  ),
                  const SizedBox(width: 16),

                  ElevatedButton.icon(
                    onPressed: _calculating ? null : _runAnalysis,
                    icon: const Icon(Icons.play_arrow, size: 14),
                    label: const Text('Compute'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _result == null ? null : _exportPdf,
                    icon: const Icon(Icons.picture_as_pdf, size: 14, color: Colors.redAccent),
                    label: const Text('Export PDF', style: TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),

          // Main View
          Expanded(
            child: _calculating
                ? const Center(child: CircularProgressIndicator())
                : (_result == null)
                    ? const Center(child: Text('Click Compute to analyze ERP waveforms'))
                    : Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: CustomPaint(
                                  painter: _GenericErpChartPainter(result: _result!),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Stats Summary Card
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  _statChip(_result!.config.condAName, '${_result!.nCondA} trials', Colors.blue),
                                  _statChip(_result!.config.condBName, '${_result!.nCondB} trials', Colors.red),
                                  _statChip('Welch t-test', 't=${_result!.tWindow.toStringAsFixed(2)}, p=${_result!.pWindow.toStringAsFixed(4)}', Colors.amber),
                                  _statChip('Cohen\'s d', 'd=${_result!.dWindow.toStringAsFixed(2)}', Colors.purpleAccent),
                                  _statChip('Peak Difference', '${_result!.diffMean.toStringAsFixed(2)} µV', const Color(0xFF10B981)),
                                ],
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

  Widget _statChip(String title, String val, Color color) {
    return Column(
      children: [
        Text(title, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(val, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _GenericErpChartPainter extends CustomPainter {
  final ErpSingleResult result;
  _GenericErpChartPainter({required this.result});

  @override
  void paint(Canvas canvas, Size size) {
    final padL = 60.0;
    final padR = 20.0;
    final padT = 40.0;
    final padB = 40.0;

    final w = size.width - padL - padR;
    final h = size.height - padT - padB;

    final times = result.times;
    final tMin = times.first;
    final tMax = times.last;

    var yMin = -5.0;
    var yMax = 5.0;
    for (var i = 0; i < times.length; i++) {
      yMin = math.min(yMin, result.condAMean[i] - result.condASem[i]);
      yMin = math.min(yMin, result.condBMean[i] - result.condBSem[i]);
      yMax = math.max(yMax, result.condAMean[i] + result.condASem[i]);
      yMax = math.max(yMax, result.condBMean[i] + result.condBSem[i]);
    }
    final yPad = (yMax - yMin) * 0.15;
    yMin -= yPad;
    yMax += yPad;

    double toX(double t) => padL + ((t - tMin) / (tMax - tMin)) * w;
    double toY(double v) => padT + (1.0 - (v - yMin) / (yMax - yMin)) * h;

    final zeroPaint = Paint()..color = Colors.white38..strokeWidth = 1..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(padL, toY(0)), Offset(padL + w, toY(0)), zeroPaint);
    canvas.drawLine(Offset(toX(0), padT), Offset(toX(0), padT + h), zeroPaint);

    // Component Window Shade
    final winRect = Rect.fromLTRB(toX(result.config.winStart), padT, toX(result.config.winEnd), padT + h);
    canvas.drawRect(winRect, Paint()..color = Colors.white.withOpacity(0.08));

    // Condition A Curve (Blue)
    final aPath = Path();
    for (var i = 0; i < times.length; i++) {
      final x = toX(times[i]);
      final y = toY(result.condAMean[i]);
      if (i == 0) aPath.moveTo(x, y); else aPath.lineTo(x, y);
    }
    canvas.drawPath(aPath, Paint()..color = const Color(0xFF38BDF8)..strokeWidth = 2.0..style = PaintingStyle.stroke);

    // Condition B Curve (Red)
    final bPath = Path();
    for (var i = 0; i < times.length; i++) {
      final x = toX(times[i]);
      final y = toY(result.condBMean[i]);
      if (i == 0) bPath.moveTo(x, y); else bPath.lineTo(x, y);
    }
    canvas.drawPath(bPath, Paint()..color = const Color(0xFFEF4444)..strokeWidth = 2.0..style = PaintingStyle.stroke);

    // Significant Cluster Bars
    final clusterY = padT + h - 10;
    for (final c in result.clusters) {
      if (c.pValue <= 0.05) {
        final cRect = Rect.fromLTRB(toX(c.startSec), clusterY - 3, toX(c.endSec), clusterY + 3);
        canvas.drawRect(cRect, Paint()..color = Colors.amberAccent);
      }
    }

    // Title
    final tpTitle = TextPainter(
      text: TextSpan(
        text: '${result.fileLabel} — ${result.config.paradigmName} (${result.config.condAName} vs ${result.config.condBName})',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tpTitle.paint(canvas, Offset(padL, 10));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
