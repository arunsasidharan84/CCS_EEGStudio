// lib/src/topostats/topo_interp.dart
//
// Port of mne.viz.plot_topomap's interpolation pipeline:
//
//   pos      = _find_topomap_coords(info)            (standard_1020, sphere 0.095)
//   outlines = _make_head_outlines(sphere, pos, 'head')
//   extent, Xi, Yi, interp = _setup_interp(pos, res=64, 'cubic', 'head', ...)
//   Zi = CloughTocher2DInterpolator(tri, values + border='mean')(Xi, Yi)
//
// The Clough-Tocher implementation is a line-by-line port of
// scipy/interpolate/_interpnd.pyx (gradient estimation by global curvature
// minimisation + _clough_tocher_2d_single). For the reference 32-channel cap
// the Qhull triangulation is embedded so the result is identical to MNE's
// (verified: max |ΔZi| = 6.6e-15). Other channel sets use a Bowyer-Watson
// Delaunay triangulation with MNE's head-extrapolation points.
//
// Also: contour-level selection (matplotlib MaxNLocator(N+1, min_n_ticks=1)
// + _autolev trimming) and marching-squares contour lines.

import 'dart:math' as math;
import 'dart:typed_data';

import 'mne_constants.dart';
import 'mpl_ticker.dart';

typedef Pt = ({double x, double y});

bool _isDefault32(List<String> chans) {
  if (chans.length != kDefault32Channels.length) return false;
  for (var i = 0; i < chans.length; i++) {
    if (chans[i] != kDefault32Channels[i]) return false;
  }
  return true;
}

/// Whether MNE's standard_1020 montage has a position for [label].
bool isStandard1020Channel(String label) =>
    kStandard1020Topo.containsKey(label) ||
    kStandard1020Topo.keys.any((k) => k.toUpperCase() == label.toUpperCase());

/// Topomap coordinates for [channels] (throws for channels not in
/// standard_1020, like MNE's set_montage would).
List<Pt> topoPositions(List<String> channels) {
  final upper = {for (final k in kStandard1020Topo.keys) k.toUpperCase(): k};
  return [
    for (final c in channels)
      () {
        final key = kStandard1020Topo.containsKey(c)
            ? c
            : upper[c.toUpperCase()];
        if (key == null) {
          throw ArgumentError(
            "Channel '$c' is not in the standard_1020 montage",
          );
        }
        final p = kStandard1020Topo[key]!;
        return (x: p[0], y: p[1]);
      }(),
  ];
}

// ─────────────────────────────────────────────────────────────────────────
//  Delaunay (Bowyer-Watson) -- used for non-default channel sets
// ─────────────────────────────────────────────────────────────────────────

