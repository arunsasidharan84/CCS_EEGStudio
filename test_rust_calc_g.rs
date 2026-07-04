fn calc_g(x: f64) -> f64 {
    let mut g = 0.0;
    let mut p_n_minus_1 = x; // P_1
    let mut p_n_minus_2 = 1.0; // P_0
    
    for n in 1..=50 {
        let n_f64 = n as f64;
        let p_n = if n == 1 {
            x
        } else {
            ((2.0 * n_f64 - 1.0) * x * p_n_minus_1 - (n_f64 - 1.0) * p_n_minus_2) / n_f64
        };
        
        let term = (2.0 * n_f64 + 1.0) / (n_f64.powi(4) * (n_f64 + 1.0).powi(4));
        g += term * p_n;
        
        if n > 1 {
            p_n_minus_2 = p_n_minus_1;
            p_n_minus_1 = p_n;
        }
    }
    g / (4.0 * std::f64::consts::PI)
}
fn main() {
    let vals = [1.0, 0.5, 0.0, -0.5, -1.0];
    for &v in &vals {
        println!("{:.8}", calc_g(v));
    }
}
