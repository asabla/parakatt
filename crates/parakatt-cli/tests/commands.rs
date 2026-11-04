use std::path::Path;
use std::process::{Command, Output};

fn run(directory: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_parakatt"))
        .args(args)
        .current_dir(directory)
        .output()
        .unwrap()
}

#[test]
fn help_and_version_need_no_model_or_state() {
    let temp = tempfile::tempdir().unwrap();
    for args in [
        vec!["--help"],
        vec!["transcribe", "--help"],
        vec!["--version"],
    ] {
        let output = run(temp.path(), &args);
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        assert!(!output.stdout.is_empty());
    }
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
}

#[test]
fn invalid_format_fails_in_argument_parsing_without_filesystem_side_effects() {
    let temp = tempfile::tempdir().unwrap();
    let output = run(
        temp.path(),
        &[
            "--models-dir",
            "missing-models",
            "transcribe",
            "missing.wav",
            "--format",
            "xml",
        ],
    );
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("xml") && error.contains("text, json"));
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
}

#[test]
fn bad_audio_fails_before_model_loading_and_creates_no_history() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("bad.raw"), f32::NAN.to_le_bytes()).unwrap();
    let output = run(
        temp.path(),
        &[
            "transcribe",
            "bad.raw",
            "--raw-f32le",
            "--models-dir",
            "missing-models",
            "--format",
            "json",
        ],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let error = String::from_utf8(output.stderr).unwrap();
    assert!(error.contains("finite") && !error.contains("verify model"));
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
}

#[test]
fn supported_input_reports_missing_model_without_creating_a_model_directory() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(temp.path().join("input.raw"), 0.25_f32.to_le_bytes()).unwrap();
    let output = run(
        temp.path(),
        &[
            "transcribe",
            "input.raw",
            "--raw-f32le",
            "--models-dir",
            "missing-models",
        ],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8(output.stderr)
        .unwrap()
        .contains("Cannot verify model"));
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
}

#[cfg(unix)]
#[test]
fn non_utf8_json_path_is_rejected_before_reading_or_loading() {
    use std::os::unix::ffi::OsStrExt;
    let temp = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_parakatt"))
        .args(["transcribe", "--format", "json"])
        .arg(std::ffi::OsStr::from_bytes(b"input-\xff.wav"))
        .current_dir(temp.path())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8(output.stderr).unwrap().contains("UTF-8"));
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
}
