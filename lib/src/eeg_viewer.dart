import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// EEG waveform viewer styled after ScoringNidra / trainNidra.
///
/// Supports a side-by-side Raw / Processed toggle when [rawRecording] is
/// provided alongside [recording] (the preprocessed version).
class EegViewer extends StatefulWidget {
  const EegViewer({
    super.key,
    required this.recording,
    this.rawRecording,
    this.allRecordings,
    this.onSelectRecording,
    required this.selection,
    required this.onSelectionChanged,
    this.filterEnabled = false,
    this.lowHz = 0.5,
    this.highHz = 40.0,
    this.notchHz = 50.0,
  });

  /// Primary (preprocessed) recording.
  final EegRecording? recording;

  /// Optional original raw recording for comparison.
  final EegRecording? rawRecording;

  /// Optional list of all pipeline stages/recordings for stage switching.
  final List<EegRecording>? allRecordings;
  final ValueChanged<EegRecording>? onSelectRecording;

  final ViewerSelection selection;
  final ValueChanged<ViewerSelection> onSelectionChanged;

  final bool filterEnabled;
  final double lowHz;
  final double highHz;
  final double notchHz;

  @override
  State<EegViewer> createState() => _EegViewerState();
}

class _EegViewerState extends State<EegViewer> {
  final FocusNode _focusNode = FocusNode();

  // ── Viewer state ────────────────────────────────────────────────────────
  double _gain = 1.0;
  double _baseGain = 1.0;
  bool _stacked = true;
  int _selectedChannel = 0;
  bool _notchEnabled = false;
  bool _bandpassEnabled = false; // default false so EEG morphology is untouched
  bool _autoscale = false; // default false so Raw vs Processed use exact same 50 uV scale
  int _windowSeconds = 20;
  double _startSeconds = 0.0;

  /// false = show preprocessed recording, true = show raw recording
  bool _showRaw = false;

  /// Which channels are visible in stacked mode.
  List<bool> _visible = [];
  int _pageSize = 0; // 0 = All, 12, 24, 32
  int _currentPage = 0;
  double _traceSpacing = 1.0;

  int _currentEpochIndex = 0;
  double _accumulatedDragDx = 0.0;
  String? _cachedFilterKey;
  List<Float32List>? _cachedFilterPreview;

  EegRecording? get _activeEeg =>
      (_showRaw && widget.rawRecording != null)
          ? widget.rawRecording
          : widget.recording;

  List<Float32List> _getEffectivePreview(EegRecording eeg) {
    if (!_bandpassEnabled && !_notchEnabled) return eeg.preview;
    final key = '${eeg.path}_${_showRaw}_${_bandpassEnabled}_${_notchEnabled}';
    if (_cachedFilterPreview != null && _cachedFilterKey == key) {
      return _cachedFilterPreview!;
    }
    _cachedFilterKey = key;
    final out = <Float32List>[];
    for (var chIdx = 0; chIdx < eeg.preview.length; chIdx++) {
      out.add(Float32List.fromList(_applyFiltersToSeries(eeg.preview[chIdx], eeg)));
    }
    _cachedFilterPreview = out;
    return out;
  }

  List<double> _applyFiltersToSeries(Float32List raw, EegRecording eeg) {
    if (raw.length < 3 || (!_bandpassEnabled && !_notchEnabled)) {
      return raw.map((v) => v.toDouble()).toList();
    }
    var out = raw.map((v) => v.toDouble()).toList();
    final effectiveRate = (eeg.sampleCount > 0 && eeg.preview.isNotEmpty && eeg.preview.first.isNotEmpty)
        ? eeg.sampleRate * (eeg.preview.first.length / eeg.sampleCount)
        : eeg.sampleRate;
    final dt = 1.0 / effectiveRate;

    final chunkLen = eeg.isEpoched ? (eeg.pointsPerEpoch ?? out.length) : out.length;

    for (var start = 0; start < out.length; start += chunkLen) {
      final end = math.min(out.length, start + chunkLen);
      if (end - start < 2) continue;

      // 1. High-pass filter (based on widget.lowHz)
      if (_bandpassEnabled) {
        final lowHz = widget.lowHz;
        if (lowHz > 0.0) {
          final rcHP = 1.0 / (2 * math.pi * lowHz);
          final alphaHP = rcHP / (rcHP + dt);
          double prevX = out[start];
          double prevY = 0.0;
          out[start] = 0.0;
          for (var i = start + 1; i < end; i++) {
            final x = out[i];
            final y = alphaHP * (prevY + x - prevX);
            prevX = x;
            prevY = y;
            out[i] = y;
          }
        }
      }

      // 2. Low-pass filter (EMA, based on widget.highHz)
      if (_bandpassEnabled) {
        final highHz = widget.highHz;
        final rcLP = 1.0 / (2 * math.pi * highHz);
        final alphaLP = dt / (rcLP + dt);
        
        // Forward pass
        for (var i = start + 1; i < end; i++) {
          out[i] = alphaLP * out[i] + (1 - alphaLP) * out[i - 1];
        }
        // Backward pass for zero-phase shift (approximate bidir filter)
        for (var i = end - 2; i >= start; i--) {
          out[i] = alphaLP * out[i] + (1 - alphaLP) * out[i + 1];
        }
      }

      // 3. Notch filter (based on widget.notchHz)
      if (_notchEnabled) {
        final notchHz = widget.notchHz;
        final double w0 = 2 * math.pi * notchHz / effectiveRate;
        final double r = 0.95; // Bandwidth parameter
        final double cosW0 = math.cos(w0);
        final double a1 = -2.0 * cosW0;
        final double b1 = -2.0 * r * cosW0;
        final double b2 = r * r;

        double x1 = out[start], x2 = out[start];
        double y1 = out[start], y2 = out[start];
        for (var i = start + 2; i < end; i++) {
          final x = out[i];
          final y = x + a1 * x1 + x2 - b1 * y1 - b2 * y2;
          x2 = x1;
          x1 = x;
          y2 = y1;
          y1 = y;
          out[i] = y;
        }
      }

      // 4. Baseline Correction (mean subtraction)
      var chunkMean = 0.0;
      for (var i = start; i < end; i++) chunkMean += out[i];
      chunkMean /= (end - start);
      for (var i = start; i < end; i++) out[i] -= chunkMean;
    }
    return out;
  }

