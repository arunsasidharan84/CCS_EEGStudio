// lib/src/erp/stim_epoch_panel.dart
//
// Preprocess option block for stimulus-locked (ERP) epochs: pick the
// markers (chips for markers found in the loaded recording, or type them),
// set the epoch window, the baseline and an optional time limit.

import 'package:flutter/material.dart';

import '../models.dart';
import 'stim_epochs.dart';

const _textMuted = Color(0xFF94A3B8);
const _accent = Color(0xFFA855F7);

class StimEpochPanel extends StatefulWidget {
  const StimEpochPanel({
    super.key,
    required this.config,
    this.markers = const [],
    this.enabled = true,
    this.onChanged,
  });

  final AnalysisConfig config;

  /// Markers of the loaded raw recording (single-recording mode).
  final List<EegMarker> markers;
  final bool enabled;
  final VoidCallback? onChanged;

  @override
  State<StimEpochPanel> createState() => _StimEpochPanelState();
}

class _StimEpochPanelState extends State<StimEpochPanel> {
  late final _markers = TextEditingController(
    text: widget.config.stimMarkers.join(', '),
  );
  late final _pattern = TextEditingController(text: widget.config.stimPattern);
  late final _tmin = TextEditingController(text: '${widget.config.stimTmin}');
  late final _tmax = TextEditingController(text: '${widget.config.stimTmax}');
  late final _b0 = TextEditingController(
    text: '${widget.config.stimBaselineStart}',
  );
  late final _b1 = TextEditingController(
    text: '${widget.config.stimBaselineEnd}',
  );
  late final _crop = TextEditingController(text: widget.config.stimCropMarker);
  late final _cropMin = TextEditingController(
    text: widget.config.stimCropMinutes > 0
        ? '${widget.config.stimCropMinutes}'
        : '',
  );

  @override
  void dispose() {
    for (final c in [
      _markers,
      _pattern,
      _tmin,
      _tmax,
      _b0,
      _b1,
      _crop,
      _cropMin,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _sync() {
    final c = widget.config;
    c
      ..stimMarkers = _markers.text
          .split(',')
          .map((x) => x.trim())
          .where((x) => x.isNotEmpty)
          .toList()
      ..stimPattern = _pattern.text.trim()
      ..stimTmin = double.tryParse(_tmin.text) ?? c.stimTmin
      ..stimTmax = double.tryParse(_tmax.text) ?? c.stimTmax
      ..stimBaselineStart = double.tryParse(_b0.text) ?? c.stimBaselineStart
      ..stimBaselineEnd = double.tryParse(_b1.text) ?? c.stimBaselineEnd
      ..stimCropMarker = _crop.text.trim()
      ..stimCropMinutes = double.tryParse(_cropMin.text) ?? 0;
    widget.onChanged?.call();
    setState(() {});
  }

  void _toggleMarker(String label) {
    final short = markerShortName(label);
    final list = widget.config.stimMarkers;
    final next = markerListContains(list, label)
        ? [
            for (final m in list)
              if (!markerListContains([m], label)) m,
          ]
        : [...list, short];
    _markers.text = next.join(', ');
    _sync();
  }

  Widget _num(TextEditingController c, String label, {String? suffix}) =>
      TextField(
        controller: c,
        enabled: widget.enabled,
        onChanged: (_) => _sync(),
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          isDense: true,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final inv = markerInventory(widget.markers);
    final spec = c.stimEpochSpec;
    int? matched;
    if (spec != null && widget.markers.isNotEmpty) {
      try {
        matched = spec.selectEvents(widget.markers).length;
      } catch (_) {
        matched = null;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          value: c.stimEpochs,
          onChanged: widget.enabled
              ? (v) {
                  c.stimEpochs = v ?? false;
                  widget.onChanged?.call();
                  setState(() {});
                }
              : null,
          title: const Text(
            'Stimulus-locked epochs (ERP)',
            style: TextStyle(fontSize: 12, color: Colors.white),
          ),
          subtitle: const Text(
            'Cut after filtering, before GEDAI (one trial per GEDAI window)',
            style: TextStyle(fontSize: 10, color: _textMuted),
          ),
        ),
        if (c.stimEpochs)
          Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (inv.isNotEmpty) ...[
                  const Text(
                    'Markers in this recording (tap to add / remove)',
                    style: TextStyle(fontSize: 10, color: _textMuted),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final e
                          in (inv.entries.toList()
                            ..sort((a, b) => a.key.compareTo(b.key))))
                        FilterChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(
                            '${markerShortName(e.key)}  ×${e.value}',
                            style: const TextStyle(fontSize: 10),
                          ),
                          selected: markerListContains(c.stimMarkers, e.key),
                          selectedColor: _accent.withValues(alpha: 0.35),
                          onSelected: widget.enabled
                              ? (_) => _toggleMarker(e.key)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                TextField(
                  controller: _markers,
                  enabled: widget.enabled,
                  onChanged: (_) => _sync(),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Epoch on markers (comma separated)',
                    helperText:
                        'e.g. S 51, S 52 — matches "Stimulus/S 51", "S51"',
                    helperStyle: TextStyle(color: _textMuted, fontSize: 10),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _pattern,
                  enabled: widget.enabled,
                  onChanged: (_) => _sync(),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'or regular expression (optional)',
                    helperText: r'e.g. \bS\s*5[12]\b',
                    helperStyle: TextStyle(color: _textMuted, fontSize: 10),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: _num(_tmin, 'tmin', suffix: 's')),
                    const SizedBox(width: 6),
                    Expanded(child: _num(_tmax, 'tmax', suffix: 's')),
                  ],
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  value: c.stimBaseline,
                  onChanged: widget.enabled
                      ? (v) {
                          c.stimBaseline = v ?? true;
                          _sync();
                        }
                      : null,
                  title: const Text(
                    'Baseline correction',
                    style: TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
                if (c.stimBaseline)
                  Row(
                    children: [
                      Expanded(child: _num(_b0, 'from', suffix: 's')),
                      const SizedBox(width: 6),
                      Expanded(child: _num(_b1, 'to', suffix: 's')),
                    ],
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _crop,
                        enabled: widget.enabled,
                        onChanged: (_) => _sync(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Only from marker (optional)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: _num(_cropMin, 'for', suffix: 'min'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (matched != null)
                      '$matched events match in this recording.',
                    'Saved as <name>${c.cleanSuffix}.ccseeg.json with epoch labels and times.',
                  ].join(' '),
                  style: TextStyle(
                    fontSize: 10,
                    color: matched != null && matched < 2
                        ? Colors.orangeAccent
                        : _textMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
