//! Usage: speakrs-bench <audio.wav> <coreml|coreml-fast> <out.tsv> [models-dir]
//!
//! Writes the raw speaker turns (start, end, speaker) for a 16 kHz mono WAV, plus
//! timing and peak memory, so they can be compared with FluidAudio on the same file.
//! Without `models-dir` the models are fetched once from Hugging Face and cached.

use std::time::Instant;

use speakrs::{ExecutionMode, OwnedDiarizationPipeline};

fn peak_rss_mb() -> f64 {
    let mut usage: libc_rusage = unsafe { std::mem::zeroed() };
    unsafe { getrusage(0, &mut usage) };
    usage.ru_maxrss as f64 / 1_048_576.0 // bytes on macOS
}

#[repr(C)]
#[allow(non_camel_case_types)]
struct libc_rusage {
    ru_utime: [i64; 2],
    ru_stime: [i64; 2],
    ru_maxrss: i64,
    rest: [i64; 13],
}

unsafe extern "C" {
    fn getrusage(who: i32, usage: *mut libc_rusage) -> i32;
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: speakrs-bench <audio.wav> <coreml|coreml-fast> <out.tsv> [models-dir]");
        std::process::exit(2);
    }
    let mode = match args[2].as_str() {
        "coreml" => ExecutionMode::CoreMl,
        "coreml-fast" => ExecutionMode::CoreMlFast,
        other => return Err(format!("unknown mode {other}").into()),
    };

    let mut reader = hound::WavReader::open(&args[1])?;
    let spec = reader.spec();
    if spec.channels != 1 || spec.sample_rate != 16_000 || spec.bits_per_sample != 16 {
        return Err(format!("expected 16 kHz mono 16-bit WAV, got {spec:?}").into());
    }
    let audio: Vec<f32> = reader
        .samples::<i16>()
        .map(|s| s.map(|v| v as f32 / 32768.0))
        .collect::<Result<_, _>>()?;

    let load = Instant::now();
    let mut pipeline = match args.get(4) {
        Some(dir) => OwnedDiarizationPipeline::from_dir(dir, mode)?,
        None => OwnedDiarizationPipeline::from_pretrained(mode)?,
    };
    let load_s = load.elapsed().as_secs_f64();

    let start = Instant::now();
    let result = pipeline.run(&audio)?;
    let process_s = start.elapsed().as_secs_f64();

    let segments = result.discrete_diarization.to_segments();
    let mut tsv = String::from("start\tend\tspeaker\n");
    let mut speakers = std::collections::BTreeSet::new();
    for s in &segments {
        tsv.push_str(&format!("{:.3}\t{:.3}\t{}\n", s.start, s.end, s.speaker));
        speakers.insert(s.speaker.to_string());
    }
    std::fs::write(&args[3], tsv)?;
    println!(
        "mode={} segments={} speakers={} load={:.1}s process={:.1}s peakRSS={:.0}MB",
        args[2], segments.len(), speakers.len(), load_s, process_s, peak_rss_mb()
    );
    Ok(())
}
