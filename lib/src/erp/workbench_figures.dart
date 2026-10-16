import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/rendering.dart';
import '../topostats/topo_interp.dart';
import '../topostats/topo_paint.dart';
import '../topostats/mne_constants.dart';

List<double> erpNumbers(dynamic value) => value is List
    ? value.map((v) => v is num ? v.toDouble() : double.nan).toList()
    : [];
Map<String, dynamic> erpMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
void erpText(
  Canvas c,
  String text,
  Offset at, {
  double size = 12,
  Color color = const Color(0xFF334155),
  double maxWidth = 1000,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size, fontFamily: 'DejaVuSans'),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  painter.paint(c, at);
}

class ErpWorkbenchWavePainter extends CustomPainter {
  ErpWorkbenchWavePainter(
    this.data, {
    this.negativeUp = true,
    this.hoverX,
    this.decode = false,
  });
  final Map<String, dynamic> data;
  final bool negativeUp, decode;
  final double? hoverX;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final times = erpNumbers(data['times']);
    if (times.length < 2) return;
    final modelPlot = data['model_plot'] == true;
    final arrays = decode
        ? [erpNumbers(data['auc']), erpNumbers(data['balanced_accuracy'])]
        : [
            erpNumbers(data['a']),
            erpNumbers(data['b']),
            if (!modelPlot) erpNumbers(data['difference']),
          ];
    final profile = erpMap(data['profile']);
    final lateral = profile['lateralized'] == true;
    final names = decode
        ? ['AUC', 'Balanced accuracy']
        : [
            lateral ? 'Ipsilateral' : profile['a_name'] ?? 'A',
            lateral ? 'Contralateral' : profile['b_name'] ?? 'B',
            if (!modelPlot) 'B - A',
          ];
    const colors = [Color(0xFF2563EB), Color(0xFFDC2626), Color(0xFF475569)];
    final ax = Rect.fromLTRB(62, 48, size.width - 20, size.height - 46);
    if (ax.width <= 0 || ax.height <= 0) return;
    var min = decode
            ? 0.0
            : arrays
                  .expand((x) => x)
                  .where((x) => x.isFinite)
                  .fold(0.0, math.min),
        max = decode
            ? 1.0
            : arrays
                  .expand((x) => x)
                  .where((x) => x.isFinite)
                  .fold(0.0, math.max);
    final bands = [
      for (final key in ['a', 'b', 'difference']) erpNumbers(data['sem_$key']),
    ];
    for (var k = 0; k < arrays.length && k < bands.length; k++) {
      if (!decode &&
          bands[k].length == times.length &&
          arrays[k].length == times.length) {
        for (var i = 0; i < times.length; i++) {
          min = math.min(min, arrays[k][i] - bands[k][i]);
          max = math.max(max, arrays[k][i] + bands[k][i]);
        }
      }
    }
    if (!decode) {
      for (final row in data['overlays'] as List? ?? []) {
        for (final value in erpNumbers(row).where((v) => v.isFinite)) {
          min = math.min(min, value);
          max = math.max(max, value);
        }
      }
    }
    final pad = decode ? 0.0 : math.max((max - min) * .1, .1);
    min -= pad;
    max += pad;
    if (max == min) max = min + 1;
    double x(double t) =>
        ax.left + (t - times.first) / (times.last - times.first) * ax.width;
    double y(double v) => negativeUp && !decode
        ? ax.top + (v - min) / (max - min) * ax.height
        : ax.bottom - (v - min) / (max - min) * ax.height;
    final grid = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;
    for (var k = 0; k <= 5; k++) {
      final t = times.first + (times.last - times.first) * k / 5;
      canvas.drawLine(Offset(x(t), ax.top), Offset(x(t), ax.bottom), grid);
      erpText(
        canvas,
        '${(t * 1000).round()}',
        Offset(x(t) - 14, ax.bottom + 8),
        size: 10,
      );
      final v = min + (max - min) * k / 5;
      canvas.drawLine(Offset(ax.left, y(v)), Offset(ax.right, y(v)), grid);
      erpText(
        canvas,
        v.toStringAsFixed(decode ? 1 : 2),
        Offset(4, y(v) - 6),
        size: 10,
      );
    }
    canvas.save();
    canvas.clipRect(ax);
    if (!decode && profile['window'] is List) {
      final w = erpNumbers(profile['window']);
      canvas.drawRect(
        Rect.fromLTRB(x(w[0]), ax.top, x(w[1]), ax.bottom),
        Paint()..color = const Color(0x147C3AED),
      );
    }
    if (times.first <= 0 && times.last >= 0)
      canvas.drawLine(
        Offset(x(0), ax.top),
        Offset(x(0), ax.bottom),
        Paint()..color = const Color(0xFF94A3B8),
      );
    canvas.drawLine(
      Offset(ax.left, y(decode ? 0.5 : 0)),
      Offset(ax.right, y(decode ? 0.5 : 0)),
      Paint()..color = const Color(0xFF94A3B8),
    );
    if (!decode) {
      for (var k = 0; k < arrays.length && k < bands.length; k++) {
        final band = bands[k];
        if (band.length != times.length || arrays[k].length != times.length)
          continue;
        final path = Path()
          ..moveTo(x(times.first), y(arrays[k].first - band.first));
        for (var i = 1; i < times.length; i++) {
          path.lineTo(x(times[i]), y(arrays[k][i] - band[i]));
        }
        for (var i = times.length - 1; i >= 0; i--) {
          path.lineTo(x(times[i]), y(arrays[k][i] + band[i]));
        }
        canvas.drawPath(
          path..close(),
          Paint()..color = colors[k].withValues(alpha: .13),
        );
      }
      for (final row in data['overlays'] as List? ?? []) {
        final values = erpNumbers(row);
        final path = Path();
        for (var i = 0; i < times.length && i < values.length; i++) {
          if (i == 0) {
            path.moveTo(x(times[i]), y(values[i]));
          } else {
            path.lineTo(x(times[i]), y(values[i]));
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0x447C3AED)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8,
        );
      }
    }
    for (var k = 0; k < arrays.length; k++) {
      final path = Path();
      var started = false;
      for (var i = 0; i < math.min(times.length, arrays[k].length); i++) {
        final v = arrays[k][i];
        if (!v.isFinite) {
          started = false;
          continue;
        }
        if (started) {
          path.lineTo(x(times[i]), y(v));
        } else {
          path.moveTo(x(times[i]), y(v));
          started = true;
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[k]
          ..strokeWidth = (k == 2 ? 1.3 : 1.8)
          ..style = PaintingStyle.stroke,
      );
    }
    if (hoverX != null) {
      final t =
          times.first +
          ((hoverX! - ax.left) / ax.width).clamp(0.0, 1.0) *
              (times.last - times.first);
      canvas.drawLine(
        Offset(x(t), ax.top),
        Offset(x(t), ax.bottom),
        Paint()..color = const Color(0xFF7C3AED),
      );
      final i = times.indexWhere((v) => v >= t);
      if (i >= 0) {
        final values = [
          for (var k = 0; k < arrays.length; k++)
            if (i < arrays[k].length)
              '${names[k]} ${arrays[k][i].toStringAsFixed(2)}',
        ];
        erpText(
          canvas,
          '${(t * 1000).round()} ms  ${values.join(' · ')}',
          Offset(ax.left + 8, ax.top + 6),
          size: 11,
          maxWidth: ax.width - 16,
        );
      }
    }
    canvas.restore();
    for (var k = 0; k < names.length; k++)
      erpText(
        canvas,
        names[k],
        Offset(65 + k * math.max(100, (size.width - 80) / 3), 10),
        size: 11,
        color: colors[k],
        maxWidth: math.max(100, (size.width - 80) / 3) - 8,
      );
    erpText(
      canvas,
      'Time (ms)',
      Offset(ax.center.dx - 30, size.height - 16),
      size: 11,
    );
    erpText(canvas, decode ? 'Score' : 'µV', const Offset(6, 27), size: 11);
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchWavePainter old) => true;
}

