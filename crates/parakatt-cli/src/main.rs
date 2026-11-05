#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::indexing_slicing,
        clippy::cast_possible_truncation,
        clippy::cast_possible_wrap,
        clippy::cast_sign_loss,
        clippy::let_underscore_must_use
    )
)]
use std::io::{self, Write};
use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};
use parakatt_cli::{default_models_dir, transcribe_file};

#[derive(Parser)]
#[command(
    name = "parakatt",
    version,
    about = "Local file transcription with Parakeet v3 on CPU"
)]
#[command(
    after_help = "Input: mono 16000 Hz WAV or explicit raw f32le, up to 30 seconds.\nPrints text/JSON without saving history. Model files must be installed in advance."
)]
struct Cli {
    /// Root directory containing the installed Parakeet v3 model
    #[arg(long, global = true)]
    models_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Transcribe an audio file to stdout
    Transcribe {
        audio: PathBuf,
        #[arg(long, value_enum, default_value_t = Format::Text)]
        format: Format,
        /// Read headerless little-endian 32-bit floats instead of WAV
        #[arg(long)]
        raw_f32le: bool,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Text,
    Json,
}

fn main() {
    let cli = Cli::parse();
    if let Err(error) = run(cli) {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<(), String> {
    let Command::Transcribe {
        audio,
        format,
        raw_f32le,
    } = cli.command;
    if matches!(format, Format::Json) && audio.to_str().is_none() {
        return Err("JSON output requires a UTF-8 input path".into());
    }
    let models = match cli.models_dir {
        Some(directory) => directory,
        None => default_models_dir()?,
    };
    parakatt_core::init_logging(Some("warn".into()));
    let result = transcribe_file(&audio, &models, raw_f32le)?;
    let mut output = io::stdout().lock();
    match format {
        Format::Text => writeln!(output, "{}", result.text).map_err(|e| e.to_string())?,
        Format::Json => {
            serde_json::to_writer(&mut output, &result).map_err(|e| e.to_string())?;
            writeln!(output).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
