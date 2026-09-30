// lib/src/topostats/etfce.dart
//
// Exact port of the statistics used by PlotFeaturesTopoStats_20260801.py:
//
//   mne.stats.permutation_cluster_test(
//       [test, base], threshold=dict(start=0, step=0.2), adjacency=adj,
//       tail=0, n_permutations=500,
//       stat_fun=partial(ttest_ind_no_p, equal_var=False), seed=42)
//
// i.e. an independent-samples permutation test with threshold-free cluster
// enhancement computed on the electrode adjacency graph ("e-TFCE").
//
// Bit-level parity notes (verified against MNE 1.12.1 on real data, max
// |Δ| = 0 for both the enhanced statistic and the p-values):
//   * numpy.random.RandomState(seed).permutation(n) is reproduced exactly
//     (MT19937 init_genrand seeding + legacy Fisher-Yates with masked
//     rejection sampling), so every permutation matches MNE's.
//   * The TFCE height term follows MNE <= 1.12 (h = dh ** h_power) by
//     default. MNE 1.13 changed it to a Riemann sum (h = thresh ** H * dh);
//     both are available through [TfceFormula].
//   * MNE returns the *TFCE-enhanced* statistic (score * sign(t)) as t_obs
//     when a TFCE threshold dict is used -- that is what the reference
//     script colours its topomaps with, so [ETfceResult.tObs] is the same.

import 'dart:math' as math;
import 'dart:typed_data';

/// numpy.random.RandomState-compatible Mersenne Twister (MT19937).
class NumpyRandomState {
  NumpyRandomState(int seed) {
    var s = seed & 0xffffffff;
    for (var i = 0; i < 624; i++) {
      _mt[i] = s;
      // (1812433253 * (s ^ (s >> 30)) + i + 1) & 0xffffffff, computed in two
      // 16-bit halves so it never overflows 64-bit ints.
      final x = s ^ (s >> 30);
      final lo = (x & 0xffff) * 1812433253;
      final hi = ((x >> 16) * 1812433253) & 0xffff;
      s = (lo + (hi << 16) + i + 1) & 0xffffffff;
    }
    _idx = 624;
  }

  final Uint32List _mt = Uint32List(624);
  int _idx = 624;

  int nextUint32() {
    if (_idx >= 624) {
      for (var k = 0; k < 624; k++) {
        final y = (_mt[k] & 0x80000000) | (_mt[(k + 1) % 624] & 0x7fffffff);
        var v = _mt[(k + 397) % 624] ^ (y >> 1);
        if ((y & 1) != 0) v ^= 0x9908b0df;
        _mt[k] = v;
      }
      _idx = 0;
    }
    var y = _mt[_idx++];
    y ^= y >> 11;
    y ^= (y << 7) & 0x9d2c5680;
    y ^= (y << 15) & 0xefc60000;
    y ^= y >> 18;
    return y & 0xffffffff;
  }

  /// numpy legacy `random_interval(max)` (32-bit masked rejection).
  int interval(int max) {
    if (max == 0) return 0;
    var mask = max;
    mask |= mask >> 1;
    mask |= mask >> 2;
    mask |= mask >> 4;
    mask |= mask >> 8;
    mask |= mask >> 16;
    while (true) {
      final v = nextUint32() & mask;
      if (v <= max) return v;
    }
  }

  /// `RandomState.permutation(n)`.
  Int32List permutation(int n) {
    final a = Int32List(n);
    for (var i = 0; i < n; i++) {
      a[i] = i;
    }
    for (var i = n - 1; i >= 1; i--) {
      final j = interval(i);
      final t = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a;
  }
}

/// Which TFCE height weighting to use.
enum TfceFormula {
  /// MNE-Python <= 1.12: `h = (thresh_i - thresh_{i-1}) ** h_power`.
  /// Reproduces figures made with MNE up to and including 1.12.x.
  legacy,

  /// MNE-Python >= 1.13: `h = thresh ** h_power * dh` (Riemann sum).
  riemann,
}

class ETfceResult {
  ETfceResult(this.tObs, this.pValues, this.rawT);

  /// TFCE-enhanced statistic, signed like the raw t (MNE's returned t_obs).
  final Float64List tObs;

  /// Per-channel p-values from the max-statistic permutation distribution.
  final Float64List pValues;