class ErpWorkbenchTopoPainter extends CustomPainter {
  ErpWorkbenchTopoPainter(this.data);
  final Map<String, dynamic> data;
  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final labels = (data['labels'] as List? ?? []).cast<String>();
    final values = erpNumbers(data['topo_difference']);
    final p = erpNumbers(data['topo_p_fwer']);
    final known = {
      for (final name in kStandard1020Topo.keys) name.toUpperCase(): name,
    };
    final indices = [
      for (var i = 0; i < labels.length; i++)
        if (known.containsKey(labels[i].toUpperCase()) && i < values.length) i,
    ];
    if (indices.length < 4) {
      erpText(
        c,
        'Topography needs at least four channels with known positions.',
        const Offset(12, 20),
        maxWidth: size.width - 24,
      );
      return;
    }
    final ch = [for (final i in indices) known[labels[i].toUpperCase()]!];
    final v = [for (final i in indices) values[i]];
    final scale = v.fold(.01, (a, b) => math.max(a, b.abs()));
    paintTopomap(
      c,
      Rect.fromLTWH(0, 20, size.width - 80, size.height - 40),
      TopoInterpolator.forChannels(ch),
      v,
      vmin: -scale,
      vmax: scale,
      cmap: 'RdBu_r',
      highlight: p.length == labels.length
          ? [for (final i in indices) p[i] <= .05]
          : null,
      fittedHead: true,
      contours: true,
    );
    erpText(c, 'B - A (µV)', const Offset(12, 2), size: 12);
    final bar = Rect.fromLTWH(
      size.width - 62,
      size.height * .25,
      10,
      size.height * .5,
    );
    paintColorbar(c, bar, cmap: 'RdBu_r');
    erpText(
      c,
      scale.toStringAsFixed(2),
      Offset(bar.right + 4, bar.top - 5),
      size: 9,
      maxWidth: 48,
    );
    erpText(
      c,
      '0',
      Offset(bar.right + 4, bar.center.dy - 5),
      size: 9,
      maxWidth: 48,
    );
    erpText(
      c,
      (-scale).toStringAsFixed(2),
      Offset(bar.right + 4, bar.bottom - 5),
      size: 9,
      maxWidth: 48,
    );
    if (p.isNotEmpty)
      erpText(c, 'Rings: pFWER ≤ .05', Offset(12, size.height - 18), size: 10);
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchTopoPainter old) => old.data != data;
}

