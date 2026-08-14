import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'extraction_service.dart';
import 'models.dart';
import 'recording_loader.dart';

typedef MicrostateProgress = void Function(double value, String message);

class MicrostateOptions {
  const MicrostateOptions({
    this.minStates = 3,
    this.maxStates = 8,
    this.selectedStates = 8,
    this.repetitions = 10,
    this.maxIterations = 1000,
    this.convergence = 1e-6,
    this.minPeakDistanceMs = 10,
    this.peaksPerRecording = 300,
    this.gfpThresholdSd = 1.5,
    this.minSegmentMs = 30,
    this.seed = 12345,
  });

  final int minStates;
  final int maxStates;
  final int selectedStates;
  final int repetitions;
  final int maxIterations;
  final double convergence;
  final double minPeakDistanceMs;
  final int peaksPerRecording;
  final double gfpThresholdSd;
  final double minSegmentMs;
  final int seed;

  Map<String, Object> toJson() => {
    'min_states': minStates,
    'max_states': maxStates,
    'selected_states': selectedStates,
    'repetitions': repetitions,
    'max_iterations': maxIterations,
    'convergence': convergence,
    'min_peak_distance_ms': minPeakDistanceMs,
    'peaks_per_recording': peaksPerRecording,
    'gfp_threshold_sd': gfpThresholdSd,
    'min_segment_ms': minSegmentMs,
    'seed': seed,
  };
}

class MicrostateResult {
  const MicrostateResult({
    required this.outputDirectory,
    required this.selectedStates,
    required this.stateLabels,
    required this.channelLabels,
    required this.channelPositions,
    required this.prototypes,
    required this.canonicalCorrelations,
    required this.modelFits,
    required this.recordings,
  });

  final String outputDirectory;
  final int selectedStates;
  final List<String> stateLabels;
  final List<String> channelLabels;
  final List<MicrostateScalpPosition> channelPositions;
  final List<List<double>> prototypes;
  final List<double?> canonicalCorrelations;
  final List<Map<String, num>> modelFits;
  final List<MicrostateRecordingResult> recordings;

  factory MicrostateResult.fromJson(
    String outputDirectory,
    Map<String, dynamic> json,
  ) => MicrostateResult(
    outputDirectory: outputDirectory,
    selectedStates: (json['selected_states'] as num).toInt(),
    stateLabels: json['state_labels'] is List
        ? [for (final x in json['state_labels'] as List) x as String]
        : [
            for (var i = 0; i < (json['selected_states'] as num).toInt(); i++)
              String.fromCharCode(65 + i),
          ],
    channelLabels: [
      for (final x in json['channel_labels'] as List) x as String,
    ],
    channelPositions: [
      for (final x in json['channel_positions'] as List)
        MicrostateScalpPosition.fromJson(x as Map<String, dynamic>),
    ],
    prototypes: [
      for (final row in json['prototypes'] as List)
        [for (final x in row as List) (x as num).toDouble()],
    ],
    canonicalCorrelations: [
      for (final x in json['canonical_correlations'] as List)
        (x as num?)?.toDouble(),
    ],
    modelFits: [
      for (final x in json['model_fits'] as List)
        (x as Map<String, dynamic>).map((k, v) => MapEntry(k, v as num)),
    ],
    recordings: [
      for (final x in json['recordings'] as List)
        MicrostateRecordingResult.fromJson(x as Map<String, dynamic>),
    ],
  );
}

class MicrostateScalpPosition {
  const MicrostateScalpPosition({
    required this.label,
    required this.x,
    required this.y,
  });
  final String label;
  final double x;
  final double y;

  factory MicrostateScalpPosition.fromJson(Map<String, dynamic> json) =>
      MicrostateScalpPosition(
        label: json['label'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
      );
}

class MicrostateRecordingResult {
  const MicrostateRecordingResult({
    required this.filename,
    required this.sampleRate,
    required this.gevTotal,
    required this.states,
    required this.transitions,
    required this.sequence,
    required this.sequenceMetrics,
  });

