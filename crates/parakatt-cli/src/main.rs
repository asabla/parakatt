use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use std::thread;
use std::time::Duration;

use parakatt_core::download::DownloadState;
use parakatt_core::engine::Engine;
use parakatt_core::storage::{StoredTranscription, TranscriptionQuery};
use parakatt_core::{
    init_logging, AppContext, CoreError, EngineConfig, ModeConfig, TimestampedSegment,
};
use serde_json::json;

const DEFAULT_MODEL: &str = "parakeet-tdt-0.6b-v3";
const DEFAULT_MODE: &str = "dictation";
const TARGET_SAMPLE_RATE: u32 = 16_000;

type CliResult<T> = Result<T, String>;

#[derive(Debug)]
struct AppPaths {
    models_dir: PathBuf,
    config_dir: PathBuf,
}

fn main() {
    if let Err(message) = run() {
        eprintln!("error: {message}");
        process::exit(1);
    }
}

fn run() -> CliResult<()> {
    init_logging(Some("warn".to_string()));

    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty()
        || args
            .first()
            .is_some_and(|arg| arg == "--help" || arg == "-h")
    {
        print_usage();
        return Ok(());
    }

    let models_dir = match take_path_option(&mut args, "--models-dir")? {
        Some(path) => path,
        None => default_models_dir()?,
    };
    let config_dir = match take_path_option(&mut args, "--config-dir")? {
        Some(path) => path,
        None => default_config_dir()?,
    };
    let paths = AppPaths {
        models_dir,
        config_dir,
    };

    let command = args
        .first()
        .cloned()
        .ok_or_else(|| "missing command".to_string())?;
    args.remove(0);

    match command.as_str() {
        "paths" => print_paths(&paths),
        "models" => run_models(args, &paths),
        "modes" => run_modes(args, &paths),
        "history" => run_history(args, &paths),
        "stats" => run_stats(args, &paths),
        "transcribe" => run_transcribe(args, &paths),
        _ => Err(format!("unknown command: {command}")),
    }
}

fn run_models(mut args: Vec<String>, paths: &AppPaths) -> CliResult<()> {
    if args.is_empty() || take_flag(&mut args, "--help") || take_flag(&mut args, "-h") {
        print_models_usage();
        return Ok(());
    }

    let subcommand = args.remove(0);
    let engine = create_engine(paths, DEFAULT_MODE)?;

    match subcommand.as_str() {
        "list" => {
            ensure_no_args(&args, "models list")?;
            list_models(&engine);
            Ok(())
        }
        "download" => {
            let model_id = take_required_arg(&mut args, "model id")?;
            ensure_no_args(&args, "models download")?;
            download_model(&engine, model_id)
        }
        "delete" => {
            let model_id = take_required_arg(&mut args, "model id")?;
            ensure_no_args(&args, "models delete")?;
            engine
                .delete_model(model_id.clone())
                .map_err(format_core_error)?;
            println!("Deleted model: {model_id}");
            Ok(())
        }
        _ => Err(format!("unknown models subcommand: {subcommand}")),
    }
}

fn run_modes(mut args: Vec<String>, paths: &AppPaths) -> CliResult<()> {
    if args.is_empty() || take_flag(&mut args, "--help") || take_flag(&mut args, "-h") {
        print_modes_usage();
        return Ok(());
    }

    let subcommand = args.remove(0);
    let engine = create_engine(paths, DEFAULT_MODE)?;

    match subcommand.as_str() {
        "list" => {
            let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
            ensure_no_args(&args, "modes list")?;
            print_modes(&engine.list_modes(), &format)
        }
        _ => Err(format!("unknown modes subcommand: {subcommand}")),
    }
}

