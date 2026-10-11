use ccs_ica::cli;
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: ccs_ica <pop_runica|iclabel|...> <case_dir> <out_dir>");
        std::process::exit(2);
    }
    let (cmd, indir, outdir) = (args[1].as_str(), PathBuf::from(&args[2]), PathBuf::from(&args[3]));
    let res = match cmd {
        "pop_runica" => cli::cmd_pop_runica(&indir, &outdir),
        "picard" => cli::cmd_picard(&indir, &outdir),
        "asr" => cli::cmd_asr(&indir, &outdir),
        "blink" => cli::cmd_blink(&indir, &outdir),
        "studio" => cli::cmd_studio(&indir, &outdir),
        "iclabel" => cli::cmd_iclabel(&indir, &outdir),
        "net" => cli::cmd_net(&indir, &outdir),
        "resample" => cli::cmd_resample(&indir, &outdir),
        "ica1" => cli::cmd_ica1(&indir, &outdir),
        "ica2" => cli::cmd_ica2(&indir, &outdir),
        "select" => cli::cmd_select(&indir, &outdir),
        _ => Err(format!("unknown command '{}'", cmd)),
    };
    if let Err(e) = res {
        eprintln!("ERROR: {}", e);
        std::process::exit(1);
    }
}