  final String filename;
  final double sampleRate;
  final double gevTotal;
  final List<Map<String, dynamic>> states;
  final List<List<double>> transitions;
  final List<int> sequence;
  final Map<String, num> sequenceMetrics;

  factory MicrostateRecordingResult.fromJson(Map<String, dynamic> json) =>
      MicrostateRecordingResult(
        filename: json['filename'] as String,
        sampleRate: (json['sample_rate'] as num).toDouble(),
        gevTotal: (json['gev_total'] as num).toDouble(),
        states: [
          for (final x in json['states'] as List)
            Map<String, dynamic>.from(x as Map),
        ],
        transitions: [
          for (final row in json['transition_matrix'] as List)
            [for (final x in row as List) (x as num).toDouble()],
        ],
        sequence: [
          for (final x in json['sequence'] as List) (x as num).toInt(),
        ],
        sequenceMetrics: (json['sequence_metrics'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as num),
        ),
      );
}

class MicrostateService {
  Process? _process;

  void cancel() => _process?.kill();

  Future<MicrostateResult> run({
    required List<EegRecording> recordings,
    required String outputDirectory,
    required MicrostateOptions options,
    required MicrostateProgress onProgress,
  }) async {
    if (recordings.isEmpty) throw ArgumentError('No recordings selected.');
    final temp = await Directory.systemTemp.createTemp('ccs_microstates_');
    try {
      final inputs = <String>[];
      final names = <String>[];
      for (var i = 0; i < recordings.length; i++) {
        final recording = recordings[i];
        final file = File('${temp.path}/input_$i.ccseeg.json');
        await file.writeAsString(
          jsonEncode({
            'format': 'ccseeg-v1',
            'sample_rate': recording.sampleRate,
            'labels': recording.labels,
            'channels': [
              for (final ch in recording.preview) [for (final x in ch) x],
            ],
            if (recording.pointsPerEpoch != null)
              'source_epoch_samples': recording.pointsPerEpoch,
          }),
        );
        inputs.add(file.path);
        names.add(File(recording.path).uri.pathSegments.last);
      }
      await Directory(outputDirectory).create(recursive: true);
      final job = File('${temp.path}/job.json');
      await job.writeAsString(
        jsonEncode({
          'job_type': 'microstates',
          'input': inputs.first,
          'output': outputDirectory,
          'format': 'ccseeg',
          'epoch_seconds': 2.0,
          'options': _emptyEngineOptions,
          'microstate_inputs': inputs,
          'microstate_names': names,
          'microstate_options': options.toJson(),
        }),
      );
      final process = await Process.start(ExtractionService.findEngine(), [
        job.path,
      ]);
      _process = process;
      final errors = <String>[];
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('PROGRESS ')) {
              final parts = line.split(' ');
              onProgress(
                (double.tryParse(parts[1]) ?? 0) / 100,
                parts.skip(2).join(' '),
              );
            } else if (line.trim().isNotEmpty) {
              errors.add(line);
            }
          });
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode;
      _process = null;
      if (code != 0) {
        throw StateError(
          errors.isEmpty
              ? 'Microstate engine exited with code $code'
              : errors.join('\n'),
        );
      }
      return MicrostateResult.fromJson(
        outputDirectory,
        jsonDecode(stdout) as Map<String, dynamic>,
      );
    } finally {
      _process = null;
      await temp.delete(recursive: true);
    }
  }
}

const _emptyEngineOptions = <String, Object>{
  'mode': 'full',
  'start_seconds': 0,
  'end_seconds': 0,
  'bin_seconds': 60,
  'psd': false,
  'fooof': false,
  'irasa': false,
  'nonlinear': false,
  'acw': false,
  'connectivity': false,
  'mic': false,
  'mim': false,
  'gc': false,
  'gc_tr': false,
  'coh': false,
  'plv': false,
  'ciplv': false,
  'pli': false,
  'wpli': false,
  'remove_non_eeg': false,
  'exclusions': <String>[],
  'non_eeg_channels': <String>[],
};

