// lib/src/topostats/mpl_ticker.dart
//
// Port of the matplotlib (3.10) tick machinery the reference figure relies
// on: MaxNLocator / AutoLocator tick selection (incl. 'auto' nbins from the
// axis length), ScalarFormatter label formatting (offset + precision) and
// the view-interval filtering done in Axis._update_ticks.

import 'dart:math' as math;

/// Python float divmod(x, y) (CPython float_divmod, bit-for-bit).
(double, double) pyDivmod(double x, double y) {
  var mod = x.remainder(y); // C fmod
  var div = (x - mod) / y;
  if (mod != 0) {
    if ((y < 0) != (mod < 0)) {
      mod += y;
      div -= 1.0;
    }
  } else {
    mod = y < 0 ? -0.0 : 0.0;
  }
  double floordiv;
  if (div != 0) {
    floordiv = div.floorToDouble();
    if (div - floordiv > 0.5) floordiv += 1.0;
  } else {
    floordiv = (x / y) < 0 ? -0.0 : 0.0;
  }
  return (floordiv, mod);
}

double _log10(double x) => math.log(x) / math.ln10;

/// floor(log10(x)) robust to the last-ulp error of log(x)/ln10 at exact
/// powers of ten (Python's math.log10 is exact there).
int floorLog10(double x) {
  var e = _log10(x).floor();
  while (math.pow(10.0, e + 1) <= x) {
    e++;
  }
  while (math.pow(10.0, e) > x) {
    e--;
  }
  return e;
}

/// ceil(log10(x)), same care as [floorLog10].
int ceilLog10(double x) {
  final f = floorLog10(x);
  return math.pow(10.0, f) == x ? f : f + 1;
}

/// matplotlib.transforms.nonsingular(vmin, vmax, expander, tiny)
(double, double) nonsingular(
  double vmin,
  double vmax, {
  double expander = 1e-13,
  double tiny = 1e-14,
}) {
  if (!vmin.isFinite || !vmax.isFinite) return (-expander, expander);
  if (vmax < vmin) {
    final t = vmin;
    vmin = vmax;
    vmax = t;
  }
  final maxabs = math.max(vmin.abs(), vmax.abs());
  if (maxabs < (1e6 / tiny) * 2.2250738585072014e-308) {
    vmin = -expander;
    vmax = expander;
  } else if (vmax - vmin <= maxabs * tiny) {
    if (vmax == 0 && vmin == 0) {
      vmin = -expander;
      vmax = expander;
    } else {
      vmin -= expander * vmin.abs();
      vmax += expander * vmax.abs();
    }
  }
  return (vmin, vmax);
}

(double, double) _scaleRange(
  double vmin,
  double vmax,
  int n, {
  double threshold = 100,
}) {
  final dv = (vmax - vmin).abs();
  final meanv = (vmax + vmin) / 2;
  double offset;
  if (meanv.abs() / dv < threshold) {
    offset = 0;
  } else {
    offset =
        math.pow(10.0, floorLog10(meanv.abs())).toDouble() *
        (meanv < 0 ? -1 : 1);
  }
  final scale = math.pow(10.0, floorLog10(dv / n)).toDouble();
  return (scale, offset);
}

class _EdgeInteger {
  _EdgeInteger(this.step, double offset) : _offset = offset.abs();
  final double step;
  final double _offset;

  bool closeto(double ms, double edge) {
    double tol;
    if (_offset > 0) {
      final digits = _log10(_offset / step);
      tol = math.max(1e-10, math.pow(10, digits - 12).toDouble());
      tol = math.min(0.4999, tol);
    } else {
      tol = 1e-10;
    }
    return (ms - edge).abs() < tol;
  }

  double le(double x) {
    final (d, m) = pyDivmod(x, step);
    if (closeto(m / step, 1)) return d + 1;
    return d;
  }

  double ge(double x) {
    final (d, m) = pyDivmod(x, step);
    if (closeto(m / step, 0)) return d;
    return d + 1;
  }
}

class MaxNLocator {
  /// [nbins] null means 'auto' (needs [tickSpace]).
  MaxNLocator({
    this.nbins,
    List<double>? steps,
    this.minNTicks = 2,
    this.tickSpace,
  }) {
    var st =
        steps ??
        const <double>[1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0];
    if (steps != null) {
      if (st.first != 1) st = <double>[1.0, ...st];
      if (st.last != 10) st = <double>[...st, 10.0];
    }
    _steps = st;
    _extended = [
      for (var i = 0; i < st.length - 1; i++) 0.1 * st[i],
      ...st,
      10 * st[1],
    ];
  }