List<List<int>> delaunay(List<Pt> pts) {
  final n = pts.length;
  if (n < 3) return [];
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x);
    maxY = math.max(maxY, p.y);
  }
  final d = math.max(maxX - minX, maxY - minY) * 20 + 1e-9;
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  final all = [
    ...pts,
    (x: cx - d, y: cy - d),
    (x: cx + d, y: cy - d),
    (x: cx, y: cy + d),
  ];
  // triangles as [a, b, c, ccx, ccy, r2]
  final tris = <List<double>>[];
  List<double> mk(int a, int b, int c) {
    final ax = all[a].x, ay = all[a].y;
    final bx = all[b].x, by = all[b].y;
    final cx2 = all[c].x, cy2 = all[c].y;
    final dd = 2 * (ax * (by - cy2) + bx * (cy2 - ay) + cx2 * (ay - by));
    final ux =
        ((ax * ax + ay * ay) * (by - cy2) +
            (bx * bx + by * by) * (cy2 - ay) +
            (cx2 * cx2 + cy2 * cy2) * (ay - by)) /
        dd;
    final uy =
        ((ax * ax + ay * ay) * (cx2 - bx) +
            (bx * bx + by * by) * (ax - cx2) +
            (cx2 * cx2 + cy2 * cy2) * (bx - ax)) /
        dd;
    final r2 = (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy);
    return [a.toDouble(), b.toDouble(), c.toDouble(), ux, uy, r2];
  }

  tris.add(mk(n, n + 1, n + 2));
  for (var i = 0; i < n; i++) {
    final p = all[i];
    final bad = <List<double>>[];
    for (final t in tris) {
      final dx = p.x - t[3], dy = p.y - t[4];
      if (dx * dx + dy * dy < t[5] * (1 - 1e-12)) bad.add(t);
    }
    // boundary edges of the cavity
    final edgeCount = <String, List<int>>{};
    for (final t in bad) {
      final v = [t[0].toInt(), t[1].toInt(), t[2].toInt()];
      for (var k = 0; k < 3; k++) {
        final a = v[k], b = v[(k + 1) % 3];
        final key = a < b ? '$a,$b' : '$b,$a';
        edgeCount.putIfAbsent(key, () => []).addAll([a, b]);
      }
    }
    tris.removeWhere(bad.contains);
    edgeCount.forEach((_, e) {
      if (e.length == 2) tris.add(mk(e[0], e[1], i));
    });
  }
  final out = <List<int>>[];
  for (final t in tris) {
    final v = [t[0].toInt(), t[1].toInt(), t[2].toInt()];
    if (v.any((x) => x >= n)) continue;
    // counter-clockwise orientation (Qhull convention irrelevant for CT)
    final a = pts[v[0]], b = pts[v[1]], c = pts[v[2]];
    final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    out.add(cross >= 0 ? v : [v[0], v[2], v[1]]);
  }
  return out;
}

/// mne.channels.find_ch_adjacency(info, 'eeg') as neighbour lists
/// (Delaunay neighbours of the 2-D topomap positions, plus self).
List<List<int>> buildChannelAdjacency(List<String> channels) {
  if (_isDefault32(channels)) {
    return [for (final l in kDefault32Adjacency) List<int>.from(l)];
  }
  final pos = topoPositions(channels);
  final n = pos.length;
  final sets = List.generate(n, (i) => <int>{i});
  for (final t in delaunay(pos)) {
    for (final a in t) {
      for (final b in t) {
        sets[a].add(b);
      }
    }
  }
  return [for (final s in sets) (s.toList()..sort())];
}

// ─────────────────────────────────────────────────────────────────────────
//  Head outlines (mne.viz.topomap._make_head_outlines)
// ─────────────────────────────────────────────────────────────────────────

class HeadOutlines {
  HeadOutlines._(
    this.head,
    this.nose,
    this.earLeft,
    this.earRight,
    this.clipRadius,
    this.radius,
  );

  factory HeadOutlines.forPositions(
    List<Pt> pos, {
    double radius = kHeadRadius,
  }) {
    final head = <Pt>[
      for (var i = 0; i <= 100; i++)
        (
          x: math.cos(2 * math.pi * i / 100) * radius,
          y: math.sin(2 * math.pi * i / 100) * radius,
        ),
    ];
    // dx = exp(i * arccos(deg2rad(12)))
    final ang = math.acos(12 * math.pi / 180);
    final ndx = math.cos(ang), ndy = math.sin(ang);
    final nose = <Pt>[
      (x: -ndx * radius, y: ndy * radius),
      (x: 0, y: 1.15 * radius),
      (x: ndx * radius, y: ndy * radius),
    ];
    const earX = [
      0.497,
      0.510,
      0.518,
      0.5299,
      0.5419,
      0.54,
      0.547,
      0.532,
      0.510,
      0.489,
    ];
    const earY = [
      0.0555,
      0.0775,
      0.0783,
      0.0746,
      0.0555,
      -0.0055,
      -0.0932,
      -0.1313,
      -0.1384,
      -0.1199,
    ];
    final earR = <Pt>[
      for (var i = 0; i < earX.length; i++)
        (x: earX[i] * radius * 2, y: earY[i] * radius * 2),
    ];
    final earL = [for (final p in earR) (x: -p.x, y: p.y)];
    var maxNorm = 0.0;
    for (final p in pos) {
      maxNorm = math.max(maxNorm, math.sqrt(p.x * p.x + p.y * p.y));
    }
    final maskScale = math.max(1.0, maxNorm * 1.01 / radius);
    return HeadOutlines._(head, nose, earL, earR, radius * maskScale, radius);
  }