class MicrostateAnalysisView extends StatefulWidget {
  const MicrostateAnalysisView({super.key, this.activeRecording});
  final EegRecording? activeRecording;

  @override
  State<MicrostateAnalysisView> createState() => _MicrostateAnalysisViewState();
}

class _MicrostateAnalysisViewState extends State<MicrostateAnalysisView> {
  final _service = MicrostateService();
  final _loader = RecordingLoader();
  final _states = TextEditingController(text: '8');
  final _peaks = TextEditingController(text: '300');
  final _segment = TextEditingController(text: '30');
  final List<String> _batchPaths = [];
  bool _batch = false;
  bool _running = false;
  double _progress = 0;
  String _message = '';
  String? _outputDirectory;
  MicrostateResult? _result;
  int _recordingIndex = 0;
  EegRecording? _interactiveRecording;

  EegRecording? get _interactiveInput =>
      _interactiveRecording ?? widget.activeRecording;

  @override
  void dispose() {
    _service.cancel();
    _states.dispose();
    _peaks.dispose();
    _segment.dispose();
    super.dispose();
  }

  Future<void> _addBatch() async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const [
        'edf',
        'set',
        'fif',
        'vhdr',
        'json',
        'orb',
        'signal',
      ],
    );
    if (picked == null) return;
    setState(() {
      for (final f in picked.files) {
        if (f.path != null && !_batchPaths.contains(f.path))
          _batchPaths.add(f.path!);
      }
    });
  }

  Future<void> _chooseInteractiveRecording() async {
    final picked = await FilePicker.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const [
        'edf',
        'set',
        'fif',
        'vhdr',
        'json',
        'orb',
        'signal',
      ],
    );
    final path = picked == null || picked.files.isEmpty
        ? null
        : picked.files.first.path;
    if (path == null) return;
    setState(() => _message = 'Loading ${_name(path)}…');
    try {
      final recording = await _loader.load(path);
      if (!mounted) return;
      setState(() {
        _interactiveRecording = recording;
        _result = null;
        _message = '';
      });
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Could not load recording: $error');
    }
  }

  String _name(String path) => File(path).uri.pathSegments.last;

  Future<void> _run() async {
    final paths = _batch ? List<String>.of(_batchPaths) : const <String>[];
    if (!_batch && _interactiveInput == null) return;
    if (_batch && paths.isEmpty) return;
    var output = _outputDirectory;
    output ??= await FilePicker.getDirectoryPath(
      dialogTitle: 'Microstate analysis output directory',
    );
    if (output == null) return;
    setState(() {
      _running = true;
      _progress = 0;
      _message = 'Loading recordings…';
      _outputDirectory = output;
    });
    try {
      final recordings = _batch
          ? <EegRecording>[for (final path in paths) await _loader.load(path)]
          : [_interactiveInput!];
      final k = int.tryParse(_states.text)?.clamp(3, 8) ?? 8;
      final result = await _service.run(
        recordings: recordings,
        outputDirectory: output,
        options: MicrostateOptions(
          selectedStates: k,
          peaksPerRecording: int.tryParse(_peaks.text)?.clamp(20, 5000) ?? 300,
          minSegmentMs: double.tryParse(_segment.text)?.clamp(0, 1000) ?? 30,
        ),
        onProgress: (p, m) {
          if (mounted)
            setState(() {
              _progress = p;
              _message = m;
            });
        },
      );
      if (mounted)
        setState(() {
          _result = result;
          _recordingIndex = 0;
        });
    } catch (e) {
      if (mounted) setState(() => _message = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 300,
        child: Material(
          color: const Color(0xFF0A1628),
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              const Text(
                'MICROSTATE ANALYSIS',
                style: TextStyle(
                  color: Color(0xFF06B6D4),
                  fontWeight: FontWeight.bold,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Canonical maps, temporal dynamics, and sequence complexity',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
              ),
              const SizedBox(height: 14),
              _workflowProgress(),
              const SizedBox(height: 18),
              _sectionTitle('1', 'Input'),
              const SizedBox(height: 8),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Interactive'),
                    icon: Icon(Icons.show_chart, size: 15),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Batch'),
                    icon: Icon(Icons.queue, size: 15),
                  ),
                ],
                selected: {_batch},
                onSelectionChanged: _running
                    ? null
                    : (v) => setState(() => _batch = v.first),
              ),
              const SizedBox(height: 12),
              if (!_batch)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _info(
                      _interactiveInput == null
                          ? 'No recording selected.'
                          : 'Input: ${_name(_interactiveInput!.path)}\n${_interactiveInput!.labels.length} channels · ${_interactiveInput!.sampleRate.toStringAsFixed(1)} Hz',
                    ),
                    const SizedBox(height: 7),
                    OutlinedButton.icon(
                      onPressed: _running ? null : _chooseInteractiveRecording,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: Text(
                        _interactiveInput == null
                            ? 'Choose recording'
                            : 'Choose a different recording',
                      ),
                    ),
                  ],
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: _running ? null : _addBatch,
                  icon: const Icon(Icons.add),
                  label: const Text('Add recordings'),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_batchPaths.length} files. One shared group template will be learned and back-fitted to every recording.',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                  ),
                ),
                for (final (i, path) in _batchPaths.indexed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      File(path).uri.pathSegments.last,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: _running
                          ? null
                          : () => setState(() => _batchPaths.removeAt(i)),
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              _sectionTitle('2', 'Configure'),
              const SizedBox(height: 9),
              const Text(
                'Number of states',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final count in [4, 5, 6, 7, 8])
                    ChoiceChip(
                      label: Text('$count'),
                      selected: _states.text == '$count',
                      onSelected: _running
                          ? null
                          : (_) => setState(() => _states.text = '$count'),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                title: const Text(
                  'Advanced parameters',
                  style: TextStyle(fontSize: 12),
                ),
                children: [
                  _field(_peaks, 'GFP peaks / recording'),
                  const SizedBox(height: 8),
                  _field(_segment, 'Minimum segment (ms)'),
                  const SizedBox(height: 9),
                  const Text(
                    'Parity defaults: average reference, dataset normalization, 10 ms peak distance, 1.5 SD GFP threshold, modified k-means ×10, polarity ignored, CV models 3–8.',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _sectionTitle('3', 'Run & export'),
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: _running
                    ? null
                    : () async {
                        final x = await FilePicker.getDirectoryPath();
                        if (x != null) setState(() => _outputDirectory = x);
                      },
                icon: const Icon(Icons.folder),
                label: Text(
                  _outputDirectory == null
                      ? 'Choose output…'
                      : File(
                          _outputDirectory!,
                        ).uri.pathSegments.where((x) => x.isNotEmpty).last,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed:
                    _running ||
                        (!_batch && _interactiveInput == null) ||
                        (_batch && _batchPaths.isEmpty)
                    ? null
                    : _run,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  _running ? 'Analysing…' : 'Run Microstate Analysis',
                ),
              ),
              if (_running) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress),
              ],
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _message,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: _result == null
            ? Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: const Color(0xFF06B6D4).withValues(alpha: .12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.grain,
                          color: Color(0xFF06B6D4),
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _interactiveInput == null && !_batch
                            ? 'Choose a recording to begin'
                            : 'Ready for microstate analysis',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Results will organize canonical headmaps, fit quality, state dynamics, transition probabilities, and complexity metrics in one workspace.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF94A3B8), height: 1.5),
                      ),
                    ],
                  ),
                ),
              )
            : _results(),
      ),
    ],
  );

  Widget _results() {
    final result = _result!;
    final recording = result.recordings[_recordingIndex];
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            Text(
              '${result.selectedStates}-state solution',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Spacer(),
            if (result.recordings.length > 1)
              DropdownButton<int>(
                value: _recordingIndex,
                items: [
                  for (final (i, r) in result.recordings.indexed)
                    DropdownMenuItem(value: i, child: Text(r.filename)),
                ],
                onChanged: (v) => setState(() => _recordingIndex = v ?? 0),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 220.0 * (result.prototypes.length / 4).ceil(),
          child: CustomPaint(
            painter: _TopographyPainter(
              result.channelPositions,
              result.prototypes,
              result.canonicalCorrelations,
              result.stateLabels,
            ),
          ),
        ),
        Text(
          result.stateLabels.any((label) => label.startsWith('U'))
              ? 'Canonical labels are assigned A-first using the accs_CompareTemplateMaps |r| > 0.5 rule. U states did not meet the remaining template threshold.'
              : 'States are polarity-aligned and assigned A-first against MetaMaps_2023_06 using MATLAB-parity spherical-spline remapping.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
        ),
        const SizedBox(height: 14),
        Text(
          recording.filename,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'GEV ${(recording.gevTotal * 100).toStringAsFixed(2)}%  ·  normalized LZ ${_n(recording.sequenceMetrics['normalized_lz'])}  ·  MDV ${_n(recording.sequenceMetrics['duration_variance_samples2'])}  ·  entropy production ${_n(recording.sequenceMetrics['entropy_production'])}',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 58,
          child: CustomPaint(
            painter: _SequencePainter(
              recording.sequence,
              result.selectedStates,
            ),
          ),
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('State')),
              DataColumn(label: Text('GFP')),
              DataColumn(label: Text('Occurrence/s')),
              DataColumn(label: Text('Duration ms')),
              DataColumn(label: Text('Coverage')),
              DataColumn(label: Text('GEV')),
              DataColumn(label: Text('Spatial r')),
            ],
            rows: [
              for (final s in recording.states)
                DataRow(
                  cells: [
                    DataCell(Text('${s['label']}')),
                    DataCell(Text(_n(s['mean_gfp']))),
                    DataCell(Text(_n(s['occurrence_hz']))),
                    DataCell(Text(_n(s['mean_duration_ms']))),
                    DataCell(Text(_n(s['coverage']))),
                    DataCell(Text(_n(s['gev']))),
                    DataCell(Text(_n(s['mean_spatial_correlation']))),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Transition probability matrix',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 260,
          child: CustomPaint(
            painter: _TransitionPainter(recording.transitions),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Exports: microstates.json, MicrostateAnalysisResults.csv, MicrostateSequenceMetrics.csv, MicrostateTransitions.csv, template topographies SVG, and per-recording sequence SVG in ${result.outputDirectory}',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
        ),
      ],
    );
  }

  static String _n(Object? x) => x is num ? x.toStringAsFixed(4) : '—';
  Widget _workflowProgress() {
    final hasInput = _batch
        ? _batchPaths.isNotEmpty
        : _interactiveInput != null;
    return Row(
      children: [
        _progressStep('1', 'Input', hasInput),
        _progressConnector(hasInput),
        _progressStep('2', 'Configure', hasInput),
        _progressConnector(_result != null),
        _progressStep('3', 'Results', _result != null),
      ],
    );
  }

  Widget _progressStep(String number, String label, bool complete) => Expanded(
    child: Column(
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: complete
              ? const Color(0xFF06B6D4)
              : const Color(0xFF1E293B),
          child: complete
              ? const Icon(Icons.check, size: 13, color: Colors.black)
              : Text(number, style: const TextStyle(fontSize: 10)),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 9),
        ),
      ],
    ),
  );

  Widget _progressConnector(bool active) => Expanded(
    child: Container(
      height: 1,
      margin: const EdgeInsets.only(bottom: 16),
      color: active ? const Color(0xFF06B6D4) : const Color(0x33FFFFFF),
    ),
  );

  Widget _sectionTitle(String number, String label) => Row(
    children: [
      Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF06B6D4).withValues(alpha: .14),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          number,
          style: const TextStyle(
            color: Color(0xFF06B6D4),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(width: 7),
      Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
      ),
    ],
  );

  Widget _info(String text) => Container(
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
    ),
  );
  Widget _field(TextEditingController c, String label) => TextField(
    controller: c,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
  );
}

