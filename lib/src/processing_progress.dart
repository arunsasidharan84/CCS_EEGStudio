import 'dart:async';
import 'package:flutter/material.dart';

class ProcessingProgress extends StatefulWidget {
  const ProcessingProgress({
    super.key,
    required this.progress,
    required this.message,
    required this.stopping,
    required this.onCancel,
    this.loading = false,
  });
  final double progress;
  final String message;
  final bool stopping, loading;
  final VoidCallback onCancel;
  @override
  State<ProcessingProgress> createState() => _ProcessingProgressState();
}

class _ProcessingProgressState extends State<ProcessingProgress> {
  final clock = Stopwatch()..start();
  String _icaStage = '';
  @override
  void didUpdateWidget(covariant ProcessingProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.contains('ICA pass')) _icaStage = widget.message;
  }

  late final Timer timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer.cancel();
    clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iteration = RegExp(
      r'ICA iteration (\d+)/(\d+)',
    ).firstMatch(widget.message);
    final elapsed = clock.elapsed.inSeconds;
    final time =
        '${elapsed ~/ 60}m ${(elapsed % 60).toString().padLeft(2, '0')}s';
    return Material(
      color: const Color(0xFF142033),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.stopping
                        ? 'Stopping at a safe checkpoint…'
                        : widget.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('Elapsed $time', style: const TextStyle(fontSize: 11)),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: widget.stopping ? null : widget.onCancel,
                  icon: const Icon(Icons.stop_circle_outlined, size: 16),
                  label: Text(widget.loading ? 'Cancel loading' : 'Stop'),
                ),
              ],
            ),
            LinearProgressIndicator(
              value: widget.progress > 0 ? widget.progress.clamp(0, 1) : null,
            ),
            if (iteration != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  '${_icaStage.isEmpty ? 'ICA' : _icaStage.split(':').first} · iteration ${iteration[1]} of at most ${iteration[2]} · remaining time depends on convergence',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (iteration == null && widget.progress > 0)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'Workflow progress: ${(widget.progress * 100).round()}%',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