  final List<Pt> head, nose, earLeft, earRight;

  /// Radius of the image clip circle (and half-size of the image extent).
  final double clipRadius;
  final double radius;

  /// View limits matplotlib's autoscaling gives a topomap Axes: data limits
  /// of the image extent + outlines (clip_on=False lines), expanded by the
  /// default 5% margins but never across the image's sticky edges.
  ({double x0, double x1, double y0, double y1}) get axesLimits {
    var x0 = -clipRadius, x1 = clipRadius, y0 = -clipRadius, y1 = clipRadius;
    for (final l in [head, nose, earLeft, earRight]) {
      for (final p in l) {
        x0 = math.min(x0, p.x);
        x1 = math.max(x1, p.x);
        y0 = math.min(y0, p.y);
        y1 = math.max(y1, p.y);
      }
    }
    (double, double) expand(double a, double b) {
      final sticky = [-clipRadius, clipRadius];
      final tol = 1e-5 * (b - a).abs();
      double? lo, hi;
      for (final s in sticky) {
        if (s <= a + tol) lo = lo == null ? s : math.max(lo, s);
        if (s >= b - tol) hi = hi == null ? s : math.min(hi, s);
      }
      final m = 0.05 * (b - a);
      var na = a - m, nb = b + m;
      if (lo != null) na = math.max(na, lo);
      if (hi != null) nb = math.min(nb, hi);
      return (na, nb);
    }

    final (ex0, ex1) = expand(x0, x1);
    final (ey0, ey1) = expand(y0, y1);
    return (x0: ex0, x1: ex1, y0: ey0, y1: ey1);
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Interpolator
// ─────────────────────────────────────────────────────────────────────────

class TopoInterpolator {
  TopoInterpolator._({
    required this.channels,
    required this.pos,
    required this.points,
    required this.simplices,
    required this.outlines,
    required this.res,
  }) {
    final n = points.length;
    // vertex_neighbor_vertices in scipy insertion order
    final vn = List.generate(n, (_) => <int>[]);
    for (final s in simplices) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 3; k++) {
          if (s[j] != s[k] && !vn[s[j]].contains(s[k])) vn[s[j]].add(s[k]);
        }
      }
    }
    _vn = [for (final l in vn) Int32List.fromList(l)];
    // neighbours opposite each vertex
    final edge = <int, List<int>>{};
    int key(int a, int b) => a < b ? a * 100000 + b : b * 100000 + a;
    for (var i = 0; i < simplices.length; i++) {
      final s = simplices[i];
      for (var k = 0; k < 3; k++) {
        edge.putIfAbsent(key(s[(k + 1) % 3], s[(k + 2) % 3]), () => []).add(i);
      }
    }
    _nb = [
      for (var i = 0; i < simplices.length; i++)
        [
          for (var k = 0; k < 3; k++)
            edge[key(simplices[i][(k + 1) % 3], simplices[i][(k + 2) % 3])]!
                .firstWhere((x) => x != i, orElse: () => -1),
        ],
    ];
    // G[k] (affine-invariant edge directions) depend only on geometry.
    _g = [for (var i = 0; i < simplices.length; i++) _gTerms(i)];

