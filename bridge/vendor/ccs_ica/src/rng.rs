//! Random number sources used by `runica`.
//!
//! EEGLAB's runica seeds MATLAB's legacy generator with the *clock* (`rand('state',sum(100*clock))`) so a
//! decomposition is not reproducible from run to run. To make numerical parity checkable the Rust port
//! abstracts the two random draws runica needs (`randperm(n)` for block shuffling and `rand(1,k)` for the
//! extended-ICA kurtosis subset) behind the [`Rng`] trait:
//!
//! * [`NativeRng`] — Mersenne-Twister (MT19937, MATLAB-compatible double stream) seeded by the caller or the clock.
//! * [`ReplayRng`] — replays the exact permutations/uniforms that a MATLAB run logged, which makes the
//!   Rust optimisation path bit-for-bit follow the MATLAB one (used for parity validation).

pub trait Rng {
    /// A random permutation of `0..n` (0-based).
    fn randperm(&mut self, n: usize) -> Vec<usize>;
    /// `k` uniform doubles in the open interval (0,1).
    fn rand(&mut self, k: usize) -> Vec<f64>;
}

pub struct Mt19937 {
    mt: [u32; 624],
    idx: usize,
}

impl Mt19937 {
    pub fn new(seed: u32) -> Self {
        let mut mt = [0u32; 624];
        mt[0] = seed;
        for i in 1..624 {
            mt[i] = 1812433253u32.wrapping_mul(mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_add(i as u32);
        }
        Mt19937 { mt, idx: 624 }
    }
    fn twist(&mut self) {
        for i in 0..624 {
            let y = (self.mt[i] & 0x8000_0000) | (self.mt[(i + 1) % 624] & 0x7fff_ffff);
            let mut v = self.mt[(i + 397) % 624] ^ (y >> 1);
            if y & 1 != 0 {
                v ^= 0x9908_b0df;
            }
            self.mt[i] = v;
        }
        self.idx = 0;
    }
    pub fn next_u32(&mut self) -> u32 {
        if self.idx >= 624 {
            self.twist();
        }
        let mut y = self.mt[self.idx];
        self.idx += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^= y >> 18;
        y
    }
    /// 53-bit resolution double in [0,1) (identical to MATLAB's twister `rand`).
    pub fn next_f64(&mut self) -> f64 {
        let a = (self.next_u32() >> 5) as f64;
        let b = (self.next_u32() >> 6) as f64;
        (a * 67108864.0 + b) / 9007199254740992.0
    }
}

pub struct NativeRng {
    mt: Mt19937,
}

impl NativeRng {
    pub fn new(seed: u32) -> Self {
        NativeRng { mt: Mt19937::new(seed) }
    }
    /// Seed from the wall clock (mirrors runica's default `rndreset='yes'`).
    pub fn from_clock() -> Self {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(5489);
        NativeRng::new((t ^ (t >> 32)) as u32)
    }
}

impl Rng for NativeRng {
    fn randperm(&mut self, n: usize) -> Vec<usize> {
        let mut p: Vec<usize> = (0..n).collect();
        for i in (1..n).rev() {
            let j = (self.mt.next_f64() * (i as f64 + 1.0)) as usize;
            p.swap(i, j.min(i));
        }
        p
    }
    fn rand(&mut self, k: usize) -> Vec<f64> {
        (0..k)
            .map(|_| loop {
                let v = self.mt.next_f64();
                if v > 0.0 {
                    break v;
                }
            })
            .collect()
    }
}

/// Replays logged permutations (1-based indices, as written by MATLAB) and uniform draws.
pub struct ReplayRng {
    perms: Vec<i32>,
    ppos: usize,
    rands: Vec<f64>,
    rpos: usize,
}

impl ReplayRng {
    pub fn new(perms: Vec<i32>, rands: Vec<f64>) -> Self {
        ReplayRng { perms, ppos: 0, rands, rpos: 0 }
    }
    pub fn exhausted_perms(&self) -> bool {
        self.ppos >= self.perms.len()
    }
}

impl Rng for ReplayRng {
    fn randperm(&mut self, n: usize) -> Vec<usize> {
        if self.ppos + n > self.perms.len() {
            panic!("ReplayRng: logged permutation stream exhausted (need {} more values, {} left)", n, self.perms.len() - self.ppos);
        }
        let out = self.perms[self.ppos..self.ppos + n].iter().map(|&v| (v - 1) as usize).collect();
        self.ppos += n;
        out
    }
    fn rand(&mut self, k: usize) -> Vec<f64> {
        if self.rpos + k > self.rands.len() {
            panic!("ReplayRng: logged uniform stream exhausted");
        }
        let out = self.rands[self.rpos..self.rpos + k].to_vec();
        self.rpos += k;
        out
    }
}
