use matfile::MatFile;
use std::fs::File;

fn main() {
    let file = File::open("/Users/arunsasidharan/EEGdata/EEGAnalysisCode/sampleData/AKNLTP014_REMED1_RCB.set").unwrap();
    let mat = MatFile::parse(file).unwrap();
    
    for array in mat.arrays() {
        println!("Name: {}", array.name());
    }
}