fn run_history(mut args: Vec<String>, paths: &AppPaths) -> CliResult<()> {
    if args.is_empty() || take_flag(&mut args, "--help") || take_flag(&mut args, "-h") {
        print_history_usage();
        return Ok(());
    }

    let subcommand = args.remove(0);
    let engine = create_engine(paths, DEFAULT_MODE)?;

    match subcommand.as_str() {
        "list" => {
            let limit = take_u32_option(&mut args, "--limit")?.unwrap_or(20);
            let offset = take_u32_option(&mut args, "--offset")?.unwrap_or(0);
            let source_filter = take_option(&mut args, "--source")?;
            let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
            ensure_no_args(&args, "history list")?;

            let records = engine
                .list_transcriptions(TranscriptionQuery {
                    search_text: None,
                    source_filter,
                    limit,
                    offset,
                })
                .map_err(format_core_error)?;
            print_transcriptions(&records, &format)
        }
        "search" => {
            let limit = take_u32_option(&mut args, "--limit")?.unwrap_or(50);
            let offset = take_u32_option(&mut args, "--offset")?.unwrap_or(0);
            let source_filter = take_option(&mut args, "--source")?;
            let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
            let query = take_required_arg(&mut args, "search query")?;
            ensure_no_args(&args, "history search")?;

            let records = engine
                .list_transcriptions(TranscriptionQuery {
                    search_text: Some(query),
                    source_filter,
                    limit,
                    offset,
                })
                .map_err(format_core_error)?;
            print_transcriptions(&records, &format)
        }
        "show" => {
            let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
            let id = take_required_arg(&mut args, "transcription id")?;
            ensure_no_args(&args, "history show")?;

            let record = engine.get_transcription(id).map_err(format_core_error)?;
            print_transcription(&record, &format)
        }
        "delete" => {
            if args.is_empty() {
                return Err("missing transcription id".to_string());
            }
            let count = if args.len() == 1 {
                engine
                    .delete_transcription(args.remove(0))
                    .map_err(format_core_error)?;
                1
            } else {
                engine
                    .delete_transcriptions(args)
                    .map_err(format_core_error)?
            };
            println!("Deleted {count} transcription(s)");
            Ok(())
        }
        _ => Err(format!("unknown history subcommand: {subcommand}")),
    }
}

fn run_transcribe(mut args: Vec<String>, paths: &AppPaths) -> CliResult<()> {
    if args.is_empty() || take_flag(&mut args, "--help") || take_flag(&mut args, "-h") {
        print_transcribe_usage();
        return Ok(());
    }

    let model_id = take_option(&mut args, "--model")?.unwrap_or_else(|| DEFAULT_MODEL.to_string());
    let mode = take_option(&mut args, "--mode")?.unwrap_or_else(|| DEFAULT_MODE.to_string());
    let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
    let raw_f32le = take_flag(&mut args, "--raw-f32le");

    let audio_path = PathBuf::from(take_required_arg(&mut args, "audio file")?);
    ensure_no_args(&args, "transcribe")?;

    let (samples, sample_rate) =
        if raw_f32le || audio_path.extension().and_then(|s| s.to_str()) == Some("raw") {
            (read_raw_f32le(&audio_path)?, TARGET_SAMPLE_RATE)
        } else {
            read_wav(&audio_path)?
        };

    if sample_rate != TARGET_SAMPLE_RATE {
        return Err(format!(
            "expected {TARGET_SAMPLE_RATE} Hz mono audio, got {sample_rate} Hz; resample before transcribing"
        ));
    }

    let engine = create_engine(paths, &mode)?;
    eprintln!("Loading model: {model_id}");
    engine.load_model(&model_id).map_err(format_core_error)?;

    eprintln!("Transcribing: {}", audio_path.display());
    let result = engine
        .transcribe(samples, sample_rate, mode, Some(AppContext::default()))
        .map_err(format_core_error)?;

    match format.as_str() {
        "text" => {
            println!("{}", result.text);
            Ok(())
        }
        "json" => {
            let segments: Vec<_> = result.segments.iter().map(segment_json).collect();
            println!(
                "{}",
                json!({
                    "text": result.text,
                    "duration_secs": result.duration_secs,
                    "provider_name": result.provider_name,
                    "llm_error": result.llm_error,
                    "segments": segments,
                })
            );
            Ok(())
        }
        _ => Err(format!("unknown output format: {format}; use text or json")),
    }
}

fn run_stats(mut args: Vec<String>, paths: &AppPaths) -> CliResult<()> {
    if take_flag(&mut args, "--help") || take_flag(&mut args, "-h") {
        print_stats_usage();
        return Ok(());
    }

    let format = take_option(&mut args, "--format")?.unwrap_or_else(|| "text".to_string());
    ensure_no_args(&args, "stats")?;

    let engine = create_engine(paths, DEFAULT_MODE)?;
    let stats = engine.get_statistics().map_err(format_core_error)?;
    print_stats(&stats, &format)
}

