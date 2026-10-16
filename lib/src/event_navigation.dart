import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'models.dart';

/// Compact whole-recording trend and event overview with a draggable viewport.
class RecordingNavigator extends StatelessWidget {
  const RecordingNavigator({
    super.key,
    required this.recording,
    required this.markers,
    required this.start,
    required this.window,
    required this.onNavigate,
  });
  final EegRecording recording;
  final List<EegMarker> markers;
  final double start, window;
  final ValueChanged<double> onNavigate;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      double time(double x) =>
          (x / width).clamp(0.0, 1.0) * recording.durationSeconds;
      void navigate(double x, {bool snap = false}) {
        var t = time(x);
        if (snap && markers.isNotEmpty) {
          final nearby = markers.reduce(
            (a, b) =>
                (a.startSeconds - t).abs() < (b.startSeconds - t).abs() ? a : b,
          );
          if ((nearby.startSeconds - t).abs() /
                  math.max(1, recording.durationSeconds) *
                  width <
              7)
            t = nearby.startSeconds;
        }
        onNavigate(
          (t - window / 2).clamp(
            0.0,
            math.max(0.0, recording.durationSeconds - window),
          ),
        );
      }

      return Semantics(
        label: 'Recording overview: click or drag to navigate time and events',
        child: Tooltip(
          message:
              'Whole recording: first-channel amplitude trend, event ticks, and highlighted visible window. Click an event or drag to navigate.',
          child: GestureDetector(
            key: const ValueKey('recording-overview'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => navigate(d.localPosition.dx, snap: true),
            onHorizontalDragUpdate: (d) => navigate(d.localPosition.dx),
            child: SizedBox(
              height: 44,
              width: double.infinity,
              child: CustomPaint(
                painter: _OverviewPainter(recording, markers, start, window),
              ),
            ),
          ),
        ),
      );
    },
  );
}

final _trendCache = Expando<List<(double, double)>>('overview trend');
List<(double, double)> _makeTrend(Float32List values) {
  final bins = math.min(512, values.length);
  return [
    for (var b = 0; b < bins; b++)
      (() {
        var lo = double.infinity, hi = double.negativeInfinity;
        for (
          var i = b * values.length ~/ bins;
          i < (b + 1) * values.length ~/ bins;
          i++
        ) {
          if (values[i].isFinite) {
            lo = math.min(lo, values[i]);
            hi = math.max(hi, values[i]);
          }
        }
        return (lo, hi);
      })(),
  ];
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.recording, this.markers, this.start, this.window);
  final EegRecording recording;
  final List<EegMarker> markers;
  final double start, window;
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF0B1727));
    final duration = recording.durationSeconds;
    if (duration <= 0) return;
    final values = recording.preview.isEmpty
        ? Float32List(0)
        : recording.preview.first;
    final trend = _trendCache[recording] ??= _makeTrend(values);
    final bins = trend.length;
    final lows = [for (final v in trend) v.$1],
        highs = [for (final v in trend) v.$2];
    final range = trend.fold(
      1e-6,
      (double r, v) =>
          v.$1.isFinite ? math.max(r, math.max(v.$1.abs(), v.$2.abs())) : r,
    );
    final trace = Paint()
      ..color = const Color(0xFF64748B)
      ..strokeWidth = 1;
    for (var b = 0; b < bins; b++) {
      if (lows[b].isFinite) {
        final x = (b + .5) / bins * s.width;
        c.drawLine(
          Offset(
            x,
            (s.height - 16) / 2 - highs[b] / range * (s.height - 16) * .3,
          ),
          Offset(
            x,
            (s.height - 16) / 2 - lows[b] / range * (s.height - 16) * .3,
          ),
          trace,
        );
      }
    }
    for (final m in markers) {
      final x = m.startSeconds / duration * s.width;
      c.drawLine(
        Offset(x, 4),
        Offset(x, 10),
        Paint()
          ..color = const Color(0xFFFBBF24)
          ..strokeWidth = 1,
      );
    }
    final r = Rect.fromLTRB(
      start / duration * s.width,
      2,
      math.min(s.width, (start + window) / duration * s.width),
      s.height - 16,
    );
    c.drawRect(r, Paint()..color = const Color(0x333B82F6));
    c.drawRect(
      r,
      Paint()
        ..color = const Color(0xFF60A5FA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    for (var k = 0; k <= 4; k++) {
      final seconds = duration * k / 4;
      final text =
          '${seconds ~/ 60}:${(seconds % 60).floor().toString().padLeft(2, '0')}';
      final p = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            fontFamily: 'DejaVuSans',
            fontSize: 10,
            color: Color(0xFFCBD5E1),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(
        c,
        Offset(
          (s.width * k / 4 - p.width / 2).clamp(
            0.0,
            math.max(0.0, s.width - p.width),
          ),
          s.height - 13,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OverviewPainter old) => true;
}

/// Labels occupy separate collision-free lanes; dense unlabeled events remain ticks.
class EventLabelLane extends StatelessWidget {
  const EventLabelLane({
    super.key,
    required this.markers,
    required this.start,
    required this.window,
    required this.onEvent,
    required this.onShowAll,
  });
  final List<EegMarker> markers;
  final double start, window;
  final ValueChanged<EegMarker> onEvent;
  final VoidCallback onShowAll;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final gutter = math.min(76.0, box.maxWidth * .22),
          width = math.max(1.0, box.maxWidth - gutter);
      final ends = List.filled(3, -100.0);
      final children = <Widget>[];
      var hidden = 0, usedRows = 0;
      final visible =
          markers
              .where(
                (m) =>
                    m.startSeconds >= start && m.startSeconds <= start + window,
              )
              .toList()
            ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
      for (final m in visible) {
        final x = gutter + (m.startSeconds - start) / window * width;
        final label = m.description.isNotEmpty ? m.description : m.type;
        final w = math.min(
          width,
          math.min(140.0, math.max(38.0, label.length * 6.5 + 12)),
        );
        final left = x.clamp(gutter, math.max(gutter, box.maxWidth - w));
        final row = ends.indexWhere((end) => end + 5 <= left);
        if (row < 0) {
          hidden++;
          continue;
        }
        ends[row] = left + w;
        usedRows = math.max(usedRows, row + 1);
        children.add(
          Positioned(
            left: left.toDouble(),
            top: row * 22.0,
            width: w,
            height: 21,
            child: Tooltip(
              message: '${m.label} · ${m.startSeconds.toStringAsFixed(3)} s',
              child: InkWell(
                onTap: () => onEvent(m),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E3A5F),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      children.add(
        Positioned(
          left: 0,
          top: 0,
          width: gutter - 3,
          child: TextButton(
            onPressed: onShowAll,
            child: Text(
              hidden > 0 ? '+$hidden\nEvents' : 'Events',
              style: const TextStyle(fontSize: 10),
            ),
          ),
        ),
      );
      return SizedBox(
        height: math.max(24.0, usedRows * 22.0 + 2),
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      );
    },
  );
}
