fn main() {
    let x = 0.5;
    let mut p_n_minus_1 = x;
    let mut p_n_minus_2 = 1.0;
    println!("P_1(0.5) = {}", p_n_minus_1);
    for n in 2..=4 {
        let n_f64 = n as f64;
        let p_n = ((2.0 * n_f64 - 1.0) * x * p_n_minus_1 - (n_f64 - 1.0) * p_n_minus_2) / n_f64;
        println!("P_{}(0.5) = {}", n, p_n);
        p_n_minus_2 = p_n_minus_1;
        p_n_minus_1 = p_n;
    }
}
