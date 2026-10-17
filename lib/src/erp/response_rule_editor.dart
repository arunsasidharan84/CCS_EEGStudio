import 'package:flutter/material.dart';

/// Explicit behavioral inclusion rules; stimulus codes never imply correctness.
class ResponseRuleEditor extends StatelessWidget {
  const ResponseRuleEditor({
    super.key,
    required this.groups,
    required this.markers,
    required this.rules,
    required this.onChanged,
    this.enabled = true,
  });
  final List<String> groups, markers;
  final Map<String, dynamic> rules;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;

  Future<void> _edit(BuildContext context, String group) async {
    final rule = Map<String, dynamic>.from(rules[group] as Map? ?? {});
    var mode = rule['mode'] as String? ?? 'all';
    final correct = {...(rule['correct'] as List? ?? []).cast<String>()};
    final incorrect = {...(rule['incorrect'] as List? ?? []).cast<String>()};
    var expectedText = (rule['expected_by_stimulus'] as Map? ?? {}).entries
        .map((e) => '${e.key} = ${(e.value as List).join(', ')}')
        .join('\n');
    var lo = '${rule['min_s'] ?? .15}', hi = '${rule['max_s'] ?? 1.5}';
    String? error;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('$group · response inclusion'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('All trials')),
                      DropdownMenuItem(
                        value: 'correct',
                        child: Text('Correct responses only'),
                      ),
                      DropdownMenuItem(
                        value: 'incorrect',
                        child: Text('Incorrect responses only'),
                      ),
                      DropdownMenuItem(
                        value: 'missed',
                        child: Text('Missed responses only'),
                      ),
                    ],
                    onChanged: (v) => update(() => mode = v!),
                  ),
                  const Text(
                    'Use correctness feedback codes directly, or map each stimulus to its expected button below. The first recognised response is used. A later selected stimulus ends the search.',
                  ),
                  for (final entry in [
                    ('Correct response codes', correct),
                    ('Incorrect response codes', incorrect),
                  ]) ...[
                    Text(entry.$1),
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final m in markers)
                          FilterChip(
                            label: Text(m),
                            selected: entry.$2.contains(m),
                            onSelected: (v) => update(() {
                              v ? entry.$2.add(m) : entry.$2.remove(m);
                              if (v)
                                (identical(entry.$2, correct)
                                        ? incorrect
                                        : correct)
                                    .remove(m);
                            }),
                          ),
                      ],
                    ),
                  ],
                  TextFormField(
                    initialValue: expectedText,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'Expected buttons by stimulus (optional)',
                      helperText:
                          'One rule per line: S20 = R1; S30 = R2 (use separate lines). Other recognised buttons are incorrect.',
                    ),
                    onChanged: (v) => expectedText = v,
                  ),
                  TextFormField(
                    initialValue: lo,
                    decoration: const InputDecoration(
                      labelText: 'Earliest response (seconds)',
                    ),
                    onChanged: (v) => lo = v,
                  ),
                  TextFormField(
                    initialValue: hi,
                    decoration: const InputDecoration(
                      labelText: 'Latest response (seconds)',
                    ),
                    onChanged: (v) => hi = v,
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              child: const Text('Save rule'),
              onPressed: () {
                final expected = <String, List<String>>{};
                for (final line
                    in expectedText
                        .split('\n')
                        .where((v) => v.trim().isNotEmpty)) {
                  final pair = line.split('=');
                  if (pair.length != 2 ||
                      pair.first.trim().isEmpty ||
                      pair.last.trim().isEmpty) {
                    update(
                      () => error = 'Use one stimulus = button rule per line.',
                    );
                    return;
                  }
                  expected[pair.first.trim()] = pair.last
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList();
                }
                final a = double.tryParse(lo), b = double.tryParse(hi);
                if (mode != 'all' &&
                    ((correct.isEmpty && expected.isEmpty) ||
                        a == null ||
                        b == null ||
                        !a.isFinite ||
                        !b.isFinite ||
                        a < 0 ||
                        b <= a ||
                        (mode == 'incorrect' &&
                            incorrect.isEmpty &&
                            expected.isEmpty))) {
                  update(
                    () => error =
                        'Choose response codes and a valid time window.',
                  );
                  return;
                }
                Navigator.pop(context, <String, dynamic>{
                  'expected_by_stimulus': expected,
                  'mode': mode,
                  'correct': correct.toList(),
                  'incorrect': incorrect.toList(),
                  'min_s': a,
                  'max_s': b,
                });
              },
            ),
          ],
        ),
      ),
    );
    if (result != null) onChanged({...rules, group: result});
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Trial correctness / response rules'),
    subtitle: const Text(
      'Optional, per condition; saved with the epoch protocol',
    ),
    children: [
      if (groups.isEmpty) const Text('Add named event groups first.'),
      for (final g in groups)
        ListTile(
          dense: true,
          title: Text(g),
          subtitle: Text('${(rules[g] as Map?)?['mode'] ?? 'all'} trials'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: enabled ? () => _edit(context, g) : null,
        ),
    ],
  );
}
