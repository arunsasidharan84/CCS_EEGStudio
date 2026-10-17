import 'package:flutter/material.dart';
import 'workbench_figures.dart';
import 'review_math.dart';

/// Independent electrode panels with equal weighting of participants.
class ErpChannelGrid extends StatefulWidget {
  const ErpChannelGrid({
    super.key,
    required this.files,
    required this.profile,
    this.negativeUp = true,
    this.smoothingMs = 0,
  });
  final List<Map<String, dynamic>> files;
  final Map<String, dynamic> profile;
  final bool negativeUp;
  final double smoothingMs;
  @override
  State<ErpChannelGrid> createState() => _ErpChannelGridState();
}

class _ErpChannelGridState extends State<ErpChannelGrid> {
  int _columns = 3;
  Set<String>? _selected;
  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) return const SizedBox.shrink();
    final files = widget.files;
    final labels = (files.first['labels'] as List? ?? [])
        .cast<String>()
        .where(
          (l) => files.every((f) => (f['labels'] as List? ?? []).contains(l)),
        )
        .toList();
    final selected =
        _selected ??
        {
          ...(widget.profile['roi'] as List? ?? []).cast<String>().where(
            labels.contains,
          ),
          ...labels,
        }.take(6).toSet();
    final times = erpNumbers(files.first['times']);
    return ExpansionTile(
      initiallyExpanded: true,
      title: const Text('Electrode panels'),
      children: [
        Wrap(
          spacing: 12,
          children: [
            DropdownButton<int>(
              value: _columns,
              items: [
                for (final n in [1, 2, 3, 4])
                  DropdownMenuItem(value: n, child: Text('$n columns')),
              ],
              onChanged: (v) => setState(() => _columns = v!),
            ),
            TextButton(
              onPressed: () => setState(() => _selected = labels.toSet()),
              child: const Text('All electrodes'),
            ),
            TextButton(
              onPressed: () => setState(() => _selected = {}),
              child: const Text('Clear electrodes'),
            ),
          ],
        ),
        ExpansionTile(
          title: Text('${selected.length} electrodes selected'),
          children: [
            Wrap(
              spacing: 4,
              children: [
                for (final l in labels)
                  FilterChip(
                    label: Text(l),
                    selected: selected.contains(l),
                    onSelected: (v) => setState(() {
                      _selected = {...selected};
                      v ? _selected!.add(l) : _selected!.remove(l);
                    }),
                  ),
              ],
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth < 650 ? 1 : _columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final l in labels.where(selected.contains))
                  SizedBox(
                    width: (constraints.maxWidth - 8 * (cols - 1)) / cols,
                    child: Column(
                      children: [
                        Text(l),
                        SizedBox(
                          height: 230,
                          child: CustomPaint(
                            size: const Size(double.infinity, 230),
                            painter: ErpWorkbenchWavePainter(
                              _data(l, times),
                              negativeUp: widget.negativeUp,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        const Text(
          'Each panel shows one electrode. Old results may contain only the difference; rerun analysis for both conditions.',
        ),
      ],
    );
  }

  Map<String, dynamic> _data(String label, List<double> times) {
    final d = <String, dynamic>{'times': times, 'profile': widget.profile};
    for (final key in ['a', 'b', 'difference']) {
      final people = <String, List<List<double>>>{};
      for (final f in widget.files) {
        final index = (f['labels'] as List).indexOf(label);
        final rows = f['channel_$key'] as List?;
        if (rows == null || index >= rows.length) continue;
        final values = erpNumbers(rows[index]);
        if (values.length != times.length) continue;
        people.putIfAbsent('${f['subject']}', () => []).add(values);
      }
      final waves = [
        for (final p in people.values)
          smoothErp(reviewAverage(p), times, widget.smoothingMs),
      ];
      d[key] = reviewAverage(waves);
      d['sem_$key'] = reviewSem(waves);
    }
    return d;
  }
}