fn create_engine(paths: &AppPaths, active_mode: &str) -> CliResult<Engine> {
    Engine::new(EngineConfig {
        models_dir: paths.models_dir.to_string_lossy().to_string(),
        config_dir: paths.config_dir.to_string_lossy().to_string(),
        active_stt_model: None,
        active_llm_provider: None,
        active_mode: active_mode.to_string(),
    })
    .map_err(format_core_error)
}

fn list_models(engine: &Engine) {
    println!("{:<36} {:<20} {:<10} SIZE", "ID", "PROVIDER", "DOWNLOADED");
    for model in engine.list_models() {
        println!(
            "{:<36} {:<20} {:<10} {}",
            &model.id,
            &model.provider_type,
            if model.downloaded { "yes" } else { "no" },
            format_bytes(model.size_bytes)
        );
    }
}

fn download_model(engine: &Engine, model_id: String) -> CliResult<()> {
    engine
        .start_download(model_id.clone())
        .map_err(format_core_error)?;

    loop {
        let progress = engine.get_download_progress().map_err(format_core_error)?;
        match progress.state {
            DownloadState::Idle => {}
            DownloadState::Downloading => {
                let percent = if progress.bytes_total > 0 {
                    progress.bytes_downloaded as f64 * 100.0 / progress.bytes_total as f64
                } else {
                    0.0
                };
                eprintln!(
                    "Downloading {} ({}/{}) {:.1}% {} / {}",
                    progress.current_file,
                    progress.file_index + 1,
                    progress.total_files,
                    percent,
                    format_bytes(progress.bytes_downloaded),
                    format_bytes(progress.bytes_total)
                );
            }
            DownloadState::Completed => {
                println!("Downloaded model: {model_id}");
                return Ok(());
            }
            DownloadState::Cancelled => return Err("download cancelled".to_string()),
            DownloadState::Failed { message } => return Err(message),
        }

        thread::sleep(Duration::from_secs(1));
    }
}

