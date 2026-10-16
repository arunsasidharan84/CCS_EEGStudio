import 'package:flutter/material.dart';

/// Named event sets. A marker belongs to at most one set; raw codes stay intact.
class EventGroupEditor extends StatelessWidget {
  const EventGroupEditor({
    super.key,
    required this.groups,
    required this.markers,
    required this.onChanged,
    this.enabled = true,
  });
  final Map<String, List<String>> groups;
  final List<String> markers;
  final ValueChanged<Map<String, List<String>>> onChanged;
  final bool enabled;
  Future<void> _edit(BuildContext context, [String? old]) async {
    var name = old ?? '';
    final selected = {...?groups[old]};
    String? error;
    final result = await showDialog<Map<String, List<String>>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(old == null ? 'Add event group' : 'Edit event group'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    initialValue: name,
                    onChanged: (v) => name = v,
                    decoration: InputDecoration(
                      labelText: 'Condition label',
                      hintText: 'e.g. Correct response',
                      errorText: error,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Choose the markers for this condition. Assigning a marker moves it from any other group.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final code in markers)
                        FilterChip(
                          label: Text(code),
                          selected: selected.contains(code),
                          onSelected: (v) => update(() {
                            v ? selected.add(code) : selected.remove(code);
                          }),
                        ),
                    ],
                  ),
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
              onPressed: () {
                final label = name.trim();
                if (label.isEmpty ||
                    selected.isEmpty ||
                    (label != old && groups.containsKey(label))) {
                  update(
                    () => error =
                        'Use a unique label and select at least one marker.',
                  );
                  return;
                }
                final next = <String, List<String>>{
                  for (final e in groups.entries)
                    if (e.key != old)
                      e.key: e.value
                          .where((m) => !selected.contains(m))
                          .toList(),
                };
                next.removeWhere((_, v) => v.isEmpty);
                next[label] = selected.toList()..sort();
                Navigator.pop(context, next);
              },
              child: const Text('Save group'),
            ),
          ],
        ),
      ),
    );
    if (result != null) onChanged(result);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Named event groups',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const Text(
        'Optional: combine codes under a condition label. Original event codes remain in the saved annotations.',
        style: TextStyle(fontSize: 11),
      ),
      for (final e in groups.entries)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(e.key),
          subtitle: Text(e.value.join(', ')),
          onTap: enabled ? () => _edit(context, e.key) : null,
          trailing: IconButton(
            tooltip: 'Remove group',
            icon: const Icon(Icons.close, size: 18),
            onPressed: enabled
                ? () => onChanged({...groups}..remove(e.key))
                : null,
          ),
        ),
      TextButton.icon(
        onPressed: enabled && markers.isNotEmpty ? () => _edit(context) : null,
        icon: const Icon(Icons.add),
        label: const Text('Add labeled group…'),
      ),
    ],
  );
}