const _stateColors = [
  Color(0xFF3B82F6),
  Color(0xFF22C55E),
  Color(0xFFF59E0B),
  Color(0xFFA855F7),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFFEF4444),
  Color(0xFF84CC16),
];

class _SequencePainter extends CustomPainter {
  const _SequencePainter(this.sequence, this.states);
  final List<int> sequence;
  final int states;
  @override
  void paint(Canvas canvas, Size size) {
    if (sequence.isEmpty) return;
    var start = 0;
    for (var i = 1; i <= sequence.length; i++) {
      if (i == sequence.length || sequence[i] != sequence[start]) {
        canvas.drawRect(
          Rect.fromLTWH(
            start / sequence.length * size.width,
            8,
            (i - start) / sequence.length * size.width,
            size.height - 16,
          ),
          Paint()
            ..color = _stateColors[(sequence[start] - 1) % _stateColors.length],
        );
        start = i;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SequencePainter old) =>
      old.sequence != sequence;
}

class _TopographyPainter extends CustomPainter {
  const _TopographyPainter(
    this.positions,
    this.maps,
    this.correlations,
    this.labels,
  );
  final List<MicrostateScalpPosition> positions;
  final List<List<double>> maps;
  final List<double?> correlations;
  final List<String> labels;

  @override
  void paint(Canvas c, Size size) {
    if (maps.isEmpty) return;
    final columns = maps.length < 4 ? maps.length : 4;
    final rows = (maps.length / columns).ceil();
    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    for (final (s, map) in maps.indexed) {
      final row = s ~/ columns;
      final column = s % columns;
      final center = Offset(
        cellWidth * (column + .5),
        cellHeight * (row + .52),
      );
      final radius = math.min(cellWidth * .36, cellHeight * .34);
      final head = Path()
        ..addOval(Rect.fromCircle(center: center, radius: radius));
      c.save();
      c.clipPath(head);
      const grid = 42;
      final step = radius * 2 / grid;
      final absmax = map
          .map((x) => x.abs())
          .fold<double>(0, math.max)
          .clamp(1e-12, double.infinity);
      for (var gy = 0; gy < grid; gy++) {
        for (var gx = 0; gx < grid; gx++) {
          final x = -1 + (gx + .5) * 2 / grid;
          final y = 1 - (gy + .5) * 2 / grid;
          if (x * x + y * y > 1) continue;
          final value = _interpolate(x, y, map) / absmax;
          c.drawRect(
            Rect.fromLTWH(
              center.dx - radius + gx * step,
              center.dy - radius + gy * step,
              step + .5,
              step + .5,
            ),
            Paint()..color = _diverging(value),
          );
        }
      }
      c.restore();
      c.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = const Color(0xFFE2E8F0),
      );
      // Nose and ears follow the conventional EEGLAB topoplot silhouette.
      c.drawPath(
        Path()
          ..moveTo(center.dx - radius * .16, center.dy - radius * .96)
          ..lineTo(center.dx, center.dy - radius * 1.18)
          ..lineTo(center.dx + radius * .16, center.dy - radius * .96),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = const Color(0xFFE2E8F0),
      );
      for (final side in [-1.0, 1.0]) {
        c.drawPath(
          Path()
            ..moveTo(center.dx + side * radius, center.dy - radius * .25)
            ..cubicTo(
              center.dx + side * radius * 1.14,
              center.dy - radius * .18,
              center.dx + side * radius * 1.14,
              center.dy + radius * .18,
              center.dx + side * radius,
              center.dy + radius * .28,
            ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFFE2E8F0),
        );
      }
      for (final position in positions) {
        c.drawCircle(
          center +
              Offset(position.x * radius * .92, -position.y * radius * .92),
          math.max(1.2, radius * .022),
          Paint()..color = const Color(0xFFF8FAFC),
        );
      }
      final correlation = s < correlations.length ? correlations[s] : null;
      final tp = TextPainter(
        text: TextSpan(
          text: correlation != null
              ? '${labels[s]}  r=${correlation.toStringAsFixed(2)}'
              : labels[s],
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(center.dx - tp.width / 2, row * cellHeight + 2));

      final barWidth = radius * 1.25;
      final barLeft = center.dx - barWidth / 2;
      final barTop = row * cellHeight + cellHeight - 13;
      const colorSteps = 36;
      for (var i = 0; i < colorSteps; i++) {
        c.drawRect(
          Rect.fromLTWH(
            barLeft + i * barWidth / colorSteps,
            barTop,
            barWidth / colorSteps + .5,
            6,
          ),
          Paint()..color = _diverging(-1 + 2 * i / (colorSteps - 1)),
        );
      }
      c.drawRect(
        Rect.fromLTWH(barLeft, barTop, barWidth, 6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = const Color(0xFF94A3B8),
      );
    }
  }

  double _interpolate(double x, double y, List<double> values) {
    var weighted = 0.0, weights = 0.0;
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      final d2 = math.pow(x - p.x, 2) + math.pow(y - p.y, 2);
      if (d2 < 1e-8) return values[i];
      final weight = 1 / math.pow(d2, 1.5);
      weighted += values[i] * weight;
      weights += weight;
    }
    return weighted / weights;
  }

  Color _diverging(double value) {
    final v = value.clamp(-1.0, 1.0);
    if (v < 0) return Color.lerp(const Color(0xFF3B4CC0), Colors.white, v + 1)!;
    return Color.lerp(Colors.white, const Color(0xFFB40426), v)!;
  }

  @override
  bool shouldRepaint(covariant _TopographyPainter old) =>
      old.maps != maps || old.positions != positions;
}

class _TransitionPainter extends CustomPainter {
  const _TransitionPainter(this.matrix);
  final List<List<double>> matrix;
  @override
  void paint(Canvas c, Size z) {
    if (matrix.isEmpty) return;
    final n = matrix.length;
    final side = math.min(z.width, z.height) - 35;
    final cell = side / n;
    final max = matrix
        .expand((x) => x)
        .fold(0.0, math.max)
        .clamp(1e-12, double.infinity);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        final v = matrix[i][j] / max;
        c.drawRect(
          Rect.fromLTWH(30 + j * cell, 5 + i * cell, cell - 1, cell - 1),
          Paint()
            ..color = Color.lerp(
              const Color(0xFF172554),
              const Color(0xFF22D3EE),
              v,
            )!,
        );
        final t = TextPainter(
          text: TextSpan(
            text: matrix[i][j].toStringAsFixed(3),
            style: TextStyle(
              color: v > .5 ? Colors.black : Colors.white,
              fontSize: math.min(10, cell * .22),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        t.paint(
          c,
          Offset(
            30 + j * cell + (cell - t.width) / 2,
            5 + i * cell + (cell - t.height) / 2,
          ),
        );
      }
      final l = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(65 + i),
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      l.paint(c, Offset(10, 5 + i * cell + (cell - l.height) / 2));
      l.paint(c, Offset(30 + i * cell + (cell - l.width) / 2, 8 + side));
    }
  }

  @override
  bool shouldRepaint(covariant _TransitionPainter old) => old.matrix != matrix;
}