  /// AutoLocator: nbins='auto', steps=[1, 2, 2.5, 5, 10].
  factory MaxNLocator.auto(int tickSpace) => MaxNLocator(
    steps: const <double>[1.0, 2.0, 2.5, 5.0, 10.0],
    tickSpace: tickSpace,
  );

  final int? nbins;
  final int minNTicks;
  final int? tickSpace;
  late final List<double> _steps;
  late final List<double> _extended;

  List<double> get steps => _steps;

  List<double> _rawTicks(double vmin, double vmax) {
    int nb;
    if (nbins == null) {
      nb = (tickSpace ?? 9).clamp(math.max(1, minNTicks - 1), 9);
    } else {
      nb = nbins!;
    }
    final (scale, offset) = _scaleRange(vmin, vmax, nb);
    final v0 = vmin - offset;
    final v1 = vmax - offset;
    final steps = [for (final s in _extended) s * scale];
    final rawStep = (v1 - v0) / nb;
    var istep = steps.length - 1;
    for (var i = 0; i < steps.length; i++) {
      if (steps[i] >= rawStep) {
        istep = i;
        break;
      }
    }
    var ticks = <double>[];
    for (var k = istep; k >= 0; k--) {
      final step = steps[k];
      final bestVmin = pyDivmod(v0, step).$1 * step;
      final edge = _EdgeInteger(step, offset);
      final low = edge.le(v0 - bestVmin);
      final high = edge.ge(v1 - bestVmin);
      ticks = [];
      // np.arange(low, high + 1)
      final count = (high + 1 - low).ceil();
      for (var j = 0; j < count; j++) {
        ticks.add((low + j) * step + bestVmin);
      }
      final nticks = ticks.where((t) => t <= v1 && t >= v0).length;
      if (nticks >= minNTicks) break;
    }
    return [for (final t in ticks) t + offset];
  }

  List<double> tickValues(double vmin, double vmax) {
    final (a, b) = nonsingular(vmin, vmax);
    return _rawTicks(a, b);
  }
}

/// XAxis.get_tick_space: floor(length_pt / (labelsize * 3)).
int xTickSpace(double axisLengthPt, double labelSizePt) =>
    (axisLengthPt / (labelSizePt * 3)).floor();

/// YAxis.get_tick_space: floor(length_pt / (labelsize * 2)).
int yTickSpace(double axisLengthPt, double labelSizePt) =>
    (axisLengthPt / (labelSizePt * 2)).floor();

double _rint(double x) {
  final r = x.roundToDouble();
  if ((r - x).abs() == 0.5) return 2.0 * (x / 2.0).roundToDouble();
  return r;
}

/// Ticks to draw + labels + offset text, the way Axis._update_ticks and the
/// default ScalarFormatter produce them.
class AxisTicks {
  AxisTicks(this.locs, this.labels, this.offsetText);
  final List<double> locs;
  final List<String> labels;
  final String offsetText;

  static AxisTicks compute(MaxNLocator loc, double vmin, double vmax) {
    final all = loc.tickValues(vmin, vmax);
    final f = ScalarFormatter(vmin, vmax)..setLocs(all);
    final lo = math.min(vmin, vmax), hi = math.max(vmin, vmax);
    final tol = (hi - lo) * 1e-10;
    final shown = <double>[];
    final labels = <String>[];
    for (final t in all) {
      if (t >= lo - tol && t <= hi + tol) {
        shown.add(t);
        labels.add(f.format(t));
      }
    }
    return AxisTicks(shown, labels, f.offsetString());
  }
}

class ScalarFormatter {
  ScalarFormatter(this.vmin, this.vmax);
  final double vmin, vmax;
  List<double> locs = [];
  double offset = 0;
  int orderOfMagnitude = 0;
  int decimals = 0;

  static const int _offsetThreshold = 4;
  static const List<int> _powerLimits = [-5, 6];

  void setLocs(List<double> l) {
    locs = l;
    if (locs.isEmpty) return;
    _computeOffset();
    _setOrderOfMagnitude();
    _setFormat();
  }

