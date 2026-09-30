// lib/src/erp/sci_stats.dart
//
// Small numpy/scipy equivalents used by the ERP analysis:
//   - pairwise summation (np.sum / np.mean on contiguous 1-D data)
//   - np.std / np.var (ddof), SEM
//   - Student-t survival function and quantile (scipy.stats.t.sf / .ppf)
//   - Welch's t-test (scipy.stats.ttest_ind(equal_var=False))
//   - Cohen's d (pooled SD), np.percentile (linear), np.linspace
//   - scipy.signal.savgol_filter(mode='interp')

import 'dart:math' as math;
import 'dart:typed_data';

// ─────────────────────────── numpy reductions ────────────────────────────

/// numpy's pairwise_sum (blocks of 8 accumulators, 128-element leaves).
double npSum(List<double> a, [int start = 0, int? end]) {
  final e = end ?? a.length;
  return _pairwise(a, start, e - start);
}

double _pairwise(List<double> a, int s, int n) {
  if (n < 8) {
    var r = 0.0;
    for (var i = 0; i < n; i++) {
      r += a[s + i];
    }
    return r;
  } else if (n <= 128) {
    final r = List<double>.generate(8, (i) => a[s + i]);
    var i = 8;
    for (; i < n - (n % 8); i += 8) {
      for (var k = 0; k < 8; k++) {
        r[k] += a[s + i + k];
      }
    }
    var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
    for (; i < n; i++) {
      res += a[s + i];
    }
    return res;
  } else {
    var n2 = n ~/ 2;
    n2 -= n2 % 8;
    return _pairwise(a, s, n2) + _pairwise(a, s + n2, n - n2);
  }
}

double npMean(List<double> a) => a.isEmpty ? double.nan : npSum(a) / a.length;

/// np.var(a, ddof).
double npVar(List<double> a, {int ddof = 0}) {
  final n = a.length;
  if (n - ddof <= 0) return double.nan;
  final m = npMean(a);
  final d = Float64List(n);
  for (var i = 0; i < n; i++) {
    final x = a[i] - m;
    d[i] = x * x;
  }
  return npSum(d) / (n - ddof);
}

double npStd(List<double> a, {int ddof = 0}) => math.sqrt(npVar(a, ddof: ddof));

/// np.linspace(start, stop, num) (endpoint=True).
Float64List npLinspace(double start, double stop, int num) {
  final y = Float64List(num);
  if (num == 1) {
    y[0] = start;
    return y;
  }
  final step = (stop - start) / (num - 1);
  for (var i = 0; i < num; i++) {
    y[i] = i * step + start;
  }
  y[num - 1] = stop;
  return y;
}

/// np.percentile(a, q) with the default 'linear' method (numpy's _lerp).
double npPercentile(List<double> a, double q) {
  final s = List<double>.of(a)..sort();
  final n = s.length;
  if (n == 0) return double.nan;
  final h = (n - 1) * (q / 100.0);
  final lo = math.min(math.max(h.floor(), 0), n - 1);
  final hi = math.min(lo + 1, n - 1);
  final t = h - lo;
  final av = s[lo], bv = s[hi];
  final diff = bv - av;
  return t >= 0.5 ? bv - diff * (1 - t) : av + diff * t;
}

// ─────────────────────────── t distribution ──────────────────────────────

const List<double> _lanczos = [
  0.99999999999980993,
  676.5203681218851,
  -1259.1392167224028,
  771.32342877765313,
  -176.61502916214059,
  12.507343278686905,
  -0.13857109526572012,
  9.9843695780195716e-6,
  1.5056327351493116e-7,
];

/// log Γ(x) for x > 0 (Lanczos, g = 7).
double lgamma(double x) {
  if (x < 0.5) {
    return math.log(math.pi / math.sin(math.pi * x)).toDouble() - lgamma(1 - x);
  }
  x -= 1;
  var a = _lanczos[0];
  final t = x + 7.5;
  for (var i = 1; i < 9; i++) {
    a += _lanczos[i] / (x + i);
  }
  return 0.5 * math.log(2 * math.pi) +
      (x + 0.5) * math.log(t) -
      t +
      math.log(a);
}