class ErpWorkbenchHeatPainter extends CustomPainter {
  ErpWorkbenchHeatPainter(
    this.values,
    this.rows,
    this.columns, {
    this.probability = false,
  });
  final List<double> values;
  final int rows, columns;
  final bool probability;
  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    if (rows <= 0 || columns <= 0) return;
    final scale = values
        .where((v) => v.isFinite)
        .fold(.01, (a, b) => math.max(a, b.abs()));
    for (var i = 0; i < rows; i++) {
      for (var j = 0; j < columns; j++) {
        final k = i * columns + j;
        if (k >= values.length) continue;
        final v = values[k];
        final q = probability ? (v - .5) * 2 : v / scale;
        final color = !v.isFinite
            ? const Color(0xFFE2E8F0)
            : q >= 0
            ? Color.lerp(
                const Color(0xFFFFFFFF),
                const Color(0xFFDC2626),
                q.abs().clamp(0.0, 1.0),
              )!
            : Color.lerp(
                const Color(0xFFFFFFFF),
                const Color(0xFF2563EB),
                q.abs().clamp(0.0, 1.0),
              )!;
        c.drawRect(
          Rect.fromLTWH(
            j * size.width / columns,
            i * size.height / rows,
            size.width / columns + .5,
            size.height / rows + .5,
          ),
          Paint()..color = color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchHeatPainter old) => true;
}

Future<Uint8List> erpPainterPng(
  CustomPainter painter, {
  int width = 1200,
  int height = 450,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}
