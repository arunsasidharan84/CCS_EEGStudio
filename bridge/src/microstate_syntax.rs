//! Artoni et al. (2023), NeuroImage 277:120196; entropy representation
//! definitions cross-checked against Frederic-vW's MIT-licensed microsynt.py.
use serde::Serialize;
use std::collections::BTreeMap;
#[derive(Clone, Debug, Serialize)]
pub struct EntropyClass {
    pub entropy_bits: f64,
    pub theoretical: f64,
    pub empirical: f64,
    pub markov: f64,
    pub ratio_theoretical: Option<f64>,
    pub ratio_markov: Option<f64>,
    pub count: usize,
}
#[derive(Clone, Debug, Serialize)]
pub struct SyntaxResult {
    pub warnings: Vec<String>,
    pub dictionary_discovery: Vec<DictionaryDiscovery>,
    pub word_length: usize,
    pub jump_symbols: usize,
    pub windows: usize,
    pub legacy_windows: bool,
    pub classes: Vec<EntropyClass>,
    pub words: BTreeMap<String, usize>,
}
fn entropy(word: &[usize], k: usize) -> i64 {
    let mut n = vec![0; k];
    for &x in word {
        n[x] += 1;
    }
    let h = n
        .iter()
        .filter(|&&x| x > 0)
        .map(|&x| {
            let p = x as f64 / word.len() as f64;
            -p * p.log2()
        })
        .sum::<f64>();
    (h * 1000.).round() as i64
}
pub fn analyse(
    trials: &[Vec<usize>],
    k: usize,
    w: usize,
    legacy: bool,
) -> Result<SyntaxResult, String> {
    if k < 2
        || !(2..=8).contains(&w)
        || k.checked_mul((k - 1).pow((w - 1) as u32))
            .unwrap_or(usize::MAX)
            > 2_000_000
    {
        return Err(
            "Syntax dictionary exceeds two million words; choose a shorter word length (2–8)"
                .into(),
        );
    }
    let jumps: Vec<Vec<usize>> = trials
        .iter()
        .map(|t| {
            t.iter()
                .enumerate()
                .filter(|(i, x)| *i == 0 || t[*i - 1] != **x)
                .map(|(_, x)| *x)
                .collect()
        })
        .collect();
    if jumps.iter().flatten().any(|&x| x >= k) {
        return Err("Invalid syntax state index".into());
    }
    let mut p = vec![0.; k];
    let mut trans = vec![vec![0.; k]; k];
    let mut empirical = BTreeMap::<i64, usize>::new();
    let mut words = BTreeMap::new();
    let mut windows = 0;
    for t in &jumps {
        for &x in t {
            p[x] += 1.;
        }
        for pair in t.windows(2) {
            trans[pair[0]][pair[1]] += 1.;
        }
        let count = if legacy {
            t.len().saturating_sub(w)
        } else {
            if t.len() >= w {
                t.len() - w + 1
            } else {
                0
            }
        };
        for i in 0..count {
            let word = &t[i..i + w];
            *empirical.entry(entropy(word, k)).or_default() += 1;
            *words
                .entry(
                    word.iter()
                        .map(|x| x.to_string())
                        .collect::<Vec<_>>()
                        .join("-"),
                )
                .or_default() += 1;
            windows += 1;
        }
    }
    let total = p.iter().sum::<f64>();
    if total > 0. {
        for v in &mut p {
            *v /= total;
        }
    }
    for row in &mut trans {
        let n = row.iter().sum::<f64>();
        if n > 0. {
            for x in row {
                *x /= n;
            }
        }
    }
    fn visit(
        word: &mut Vec<usize>,
        k: usize,
        w: usize,
        p: &[f64],
        t: &[Vec<f64>],
        out: &mut BTreeMap<i64, (usize, f64)>,
    ) {
        if word.len() == w {
            let h = entropy(word, k);
            let prob = p[word[0]] * word.windows(2).map(|x| t[x[0]][x[1]]).product::<f64>();
            let e = out.entry(h).or_default();
            e.0 += 1;
            e.1 += prob;
            return;
        }
        for x in 0..k {
            if word.last() == Some(&x) {
                continue;
            }
            word.push(x);
            visit(word, k, w, p, t, out);
            word.pop();
        }
    }
    let mut theoretical = BTreeMap::new();
    visit(&mut vec![], k, w, &p, &trans, &mut theoretical);
    let dictionary = theoretical.values().map(|v| v.0).sum::<usize>() as f64;
    let markov = theoretical.values().map(|v| v.1).sum::<f64>();
    let classes = theoretical
        .into_iter()
        .map(|(h, (n, m))| {
            let count = *empirical.get(&h).unwrap_or(&0);
            let e = if windows > 0 {
                count as f64 / windows as f64
            } else {
                0.
            };
            let t = n as f64 / dictionary;
            let m = if markov > 0. { m / markov } else { 0. };
            EntropyClass {
                entropy_bits: h as f64 / 1000.,
                theoretical: t,
                empirical: e,
                markov: m,
                ratio_theoretical: (windows > 0).then_some(e / t),
                ratio_markov: if windows > 0 && m > 0. {
                    Some(e / m)
                } else {
                    None
                },
                count,
            }
        })
        .collect();
    Ok(SyntaxResult {
        warnings: if windows < dictionary as usize {
            vec![format!("Only {windows} observed windows for {} possible words; inspect dictionary discovery and consider a shorter word length. Ratios are descriptive.",dictionary as usize)]
        } else {
            vec![]
        },
        dictionary_discovery: vec![],
        word_length: w,
        jump_symbols: jumps.iter().map(Vec::len).sum(),
        windows,
        legacy_windows: legacy,
        classes,
        words,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paper_example() {
        let r = analyse(&[vec![0, 1, 0, 1, 0, 2]], 3, 3, false).unwrap();
        assert_eq!(r.windows, 4);
        assert_eq!(r.classes[0].count, 3);
        assert_eq!(r.classes[0].ratio_theoretical, Some(1.5));
        assert_eq!(r.classes[1].ratio_theoretical, Some(0.5));
    }
    #[test]
    fn legacy_and_boundaries() {
        let r = analyse(&[vec![0, 1, 0, 1, 0, 2]], 3, 3, true).unwrap();
        assert_eq!(r.windows, 3);
        assert_eq!(
            analyse(&[vec![0, 1], vec![0, 2]], 3, 3, false)
                .unwrap()
                .windows,
            0
        );
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct DictionaryDiscovery {
    pub word_length: usize,
    pub theoretical_words: u64,
    pub observed_words: usize,
    pub random_words_mean: f64,
    pub random_words_min: usize,
    pub random_words_max: usize,
}
pub fn discover(trials: &[Vec<usize>], k: usize, seed: u64) -> Vec<DictionaryDiscovery> {
    if k < 2 {return vec![];}
    use std::collections::HashSet;
    let jumps: Vec<Vec<usize>> = trials
        .iter()
        .map(|t| {
            t.iter()
                .enumerate()
                .filter(|(i, x)| *i == 0 || t[*i - 1] != **x)
                .map(|(_, x)| *x)
                .collect()
        })
        .collect();
    let mut random = Vec::new();
    let mut rng = seed;
    for _ in 0..3 {
        random.push(
            jumps
                .iter()
                .map(|trial| {
                    let mut t = Vec::new();
                    for _ in trial {
                        rng = rng
                            .wrapping_mul(6364136223846793005)
                            .wrapping_add(1442695040888963407);
                        let mut state = ((rng >> 32) as usize) % k;
                        if let Some(last) = t.last() {
                            state = ((rng >> 32) as usize) % (k - 1);
                            if state >= *last {
                                state += 1;
                            }
                        }
                        t.push(state);
                    }
                    t
                })
                .collect::<Vec<_>>(),
        );
    }
    fn count(trials: &[Vec<usize>], w: usize) -> usize {
        trials
            .iter()
            .flat_map(|t| t.windows(w).map(|x| x.to_vec()))
            .collect::<HashSet<_>>()
            .len()
    }
    (1..=10)
        .map(|w| {
            let counts: Vec<usize> = random.iter().map(|t| count(t, w)).collect();
            DictionaryDiscovery {
                word_length: w,
                theoretical_words: k as u64 * (k as u64 - 1).pow((w - 1) as u32),
                observed_words: count(&jumps, w),
                random_words_mean: counts.iter().sum::<usize>() as f64 / 3.,
                random_words_min: *counts.iter().min().unwrap(),
                random_words_max: *counts.iter().max().unwrap(),
            }
        })
        .collect()
}
#[cfg(test)]
mod reference_parity {
    use super::*;
    #[test]
    fn supplied_python_reference() {
        let v: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/microsynt_reference.json"))
                .unwrap();
        let seq = v["sequence"]
            .as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_u64().unwrap() as usize)
            .collect();
        let r = analyse(&[seq], 3, 4, true).unwrap();
        for (i, c) in r.classes.iter().enumerate() {
            assert!((c.entropy_bits - v["classes"][i].as_f64().unwrap()).abs() < 1e-10);
            for (a, key) in [
                (c.theoretical, "TER"),
                (c.empirical, "EER"),
                (c.markov, "MER"),
            ] {
                assert!((a - v[key][i].as_f64().unwrap()).abs() < 1e-10, "{key}");
            }
        }
    }
}