/// Continued fraction for the incomplete beta function (modified Lentz).
double _betacf(double a, double b, double x) {
  const tiny = 1e-300;
  const eps = 1e-16;
  final qab = a + b, qap = a + 1, qam = a - 1;
  var c = 1.0;
  var d = 1 - qab * x / qap;
  if (d.abs() < tiny) d = tiny;
  d = 1 / d;
  var h = d;
  for (var m = 1; m <= 10000; m++) {
    final m2 = 2 * m;
    var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
    d = 1 + aa * d;
    if (d.abs() < tiny) d = tiny;
    c = 1 + aa / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    h *= d * c;
    aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
    d = 1 + aa * d;
    if (d.abs() < tiny) d = tiny;
    c = 1 + aa / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final del = d * c;
    h *= del;
    if ((del - 1).abs() < eps) break;
  }
  return h;
}

/// Regularized incomplete beta I_x(a, b).
double betaInc(double a, double b, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final lbt =
      lgamma(a + b) -
      lgamma(a) -
      lgamma(b) +
      a * math.log(x) +
      b * math.log(1 - x);
  final bt = math.exp(lbt);
  if (x < (a + 1) / (a + b + 2)) {
    return bt * _betacf(a, b, x) / a;
  }
  return 1 - bt * _betacf(b, a, 1 - x) / b;
}

/// P(T > t) for Student's t with [df] degrees of freedom.
double tSf(double t, double df) {
  if (t.isNaN || df.isNaN) return double.nan;
  if (t.isInfinite) return t > 0 ? 0 : 1;
  final x = df / (df + t * t);
  final tail = 0.5 * betaInc(df / 2, 0.5, x);
  return t > 0 ? tail : 1 - tail;
}

double tCdf(double t, double df) => 1 - tSf(t, df);

/// Two-sided p-value, 2 * sf(|t|).
double tTwoSidedP(double t, double df) {
  if (t.isNaN || df.isNaN) return double.nan;
  return betaInc(df / 2, 0.5, df / (df + t * t));
}

