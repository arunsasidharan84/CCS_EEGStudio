import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models.dart';
import 'recording_loader.dart';
import 'recording_transform.dart';

class RecordingPreparationDialog extends StatefulWidget {
  const RecordingPreparationDialog({super.key, required this.recording});
  final EegRecording recording;
  @override
  State<RecordingPreparationDialog> createState() => _PreparationState();
}

class _PreparationState extends State<RecordingPreparationDialog> {
  late final TextEditingController start, end;
  final window = TextEditingController(text: '2'),
      overlap = TextEditingController(text: '0');
  bool crop = true,
      subepoch = false,
      durationMode = false,
      markers = false,
      busy = false;
  String scope = 'within';
  int? startMarker, endMarker;
  String? error;
  bool get epoched => widget.recording.pointsPerEpoch != null;
  double get timeOrigin =>
      epoched && scope == 'within' ? (widget.recording.epochTmin ?? 0) : 0;
  double get limit => epoched && scope == 'within'
      ? widget.recording.pointsPerEpoch! / widget.recording.sampleRate
      : widget.recording.durationSeconds;
  @override
  void initState() {
    super.initState();
    start = TextEditingController(text: timeOrigin.toStringAsFixed(3));
    end = TextEditingController(text: (timeOrigin + limit).toStringAsFixed(3));
    window.text = math.min(2, limit).toString();
  }

  @override
  void dispose() {
    for (final c in [start, end, window, overlap]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget number(TextEditingController c, String label) => Expanded(
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget markerSelector(bool first) => DropdownButtonFormField<int>(
    initialValue: first ? startMarker : endMarker,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: first ? 'Start annotation' : 'End annotation',
    ),
    items: [
      for (var i = 0; i < widget.recording.markers.length; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            '${widget.recording.markers[i].description} [${widget.recording.markers[i].startSeconds.toStringAsFixed(3)} s]',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: (v) => setState(() {
      if (first) {
        startMarker = v;
      } else {
        endMarker = v;
      }
    }),
  );
  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var prepared = await RecordingLoader().loadFull(widget.recording);
      final a = !crop
          ? 0.0
          : markers
          ? (startMarker == null
                ? throw ArgumentError('Choose the start annotation.')
                : widget.recording.markers[startMarker!].startSeconds)
          : double.parse(start.text);
      final b = !crop
          ? limit
          : durationMode
          ? a + double.parse(end.text)
          : markers
          ? (endMarker == null
                ? throw ArgumentError('Choose the end annotation.')
                : widget.recording.markers[endMarker!].startSeconds)
          : double.parse(end.text);
      if (crop)
        prepared = scope == 'across'
            ? RecordingTransform.cropEpochRange(prepared, a, b)
            : RecordingTransform.crop(prepared, a - timeOrigin, b - timeOrigin);
      if (subepoch)
        prepared = RecordingTransform.subepoch(
          prepared,
          double.parse(window.text),
          double.parse(overlap.text),
        );
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save prepared recording',
        fileName:
            '${widget.recording.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.(ccseeg\.json|edf|set|fif|vhdr|mat)', caseSensitive: false), '')}_prepared.ccseeg.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path == null) return;
      final output = path.endsWith('.ccseeg.json') ? path : '$path.ccseeg.json';
      await RecordingTransform.save(
        prepared,
        output,
        sourcePath: widget.recording.path,
        operations: {
          'crop': crop,
          'start_seconds': a,
          'end_seconds': b,
          'subepoch': subepoch,
          'window_seconds': double.tryParse(window.text),
          'overlap_seconds': double.tryParse(overlap.text),
        },
      );
      final loaded = await RecordingLoader().load(output);
      if (mounted) Navigator.of(context).pop(loaded);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      epoched ? 'Crop / subepoch existing trials' : 'Crop / epoch recording',
    ),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              epoched
                  ? 'Times are relative to each parent epoch. New windows never cross trial boundaries.'
                  : 'Cropping is applied before sliding epochs. Endpoints are in recording seconds.',
            ),
            CheckboxListTile(
              title: const Text('Crop data'),
              value: crop,
              onChanged: busy ? null : (v) => setState(() => crop = v!),
            ),
            if (crop) ...[
              if (epoched)
                DropdownButtonFormField<String>(
                  initialValue: scope,
                  decoration: const InputDecoration(labelText: 'Crop domain'),
                  items: const [
                    DropdownMenuItem(
                      value: 'within',
                      child: Text('Within every parent epoch'),
                    ),
                    DropdownMenuItem(
                      value: 'across',
                      child: Text(
                        'Across stitched recording (complete epochs)',
                      ),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    scope = value!;
                    start.text = timeOrigin.toStringAsFixed(3);
                    end.text = (timeOrigin + limit).toStringAsFixed(3);
                  }),
                ),
              if (epoched &&
                  scope == 'within' &&
                  widget.recording.epochTmin != null)
                Text(
                  'Endpoints are event-relative: ${timeOrigin.toStringAsFixed(3)} to ${(timeOrigin + limit).toStringAsFixed(3)} s.',
                ),

              if (!epoched && widget.recording.markers.isNotEmpty)
                SwitchListTile(
                  title: const Text('Use annotations'),
                  value: markers,
                  onChanged: (v) => setState(() => markers = v),
                ),
              SwitchListTile(
                title: const Text('Start + duration (instead of start / end)'),
                value: durationMode,
                onChanged: (v) => setState(() => durationMode = v),
              ),
              if (markers)
                markerSelector(true)
              else
                Row(children: [number(start, 'Start (s)')]),
              if (markers && !durationMode)
                markerSelector(false)
              else
                Row(
                  children: [
                    number(end, durationMode ? 'Duration (s)' : 'End (s)'),
                  ],
                ),
            ],
            CheckboxListTile(
              title: Text(
                epoched ? 'Subepoch each trial' : 'Create sliding epochs',
              ),
              value: subepoch,
              onChanged: busy ? null : (v) => setState(() => subepoch = v!),
            ),
            if (subepoch) ...[
              Row(
                children: [
                  number(window, 'Window (s)'),
                  const SizedBox(width: 12),
                  number(overlap, 'Overlap (s)'),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Incomplete windows are dropped. Overlapping windows share samples and are not independent observations.',
              ),
            ],
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy || (!crop && !subepoch) ? null : save,
        child: Text(busy ? 'Saving…' : 'Save and open'),
      ),
    ],
  );
}
