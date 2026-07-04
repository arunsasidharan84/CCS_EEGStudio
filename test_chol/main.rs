use nalgebra::{DMatrix, SymmetricEigen};

fn main() {
    let mut b = DMatrix::from_element(3, 3, 0.5);
    b[(0,0)] = 2.0; b[(1,1)] = 3.0; b[(2,2)] = 1.0;
    let eig = SymmetricEigen::new(b);
    println!("Evals: {:?}", eig.eigenvalues.as_slice());
}