/// Quantile of Student's t (scipy.stats.t.ppf).
double tPpf(double p, double df) {
  if (p <= 0) return double.negativeInfinity;
  if (p >= 1) return double.infinity;
  if (p == 0.5) return 0;
  if (p < 0.5) return -tPpf(1 - p, df);
  // Bracket, then bisect on the upper tail probability.
  final target = 1 - p;
  var lo = 0.0, hi = 1.0;
  while (tSf(hi, df) > target) {
    lo = hi;
    hi *= 2;
    if (hi > 1e12) break;
  }
  for (var i = 0; i < 200; i++) {
    final mid = 0.5 * (lo + hi);
    if (mid == lo || mid == hi) break;
    if (tSf(mid, df) > target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return 0.5 * (lo + hi);
}

// ─────────────────────────── two-sample tests ────────────────────────────

class WelchResult {
  const WelchResult(this.t, this.df, this.p);
  final double t, df, p;
}

/// scipy.stats.ttest_ind(a, b, equal_var=False).
WelchResult welchTTest(List<double> a, List<double> b) {
  final n1 = a.length.toDouble(), n2 = b.length.toDouble();
  final v1 = npVar(a, ddof: 1), v2 = npVar(b, ddof: 1);
  final vn1 = v1 / n1, vn2 = v2 / n2;
  final df =
      (vn1 + vn2) * (vn1 + vn2) / (vn1 * vn1 / (n1 - 1) + vn2 * vn2 / (n2 - 1));
  final denom = math.sqrt(vn1 + vn2);
  final t = (npMean(a) - npMean(b)) / denom;
  return WelchResult(t, df, tTwoSidedP(t, df));
}

/// Cohen's d with the pooled SD (as in compute_mmn_erp.cohens_d).
double cohensD(List<double> a, List<double> b) {
  final n1 = a.length, n2 = b.length;
  final m1 = npMean(a), m2 = npMean(b);
  final s1 = npStd(a, ddof: 1), s2 = npStd(b, ddof: 1);
  final pooled = math.sqrt(
    ((n1 - 1) * s1 * s1 + (n2 - 1) * s2 * s2) / (n1 + n2 - 2),
  );
  if (pooled == 0) return 0.0;
  return (m1 - m2) / pooled;
}

// ─────────────────────────── Savitzky–Golay ──────────────────────────────

/// Least-squares polynomial fit of degree [order] to y[s..s+n) at x = 0..n-1,
/// evaluated at the integer positions [evalFrom, evalTo).
List<double> _polyFitEval(
  List<double> y,
  int s,
  int n,
  int order,
  int evalFrom,
  int evalTo,
) {
  final c = (n - 1) / 2.0;
  final sc = c == 0 ? 1.0 : c;
  final m = order + 1;
  final ata = List.generate(m, (_) => List<double>.filled(m, 0));
  final atb = List<double>.filled(m, 0);
  for (var i = 0; i < n; i++) {
    final u = (i - c) / sc;
    final pw = List<double>.filled(m, 1);
    for (var k = 1; k < m; k++) {
      pw[k] = pw[k - 1] * u;
    }
    for (var r = 0; r < m; r++) {
      atb[r] += pw[r] * y[s + i];
      for (var q = 0; q < m; q++) {
        ata[r][q] += pw[r] * pw[q];
      }
    }
  }
  final coef = _solve(ata, atb);
  return [
    for (var p = evalFrom; p < evalTo; p++)
      () {
        final u = (p - c) / sc;
        var v = 0.0;
        for (var k = m - 1; k >= 0; k--) {
          v = v * u + coef[k];
        }
        return v;
      }(),
  ];
}

List<double> _solve(List<List<double>> a, List<double> b) {
  final n = b.length;
  final m = [
    for (var i = 0; i < n; i++) [...a[i], b[i]],
  ];
  for (var col = 0; col < n; col++) {
    var piv = col;
    for (var r = col + 1; r < n; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    final t = m[col];
    m[col] = m[piv];
    m[piv] = t;
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      for (var k = col; k <= n; k++) {
        m[r][k] -= f * m[col][k];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
}

/// Smoothing coefficients (deriv 0) for a centred window.
List<double> savgolCoeffs(int window, int order) {
  final half = window ~/ 2;
  // coefficient j = value at 0 of the LS fit to a unit impulse at j.
  final out = <double>[];
  for (var j = 0; j < window; j++) {
    final y = List<double>.filled(window, 0)..[j] = 1;
    out.add(_polyFitEval(y, 0, window, order, half, half + 1).first);
  }
  return out;
}

/// scipy.signal.savgol_filter(x, window, order) with mode='interp'.
Float64List savgolFilter(List<double> x, {int window = 31, int order = 3}) {
  final n = x.length;
  final out = Float64List(n);
  if (window > n || window <= order) {
    for (var i = 0; i < n; i++) {
      out[i] = x[i];
    }
    return out;
  }
  final half = window ~/ 2;
  final c = savgolCoeffs(window, order);
  for (var i = half; i < n - half; i++) {
    var s = 0.0;
    for (var k = 0; k < window; k++) {
      s += c[k] * x[i - half + k];
    }
    out[i] = s;
  }
  final head = _polyFitEval(x, 0, window, order, 0, half);
  for (var i = 0; i < half; i++) {
    out[i] = head[i];
  }
  final tail = _polyFitEval(
    x,
    n - window,
    window,
    order,
    window - half,
    window,
  );
  for (var i = 0; i < half; i++) {
    out[n - half + i] = tail[i];
  }
  return out;
}