  List<double> get _visible {
    final lo = math.min(vmin, vmax), hi = math.max(vmin, vmax);
    return [
      for (final x in locs)
        if (lo <= x && x <= hi) x,
    ];
  }

  void _computeOffset() {
    final v = _visible;
    if (v.isEmpty) {
      offset = 0;
      return;
    }
    final lmin = v.reduce(math.min), lmax = v.reduce(math.max);
    if (lmin == lmax || (lmin <= 0 && 0 <= lmax)) {
      offset = 0;
      return;
    }
    final a = [lmin.abs(), lmax.abs()]..sort();
    final absMin = a[0], absMax = a[1];
    final sign = lmin < 0 ? -1.0 : 1.0;
    final oomMax = ceilLog10(absMax).toDouble();
    double p10(double o) => math.pow(10, o).toDouble();
    double fdiv(double x, double y) => pyDivmod(x, y).$1;
    var oom = oomMax;
    while (fdiv(absMin, p10(oom)) == fdiv(absMax, p10(oom))) {
      oom -= 1;
    }
    oom += 1;
    if ((absMax - absMin) / p10(oom) <= 1e-2) {
      var o2 = oomMax;
      while (!(fdiv(absMax, p10(o2)) - fdiv(absMin, p10(o2)) > 1)) {
        o2 -= 1;
      }
      oom = o2 + 1;
    }
    final n = _offsetThreshold - 1;
    offset = fdiv(absMax, p10(oom)) >= math.pow(10, n)
        ? sign * fdiv(absMax, p10(oom)) * p10(oom)
        : 0;
  }

  void _setOrderOfMagnitude() {
    final v = _visible.map((x) => x.abs()).toList();
    if (v.isEmpty) {
      orderOfMagnitude = 0;
      return;
    }
    int oom;
    if (offset != 0) {
      oom = floorLog10(vmax - vmin);
    } else {
      final val = v.reduce(math.max);
      oom = val == 0 ? 0 : floorLog10(val);
    }
    if (oom <= _powerLimits[0] || oom >= _powerLimits[1]) {
      orderOfMagnitude = oom;
    } else {
      orderOfMagnitude = 0;
    }
  }

  void _setFormat() {
    final src = locs.length < 2 ? [...locs, vmin, vmax] : locs;
    final scale = math.pow(10, orderOfMagnitude).toDouble();
    var l = [for (final x in src) (x - offset) / scale];
    var range = l.reduce(math.max) - l.reduce(math.min);
    if (range == 0) range = l.map((x) => x.abs()).reduce(math.max);
    if (range == 0) range = 1;
    if (locs.length < 2) l = l.sublist(0, l.length - 2);
    final rangeOom = floorLog10(range);
    var sig = math.max(0, 3 - rangeOom);
    final thresh = 1e-3 * math.pow(10, rangeOom);
    while (sig >= 0) {
      final p = math.pow(10, sig).toDouble();
      var mx = 0.0;
      for (final x in l) {
        mx = math.max(mx, (x - _rint(x * p) / p).abs());
      }
      if (mx < thresh) {
        sig -= 1;
      } else {
        break;
      }
    }
    decimals = sig + 1;
  }

  String format(double x) {
    if (locs.isEmpty) return '';
    var xp = (x - offset) / math.pow(10, orderOfMagnitude);
    if (xp.abs() < 1e-8) xp = 0;
    return _fixMinus(xp.toStringAsFixed(decimals));
  }

  String _formatData(double value) {
    final e = floorLog10(value.abs());
    final s = double.parse((value / math.pow(10, e)).toStringAsFixed(10));
    final sig = s % 1 == 0 ? s.toInt().toString() : _g10(s);
    if (e == 0) return sig;
    return '${sig}e$e';
  }

  String _g10(double v) {
    var t = v.toStringAsPrecision(10);
    if (t.contains('.') && !t.contains('e')) {
      t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return t;
  }

  String offsetString() {
    if (locs.isEmpty) return '';
    if (orderOfMagnitude == 0 && offset == 0) return '';
    var off = '';
    var sci = '';
    if (offset != 0) {
      off = _formatData(offset);
      if (offset > 0) off = '+$off';
    }
    if (orderOfMagnitude != 0) sci = '1e$orderOfMagnitude';
    return _fixMinus(sci + off);
  }

  static String _fixMinus(String s) => s.replaceAll('-', '−');
}
