// lib/src/plot_dialog.dart
//
// Full-screen dialog for configuring and running the Dart-native
// EEG feature plot generator (feature_plotter.dart).
//
// Capabilities:
//   • Reads channel/feature names from selected .features.csv files.
//   • User configures: N topoplot windows, epoch size, features to plot,
//     montage (auto 10-10 or custom file), output directory.
//   • Renders plots via generateFeaturePlots() and shows inline PNG gallery.

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'feature_plotter.dart';

// ── Design tokens (match app.dart) ────────────────────────────────────────
const _bg       = Color(0xFF0F172A);
const _card     = Color(0xFF1E293B);
const _border   = Color(0x1FFFFFFF);
const _blue     = Color(0xFF3B82F6);
const _green    = Color(0xFF22C55E);
const _amber    = Color(0xFFF59E0B);
const _purple   = Color(0xFF7C3AED);
const _muted    = Color(0xFF94A3B8);

// ─────────────────────────────────────────────────────────────────────────────

class PlotDialog extends StatefulWidget {
  const PlotDialog({super.key, required this.initialCsvPaths});

  /// Pre-populated list of .features.csv files (from the batch pipeline).
  final List<String> initialCsvPaths;

  @override
  State<PlotDialog> createState() => _PlotDialogState();
}

class _PlotDialogState extends State<PlotDialog> {
  // ── File state ─────────────────────────────────────────────────────────
  final List<String> _csvPaths = [];
  String? _outputDir;
  String? _montagePath;

  // ── Configuration ───────────────────────────────────────────────────────
  final _nTopoCtrl   = TextEditingController(text: '10');
  final _epochCtrl   = TextEditingController(text: '2');
  final _smoothCtrl  = TextEditingController(text: '25');
  bool _autoMontage  = true;

  // ── Feature list discovered from CSVs ──────────────────────────────────
  List<String> _allFeatures   = [];
  Set<String>  _selectedFeatures = {};
  bool         _featuresLoaded  = false;

  // ── Progress / results ──────────────────────────────────────────────────
  bool         _running    = false;
  double       _progress   = 0;
  String       _statusMsg  = '';
  List<String> _savedPaths = [];

  @override
  void initState() {
    super.initState();
    _csvPaths.addAll(widget.initialCsvPaths);
    if (_csvPaths.isNotEmpty) {
      _outputDir = File(_csvPaths.first).parent.path;
      _discoverFeatures();
    }
  }

  @override
  void dispose() {
    _nTopoCtrl.dispose();
    _epochCtrl.dispose();
    _smoothCtrl.dispose();
    super.dispose();
  }

  // ── Feature discovery ────────────────────────────────────────────────────