  /// Raw Welch t-values (for tooltips / optional display).
  final Float64List rawT;
}

/// Welch (unequal variance) t for `a` vs `b`, per column. Mirrors
/// mne.stats.ttest_ind_no_p(a, b, equal_var=False).
///
/// [rows] is the pooled sample matrix (row-major, [nCh] columns), and
/// [idx] gives which rows belong to group A (first [nA]) and B (rest).
void welchT(
  Float64List rows,
  int nCh,
  Int32List idx,
  int nA,
  Float64List out,
  Float64List scratchMeanA,
  Float64List scratchMeanB,
) {
  final n = idx.length;
  final nB = n - nA;
  for (var c = 0; c < nCh; c++) {
    scratchMeanA[c] = 0;
    scratchMeanB[c] = 0;
  }
  for (var r = 0; r < nA; r++) {
    final base = idx[r] * nCh;
    for (var c = 0; c < nCh; c++) {
      scratchMeanA[c] += rows[base + c];
    }
  }
  for (var r = nA; r < n; r++) {
    final base = idx[r] * nCh;
    for (var c = 0; c < nCh; c++) {
      scratchMeanB[c] += rows[base + c];
    }
  }
  for (var c = 0; c < nCh; c++) {
    scratchMeanA[c] /= nA;
    scratchMeanB[c] /= nB;
  }
  for (var c = 0; c < nCh; c++) {
    var ssA = 0.0;
    final mA = scratchMeanA[c];
    for (var r = 0; r < nA; r++) {
      final d = rows[idx[r] * nCh + c] - mA;
      ssA += d * d;
    }
    var ssB = 0.0;
    final mB = scratchMeanB[c];
    for (var r = nA; r < n; r++) {
      final d = rows[idx[r] * nCh + c] - mB;
      ssB += d * d;
    }
    final v1 = ssA / (nA - 1);
    final v2 = ssB / (nB - 1);
    final denom = math.sqrt(v1 / nA + v2 / nB);
    out[c] = (mA - mB) / denom; // IEEE semantics: ±inf / NaN like numpy
  }
}

/// Channel adjacency as neighbour lists (self-loops allowed / ignored).
class ChannelGraph {
  ChannelGraph(List<List<int>> neighbours)
    : n = neighbours.length,
      _nbr = [for (final l in neighbours) Int32List.fromList(l)];

  final int n;
  final List<Int32List> _nbr;

