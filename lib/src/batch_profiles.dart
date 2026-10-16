import 'package:flutter/material.dart';

/// One entry point for multi-recording workflows; profile state stays alive.
class BatchProfilesView extends StatelessWidget {
  const BatchProfilesView({
    super.key,
    required this.profile,
    required this.onChanged,
    required this.eeg,
    required this.erp,
    required this.microstates,
  });
  final String profile;
  final ValueChanged<String> onChanged;
  final Widget eeg, erp, microstates;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.queue_play_next, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Batch Workspace',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: box.maxWidth < 900
                    ? DropdownButton<String>(
                        value: profile,
                        isExpanded: true,
                        items: [
                          for (final name in ['EEG', 'ERP', 'Microstates'])
                            DropdownMenuItem(
                              value: name,
                              child: Text('$name profile'),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) onChanged(v);
                        },
                      )
                    : SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'EEG',
                            label: Text('EEG'),
                            icon: Icon(Icons.waves, size: 16),
                          ),
                          ButtonSegment(
                            value: 'ERP',
                            label: Text('ERP'),
                            icon: Icon(Icons.show_chart, size: 16),
                          ),
                          ButtonSegment(
                            value: 'Microstates',
                            label: Text('Microstates'),
                            icon: Icon(Icons.grain, size: 16),
                          ),
                        ],
                        selected: {profile},
                        onSelectionChanged: (v) => onChanged(v.first),
                      ),
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: ['EEG', 'ERP', 'Microstates'].indexOf(profile),
            children: [eeg, erp, microstates],
          ),
        ),
      ],
    ),
  );
}