    // Grid (np.linspace over the extent) and per-node simplex lookup.
    final cr = outlines.clipRadius;
    xs = Float64List(res);
    ys = Float64List(res);
    for (var i = 0; i < res; i++) {
      xs[i] = -cr + (2 * cr) * i / (res - 1);
      ys[i] = -cr + (2 * cr) * i / (res - 1);
    }
    _cellSimplex = Int32List(res * res);
    _cellBary = Float64List(res * res * 3);
    for (var iy = 0; iy < res; iy++) {
      for (var ix = 0; ix < res; ix++) {
        final idx = iy * res + ix;
        _cellSimplex[idx] = -1;
        for (var si = 0; si < simplices.length; si++) {
          final b = _bary(si, xs[ix], ys[iy]);
          final eps = 100 * 2.220446049250313e-16;
          if (b[0] >= -eps && b[1] >= -eps && b[2] >= -eps) {
            _cellSimplex[idx] = si;
            _cellBary[idx * 3] = b[0];
            _cellBary[idx * 3 + 1] = b[1];
            _cellBary[idx * 3 + 2] = b[2];
            break;
          }
        }
      }
    }
  }

  /// Builds (and caches) the interpolator for a channel set.
  factory TopoInterpolator.forChannels(List<String> channels, {int res = 64}) {
    final key = '${channels.join(',')}@$res';
    return _cache.putIfAbsent(key, () {
      final pos = topoPositions(channels);
      final outlines = HeadOutlines.forPositions(pos);
      List<Pt> extra;
      List<List<int>> simp;
      if (_isDefault32(channels)) {
        extra = [for (final p in kDefault32InterpExtra) (x: p[0], y: p[1])];
        simp = [for (final s in kDefault32InterpSimplices) List<int>.from(s)];
      } else {
        extra = _headExtraPoints(pos, outlines.clipRadius);
        simp = delaunay([...pos, ...extra]);
      }
      return TopoInterpolator._(
        channels: channels,
        pos: pos,
        points: [...pos, ...extra],
        simplices: simp,
        outlines: outlines,
        res: res,
      );
    });
  }

  static final Map<String, TopoInterpolator> _cache = {};

  final List<String> channels;
  final List<Pt> pos;
  final List<Pt> points;
  final List<List<int>> simplices;
  final HeadOutlines outlines;
  final int res;
  late final Float64List xs, ys;
  late final List<Int32List> _vn;
  late final List<List<int>> _nb;
  late final List<List<double>> _g;
  late final Int32List _cellSimplex;
  late final Float64List _cellBary;

  int get nChannels => pos.length;

  List<double> _bary(int si, double x, double y) {
    final s = simplices[si];
    final p1 = points[s[0]], p2 = points[s[1]], p3 = points[s[2]];
    final det = (p2.y - p3.y) * (p1.x - p3.x) + (p3.x - p2.x) * (p1.y - p3.y);
    final l1 = ((p2.y - p3.y) * (x - p3.x) + (p3.x - p2.x) * (y - p3.y)) / det;
    final l2 = ((p3.y - p1.y) * (x - p3.x) + (p1.x - p3.x) * (y - p3.y)) / det;
    return [l1, l2, 1 - l1 - l2];
  }

  List<double> _gTerms(int si) {
    final g = [0.0, 0.0, 0.0];
    for (var k = 0; k < 3; k++) {
      final it = _nb[si][k];
      if (it == -1) {
        g[k] = -0.5;
        continue;
      }
      final t = simplices[it];
      final cx = (points[t[0]].x + points[t[1]].x + points[t[2]].x) / 3;
      final cy = (points[t[0]].y + points[t[1]].y + points[t[2]].y) / 3;
      final c = _bary(si, cx, cy);
      if (k == 0) {
        g[k] = (2 * c[2] + c[1] - 1) / (2 - 3 * c[2] - 3 * c[1]);
      } else if (k == 1) {
        g[k] = (2 * c[0] + c[2] - 1) / (2 - 3 * c[0] - 3 * c[2]);
      } else {
        g[k] = (2 * c[1] + c[0] - 1) / (2 - 3 * c[1] - 3 * c[0]);
      }
    }
    return g;
  }

  /// Values at all interpolation nodes (channels + border='mean' extras).
  Float64List _nodeValues(List<double> v) {
    final n = pos.length;
    final f = Float64List(points.length);
    for (var i = 0; i < n; i++) {
      f[i] = v[i];
    }
    final used = <bool>[];
    final extra = <double>[];
    for (var e = n; e < points.length; e++) {
      var s = 0.0;
      var c = 0;
      for (final k in _vn[e]) {
        if (k < n) {
          s += v[k];
          c++;
        }
      }
      used.add(c > 0);
      extra.add(c > 0 ? s / c : 0.0);
    }
    if (used.any((u) => u) && !used.every((u) => u)) {
      var s = 0.0;
      var c = 0;
      for (var i = 0; i < extra.length; i++) {
        if (used[i]) {
          s += extra[i];
          c++;
        }
      }
      for (var i = 0; i < extra.length; i++) {
        if (!used[i]) extra[i] = s / c;
      }
    }
    for (var i = 0; i < extra.length; i++) {
      f[n + i] = extra[i];
    }
    return f;
  }

  /// scipy estimate_gradients_2d_global (Gauss-Seidel, tol 1e-6, 400 iter).
  Float64List _gradients(Float64List f) {
    final n = points.length;
    final y = Float64List(2 * n);
    for (var iter = 0; iter < 400; iter++) {
      var err = 0.0;
      for (var i = 0; i < n; i++) {
        var q0 = 0.0, q1 = 0.0, q3 = 0.0, s0 = 0.0, s1 = 0.0;
        final pi = points[i];
        for (final j in _vn[i]) {
          final ex = points[j].x - pi.x;
          final ey = points[j].y - pi.y;
          final l = math.sqrt(ex * ex + ey * ey);
          final l3 = l * l * l;
          final f1 = f[i], f2 = f[j];
          final df2 = -ex * y[2 * j] - ey * y[2 * j + 1];
          q0 += 4 * ex * ex / l3;
          q1 += 4 * ex * ey / l3;
          q3 += 4 * ey * ey / l3;
          s0 += (6 * (f1 - f2) - 2 * df2) * ex / l3;
          s1 += (6 * (f1 - f2) - 2 * df2) * ey / l3;
        }
        final q2 = q1;
        final det = q0 * q3 - q1 * q2;
        final r0 = (q3 * s0 - q1 * s1) / det;
        final r1 = (-q2 * s0 + q0 * s1) / det;
        var change = math.max((y[2 * i] + r0).abs(), (y[2 * i + 1] + r1).abs());
        y[2 * i] = -r0;
        y[2 * i + 1] = -r1;
        change /= math.max(1.0, math.max(r0.abs(), r1.abs()));
        err = math.max(err, change);
      }
      if (err < 1e-6) break;
    }
    return y;
  }

  double _ct(
    int si,
    double b0,
    double b1,
    double b2,
    Float64List f,
    Float64List df,
  ) {
    final s = simplices[si];
    final p0 = points[s[0]], p1 = points[s[1]], p2 = points[s[2]];
    final e12x = p1.x - p0.x, e12y = p1.y - p0.y;
    final e23x = p2.x - p1.x, e23y = p2.y - p1.y;
    final e31x = p0.x - p2.x, e31y = p0.y - p2.y;
    final f1 = f[s[0]], f2 = f[s[1]], f3 = f[s[2]];
    final d0x = df[2 * s[0]], d0y = df[2 * s[0] + 1];
    final d1x = df[2 * s[1]], d1y = df[2 * s[1] + 1];
    final d2x = df[2 * s[2]], d2y = df[2 * s[2] + 1];
    final df12 = (d0x * e12x + d0y * e12y);
    final df21 = -(d1x * e12x + d1y * e12y);
    final df23 = (d1x * e23x + d1y * e23y);
    final df32 = -(d2x * e23x + d2y * e23y);
    final df31 = (d2x * e31x + d2y * e31y);
    final df13 = -(d0x * e31x + d0y * e31y);
    final c3000 = f1;
    final c2100 = (df12 + 3 * c3000) / 3;
    final c2010 = (df13 + 3 * c3000) / 3;
    final c0300 = f2;
    final c1200 = (df21 + 3 * c0300) / 3;
    final c0210 = (df23 + 3 * c0300) / 3;
    final c0030 = f3;
    final c1020 = (df31 + 3 * c0030) / 3;
    final c0120 = (df32 + 3 * c0030) / 3;
    final c2001 = (c2100 + c2010 + c3000) / 3;
    final c0201 = (c1200 + c0300 + c0210) / 3;
    final c0021 = (c1020 + c0120 + c0030) / 3;
    final g = _g[si];
    final c0111 =
        (g[0] * (-c0300 + 3 * c0210 - 3 * c0120 + c0030) +
            (-c0300 + 2 * c0210 - c0120 + c0021 + c0201)) /
        2;
    final c1011 =
        (g[1] * (-c0030 + 3 * c1020 - 3 * c2010 + c3000) +
            (-c0030 + 2 * c1020 - c2010 + c2001 + c0021)) /
        2;
    final c1101 =
        (g[2] * (-c3000 + 3 * c2100 - 3 * c1200 + c0300) +
            (-c3000 + 2 * c2100 - c1200 + c2001 + c0201)) /
        2;
    final c1002 = (c1101 + c1011 + c2001) / 3;
    final c0102 = (c1101 + c0111 + c0201) / 3;
    final c0012 = (c1011 + c0111 + c0021) / 3;
    final c0003 = (c1002 + c0102 + c0012) / 3;
    final mv = math.min(b0, math.min(b1, b2));
    final x1 = b0 - mv, x2 = b1 - mv, x3 = b2 - mv, x4 = 3 * mv;
    return x1 * x1 * x1 * c3000 +
        3 * x1 * x1 * x2 * c2100 +
        3 * x1 * x1 * x3 * c2010 +
        3 * x1 * x1 * x4 * c2001 +
        3 * x1 * x2 * x2 * c1200 +
        6 * x1 * x2 * x4 * c1101 +
        3 * x1 * x3 * x3 * c1020 +
        6 * x1 * x3 * x4 * c1011 +
        3 * x1 * x4 * x4 * c1002 +
        x2 * x2 * x2 * c0300 +
        3 * x2 * x2 * x3 * c0210 +
        3 * x2 * x2 * x4 * c0201 +
        3 * x2 * x3 * x3 * c0120 +
        6 * x2 * x3 * x4 * c0111 +
        3 * x2 * x4 * x4 * c0102 +
        x3 * x3 * x3 * c0030 +
        3 * x3 * x3 * x4 * c0021 +
        3 * x3 * x4 * x4 * c0012 +
        x4 * x4 * x4 * c0003;
  }

  /// Zi on the res x res grid (row-major, row = y index from ymin upward).
  /// NaN outside the triangulation (matches scipy fill_value).
  Float64List grid(List<double> values) {
    final f = _nodeValues(values);
    final df = _gradients(f);
    final z = Float64List(res * res);
    for (var i = 0; i < res * res; i++) {
      final si = _cellSimplex[i];
      if (si < 0) {
        z[i] = double.nan;
        continue;
      }
      z[i] = _ct(
        si,
        _cellBary[i * 3],
        _cellBary[i * 3 + 1],
        _cellBary[i * 3 + 2],
        f,
        df,
      );
    }
    return z;
  }
}