fn read_raw_f32le(path: &Path) -> CliResult<Vec<f32>> {
    let bytes = fs::read(path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    if bytes.len() % 4 != 0 {
        return Err(format!(
            "raw f32le file length must be divisible by 4 bytes: {}",
            path.display()
        ));
    }

    Ok(bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect())
}

fn read_wav(path: &Path) -> CliResult<(Vec<f32>, u32)> {
    let mut reader = hound::WavReader::open(path)
        .map_err(|e| format!("failed to open WAV {}: {e}", path.display()))?;
    let spec = reader.spec();

    if spec.channels != 1 {
        return Err(format!(
            "expected mono WAV, got {} channels in {}",
            spec.channels,
            path.display()
        ));
    }

    let samples = match spec.sample_format {
        hound::SampleFormat::Float => {
            if spec.bits_per_sample != 32 {
                return Err(format!(
                    "unsupported float WAV bit depth: {}; expected 32-bit float",
                    spec.bits_per_sample
                ));
            }
            reader
                .samples::<f32>()
                .map(|sample| sample.map_err(|e| format!("failed to read WAV sample: {e}")))
                .collect::<CliResult<Vec<_>>>()?
        }
        hound::SampleFormat::Int => read_int_wav_samples(&mut reader, spec.bits_per_sample)?,
    };

    Ok((samples, spec.sample_rate))
}

fn read_int_wav_samples(
    reader: &mut hound::WavReader<std::io::BufReader<fs::File>>,
    bits_per_sample: u16,
) -> CliResult<Vec<f32>> {
    match bits_per_sample {
        16 => reader
            .samples::<i16>()
            .map(|sample| {
                sample
                    .map(|value| value as f32 / i16::MAX as f32)
                    .map_err(|e| format!("failed to read WAV sample: {e}"))
            })
            .collect(),
        24 | 32 => {
            let scale = ((1_i64 << (bits_per_sample - 1)) - 1) as f32;
            reader
                .samples::<i32>()
                .map(|sample| {
                    sample
                        .map(|value| value as f32 / scale)
                        .map_err(|e| format!("failed to read WAV sample: {e}"))
                })
                .collect()
        }
        _ => Err(format!(
            "unsupported integer WAV bit depth: {bits_per_sample}; expected 16, 24, or 32"
        )),
    }
}

fn print_paths(paths: &AppPaths) -> CliResult<()> {
    println!("config_dir={}", paths.config_dir.display());
    println!("models_dir={}", paths.models_dir.display());
    Ok(())
}

fn print_usage() {
    println!(
        "Parakatt CLI\n\n\
Usage:\n\
  parakatt [--config-dir PATH] [--models-dir PATH] <command>\n\n\
Commands:\n\
  paths                         Print resolved config/model directories\n\
  models list                   List known speech models\n\
  models download <model-id>    Download a model\n\
  models delete <model-id>      Delete a downloaded model\n\
  modes list                    List configured transcription modes\n\
  history list                  List saved transcriptions\n\
  stats                         Show aggregate transcription statistics\n\
  transcribe [options] <file>   Transcribe 16 kHz mono WAV or raw f32le audio\n\n\
Run `parakatt <command> --help` for command-specific help."
    );
}

fn print_models_usage() {
    println!(
        "Usage:\n\
  parakatt models list\n\
  parakatt models download <model-id>\n\
  parakatt models delete <model-id>"
    );
}

fn print_modes_usage() {
    println!("Usage:\n  parakatt modes list [--format text|json]");
}

fn print_history_usage() {
    println!(
        "Usage:\n\
  parakatt history list [--limit N] [--offset N] [--source SOURCE] [--format text|json]\n\
  parakatt history search [options] <query>\n\
  parakatt history show [--format text|json] <id>\n\
  parakatt history delete <id> [id ...]"
    );
}

fn print_transcribe_usage() {
    println!(
        "Usage:\n\
  parakatt transcribe [--model MODEL] [--mode MODE] [--format text|json] [--raw-f32le] <file>\n\n\
Input must be 16 kHz mono audio. WAV supports 16/24/32-bit integer PCM or 32-bit float.\n\
Use --raw-f32le for headerless little-endian f32 samples."
    );
}

fn print_stats_usage() {
    println!("Usage:\n  parakatt stats [--format text|json]");
}

fn default_models_dir() -> CliResult<PathBuf> {
    let base = dirs::data_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| "could not resolve a data directory".to_string())?;
    Ok(base.join("parakatt").join("models"))
}

fn default_config_dir() -> CliResult<PathBuf> {
    let base = dirs::config_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| "could not resolve a config directory".to_string())?;
    Ok(base.join("parakatt"))
}

fn take_required_arg(args: &mut Vec<String>, label: &str) -> CliResult<String> {
    if args.is_empty() {
        return Err(format!("missing {label}"));
    }
    Ok(args.remove(0))
}

fn take_path_option(args: &mut Vec<String>, flag: &str) -> CliResult<Option<PathBuf>> {
    Ok(take_option(args, flag)?.map(PathBuf::from))
}

fn take_option(args: &mut Vec<String>, flag: &str) -> CliResult<Option<String>> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == flag {
            args.remove(i);
            if i >= args.len() {
                return Err(format!("{flag} requires a value"));
            }
            return Ok(Some(args.remove(i)));
        }
        i += 1;
    }
    Ok(None)
}

fn take_u32_option(args: &mut Vec<String>, flag: &str) -> CliResult<Option<u32>> {
    take_option(args, flag)?
        .map(|value| {
            value
                .parse::<u32>()
                .map_err(|_| format!("{flag} requires a non-negative integer"))
        })
        .transpose()
}

fn take_flag(args: &mut Vec<String>, flag: &str) -> bool {
    if let Some(index) = args.iter().position(|arg| arg == flag) {
        args.remove(index);
        true
    } else {
        false
    }
}

fn ensure_no_args(args: &[String], command: &str) -> CliResult<()> {
    if args.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "unexpected argument for {command}: {}",
            args.join(" ")
        ))
    }
}