  @override
  void didUpdateWidget(covariant EegViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newPath = widget.recording?.path ?? widget.rawRecording?.path;
    final oldPath = oldWidget.recording?.path ?? oldWidget.rawRecording?.path;
    if (newPath != oldPath) {
      _startSeconds = 0.0;
      _currentEpochIndex = 0;
      _selectedChannel = 0;
      _currentPage = 0;
      _cachedFilterKey = null;
      _cachedFilterPreview = null;
      _bandpassEnabled = widget.filterEnabled;
      _notchEnabled = widget.filterEnabled;
      final n = widget.recording?.labels.length ?? widget.rawRecording?.labels.length ?? 0;
      _visible = List.filled(n, true);
      widget.onSelectionChanged(const ViewerSelection.empty());
    } else if (widget.filterEnabled != oldWidget.filterEnabled ||
        widget.lowHz != oldWidget.lowHz ||
        widget.highHz != oldWidget.highHz ||
        widget.notchHz != oldWidget.notchHz) {
      _cachedFilterKey = null;
      _cachedFilterPreview = null;
      _bandpassEnabled = widget.filterEnabled;
      _notchEnabled = widget.filterEnabled;
    }
  }

  @override
  void initState() {
    super.initState();
    _bandpassEnabled = widget.filterEnabled;
    _notchEnabled = widget.filterEnabled;
    final n = widget.recording?.labels.length ?? widget.rawRecording?.labels.length ?? 0;
    _visible = List.filled(n, true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _adjustGain(double factor) =>
      setState(() => _gain = (_gain * factor).clamp(0.1, 16.0));

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final eeg = _activeEeg;
    if (eeg == null) return _emptyState();

    if (_visible.length != eeg.labels.length) {
      _visible = List.filled(eeg.labels.length, true);
    }

    final duration = eeg.durationSeconds;
    final maxStart = math.max(0.0, duration - _windowSeconds);
    _startSeconds = _startSeconds.clamp(0.0, maxStart);

    return DecoratedBox(
      decoration: _panelDecoration,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(eeg),
            const SizedBox(height: 10),
            _buildControls(eeg),
            const SizedBox(height: 8),
            if (eeg.isEpoched) ...[
              _buildEpochStepper(eeg),
              const SizedBox(height: 4),
            ] else if (maxStart > 0) ...[
              _buildScrollBar(maxStart, duration),
              const SizedBox(height: 4),
            ],
            Expanded(child: _buildWaveform(eeg)),
          ],
        ),
      ),
    );
  }

  // ── Empty state ─────────────────────────────────────────────────────────
  Widget _emptyState() => DecoratedBox(
    decoration: _panelDecoration,
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 48, color: Color(0xFF334155)),
          SizedBox(height: 12),
          Text(
            'Load an EDF, SET, or CCSEEG file to preview signals',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  // ── Header ──────────────────────────────────────────────────────────────
  Widget _buildHeader(EegRecording eeg) {
    final hasRaw = widget.rawRecording != null;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eeg.path.split('/').last,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  _badge('${eeg.labels.length} ch', const Color(0xFF3B82F6)),
                  const SizedBox(width: 4),
                  _badge('${eeg.sampleRate.toStringAsFixed(0)} Hz', const Color(0xFFF59E0B)),
                  const SizedBox(width: 4),
                  if (eeg.isEpoched)
                    _badge('${eeg.epochCount} epochs • ${eeg.epochDurationSeconds.toStringAsFixed(2)}s/ep', const Color(0xFF22C55E))
                  else
                    _badge('${(eeg.durationSeconds / 60).toStringAsFixed(1)} min', const Color(0xFF22C55E)),
                  if (eeg.isEpoched) ...[
                    const SizedBox(width: 4),
                    Builder(builder: (_) {
                      final idx = _currentEpochIndex.clamp(0, eeg.epochCount - 1);
                      final lbl = eeg.epochLabels != null && idx < eeg.epochLabels!.length
                          ? ' • [${eeg.epochLabels![idx]}]'
                          : '';
                      return _badge('Epoch ${idx + 1}/${eeg.epochCount}$lbl', const Color(0xFFA855F7));
                    }),
                  ],
                ],
              ),
            ],
          ),
        ),
        // Pipeline stage / recording switcher
        if (widget.allRecordings != null && widget.allRecordings!.length > 1) ...[
          _buildMultiStageSwitcher(),
          const SizedBox(width: 8),
        ] else if (hasRaw) ...[
          _buildRawProcessedToggle(),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildMultiStageSwitcher() {
    final list = widget.allRecordings!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final rec in list) ...[
              _stageBtn(rec, rec == widget.recording),
            ]
          ],
        ),
      ),
    );
  }

  Widget _stageBtn(EegRecording rec, bool active) {
    String label;
    Color color;
    if (rec.labels.length == 68 && (rec.labels.contains('bankssts-lh') || rec.path.contains('_source'))) {
      label = '🧠 Source (${rec.labels.length} ch)';
      color = const Color(0xFFA855F7);
    } else if (rec.path.contains('_clean')) {
      label = '🧹 Preprocessed (${rec.labels.length} ch)';
      color = const Color(0xFF22C55E);
    } else {
      label = '⚡ Raw (${rec.labels.length} ch)';
      color = const Color(0xFFF59E0B);
    }
    return GestureDetector(
      onTap: () {
        if (widget.onSelectRecording != null) {
          widget.onSelectRecording!(rec);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: active ? Border.all(color: color.withOpacity(0.5)) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : const Color(0xFF64748B),
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildRawProcessedToggle() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggleBtn('Raw', _showRaw, () => setState(() => _showRaw = true),
              const Color(0xFFF59E0B)),
          _toggleBtn('Processed', !_showRaw, () => setState(() => _showRaw = false),
              const Color(0xFF22C55E)),
        ],
      ),
    );
  }

  Widget _toggleBtn(String label, bool active, VoidCallback onTap, Color color) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: active ? Border.all(color: color.withOpacity(0.5)) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : const Color(0xFF64748B),
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ── Controls row ────────────────────────────────────────────────────────
  Widget _buildControls(EegRecording eeg) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              icon: Icon(Icons.view_stream, size: 14),
              label: Text('Stacked', style: TextStyle(fontSize: 12)),
            ),
            ButtonSegment(
              value: false,
              icon: Icon(Icons.show_chart, size: 14),
              label: Text('Single', style: TextStyle(fontSize: 12)),
            ),
          ],
          selected: {_stacked},
          onSelectionChanged: (v) => setState(() => _stacked = v.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
          ),
        ),
        FilterChip(
          label: const Text('Notch', style: TextStyle(fontSize: 12)),
          selected: _notchEnabled,
          onSelected: (v) => setState(() => _notchEnabled = v),
          visualDensity: VisualDensity.compact,
        ),
        FilterChip(
          label: const Text('1–40 Hz', style: TextStyle(fontSize: 12)),
          selected: _bandpassEnabled,
          onSelected: (v) => setState(() => _bandpassEnabled = v),
          visualDensity: VisualDensity.compact,
        ),
        FilterChip(
          label: const Text('Autoscale', style: TextStyle(fontSize: 12)),
          selected: _autoscale,
          onSelected: (v) => setState(() => _autoscale = v),
          visualDensity: VisualDensity.compact,
        ),
        // Gain controls pill
        Container(
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Decrease amplitude',
                onPressed: () => _adjustGain(1 / 1.25),
                icon: const Icon(Icons.remove, size: 16, color: Colors.white70),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
              ),
              Tooltip(
                message: 'Reset gain (100%)',
                child: InkWell(
                  onTap: () => setState(() => _gain = 1.0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '${(_gain * 100).round()}%',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Increase amplitude',
                onPressed: () => _adjustGain(1.25),
                icon: const Icon(Icons.add, size: 16, color: Colors.white70),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
              ),
            ],
          ),
        ),
        // Window duration
        _dropdown<int>(
          value: _windowSeconds,
          items: const [5, 10, 20, 30, 60, 120],
          label: (s) => '$s s',
          onChanged: (v) => setState(() {
            _windowSeconds = v ?? _windowSeconds;
            _startSeconds = _startSeconds.clamp(
              0.0,
              math.max(0.0, eeg.durationSeconds - _windowSeconds),
            );
          }),
        ),
        // Trace spacing
        _dropdown<double>(
          value: _traceSpacing,
          items: const [0.5, 0.75, 1.0, 1.5, 2.0],
          label: (s) => '${s}x Spacing',
          onChanged: (v) => setState(() => _traceSpacing = v ?? 1.0),
        ),
        // Pagination (stacked mode)
        if (_stacked) ...[
          _dropdown<int>(
            value: _pageSize,
            items: const [0, 12, 24, 32],
            label: (v) => v == 0 ? 'All Chs' : '$v Chs/page',
            onChanged: (v) => setState(() {
              _pageSize = v ?? 0;
              _currentPage = 0;
            }),
          ),
          if (_pageSize > 0) ...[
            IconButton(
              tooltip: 'Previous page',
              icon: const Icon(Icons.chevron_left, size: 18, color: Colors.white70),
              onPressed: _currentPage > 0 ? () => setState(() => _currentPage--) : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
            ),
            Text(
              'Page ${_currentPage + 1}',
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
            IconButton(
              tooltip: 'Next page',
              icon: const Icon(Icons.chevron_right, size: 18, color: Colors.white70),
              onPressed: () {
                final totalVisible = _visible.where((v) => v).length;
                final maxPage = math.max(0, (totalVisible / _pageSize).ceil() - 1);
                if (_currentPage < maxPage) setState(() => _currentPage++);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
            ),
          ],
        ],
        if (!_stacked)
          _dropdown<int>(
            value: _selectedChannel.clamp(0, eeg.labels.length - 1),
            items: List.generate(eeg.labels.length, (i) => i),
            label: (i) => eeg.labels[i],
            itemColor: (i) => _channelColors[i % _channelColors.length],
            onChanged: (v) => setState(() => _selectedChannel = v ?? 0),
          ),
        ActionChip(
          avatar: const Icon(Icons.checklist, size: 14, color: Color(0xFF38BDF8)),
          label: Text(
            'Manage Channels (${widget.selection.selectedChannels.isEmpty ? eeg.labels.length : widget.selection.selectedChannels.length}/${eeg.labels.length})',
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
          backgroundColor: const Color(0xFF1E293B),
          side: const BorderSide(color: Color(0xFF334155)),
          onPressed: () => _showChannelsDialog(context, eeg),
        ),
      ],
    );
  }

  void _showChannelsDialog(BuildContext context, EegRecording eeg) {
    // If selectedChannels is empty, it means all channels are active.
    final initialSelected = widget.selection.selectedChannels.isEmpty
        ? Set<String>.from(eeg.labels)
        : Set<String>.from(widget.selection.selectedChannels);
    final workingSet = Set<String>.from(initialSelected);
    String searchQuery = '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final filteredLabels = eeg.labels.where((lbl) =>
              lbl.toLowerCase().contains(searchQuery.toLowerCase())).toList();

          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Interactive Channels Manager', style: TextStyle(color: Colors.white, fontSize: 16)),
                Text('${workingSet.length} of ${eeg.labels.length} active', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 13)),
              ],
            ),
            content: SizedBox(
              width: 550,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search channel labels (e.g. Fz, Cz, EOG)...',
                      hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                      prefixIcon: const Icon(Icons.search, color: Color(0xFF64748B), size: 18),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    onChanged: (val) => setDialogState(() => searchQuery = val),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Select All', style: TextStyle(fontSize: 12, color: Colors.white)),
                        backgroundColor: const Color(0xFF1E293B),
                        onPressed: () => setDialogState(() => workingSet.addAll(eeg.labels)),
                      ),
                      ActionChip(
                        label: const Text('Deselect All', style: TextStyle(fontSize: 12, color: Colors.white)),
                        backgroundColor: const Color(0xFF1E293B),
                        onPressed: () => setDialogState(() => workingSet.clear()),
                      ),
                      ActionChip(
                        label: const Text('Remove Non-EEG / Ref', style: TextStyle(fontSize: 12, color: Colors.white)),
                        backgroundColor: const Color(0xFF1E293B),
                        onPressed: () => setDialogState(() {
                          const nonEeg = {'ecg', 'eog', 'emg', 'm1', 'm2', 'a1', 'a2', 'tp9', 'tp10', 'ft9', 'ft10', 'ref', 'status'};
                          workingSet.removeWhere((lbl) => nonEeg.contains(lbl.toLowerCase()));
                        }),
                      ),
                      ActionChip(
                        label: const Text('Invert Selection', style: TextStyle(fontSize: 12, color: Colors.white)),
                        backgroundColor: const Color(0xFF1E293B),
                        onPressed: () => setDialogState(() {
                          final inv = eeg.labels.where((l) => !workingSet.contains(l)).toSet();
                          workingSet.clear();
                          workingSet.addAll(inv);
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(color: Color(0xFF334155)),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: filteredLabels.map((lbl) {
                          final selected = workingSet.contains(lbl);
                          return FilterChip(
                            label: Text(lbl, style: TextStyle(fontSize: 12, color: selected ? Colors.white : const Color(0xFF94A3B8))),
                            selected: selected,
                            selectedColor: const Color(0xFF0284C7).withOpacity(0.4),
                            checkmarkColor: const Color(0xFF38BDF8),
                            backgroundColor: const Color(0xFF1E293B),
                            side: BorderSide(color: selected ? const Color(0xFF38BDF8) : const Color(0xFF334155)),
                            onSelected: (val) => setDialogState(() {
                              if (val) workingSet.add(lbl); else workingSet.remove(lbl);
                            }),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  final finalList = workingSet.length == eeg.labels.length ? const <String>[] : eeg.labels.where((l) => workingSet.contains(l)).toList();
                  widget.onSelectionChanged(ViewerSelection(
                    selectedChannels: finalList,
                    acceptedIntervals: widget.selection.acceptedIntervals,
                    rejectedIntervals: widget.selection.rejectedIntervals,
                  ));
                },
                child: const Text('Apply Selection', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _dropdown<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    Color Function(T)? itemColor,
    required ValueChanged<T?> onChanged,
  }) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: DropdownButton<T>(
            value: value,
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox(),
            isDense: true,
            items: items
                .map((i) => DropdownMenuItem(
                      value: i,
                      child: Text(
                        label(i),
                        style: itemColor != null
                            ? TextStyle(color: itemColor(i), fontSize: 12)
                            : null,
                      ),
                    ))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      );

  // ── Time scroll bar ─────────────────────────────────────────────────────
  Widget _buildScrollBar(double maxStart, double duration) {
    return Row(
      children: [
        const Icon(Icons.access_time, size: 13, color: Color(0xFF64748B)),
        const SizedBox(width: 4),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: const Color(0xFF3B82F6),
              inactiveTrackColor: const Color(0xFF334155),
              thumbColor: const Color(0xFF3B82F6),
              overlayColor: const Color(0x223B82F6),
            ),
            child: Slider(
              min: 0,
              max: maxStart,
              value: _startSeconds.clamp(0.0, maxStart),
              onChanged: (v) => setState(() => _startSeconds = v),
            ),
          ),
        ),
        SizedBox(
          width: 88,
          child: Text(
            '${_fmt(_startSeconds)} – ${_fmt(_startSeconds + _windowSeconds)}',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  String _fmt(double s) {
    final m = (s ~/ 60);
    final sec = (s % 60).toStringAsFixed(0).padLeft(2, '0');
    return m > 0 ? '$m:$sec' : '${s.toStringAsFixed(0)}s';
  }

  Widget _buildEpochStepper(EegRecording eeg) {
    final idx = _currentEpochIndex.clamp(0, eeg.epochCount - 1);
    final lbl = eeg.epochLabels != null && idx < eeg.epochLabels!.length
        ? eeg.epochLabels![idx]
        : 'Epoch #${idx + 1}';
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 18, color: Colors.white),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: idx > 0 ? () => setState(() => _currentEpochIndex--) : null,
          ),
          Text(
            'Epoch ${idx + 1} / ${eeg.epochCount}',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          _badge(lbl, const Color(0xFFA855F7)),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: const Color(0xFFA855F7),
                inactiveTrackColor: const Color(0xFF334155),
                thumbColor: const Color(0xFFA855F7),
              ),
              child: Slider(
                value: idx.toDouble(),
                min: 0,
                max: (eeg.epochCount - 1).toDouble().clamp(0.0, double.infinity),
                divisions: math.max(1, eeg.epochCount - 1),
                onChanged: (val) => setState(() => _currentEpochIndex = val.round()),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 18, color: Colors.white),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: idx < eeg.epochCount - 1 ? () => setState(() => _currentEpochIndex++) : null,
          ),
        ],
      ),
    );
  }

  // ── Waveform canvas ─────────────────────────────────────────────────────
  Widget _buildWaveform(EegRecording eeg) {
    final List<int> channelIndices;
    if (_stacked) {
      final activeVisible = [
        for (var i = 0; i < eeg.labels.length; i++)
          if (i < _visible.length &&
              _visible[i] &&
              (widget.selection.selectedChannels.isEmpty ||
                  widget.selection.selectedChannels.contains(eeg.labels[i])))
            i,
      ];
      if (_pageSize > 0 && activeVisible.isNotEmpty) {
        final totalPages = (activeVisible.length / _pageSize).ceil();
        if (_currentPage >= totalPages) _currentPage = totalPages - 1;
        if (_currentPage < 0) _currentPage = 0;
        final start = _currentPage * _pageSize;
        final end = math.min(start + _pageSize, activeVisible.length);
        channelIndices = activeVisible.sublist(start, end);
      } else {
        channelIndices = activeVisible;
      }
    } else {
      channelIndices = [_selectedChannel.clamp(0, eeg.labels.length - 1)];
    }

    return Listener(
      onPointerDown: (_) => _focusNode.requestFocus(),
      onPointerHover: (_) {
        if (mounted && !_focusNode.hasFocus) _focusNode.requestFocus();
      },
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          final isVert = signal.scrollDelta.dy.abs() > signal.scrollDelta.dx.abs();
          if (isVert && signal.scrollDelta.dy.abs() > 1.0) {
            // Page through channels vertically
            if (_stacked && _pageSize > 0) {
              if (signal.scrollDelta.dy > 3) {
                setState(() => _currentPage++);
              } else if (signal.scrollDelta.dy < -3) {
                setState(() => _currentPage = math.max(0, _currentPage - 1));
              }
            } else if (!_stacked) {
              if (signal.scrollDelta.dy > 3) {
                setState(() => _selectedChannel = (_selectedChannel + 1).clamp(0, eeg.labels.length - 1));
              } else if (signal.scrollDelta.dy < -3) {
                setState(() => _selectedChannel = (_selectedChannel - 1).clamp(0, eeg.labels.length - 1));
              }
            }
          } else if (!isVert || signal.scrollDelta.dx.abs() > 1.0) {
            // Navigate horizontally across time or epochs
            if (eeg.isEpoched) {
              if (signal.scrollDelta.dx > 5) {
                setState(() => _currentEpochIndex = math.min(eeg.epochCount - 1, _currentEpochIndex + 1));
              } else if (signal.scrollDelta.dx < -5) {
                setState(() => _currentEpochIndex = math.max(0, _currentEpochIndex - 1));
              }
            } else {
              final maxStart = math.max(0.0, eeg.durationSeconds - _windowSeconds);
              if (maxStart > 0) {
                final secPerPx = _windowSeconds / (context.size?.width ?? 800);
                setState(() => _startSeconds = (_startSeconds + signal.scrollDelta.dx * secPerPx * 3.0).clamp(0.0, maxStart));
              }
            }
          }
        }
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            if (eeg.isEpoched) {
              setState(() => _currentEpochIndex = math.min(eeg.epochCount - 1, _currentEpochIndex + 1));
            } else {
              final maxStart = math.max(0.0, eeg.durationSeconds - _windowSeconds);
              final step = (event is KeyRepeatEvent) ? _windowSeconds * 0.1 : _windowSeconds * 0.5;
              setState(() => _startSeconds = (_startSeconds + step).clamp(0.0, maxStart));
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            if (eeg.isEpoched) {
              setState(() => _currentEpochIndex = math.max(0, _currentEpochIndex - 1));
            } else {
              final maxStart = math.max(0.0, eeg.durationSeconds - _windowSeconds);
              final step = (event is KeyRepeatEvent) ? _windowSeconds * 0.1 : _windowSeconds * 0.5;
              setState(() => _startSeconds = (_startSeconds - step).clamp(0.0, maxStart));
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            if (_stacked && _pageSize > 0) {
              setState(() => _currentPage++);
            } else if (!_stacked) {
              setState(() => _selectedChannel = (_selectedChannel + 1).clamp(0, eeg.labels.length - 1));
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            if (_stacked && _pageSize > 0) {
              setState(() => _currentPage = math.max(0, _currentPage - 1));
            } else if (!_stacked) {
              setState(() => _selectedChannel = (_selectedChannel - 1).clamp(0, eeg.labels.length - 1));
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTapDown: (_) => _focusNode.requestFocus(),
          onScaleStart: (_) => _baseGain = _gain,
          onScaleUpdate: (details) =>
              setState(() => _gain = (_baseGain * details.scale).clamp(0.1, 16.0)),
          onDoubleTap: () => setState(() => _gain = 1.0),
          onHorizontalDragUpdate: (details) {
            if (eeg.isEpoched) {
              _accumulatedDragDx -= details.delta.dx;
              if (_accumulatedDragDx.abs() > 40) {
                final steps = (_accumulatedDragDx / 40).floor();
                _accumulatedDragDx -= steps * 40;
                setState(() => _currentEpochIndex = (_currentEpochIndex + steps).clamp(0, eeg.epochCount - 1));
              }
            } else {
              final maxStart = math.max(0.0, eeg.durationSeconds - _windowSeconds);
              if (maxStart <= 0) return;
              final secPerPx = _windowSeconds / (context.size?.width ?? 800);
              setState(() => _startSeconds = (_startSeconds - details.delta.dx * secPerPx).clamp(0.0, maxStart));
            }
          },
          child: ClipRect(
            child: CustomPaint(
              painter: _EegSignalPainter(
                eeg: eeg,
                effectivePreview: _getEffectivePreview(eeg),
                currentEpochIndex: _currentEpochIndex,
                channelIndices: channelIndices,
                startSeconds: _startSeconds,
                windowSeconds: _windowSeconds.toDouble(),
                gain: _gain,
                autoscale: _autoscale,
                stacked: _stacked,
                traceSpacing: _traceSpacing,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  BoxDecoration get _panelDecoration => BoxDecoration(
    color: const Color(0xFF1E293B),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: const Color(0xFF334155)),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Text(label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600)),
  );

  static const _channelColors = [
    Color(0xFF14B8A6), // Teal  ← exact ScoringNidra palette
    Color(0xFF3B82F6), // Blue
    Color(0xFFF87171), // Coral
    Color(0xFFFBBF24), // Amber
    Color(0xFF8B5CF6), // Purple
    Color(0xFF10B981), // Emerald
    Color(0xFF38BDF8), // Sky
    Color(0xFFF472B6), // Pink
    Color(0xFF4ADE80), // Green
    Color(0xFFFF7043), // Deep orange
    Color(0xFF26C6DA), // Cyan
    Color(0xFFFFCA28), // Yellow
    Color(0xFFEC407A), // Pink 400
    Color(0xFF7E57C2), // Deep purple
    Color(0xFF26A69A), // Teal 400
    Color(0xFF8D6E63), // Brown
  ];
}

// ── Signal Painter ────────────────────────────────────────────────────────────
class _EegSignalPainter extends CustomPainter {
  const _EegSignalPainter({
    required this.eeg,
    required this.effectivePreview,
    required this.currentEpochIndex,
    required this.channelIndices,
    required this.startSeconds,
    required this.windowSeconds,
    required this.gain,
    required this.autoscale,
    required this.stacked,
    required this.traceSpacing,
  });

  final EegRecording eeg;
  final List<Float32List> effectivePreview;
  final int currentEpochIndex;
  final List<int> channelIndices;
  final double startSeconds;
  final double windowSeconds;
  final double gain;
  final bool autoscale;
  final bool stacked;
  final double traceSpacing;

  static const _timeAxisH = 20.0;

  static const _colors = [
    Color(0xFF14B8A6),
    Color(0xFF3B82F6),
    Color(0xFFF87171),
    Color(0xFFFBBF24),
    Color(0xFF8B5CF6),
    Color(0xFF10B981),
    Color(0xFF38BDF8),
    Color(0xFFF472B6),
    Color(0xFF4ADE80),
    Color(0xFFFF7043),
    Color(0xFF26C6DA),
    Color(0xFFFFCA28),
    Color(0xFFEC407A),
    Color(0xFF7E57C2),
    Color(0xFF26A69A),
    Color(0xFF8D6E63),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (channelIndices.isEmpty) return;

    final drawH = size.height - _timeAxisH;
    final numLanes = channelIndices.length;
    final laneH = drawH / numLanes;

    // ── Grid (identical to ScoringNidra) ────────────────────────────
    final grid = Paint()
      ..color = const Color(0xFF334155)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = drawH * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, drawH), grid);
    }

    // ── Epoch boundary background & edge indicator ───────────────────
    final double drawW = eeg.isEpoched
        ? math.min(size.width, (eeg.epochDurationSeconds / windowSeconds) * size.width)
        : size.width;

    if (eeg.isEpoched && drawW < size.width) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, drawW, drawH),
        Paint()..color = const Color(0xFFA855F7).withOpacity(0.05),
      );
      final edgePaint = Paint()
        ..color = const Color(0xFFA855F7).withOpacity(0.45)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(drawW, 0), Offset(drawW, drawH), edgePaint);

      // Label showing epoch end time
      final endLbl = TextPainter(
        text: TextSpan(
          text: '${eeg.epochDurationSeconds.toStringAsFixed(1)}s (Epoch End)',
          style: const TextStyle(color: Color(0xFFA855F7), fontSize: 10, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      endLbl.paint(canvas, Offset(drawW + 4, 4));
    }

    // ── Lane separator lines ─────────────────────────────────────────
    if (numLanes > 1) {
      final sep = Paint()
        ..color = const Color(0xFF253347)
        ..strokeWidth = 0.5;
      for (var l = 1; l < numLanes; l++) {
        canvas.drawLine(Offset(0, l * laneH), Offset(size.width, l * laneH), sep);
      }
    }

    // ── Per-channel signal ───────────────────────────────────────────
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var lane = 0; lane < numLanes; lane++) {
      final chIdx = channelIndices[lane];
      final color = _colors[chIdx % _colors.length];
      final label = chIdx < eeg.labels.length ? eeg.labels[chIdx] : 'Ch $chIdx';
      final centerY = lane * laneH + laneH * 0.5;

      // Channel label — top-left of each lane (matches ScoringNidra)
      labelPainter.text = TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: math.max(8.0, math.min(10.0, laneH * 0.4)),
          fontWeight: FontWeight.w600,
        ),
      );
      labelPainter.layout();
      labelPainter.paint(canvas, Offset(4, laneH * lane + 2));

      final values = _windowedSamples(chIdx);
      if (values.length < 2) continue;

      // Calculate channel mean within visible window to center the trace cleanly
      var mean = 0.0;
      var minV = values[0];
      var maxV = values[0];
      for (final v in values) {
        mean += v;
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
      mean /= values.length;

      var laneScale = 50.0;
      if (autoscale && maxV > minV) {
        laneScale = (maxV - minV) / 2.0;
        if (laneScale < 1e-3) laneScale = 50.0;
      }

      final path = Path();
      final n = values.length;

      if (n > drawW * 2) {
        final step = n / drawW;
        for (var px = 0; px <= drawW.ceil(); px++) {
          final idxStart = (px * step).floor().clamp(0, n - 1);
          final idxEnd = ((px + 1) * step).ceil().clamp(idxStart + 1, n);
          var segMin = values[idxStart];
          var segMax = values[idxStart];
          for (var i = idxStart; i < idxEnd; i++) {
            if (values[i] < segMin) segMin = values[i];
            if (values[i] > segMax) segMax = values[i];
          }
          final yMin = (centerY - ((segMax - mean) / laneScale) * laneH * 0.42 * gain * traceSpacing).clamp(0.0, size.height);
          final yMax = (centerY - ((segMin - mean) / laneScale) * laneH * 0.42 * gain * traceSpacing).clamp(0.0, size.height);
          final x = px.toDouble();
          if (px == 0) {
            path.moveTo(x, yMin);
          } else {
            path.lineTo(x, yMin);
          }
          if ((yMax - yMin).abs() > 0.5) {
            path.lineTo(x, yMax);
          }
        }
      } else {
        for (var i = 0; i < n; i++) {
          final x = i * drawW / math.max(1, n - 1);
          final y = (centerY - ((values[i] - mean) / laneScale) * laneH * 0.42 * gain * traceSpacing).clamp(0.0, size.height);
          i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = stacked ? 1.2 : 1.6
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── Time axis ────────────────────────────────────────────────────
    _paintTimeAxis(canvas, size, drawH);
  }

  void _paintTimeAxis(Canvas canvas, Size size, double drawH) {
    canvas.drawRect(
      Rect.fromLTWH(0, drawH, size.width, _timeAxisH),
      Paint()..color = const Color(0xFF0F172A),
    );
    canvas.drawLine(
      Offset(0, drawH),
      Offset(size.width, drawH),
      Paint()
        ..color = const Color(0xFF334155)
        ..strokeWidth = 1,
    );

    final approxTicks = (size.width / 80).floor().clamp(4, 12);
    final niceInterval = _niceInterval(windowSeconds / approxTicks);

    final tickPaint = Paint()
      ..color = const Color(0xFF475569)
      ..strokeWidth = 1;
    final labelPainter = TextPainter(textDirection: TextDirection.ltr);

    final firstTick = (startSeconds / niceInterval).ceil() * niceInterval;
    var t = firstTick;
    while (t <= startSeconds + windowSeconds + 1e-9) {
      final x = (t - startSeconds) / windowSeconds * size.width;
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(Offset(x, drawH), Offset(x, drawH + 5), tickPaint);
        labelPainter.text = TextSpan(
          text: _formatTime(t),
          style: const TextStyle(fontSize: 9, color: Color(0xFF64748B)),
        );
        labelPainter.layout();
        labelPainter.paint(
          canvas,
          Offset(
            (x - labelPainter.width / 2).clamp(0, size.width - labelPainter.width),
            drawH + 6,
          ),
        );
      }
      t += niceInterval;
    }
  }

  // ── Sample extraction ────────────────────────────────────────────────────
  List<double> _windowedSamples(int chIdx) {
    if (chIdx >= effectivePreview.length) return [];
    final all = effectivePreview[chIdx];
    if (all.isEmpty) return [];
    if (eeg.isEpoched) {
      final pts = eeg.pointsPerEpoch ?? all.length;
      final epochIdx = currentEpochIndex.clamp(0, eeg.epochCount - 1);
      final startIdx = epochIdx * pts;
      final endIdx = math.min(all.length, (epochIdx + 1) * pts);
      if (startIdx >= all.length) return [];
      return all.sublist(startIdx, endIdx).map((v) => v.toDouble()).toList();
    }
    final duration = eeg.durationSeconds;
    if (duration <= 0) return all.map((v) => v.toDouble()).toList();
    final a = ((startSeconds / duration).clamp(0.0, 1.0) * all.length).floor();
    final b = (((startSeconds + windowSeconds) / duration).clamp(0.0, 1.0) * all.length)
        .ceil()
        .clamp(a + 1, all.length);
    return all.sublist(a, b).map((v) => v.toDouble()).toList();
  }

  static double _niceInterval(double raw) {
    const c = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 6.0, 10.0, 15.0, 20.0, 30.0, 60.0, 120.0, 300.0];
    for (final v in c) if (v >= raw) return v;
    return raw;
  }

  static String _formatTime(double t) {
    if (t < 120 && (t % 1).abs() < 1e-4) {
      return '${t.round()} s';
    }
    final m = (t ~/ 60);
    final s = (t % 60).toStringAsFixed(0).padLeft(2, '0');
    return m > 0 ? '$m:$s' : '${t.toStringAsFixed(0)} s';
  }

  @override
  bool shouldRepaint(covariant _EegSignalPainter old) =>
      old.effectivePreview != effectivePreview ||
      old.currentEpochIndex != currentEpochIndex ||
      old.eeg != eeg ||
      old.channelIndices != channelIndices ||
      old.startSeconds != startSeconds ||
      old.windowSeconds != windowSeconds ||
      old.gain != gain ||
      old.autoscale != autoscale ||
      old.stacked != stacked ||
      old.traceSpacing != traceSpacing;
}