/// MNE _get_extra_points(..., extrapolate='head') for a generic montage.
List<Pt> _headExtraPoints(List<Pt> pos, double radius) {
  final tri = delaunay(pos);
  final dists = <double>[];
  double dist(Pt a, Pt b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  for (final t in tri) {
    dists.add(dist(pos[t[0]], pos[t[1]]));
  }
  for (final t in tri) {
    dists.add(dist(pos[t[1]], pos[t[2]]));
  }
  dists.sort();
  final m = dists.length;
  final distance = m == 0
      ? radius / 4
      : (m.isOdd ? dists[m ~/ 2] : (dists[m ~/ 2 - 1] + dists[m ~/ 2]) / 2);
  final angle = math.asin(math.min(distance / radius, 1.0));
  final nP = math.max(12, (2 * math.pi / angle).round());
  final useR = radius * 1.1 + distance;
  return [
    for (var i = 0; i < nP; i++)
      (
        x: math.cos(2 * math.pi * i / nP) * useR,
        y: math.sin(2 * math.pi * i / nP) * useR,
      ),
  ];
}

// ─────────────────────────────────────────────────────────────────────────
//  Contours
// ─────────────────────────────────────────────────────────────────────────

/// matplotlib ContourSet._autolev(N) for integer `contours=N`.
List<double> contourLevels(Float64List z, int n) {
  var zmin = double.infinity, zmax = -double.infinity;
  for (final v in z) {
    if (v.isNaN) continue;
    zmin = math.min(zmin, v);
    zmax = math.max(zmax, v);
  }
  if (!zmin.isFinite) return [];
  final lev = MaxNLocator(nbins: n + 1, minNTicks: 1).tickValues(zmin, zmax);
  var i0 = 0;
  for (var i = 0; i < lev.length; i++) {
    if (lev[i] < zmin) i0 = i;
  }
  var i1 = lev.length;
  for (var i = 0; i < lev.length; i++) {
    if (lev[i] > zmax) {
      i1 = i + 1;
      break;
    }
  }
  if (i1 - i0 < 3) {
    i0 = 0;
    i1 = lev.length;
  }
  return lev.sublist(i0, i1);
}

/// Marching-squares iso-lines of [z] (res x res on xs/ys) at [level], as
/// independent segments [x0, y0, x1, y1] in data coordinates.
List<List<double>> contourSegments(
  Float64List z,
  Float64List xs,
  Float64List ys,
  double level,
) {
  final res = xs.length;
  final out = <List<double>>[];
  double at(int ix, int iy) => z[iy * res + ix];
  for (var iy = 0; iy < res - 1; iy++) {
    for (var ix = 0; ix < res - 1; ix++) {
      final v00 = at(ix, iy), v10 = at(ix + 1, iy);
      final v11 = at(ix + 1, iy + 1), v01 = at(ix, iy + 1);
      if (v00.isNaN || v10.isNaN || v11.isNaN || v01.isNaN) continue;
      var code = 0;
      if (v00 > level) code |= 1;
      if (v10 > level) code |= 2;
      if (v11 > level) code |= 4;
      if (v01 > level) code |= 8;
      if (code == 0 || code == 15) continue;
      final x0 = xs[ix], x1 = xs[ix + 1], y0 = ys[iy], y1 = ys[iy + 1];
      double lerp(double a, double b, double va, double vb) =>
          a + (b - a) * ((level - va) / (vb - va));
      // edge points: bottom(0), right(1), top(2), left(3)
      List<double> e(int k) => switch (k) {
        0 => [lerp(x0, x1, v00, v10), y0],
        1 => [x1, lerp(y0, y1, v10, v11)],
        2 => [lerp(x0, x1, v01, v11), y1],
        _ => [x0, lerp(y0, y1, v00, v01)],
      };
      void seg(int a, int b) {
        final p = e(a), q = e(b);
        out.add([p[0], p[1], q[0], q[1]]);
      }

      switch (code) {
        case 1 || 14:
          seg(3, 0);
        case 2 || 13:
          seg(0, 1);
        case 3 || 12:
          seg(3, 1);
        case 4 || 11:
          seg(1, 2);
        case 6 || 9:
          seg(0, 2);
        case 7 || 8:
          seg(3, 2);
        case 5 || 10:
          final centre = (v00 + v10 + v11 + v01) / 4;
          final centreHigh = centre > level;
          if ((code == 5) == centreHigh) {
            seg(3, 2);
            seg(0, 1);
          } else {
            seg(3, 0);
            seg(1, 2);
          }
      }
    }
  }
  return out;
}