  Int32List neighboursOf(int i) => _nbr[i];
}

/// TFCE scores (non-negative) for statistic [x] on [graph].
/// Mirrors mne.stats.cluster_level._find_clusters with a TFCE dict, tail=0,
/// e_power=0.5, h_power=2.
void tfceScores(
  Float64List x,
  ChannelGraph graph,
  double start,
  double step,
  TfceFormula formula,
  Float64List scores,
  Int32List stack,
  Uint8List state,
) {
  final n = x.length;
  for (var i = 0; i < n; i++) {
    scores[i] = 0.0;
  }
  var maxV = -double.infinity;
  var minV = double.infinity;
  var anyFinite = false;
  for (var i = 0; i < n; i++) {
    final v = x[i];
    if (v.isFinite) {
      anyFinite = true;
      if (v > maxV) maxV = v;
      if (v < minV) minV = v;
    }
  }
  if (!anyFinite) return;
  final stop = math.max(maxV, -minV);
  // numpy.arange(start, stop, step): length ceil((stop - start) / step),
  // values start + i * step.
  final nThr = ((stop - start) / step).ceil();
  if (nThr <= 0) return;

  double prevThr = 0;
  for (var ti = 0; ti < nThr; ti++) {
    final thr = start + ti * step;
    double h;
    if (formula == TfceFormula.legacy) {
      h = ti == 0 ? thr.abs() : (thr - prevThr).abs();
      h = h * h; // h_power = 2
    } else {
      final dh = ti == 0 ? thr.abs() : (thr - prevThr).abs();
      h = thr.abs() * thr.abs() * dh;
    }
    prevThr = thr;
    // Two tails: x > thr, then x < -thr. Clusters are connected components
    // of the supra-threshold set on the adjacency graph.
    for (var tail = 0; tail < 2; tail++) {
      // state: 0 = excluded, 1 = in-set unvisited, 2 = visited
      var any = false;
      for (var i = 0; i < n; i++) {
        final v = x[i];
        final inSet = tail == 0 ? v > thr : v < -thr;
        state[i] = inSet ? 1 : 0;
        if (inSet) any = true;
      }
      if (!any) continue;
      for (var s0 = 0; s0 < n; s0++) {
        if (state[s0] != 1) continue;
        // BFS/DFS component
        var sp = 0;
        stack[sp++] = s0;
        state[s0] = 2;
        final members = <int>[];
        while (sp > 0) {
          final u = stack[--sp];
          members.add(u);
          final nb = graph.neighboursOf(u);
          for (var k = 0; k < nb.length; k++) {
            final v = nb[k];
            if (state[v] == 1) {
              state[v] = 2;
              stack[sp++] = v;
            }
          }
        }
        final add = h * math.sqrt(members.length.toDouble()); // e_power 0.5
        for (final m in members) {
          scores[m] += add;
        }
      }
    }
  }
}

/// One baseline-vs-window e-TFCE permutation test (see file header).
///
/// [test] and [base] are row lists of length-[nCh] samples. Rows containing
/// any NaN are dropped (as the reference script does). Returns `null` when
/// either group has fewer than 3 complete rows (script returns NaN arrays).
ETfceResult? runETfce({
  required List<Float64List> test,
  required List<Float64List> base,
  required ChannelGraph graph,
  int nPermutations = 500,
  int seed = 42,
  double tfceStart = 0.0,
  double tfceStep = 0.2,
  TfceFormula formula = TfceFormula.legacy,
}) {
  bool complete(Float64List r) {
    for (final v in r) {
      if (v.isNaN) return false;
    }
    return true;
  }

  final t = test.where(complete).toList();
  final b = base.where(complete).toList();
  final nCh = graph.n;
  if (t.length < 3 || b.length < 3) return null;

  final nA = t.length;
  final nTot = nA + b.length;
  // X_full = concatenate([test, base])
  final rows = Float64List(nTot * nCh);
  for (var r = 0; r < nA; r++) {
    rows.setRange(r * nCh, (r + 1) * nCh, t[r]);
  }
  for (var r = 0; r < b.length; r++) {
    rows.setRange((nA + r) * nCh, (nA + r + 1) * nCh, b[r]);
  }

  final mA = Float64List(nCh);
  final mB = Float64List(nCh);
  final tv = Float64List(nCh);
  final scores = Float64List(nCh);
  final stack = Int32List(nCh + 1);
  final state = Uint8List(nCh);

  final ident = Int32List(nTot);
  for (var i = 0; i < nTot; i++) {
    ident[i] = i;
  }
  welchT(rows, nCh, ident, nA, tv, mA, mB);
  final rawT = Float64List.fromList(tv);
  tfceScores(rawT, graph, tfceStart, tfceStep, formula, scores, stack, state);
  final obsScores = Float64List.fromList(scores);

  // H0[0] = observed max |score|; then n_permutations - 1 permutations.
  final h0 = Float64List(nPermutations);
  var orig = 0.0;
  for (final s in obsScores) {
    if (s.abs() > orig) orig = s.abs();
  }
  h0[0] = orig;
  final rng = NumpyRandomState(seed);
  for (var p = 1; p < nPermutations; p++) {
    final order = rng.permutation(nTot);
    welchT(rows, nCh, order, nA, tv, mA, mB);
    tfceScores(tv, graph, tfceStart, tfceStep, formula, scores, stack, state);
    var mx = -double.infinity;
    for (final s in scores) {
      if (s > mx) mx = s;
    }
    h0[p] = mx.isFinite ? mx : 0.0;
  }

  final pv = Float64List(nCh);
  for (var c = 0; c < nCh; c++) {
    final target = obsScores[c].abs();
    var cnt = 0;
    for (var k = 0; k < nPermutations; k++) {
      if (h0[k].abs() >= target) cnt++;
    }
    pv[c] = cnt / nPermutations;
  }

  final tObs = Float64List(nCh);
  for (var c = 0; c < nCh; c++) {
    final r = rawT[c];
    final sgn = r.isNaN ? double.nan : (r > 0 ? 1.0 : (r < 0 ? -1.0 : 0.0));
    tObs[c] = obsScores[c] * sgn;
  }
  return ETfceResult(tObs, pv, rawT);
}

/// Benjamini-Hochberg FDR (same as the script's fdr_bh).
({Float64List q, List<bool> reject}) fdrBH(List<double> p, double alpha) {
  final n = p.length;
  if (n == 0) return (q: Float64List(0), reject: <bool>[]);
  // np.argsort default is quicksort (not stable) -- ties don't change q.
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final c = p[a].compareTo(p[b]);
      return c != 0 ? c : a.compareTo(b);
    });
  final qRaw = Float64List(n);
  for (var i = 0; i < n; i++) {
    qRaw[i] = p[order[i]] * n / (i + 1);
  }
  final qSorted = Float64List(n);
  var run = double.infinity;
  for (var i = n - 1; i >= 0; i--) {
    run = math.min(run, qRaw[i]);
    qSorted[i] = run.clamp(0.0, 1.0);
  }
  final q = Float64List(n);
  for (var i = 0; i < n; i++) {
    q[order[i]] = qSorted[i];
  }
  return (q: q, reject: [for (final v in q) v <= alpha]);
}
