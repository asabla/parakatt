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
use parakatt_core::chatgpt::{ChatGptAccounts, ChatGptProvider, USAGE_URL};

#[derive(Parser)]
#[command(
    name = "parakatt",
    version,
    about = "Local file transcription with optional ChatGPT text processing"
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
    /// Transcribe an audio file to stdout; text processing requires --llm
    Transcribe {
        audio: PathBuf,
        #[arg(long, value_enum, default_value_t = Format::Text)]
        format: Format,
        #[arg(long)]
        raw_f32le: bool,
        /// Send recognized text to the selected ChatGPT account
        #[arg(long, value_enum, requires = "llm_model")]
        llm: Option<Provider>,
        #[arg(long, requires = "llm")]
        llm_model: Option<String>,
        #[arg(long, value_enum, requires = "llm")]
        mode: Option<Mode>,
    },
    /// Manage the ChatGPT accounts shared with the macOS app
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },
    /// Inspect text-processing providers
    Llm {
        #[command(subcommand)]
        command: LlmCommand,
    },
}
#[derive(Subcommand)]
enum AuthCommand {
    Login {
        #[arg(long)]
        account: Option<String>,
    },
    List,
    Use {
        id: String,
    },
    Status,
    Logout {
        #[arg(long)]
        account: Option<String>,
    },
}
#[derive(Subcommand)]
enum LlmCommand {
    Models {
        #[arg(long, value_enum)]
        provider: Provider,
    },
}
#[derive(Clone, Copy, ValueEnum)]
enum Provider {
    Chatgpt,
}
#[derive(Clone, Copy, ValueEnum)]
enum Format {
    Text,
    Json,
}
#[derive(Clone, Copy, ValueEnum)]
enum Mode {
    Clean,
    Email,
    Code,
}
impl Mode {
    fn name(self) -> &'static str {
        match self {
            Self::Clean => "clean",
            Self::Email => "email",
            Self::Code => "code",
        }
    }
}
fn main() {
    match run(Cli::parse()) {
        Ok(0) => {}
        Ok(code) => std::process::exit(i32::from(code)),
        Err(error) => {
            eprintln!("error: {error}");
            std::process::exit(1);
        }
    }
}
fn run(cli: Cli) -> Result<u8, String> {
    match cli.command {
        Command::Auth { command } => auth(command),
        Command::Llm {
            command: LlmCommand::Models {
                provider: Provider::Chatgpt,
            },
        } => {
            let accounts = ChatGptAccounts::new().map_err(|e| e.to_string())?;
            for model in accounts.models(None).map_err(|e| e.to_string())? {
                println!("{}\t{}", model.slug, model.display_name);
            }
            Ok(0)
        }
        Command::Transcribe {
            audio,
            format,
            raw_f32le,
            llm,
            llm_model,
            mode,
        } => {
            if matches!(format, Format::Json) && audio.to_str().is_none() {
                return Err("JSON output requires a UTF-8 input path".into());
            }
            let models = match cli.models_dir {
                Some(directory) => directory,
                None => default_models_dir()?,
            };
            parakatt_core::init_logging(Some("warn".into()));
            let mut result = transcribe_file(&audio, &models, raw_f32le)?;
            if llm.is_some() {
                let model = llm_model.ok_or("--llm-model is required")?;
                let provider = ChatGptAccounts::new().and_then(|accounts| {
                    // A new explicit CLI invocation is an explicit retry.
                    accounts.retry(None)?;
                    ChatGptProvider::new(accounts, None, model.clone())
                });
                let processing = match provider {
                    Ok(provider) => parakatt_cli::processing::process(
                        &result.text,
                        &model,
                        mode.unwrap_or(Mode::Clean).name(),
                        Ok(&provider),
                    ),
                    Err(error) => {
                        parakatt_cli::processing::process(&result.text, &model, "clean", Err(error))
                    }
                };
                if let Some(error) = &processing.error {
                    eprintln!(
                        "ChatGPT {}: {}\nManage usage: {USAGE_URL}",
                        error.code, error.message
                    );
                }
                result.processing = Some(processing);
            }
            write_transcript(&result, format, &mut io::stdout().lock())
        }
    }
}
fn write_transcript(
    result: &parakatt_cli::FileTranscript,
    format: Format,
    output: &mut impl Write,
) -> Result<u8, String> {
    match format {
        Format::Text => writeln!(
            output,
            "{}",
            result
                .processing
                .as_ref()
                .and_then(|p| p.processed_text.as_deref())
                .unwrap_or(&result.text)
        )
        .map_err(|e| e.to_string())?,
        Format::Json => {
            serde_json::to_writer(&mut *output, result).map_err(|e| e.to_string())?;
            writeln!(output).map_err(|e| e.to_string())?;
        }
    }
    Ok(
        if result
            .processing
            .as_ref()
            .is_some_and(|p| p.error.is_some())
        {
            3
        } else {
            0
        },
    )
}
fn auth(command: AuthCommand) -> Result<u8, String> {
    let accounts = ChatGptAccounts::new().map_err(|e| e.to_string())?;
    match command {
        AuthCommand::Login { account } => {
            let attempt = accounts.begin_sign_in(account).map_err(|e| e.to_string())?;
            // Authorization URLs contain no access, refresh, or ID tokens.
            eprintln!(
                "Continue with ChatGPT in your browser: {}",
                attempt.authorization_url
            );
            let program = if cfg!(target_os = "macos") {
                "open"
            } else {
                "xdg-open"
            };
            let _browser = std::process::Command::new(program)
                .arg(&attempt.authorization_url)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
            let account = accounts
                .complete_sign_in(attempt.id)
                .map_err(|e| e.to_string())?;
            println!("Connected: {}", account.label);
            if !account.plan_enabled {
                eprintln!("ChatGPT plan usage is disabled. Sign in again to grant permission.");
            }
            if accounts
                .take_plan_confirmation(account.id)
                .map_err(|e| e.to_string())?
            {
                eprintln!(
                    "Eligible text processing uses your ChatGPT plan. Manage usage: {USAGE_URL}"
                );
            }
        }
        AuthCommand::List | AuthCommand::Status => {
            let saved = accounts.list().map_err(|e| e.to_string())?;
            if saved.is_empty() {
                println!("No saved ChatGPT accounts. Use parakatt auth login.");
            }
            for account in saved {
                println!(
                    "{}\t{}\t{}{}",
                    if account.active { "active" } else { "saved" },
                    account.label,
                    if account.signed_in {
                        if account.plan_enabled {
                            "plan enabled"
                        } else {
                            "consent required"
                        }
                    } else {
                        "signed out"
                    },
                    if account.paused {
                        " (usage paused)"
                    } else {
                        ""
                    }
                );
            }
            println!("Manage usage: {USAGE_URL}");
        }
        AuthCommand::Use { id } => accounts.select(id).map_err(|e| e.to_string())?,
        AuthCommand::Logout { account } => println!(
            "{}",
            accounts
                .sign_out(account)
                .map_err(|e| e.to_string())?
                .message
        ),
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use parakatt_cli::{FileSource, FileTranscript, Segment};
    use parakatt_core::{
        llm::{LlmProvider, LlmRequest},
        CoreError,
    };
    struct Polish;
    impl LlmProvider for Polish {
        fn process(&self, request: &LlmRequest) -> Result<String, CoreError> {
            assert_eq!(request.text, "Talet är 42");
            assert!(request.context.is_none());
            assert!(request.preceding_text.is_none());
            assert!(request.system_prompt.contains("grammar"));
            Ok("Talet är 42.".into())
        }
        fn name(&self) -> &str {
            "chatgpt"
        }
        fn is_available(&self) -> bool {
            true
        }
    }
    fn transcript() -> FileTranscript {
        FileTranscript {
            source: FileSource {
                kind: "file",
                path: "speech.wav".into(),
            },
            model: "parakeet-tdt-0.6b-v3",
            backend: "cpu",
            text: "Talet är 42".into(),
            duration_secs: 1.0,
            segments: vec![Segment {
                text: "Talet är 42".into(),
                start_secs: 0.0,
                end_secs: 1.0,
            }],
            processing: None,
        }
    }
    #[test]
    fn processing_requires_explicit_provider_and_model() {
        for args in [
            vec!["parakatt", "transcribe", "speech.wav", "--llm", "chatgpt"],
            vec![
                "parakatt",
                "transcribe",
                "speech.wav",
                "--llm-model",
                "model",
            ],
            vec!["parakatt", "transcribe", "speech.wav", "--mode", "clean"],
        ] {
            assert!(Cli::try_parse_from(args).is_err());
        }
        assert!(Cli::try_parse_from([
            "parakatt",
            "transcribe",
            "speech.wav",
            "--llm",
            "chatgpt",
            "--llm-model",
            "model"
        ])
        .is_ok());
        assert!(Cli::try_parse_from(["parakatt", "auth", "status"]).is_ok());
        assert!(
            Cli::try_parse_from(["parakatt", "llm", "models", "--provider", "chatgpt"]).is_ok()
        );
    }
    #[test]
    fn plain_json_has_no_processing_and_processed_json_keeps_timeline() {
        let mut result = transcript();
        let mut plain = Vec::new();
        write_transcript(&result, Format::Json, &mut plain).unwrap();
        let plain: serde_json::Value = serde_json::from_slice(&plain).unwrap();
        assert!(plain.get("processing").is_none());
        result.processing = Some(parakatt_cli::processing::process(
            &result.text,
            "model",
            "clean",
            Ok(&Polish),
        ));
        let mut json = Vec::new();
        write_transcript(&result, Format::Json, &mut json).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&json).unwrap();
        assert_eq!(json["text"], plain["text"]);
        assert_eq!(json["segments"], plain["segments"]);
        assert_eq!(json["processing"]["processed_text"], "Talet är 42.");
        let mut text = Vec::new();
        write_transcript(&result, Format::Text, &mut text).unwrap();
        assert_eq!(String::from_utf8(text).unwrap(), "Talet är 42.\n");
    }
    #[test]
    fn processing_failure_returns_recognized_text_and_safe_code() {
        let mut result = transcript();
        result.processing = Some(parakatt_cli::processing::process(
            &result.text,
            "model",
            "clean",
            Err(CoreError::ChatGptError {
                code: "subscription_sharing_usage_limit_exceeded".into(),
                message: "Manage usage".into(),
                request_id: Some("request-test".into()),
                http_status: Some(429),
                param: None,
            }),
        ));
        let mut output = Vec::new();
        assert_eq!(
            write_transcript(&result, Format::Text, &mut output).unwrap(),
            3
        );
        assert_eq!(String::from_utf8(output).unwrap(), "Talet är 42\n");
        let mut output = Vec::new();
        write_transcript(&result, Format::Json, &mut output).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(json["processing"]["status"], "failed");
        assert_eq!(
            json["processing"]["error"]["code"],
            "subscription_sharing_usage_limit_exceeded"
        );
        assert!(json["processing"].get("processed_text").is_none());
    }
}
