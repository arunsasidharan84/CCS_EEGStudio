import 'package:flutter/material.dart';
import 'models.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

List<String> recordingWarnings(EegRecording recording) =>
    (_map(recording.provenance['summary'])['warnings'] as List? ?? [])
        .map((w) => '$w')
        .toList();

/// Recorded outcomes are kept separate from requested settings.
List<(String, String)> recordingHistory(EegRecording r) {
  final p = r.provenance;
  final summary = _map(p['summary']);
  final settings = _map(p['preprocessing']);
  final ica = _map(_map(summary['ica'])['ica']);
  final history = <(String, String)>[
    (
      'Data',
      '${r.labels.length} channels · ${r.sampleRate.toStringAsFixed(1)} Hz',
    ),
    (
      'Structure',
      r.isEpoched
          ? '${r.epochCount} trials · ${r.epochDurationSeconds.toStringAsFixed(3)} s/trial'
          : 'Continuous',
    ),
    if (r.isEpoched && r.epochTmin != null)
      (
        'Event timing',
        'Trial starts ${r.epochTmin} s relative to its locking event',
      ),
    if (p['source_path'] != null) ('Source', '${p['source_path']}'),
    if (p['created_at'] != null) ('Saved', '${p['created_at']}'),
  ];
  if (summary.isNotEmpty) {
    history.add((
      'Preprocessing',
      recordingWarnings(r).isEmpty ? 'Completed' : 'Completed with warnings',
    ));
    for (final name in ['blink_stage', 'other_stage']) {
      final stage = _map(ica[name]);
      if (stage.isNotEmpty)
        history.add((
          name == 'blink_stage' ? 'ICA: eye / ECG' : 'ICA: other artifacts',
          stage['ran'] == true
              ? '${(stage['removed'] as List? ?? []).length} of ${stage['components']} components removed'
              : 'Skipped${stage['note'] == null ? '' : ': ${stage['note']}'}',
        ));
    }
    if (settings['ica_method'] != null &&
        settings['ica_method'] != 'none' &&
        ica.isEmpty) {
      history.add((
        'ICA / ICLabel',
        'Requested but not completed — see warnings',
      ));
    }
    if (settings['gedai'] == true)
      history.add((
        'GEDAI',
        summary['gedai_reference'] == null
            ? 'Not completed — see warnings'
            : 'Completed · ${summary['gedai_reference']} reference',
      ));
    final bad = summary['bad_channels'] as List? ?? [];
    history.add((
      'Bad channels',
      settings['badchannel'] == false
          ? 'Detection off'
          : bad.isEmpty
          ? 'None detected'
          : bad.join(', '),
    ));
  }
  if (p['epoch_protocol'] != null)
    history.add(('Epoching', 'Saved event protocol and condition labels'));
  if (settings.isNotEmpty) {
    history.add((
      'Filter settings',
      settings['filter'] == true
          ? '${settings['low_hz']}–${settings['high_hz']} Hz · notch ${settings['notch_hz']} Hz'
          : 'Off',
    ));
    history.add((
      'Reference setting',
      '${settings['reference_mode'] ?? 'keep existing'}',
    ));
    history.add((
      'ICA training-copy ASR',
      settings['ica_fit_asr'] == true ? 'Enabled for fit copy only' : 'Off',
    ));
    history.add(('Standalone output ASR', '${settings['asr_mode'] ?? 'off'}'));
  }
  if (p.isEmpty)
    history.add((
      'History',
      'No processing history supplied by this file. The filename alone is not proof of cleaning.',
    ));
  return history;
}

List<String> _earlierSteps(Map<String, dynamic> p, [int depth = 0]) {
  if (depth > 12 || p.isEmpty) return [];
  final protocol = _map(p['epoch_protocol']);
  final summary = _map(p['summary']);
  return [
    if (p['source_path'] != null) 'Source: ${p['source_path']}',
    if (protocol.isNotEmpty)
      'Event trials: ${protocol['tmin']}…${protocol['tmax']} s; conditions ${_map(protocol['marker_groups']).keys.join(', ')}',
    if (summary.isNotEmpty)
      'Preprocessing: ${summary['channels']} channels, ${summary['sample_rate']} Hz',
    for (final warning in summary['warnings'] as List? ?? [])
      'Warning: $warning',
    ..._earlierSteps(_map(p['parent_provenance']), depth + 1),
  ];
}

Future<void> showRecordingDetails(BuildContext context, EegRecording r) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recording history'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(r.path),
                const SizedBox(height: 12),
                for (final entry in recordingHistory(r))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 155,
                          child: Text(
                            entry.$1,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(child: SelectableText(entry.$2)),
                      ],
                    ),
                  ),
                if (recordingWarnings(r).isNotEmpty) ...[
                  const Divider(),
                  const Text(
                    'Warnings',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                  for (final warning in recordingWarnings(r))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(warning),
                    ),
                ],
                if (r.provenance['parent_provenance'] is Map &&
                    (r.provenance['parent_provenance'] as Map).isNotEmpty)
                  ExpansionTile(
                    title: const Text('Earlier processing'),
                    children: [
                      SelectableText(
                        _earlierSteps(
                          _map(r.provenance['parent_provenance']),
                        ).join('\n\n'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