fn format_core_error(error: CoreError) -> String {
    error.to_string()
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn print_modes(modes: &[ModeConfig], format: &str) -> CliResult<()> {
    match format {
        "text" => {
            println!("{:<16} {:<12} {:<12} DICTIONARY", "NAME", "STT", "LLM");
            for mode in modes {
                println!(
                    "{:<16} {:<12} {:<12} {}",
                    &mode.name,
                    mode.stt_provider.as_deref().unwrap_or("default"),
                    mode.llm_provider.as_deref().unwrap_or("none"),
                    if mode.dictionary_enabled { "yes" } else { "no" }
                );
            }
            Ok(())
        }
        "json" => {
            let values: Vec<_> = modes.iter().map(mode_json).collect();
            println!("{}", json!(values));
            Ok(())
        }
        _ => Err(format!("unknown output format: {format}; use text or json")),
    }
}

fn mode_json(mode: &ModeConfig) -> serde_json::Value {
    json!({
        "name": &mode.name,
        "stt_provider": &mode.stt_provider,
        "llm_provider": &mode.llm_provider,
        "system_prompt": &mode.system_prompt,
        "dictionary_enabled": mode.dictionary_enabled,
    })
}

fn print_stats(stats: &[Vec<String>], format: &str) -> CliResult<()> {
    match format {
        "text" => {
            for row in stats {
                if row.len() >= 2 {
                    println!("{:<24} {}", row[0], row[1]);
                }
            }
            Ok(())
        }
        "json" => {
            let values: Vec<_> = stats
                .iter()
                .filter_map(|row| {
                    if row.len() >= 2 {
                        Some(json!({ "key": &row[0], "value": &row[1] }))
                    } else {
                        None
                    }
                })
                .collect();
            println!("{}", json!(values));
            Ok(())
        }
        _ => Err(format!("unknown output format: {format}; use text or json")),
    }
}

fn print_transcriptions(records: &[StoredTranscription], format: &str) -> CliResult<()> {
    match format {
        "text" => {
            println!(
                "{:<36} {:<20} {:<13} {:<10} TEXT",
                "ID", "CREATED", "SOURCE", "MODE"
            );
            for record in records {
                println!(
                    "{:<36} {:<20} {:<13} {:<10} {}",
                    &record.id,
                    &record.created_at,
                    &record.source,
                    &record.mode,
                    preview_text(&record.text, 80)
                );
            }
            Ok(())
        }
        "json" => {
            let values: Vec<_> = records.iter().map(transcription_json).collect();
            println!("{}", json!(values));
            Ok(())
        }
        _ => Err(format!("unknown output format: {format}; use text or json")),
    }
}

fn print_transcription(record: &StoredTranscription, format: &str) -> CliResult<()> {
    match format {
        "text" => {
            println!("id: {}", record.id);
            println!("created_at: {}", record.created_at);
            println!("duration_secs: {:.2}", record.duration_secs);
            println!("source: {}", record.source);
            println!("mode: {}", record.mode);
            if let Some(audio_source) = &record.audio_source {
                println!("audio_source: {audio_source}");
            }
            if let Some(title) = &record.title {
                println!("title: {title}");
            }
            println!("\n{}", record.text);
            Ok(())
        }
        "json" => {
            println!("{}", transcription_json(record));
            Ok(())
        }
        _ => Err(format!("unknown output format: {format}; use text or json")),
    }
}

fn transcription_json(record: &StoredTranscription) -> serde_json::Value {
    json!({
        "id": &record.id,
        "created_at": &record.created_at,
        "duration_secs": record.duration_secs,
        "source": &record.source,
        "mode": &record.mode,
        "audio_source": &record.audio_source,
        "app_context": &record.app_context,
        "title": &record.title,
        "text": &record.text,
    })
}

fn preview_text(text: &str, max_chars: usize) -> String {
    let flattened = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut preview: String = flattened.chars().take(max_chars).collect();
    if flattened.chars().count() > max_chars {
        preview.push_str("...");
    }
    preview
}

fn segment_json(segment: &TimestampedSegment) -> serde_json::Value {
    json!({
        "text": &segment.text,
        "start_secs": segment.start_secs,
        "end_secs": segment.end_secs,
        "speaker": &segment.speaker,
    })
}