  void _discoverFeatures() {
    final skipCols = {'Chan', 'Epoch', 'Segment', 'Time', 'File', 'Recording'};
    final found = <String>{};
    for (final path in _csvPaths) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        final lines = f.readAsLinesSync();
        if (lines.isEmpty) continue;
        final firstLine = lines.first;
        for (final col in firstLine.split(',')) {
          final c = col.trim().replaceAll('"', '');
          if (!skipCols.contains(c) && c.isNotEmpty) {
            found.add(c);
          }
        }
      } catch (_) {}
    }
    setState(() {
      _allFeatures = found.toList()..sort();
      _selectedFeatures = Set.from(_allFeatures);
      _featuresLoaded = true;
    });
  }

  // ── File pickers ─────────────────────────────────────────────────────────

  Future<void> _pickCsvFiles() async {
    final pick = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (pick == null) return;
    setState(() {
      for (final f in pick.files) {
        if (f.path != null && !_csvPaths.contains(f.path)) {
          _csvPaths.add(f.path!);
        }
      }
      _outputDir ??= _csvPaths.isNotEmpty ? File(_csvPaths.first).parent.path : null;
      _featuresLoaded = false;
    });
    _discoverFeatures();
  }

  Future<void> _pickOutputDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select output folder for plots',
    );
    if (dir != null) setState(() => _outputDir = dir);
  }

  Future<void> _pickMontageFile() async {
    final pick = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['loc', 'ced', 'xyz', 'csv'],
    );
    if (pick?.files.first.path != null) {
      setState(() => _montagePath = pick!.files.first.path!);
    }
  }

  // ── Generate ──────────────────────────────────────────────────────────────

  Future<void> _generate() async {
    if (_csvPaths.isEmpty) return;
    final outDir = _outputDir ?? File(_csvPaths.first).parent.path;
    final features = _selectedFeatures.toList();
    final nTopo   = int.tryParse(_nTopoCtrl.text) ?? 10;
    final epoch   = double.tryParse(_epochCtrl.text) ?? 2.0;
    final smooth  = int.tryParse(_smoothCtrl.text) ?? 25;

    setState(() {
      _running    = true;
      _progress   = 0;
      _statusMsg  = 'Starting…';
      _savedPaths = [];
    });

    try {
      final paths = await generateFeaturePlots(
        csvPaths: List.from(_csvPaths),
        outputDir: outDir,
        options: PlotOptions(
          nTopoWindows:    nTopo,
          smoothingWindow: smooth,
          epochSizeSeconds: epoch,
          features:        features,
          montagePath:     _autoMontage ? null : _montagePath,
        ),
        onProgress: (p, msg) {
          if (mounted) {
            setState(() {
              _progress  = p;
              _statusMsg = msg;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _savedPaths = paths;
          _statusMsg  = '✓ ${paths.length} plots saved';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusMsg = '✗ Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF060D1A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Row(children: [
          Icon(Icons.stacked_line_chart, color: _blue, size: 18),
          SizedBox(width: 8),
          Text('Generate Feature Plots',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
        actions: [
          if (_savedPaths.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('Open folder'),
              style: TextButton.styleFrom(foregroundColor: _green),
              onPressed: () => _openFolder(_outputDir ?? ''),
            ),
        ],
      ),
      body: _savedPaths.isNotEmpty && !_running
          ? _buildGallery()
          : _buildConfig(),
    );
  }

  // ── Configuration panel ────────────────────────────────────────────────────

  Widget _buildConfig() {
    return Row(children: [
      // ── Left panel: settings ───────────────────────────────────────────
      SizedBox(
        width: 300,
        child: Container(
          color: const Color(0xFF0A1628),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            _sectionLabel('INPUT FILES'),
            const SizedBox(height: 6),
            ..._csvPaths.map((p) => _fileChip(File(p).uri.pathSegments.last, () {
                  setState(() => _csvPaths.remove(p));
                })),
            const SizedBox(height: 6),
            _outlineBtn(
              'Add CSV Files…',
              Icons.add,
              _running ? null : _pickCsvFiles,
              _blue,
            ),
            const SizedBox(height: 18),

            _sectionLabel('OUTPUT FOLDER'),
            const SizedBox(height: 6),
            _pathDisplay(_outputDir ?? 'Same as first CSV'),
            const SizedBox(height: 4),
            _outlineBtn('Browse…', Icons.folder_open,
                _running ? null : _pickOutputDir, _muted),
            const SizedBox(height: 18),

            _sectionLabel('PLOT SETTINGS'),
            const SizedBox(height: 8),
            _labelledField('Topoplot windows (N)', _nTopoCtrl,
                hint: 'e.g. 10'),
            const SizedBox(height: 8),
            _labelledField('Epoch size (s)', _epochCtrl, hint: 'e.g. 2'),
            const SizedBox(height: 8),
            _labelledField('Smoothing window (epochs)', _smoothCtrl,
                hint: 'e.g. 25'),
            const SizedBox(height: 18),

            _sectionLabel('ELECTRODE MONTAGE'),
            const SizedBox(height: 6),
            _radioRow(
              label: 'Auto (standard 10-10)',
              value: true,
              groupValue: _autoMontage,
              onChanged: (v) => setState(() => _autoMontage = true),
            ),
            _radioRow(
              label: 'Custom montage file',
              value: false,
              groupValue: _autoMontage,
              onChanged: (v) => setState(() => _autoMontage = false),
            ),
            if (!_autoMontage) ...[
              const SizedBox(height: 4),
              _pathDisplay(_montagePath ?? 'No file selected'),
              const SizedBox(height: 4),
              _outlineBtn(
                'Load montage (.loc/.ced/.xyz/.csv)…',
                Icons.file_open,
                _running ? null : _pickMontageFile,
                _amber,
              ),
            ],
          ]),
        ),
      ),

      const VerticalDivider(width: 1, color: _border),

      // ── Right panel: feature selector + generate ───────────────────────
      Expanded(
        child: Column(children: [
          // Feature selector header.
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            color: const Color(0xFF0A1628),
            child: Row(children: [
              const Icon(Icons.analytics, size: 14, color: _purple),
              const SizedBox(width: 6),
              Text('FEATURES TO PLOT (${_selectedFeatures.length}/${_allFeatures.length})',
                  style: const TextStyle(
                      color: _purple,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.7)),
              const Spacer(),
              TextButton(
                onPressed: _running ? null : () => setState(() => _selectedFeatures = Set.from(_allFeatures)),
                child: const Text('All', style: TextStyle(fontSize: 11, color: _muted)),
              ),
              TextButton(
                onPressed: _running ? null : () => setState(() => _selectedFeatures = {}),
                child: const Text('None', style: TextStyle(fontSize: 11, color: _muted)),
              ),
            ]),
          ),
          const Divider(color: _border, height: 1),

          // Feature checkboxes.
          Expanded(
            child: !_featuresLoaded
                ? const Center(child: CircularProgressIndicator())
                : _allFeatures.isEmpty
                    ? const Center(
                        child: Text('No features found. Add CSV files.',
                            style: TextStyle(color: _muted, fontSize: 13)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        itemCount: _allFeatures.length,
                        itemBuilder: (ctx, i) {
                          final feat = _allFeatures[i];
                          return CheckboxListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                            value: _selectedFeatures.contains(feat),
                            onChanged: _running
                                ? null
                                : (v) => setState(() => v == true
                                    ? _selectedFeatures.add(feat)
                                    : _selectedFeatures.remove(feat)),
                            title: Text(feat,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                            activeColor: _blue,
                            side: const BorderSide(color: _muted),
                          );
                        },
                      ),
          ),

          // Progress + generate button.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF060D1A),
              border: Border(top: BorderSide(color: _border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_running || _statusMsg.isNotEmpty) ...[
                  Text(_statusMsg,
                      style: TextStyle(
                          color: _statusMsg.startsWith('✗') ? Colors.redAccent
                              : _statusMsg.startsWith('✓') ? _green
                              : _muted,
                          fontSize: 12)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _running ? _progress : null,
                      backgroundColor: const Color(0xFF1E293B),
                      color: _green,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: (_running || _csvPaths.isEmpty || _selectedFeatures.isEmpty)
                        ? null
                        : _generate,
                    icon: _running
                        ? const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.play_arrow, size: 16),
                    label: Text(
                        _running
                            ? 'Generating…'
                            : 'Generate ${_selectedFeatures.length} Plot${_selectedFeatures.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13)),
                    style: FilledButton.styleFrom(
                      backgroundColor: (_csvPaths.isEmpty || _selectedFeatures.isEmpty)
                          ? const Color(0xFF1E293B)
                          : _green,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    ]);
  }

  // ── Gallery panel (after generation) ──────────────────────────────────────

  Widget _buildGallery() {
    return Column(children: [
      // Header bar.
      Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: const Color(0xFF0A1628),
        child: Row(children: [
          const Icon(Icons.check_circle, color: _green, size: 15),
          const SizedBox(width: 6),
          Text('${_savedPaths.length} plots saved',
              style: const TextStyle(
                  color: _green, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.arrow_back, size: 13),
            label: const Text('Configure again', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: _muted),
            onPressed: () => setState(() {
              _savedPaths = [];
              _statusMsg  = '';
            }),
          ),
        ]),
      ),
      const Divider(color: _border, height: 1),

      // Thumbnail grid.
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 460,
            childAspectRatio: 2.2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: _savedPaths.length,
          itemBuilder: (ctx, i) {
            final path = _savedPaths[i];
            final name = File(path).uri.pathSegments.last;
            return GestureDetector(
              onTap: () => _openFile(path),
              child: Container(
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _border),
                ),
                child: Column(children: [
                  // PNG thumbnail.
                  Expanded(
                    child: ClipRRect(
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(8)),
                      child: _PngThumbnail(path: path),
                    ),
                  ),
                  // Name bar.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(children: [
                      const Icon(Icons.image, size: 12, color: _muted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.open_in_new, size: 11, color: _muted),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }

  // ── Widget helpers ────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(text,
            style: const TextStyle(
                color: _muted,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.7)),
      );

  Widget _labelledField(String label, TextEditingController ctrl,
      {String hint = ''}) =>
      TextField(
        controller: ctrl,
        enabled: !_running,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: _bg,
          border: const OutlineInputBorder(
              borderSide: BorderSide(color: _border)),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _border)),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: _blue)),
          labelStyle: const TextStyle(color: _muted),
        ),
      );

  Widget _pathDisplay(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _border),
        ),
        child: Text(text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 11)),
      );

  Widget _outlineBtn(
          String label, IconData icon, VoidCallback? onPressed, Color color) =>
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 13, color: color),
          label: Text(label,
              style: TextStyle(color: color, fontSize: 12)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: color.withOpacity(0.5)),
            padding: const EdgeInsets.symmetric(vertical: 9),
          ),
        ),
      );

  Widget _fileChip(String name, VoidCallback onRemove) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _border),
        ),
        child: Row(children: [
          const Icon(Icons.description, size: 12, color: _muted),
          const SizedBox(width: 4),
          Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 11))),
          IconButton(
            icon: const Icon(Icons.close, size: 12, color: _muted),
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 20, minHeight: 20),
            onPressed: onRemove,
          ),
        ]),
      );

  Widget _radioRow<T>({
    required String label,
    required T value,
    required T groupValue,
    required ValueChanged<T?> onChanged,
  }) =>
      RadioListTile<T>(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.zero,
        title: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
        value: value,
        groupValue: groupValue,
        onChanged: _running ? null : onChanged,
        activeColor: _blue,
      );

  // ── OS file openers ────────────────────────────────────────────────────────

  void _openFile(String path) {
    if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', [path]);
    }
  }

  void _openFolder(String path) {
    if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', [path]);
    }
  }
}

// ── PNG thumbnail widget (lazy-loaded from disk) ───────────────────────────

class _PngThumbnail extends StatefulWidget {
  const _PngThumbnail({required this.path});
  final String path;

  @override
  State<_PngThumbnail> createState() => _PngThumbnailState();
}

class _PngThumbnailState extends State<_PngThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Image.memory(_bytes!, fit: BoxFit.cover);
  }
}
