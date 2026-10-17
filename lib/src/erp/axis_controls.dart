import 'package:flutter/material.dart';

/// Display-only limits. Epoch data, baselines and measurement windows are unchanged.
class ErpAxisControls extends StatefulWidget {
  const ErpAxisControls({super.key, required this.onChanged});
  final ValueChanged<Map<String, dynamic>> onChanged;
  @override
  State<ErpAxisControls> createState() => _ErpAxisControlsState();
}

class _ErpAxisControlsState extends State<ErpAxisControls> {
  final _fields = List.generate(4, (_) => TextEditingController());
  String? _error;
  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final limits = <String, dynamic>{};
    for (var i = 0; i < 2; i++) {
      final a = _fields[i * 2].text.trim(), b = _fields[i * 2 + 1].text.trim();
      if (a.isEmpty && b.isEmpty) continue;
      final lo = double.tryParse(a), hi = double.tryParse(b);
      if (lo == null ||
          hi == null ||
          !lo.isFinite ||
          !hi.isFinite ||
          hi <= lo) {
        setState(
          () => _error =
              'Enter both finite limits with minimum < maximum, or leave the pair empty for Auto.',
        );
        return;
      }
      limits[i == 0 ? 'x_limits' : 'y_limits'] = [
        lo / (i == 0 ? 1000 : 1),
        hi / (i == 0 ? 1000 : 1),
      ];
    }
    setState(() => _error = null);
    widget.onChanged(limits);
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Plot axis limits'),
    subtitle: const Text('Display only · time (ms) and amplitude (µV)'),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < 4; i++)
            SizedBox(
              width: 150,
              child: TextField(
                controller: _fields[i],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: [
                    'Time min (ms)',
                    'Time max (ms)',
                    'Amplitude min (µV)',
                    'Amplitude max (µV)',
                  ][i],
                  hintText: 'Auto',
                ),
                onSubmitted: (_) => _apply(),
              ),
            ),
        ],
      ),
      if (_error != null)
        Text(_error!, style: const TextStyle(color: Colors.red)),
      Wrap(
        children: [
          TextButton(onPressed: _apply, child: const Text('Apply limits')),
          TextButton(
            onPressed: () {
              for (final f in _fields) {
                f.clear();
              }
              setState(() => _error = null);
              widget.onChanged({});
            },
            child: const Text('Reset to Auto'),
          ),
        ],
      ),
    ],
  );
}
