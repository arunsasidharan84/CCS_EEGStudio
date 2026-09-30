// lib/src/erp/np_random.dart
//
// Bit-exact port of numpy's default generator,
// `np.random.default_rng(seed)`: SeedSequence -> PCG64 (XSL-RR 128/64), plus
// Generator.permutation / integers / choice(replace=True). The same seed
// therefore gives the same permutations and bootstrap resamples as the Python
// scripts (compute_mmn_erp.py uses default_rng(42)).
//
// 128-bit state arithmetic uses two 64-bit halves. Dart native ints wrap on
// overflow, and `>>>` is a logical shift.

const int _m32 = 0xFFFFFFFF;
const int _minInt = -9223372036854775807 - 1;

// SeedSequence constants (numpy/random/bit_generator.pyx)
const int _initA = 0x43b0d7e5;
const int _multA = 0x931e8875;
const int _initB = 0x8b51f9dd;
const int _multB = 0x58f38ded;
const int _mixMultL = 0xca01f9dd;
const int _mixMultR = 0x4973f715;

/// SeedSequence(entropy).generate_state(nWords, uint32).
List<int> seedSequenceState(List<int> entropy, int nWords) {
  final pool = List<int>.filled(4, 0);
  var hashConst = _initA;
  int hashmix(int v) {
    v = (v ^ hashConst) & _m32;
    hashConst = (hashConst * _multA) & _m32;
    v = (v * hashConst) & _m32;
    v ^= v >>> 16;
    return v;
  }

  int mix(int x, int y) {
    var r = (_mixMultL * x - _mixMultR * y) & _m32;
    r ^= r >>> 16;
    return r;
  }

  for (var i = 0; i < 4; i++) {
    pool[i] = hashmix(i < entropy.length ? entropy[i] : 0);
  }
  for (var s = 0; s < 4; s++) {
    for (var d = 0; d < 4; d++) {
      if (s != d) pool[d] = mix(pool[d], hashmix(pool[s]));
    }
  }
  for (var s = 4; s < entropy.length; s++) {
    for (var d = 0; d < 4; d++) {
      pool[d] = mix(pool[d], hashmix(entropy[s]));
    }
  }
  final out = <int>[];
  var h = _initB;
  for (var i = 0; i < nWords; i++) {
    var v = pool[i % 4];
    v = (v ^ h) & _m32;
    h = (h * _multB) & _m32;
    v = (v * h) & _m32;
    v ^= v >>> 16;
    out.add(v);
  }
  return out;
}

/// Unsigned 64-bit comparison a < b.
bool _ult(int a, int b) => (a ^ _minInt) < (b ^ _minInt);

/// Full 64x64 -> 128-bit product, returned as (hi, lo).
(int, int) _mul64(int a, int b) {
  final a0 = a & _m32, a1 = a >>> 32;
  final b0 = b & _m32, b1 = b >>> 32;
  final p00 = a0 * b0;
  final p01 = a0 * b1;
  final p10 = a1 * b0;
  final p11 = a1 * b1;
  final mid = (p00 >>> 32) + (p01 & _m32) + (p10 & _m32);
  final lo = (p00 & _m32) | (mid << 32);
  final hi = p11 + (p01 >>> 32) + (p10 >>> 32) + (mid >>> 32);
  return (hi, lo);
}

/// numpy.random.Generator(PCG64(SeedSequence(seed))).
class NpGenerator {
  NpGenerator(int seed) {
    if (seed < 0) throw ArgumentError('seed must be non-negative');
    final entropy = <int>[];
    var s = seed;
    do {
      entropy.add(s & _m32);
      s = s >>> 32;
    } while (s > 0);
    final w = seedSequenceState(entropy, 8);
    final u = [for (var i = 0; i < 4; i++) w[2 * i] | (w[2 * i + 1] << 32)];
    // pcg64_set_seed: state = u0:u1, initseq = u2:u3; inc = initseq << 1 | 1
    final initHi = u[0], initLo = u[1];
    _incHi = (u[2] << 1) | (u[3] >>> 63);
    _incLo = (u[3] << 1) | 1;
    _hi = 0;
    _lo = 0;
    _step();
    final lo = _lo + initLo;
    final carry = _ult(lo, _lo) ? 1 : 0;
    _lo = lo;
    _hi = _hi + initHi + carry;
    _step();
  }

  // PCG_DEFAULT_MULTIPLIER_128
  static const int _mulHi = 2549297995355413924;
  static const int _mulLo = 4865540595714422341;

  late int _hi, _lo, _incHi, _incLo;
  bool _hasU32 = false;
  int _u32 = 0;

  void _step() {
    // state = state * MUL + inc  (mod 2^128)
    final (h, l) = _mul64(_lo, _mulLo);
    var hi = h + _hi * _mulLo + _lo * _mulHi;
    final lo = l + _incLo;
    if (_ult(lo, l)) hi += 1;
    hi += _incHi;
    _hi = hi;
    _lo = lo;
  }

  /// PCG64 next_uint64 (step, then XSL-RR output).
  int nextUint64() {
    _step();
    final x = _hi ^ _lo;
    final r = _hi >>> 58;
    return (x >>> r) | (x << ((64 - r) & 63));
  }

  /// PCG64 next_uint32 (low half first, high half buffered).
  int nextUint32() {
    if (_hasU32) {
      _hasU32 = false;
      return _u32;
    }
    final n = nextUint64();
    _hasU32 = true;
    _u32 = n >>> 32;
    return n & _m32;
  }

  /// random_interval(max): uniform integer in [0, max] by masked rejection.
  int randomInterval(int max) {
    if (max == 0) return 0;
    var mask = max;
    mask |= mask >>> 1;
    mask |= mask >>> 2;
    mask |= mask >>> 4;
    mask |= mask >>> 8;
    mask |= mask >>> 16;
    mask |= mask >>> 32;
    if (max <= _m32) {
      while (true) {
        final v = nextUint32() & mask;
        if (v <= max) return v;
      }
    }
    while (true) {
      final v = nextUint64() & mask;
      if (!_ult(max, v)) return v;
    }
  }

  /// Generator.permutation(n): shuffles arange(n) from the back.
  List<int> permutation(int n) {
    final a = List<int>.generate(n, (i) => i);
    for (var i = n - 1; i > 0; i--) {
      final j = randomInterval(i);
      final t = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a;
  }

  /// Generator.integers(0, high, size) for high <= 2^32 (buffered Lemire).
  List<int> integers(int high, int size) {
    final rng = high - 1;
    final out = List<int>.filled(size, 0);
    if (rng == 0) return out;
    if (rng > _m32) throw UnsupportedError('range > 2^32');
    final excl = rng + 1;
    for (var i = 0; i < size; i++) {
      var m = nextUint32() * excl;
      var left = m & _m32;
      if (left < excl) {
        final thresh = (_m32 - rng) % excl;
        while (left < thresh) {
          m = nextUint32() * excl;
          left = m & _m32;
        }
      }
      out[i] = m >>> 32;
    }
    return out;
  }

  /// Generator.choice(a, size, replace=True).
  List<double> choice(List<double> a, int size) {
    final idx = integers(a.length, size);
    return [for (final i in idx) a[i]];
  }
}
