// lib/src/topostats/topo_paint.dart
//
// Stand-alone MNE-style topomap painter (same interpolation, head outline
// and colormaps as the TopoStats figure) for reports and thumbnails.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'mpl_colormaps.dart';
import 'topo_interp.dart';

/// Paints one topomap of [values] (ordered like [interp.channels]) into
/// [box] (px). Colour limits [vmin]..[vmax] map onto [cmap].
void paintTopomap(
  Canvas canvas,
  Rect box,
  TopoInterpolator interp,
  List<double> values, {
  required double vmin,
  required double vmax,
  String cmap = 'viridis',
  bool sensors = true,
  List<bool>? highlight,
  double outlineWidth = 1.0,
}) {
  final lut = kMplColormaps[cmap] ?? kMplColormaps['viridis']!;
  final lim = interp.outlines.axesLimits;
  final aspect = (lim.y1 - lim.y0) / (lim.x1 - lim.x0);
  Rect ax;
  if (box.width * aspect <= box.height) {
    final h = box.width * aspect;
    ax = Rect.fromLTWH(box.left, box.center.dy - h / 2, box.width, h);
  } else {
    final w = box.height / aspect;
    ax = Rect.fromLTWH(box.center.dx - w / 2, box.top, w, box.height);
  }
  final k = ax.width / (lim.x1 - lim.x0);
  final cr = interp.outlines.clipRadius;

  // Fill NaNs with the mean so the interpolation stays defined.
  final finite = values.where((v) => v.isFinite).toList();
  final fill = finite.isEmpty
      ? 0.0
      : finite.reduce((a, b) => a + b) / finite.length;
  final v = [for (final x in values) x.isFinite ? x : fill];
  final z = interp.grid(v);

  int colorFor(double x) {
    if (x.isNaN) return 0;
    final span = vmax - vmin;
    final n = span == 0 ? 0.5 : (x - vmin) / span;
    return lut[(n * 256).floor().clamp(0, 255)].toSigned(32);
  }

  final res = interp.res;
  final nodes = res + 2;
  final dx = 2 * cr / res;
  final coords = Float64List(nodes);
  for (var i = 0; i < nodes; i++) {
    coords[i] = i == 0 ? -cr : (i == nodes - 1 ? cr : -cr + (i - 0.5) * dx);
  }
  final pos = Float32List(nodes * nodes * 2);
  final col = Int32List(nodes * nodes);
  for (var j = 0; j < nodes; j++) {
    final zj = (j - 1).clamp(0, res - 1);
    for (var i = 0; i < nodes; i++) {
      final zi = (i - 1).clamp(0, res - 1);
      final p = j * nodes + i;
      pos[2 * p] = coords[i];
      pos[2 * p + 1] = coords[j];
      col[p] = colorFor(z[zj * res + zi]);
    }
  }
  final idx = Uint16List((nodes - 1) * (nodes - 1) * 6);
  var q = 0;
  for (var j = 0; j < nodes - 1; j++) {
    for (var i = 0; i < nodes - 1; i++) {
      final a = j * nodes + i, b = a + 1, c = a + nodes, d = c + 1;
      idx[q++] = a;
      idx[q++] = b;
      idx[q++] = d;
      idx[q++] = a;
      idx[q++] = d;
      idx[q++] = c;
    }
  }
  final verts = ui.Vertices.raw(
    ui.VertexMode.triangles,
    pos,
    colors: col,
    indices: idx,
  );

  canvas.save();
  canvas.translate(ax.left - lim.x0 * k, ax.top + lim.y1 * k);
  canvas.scale(k, -k);
  canvas.save();
  canvas.clipPath(
    Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: cr)),
  );
  canvas.drawVertices(verts, BlendMode.dst, Paint());
  canvas.restore();
  if (sensors) {
    final dot = Paint()..color = const Color(0xFF000000);
    final ring = Paint()
      ..color = const Color(0xFF000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 / k;
    for (var c = 0; c < interp.pos.length; c++) {
      final p = interp.pos[c];
      canvas.drawCircle(Offset(p.x, p.y), 0.9 / k, dot);
      if (highlight != null && c < highlight.length && highlight[c]) {
        canvas.drawCircle(Offset(p.x, p.y), 2.6 / k, ring);
      }
    }
  }
  final ol = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = outlineWidth / k
    ..strokeJoin = StrokeJoin.round;
  final o = interp.outlines;
  for (final line in [o.head, o.nose, o.earLeft, o.earRight]) {
    final p = Path()..moveTo(line.first.x, line.first.y);
    for (final pt in line.skip(1)) {
      p.lineTo(pt.x, pt.y);
    }
    canvas.drawPath(p, ol);
  }
  canvas.restore();
}

/// Vertical colourbar with min / max labels drawn by [label].
void paintColorbar(Canvas canvas, Rect r, {String cmap = 'viridis'}) {
  final lut = kMplColormaps[cmap] ?? kMplColormaps['viridis']!;
  for (var i = 0; i < 64; i++) {
    final c = Color(lut[(i * 256 / 64).floor().clamp(0, 255)]);
    final y1 = r.bottom - r.height * i / 64;
    final y0 = r.bottom - r.height * (i + 1) / 64;
    canvas.drawRect(
      Rect.fromLTRB(r.left, y0 - 0.3, r.right, y1 + 0.3),
      Paint()..color = c,
    );
  }
  canvas.drawRect(
    r,
    Paint()
      ..color = const Color(0xFF333333)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.5, r.width / 12),
  );
}
