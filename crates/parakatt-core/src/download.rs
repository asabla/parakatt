/// Model downloading with progress reporting and cancellation.
///
/// Downloads model files from HuggingFace in chunks, writing to `.part`
/// temp files and renaming on completion. Progress is reported via a
/// shared `Mutex<DownloadProgress>` that Swift polls across the FFI boundary.

use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::models;
use crate::CoreError;

/// State of a model download.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum DownloadState {
    /// No download in progress.
    Idle,
    /// Currently downloading files.
    Downloading,
    /// All files downloaded successfully.
    Completed,
    /// Download failed.
    Failed { message: String },
    /// Download was cancelled by the user.
    Cancelled,
}

/// Progress of an ongoing model download, polled by Swift.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DownloadProgress {
    pub model_id: String,
    pub state: DownloadState,
    pub current_file: String,
    pub file_index: u32,
    pub total_files: u32,
    pub bytes_downloaded: u64,
    pub bytes_total: u64,
}

impl DownloadProgress {
    pub fn idle() -> Self {
        Self {
            model_id: String::new(),
            state: DownloadState::Idle,
            current_file: String::new(),
            file_index: 0,
            total_files: 0,
            bytes_downloaded: 0,
            bytes_total: 0,
        }
    }
}

const CHUNK_SIZE: usize = 8 * 1024; // 8KB read chunks

/// Download all files for a model, reporting progress and respecting cancellation.
///
/// - Skips files that already exist in the model directory.
/// - Downloads to `.part` temp files, renames on completion.
/// - Cleans up `.part` files on failure or cancellation.
pub fn download_model(
    models_dir: &Path,
    model_id: &str,
    progress: Arc<Mutex<DownloadProgress>>,
    cancel: Arc<AtomicBool>,
) -> Result<(), CoreError> {
    let file_set = models::model_file_set(model_id).ok_or_else(|| {
        CoreError::ModelNotFound(format!("No download info for model: {model_id}"))
    })?;

    let model_dir = models_dir.join(model_id);
    fs::create_dir_all(&model_dir)
        .map_err(|e| CoreError::IoError(format!("Failed to create model dir: {e}")))?;

    let total_files = file_set.files.len() as u32;

    // Initialize progress
    {
        let mut p = progress.lock().unwrap();
        *p = DownloadProgress {
            model_id: model_id.to_string(),
            state: DownloadState::Downloading,
            current_file: String::new(),
            file_index: 0,
            total_files,
            bytes_downloaded: 0,
            bytes_total: 0,
        };
    }

    let client = reqwest::blocking::Client::builder()
        .timeout(None) // Large files, no overall timeout
        .connect_timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| CoreError::IoError(format!("HTTP client error: {e}")))?;

    for (i, filename) in file_set.files.iter().enumerate() {
        // Check cancel before starting each file
        if cancel.load(Ordering::Relaxed) {
            cleanup_part_files(&model_dir, file_set.files);
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Cancelled;
            return Ok(());
        }

        let dest = model_dir.join(filename);

        // Skip files that already exist
        if dest.exists() {
            log::info!("Skipping {filename} — already exists");
            let mut p = progress.lock().unwrap();
            p.file_index = i as u32 + 1;
            p.current_file = filename.to_string();
            continue;
        }

        let part_path = model_dir.join(format!("{filename}.part"));
        let url = format!("{}/{filename}", file_set.repo_url);

        log::info!("Downloading {url}");

        // Update progress for this file
        {
            let mut p = progress.lock().unwrap();
            p.current_file = filename.to_string();
            p.file_index = i as u32;
            p.bytes_downloaded = 0;
            p.bytes_total = 0;
        }

        let response = client.get(&url).send().map_err(|e| {
            cleanup_part_files(&model_dir, file_set.files);
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: format!("Failed to download {filename}: {e}"),
            };
            CoreError::IoError(format!("Download failed for {filename}: {e}"))
        })?;

        if !response.status().is_success() {
            cleanup_part_files(&model_dir, file_set.files);
            let msg = format!("HTTP {} for {filename}", response.status());
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: msg.clone(),
            };
            return Err(CoreError::IoError(msg));
        }

        let content_length = response.content_length().unwrap_or(0);
        {
            let mut p = progress.lock().unwrap();
            p.bytes_total = content_length;
        }

        // Stream response body to .part file
        let mut file = fs::File::create(&part_path).map_err(|e| {
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: format!("Cannot create {}: {e}", part_path.display()),
            };
            CoreError::IoError(format!("Cannot create file: {e}"))
        })?;

        let mut reader = response;
        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut downloaded: u64 = 0;

        loop {
            // Check cancel between chunks
            if cancel.load(Ordering::Relaxed) {
                drop(file);
                cleanup_part_files(&model_dir, file_set.files);
                let mut p = progress.lock().unwrap();
                p.state = DownloadState::Cancelled;
                return Ok(());
            }

            let n = match reader.read(&mut buf) {
                Ok(n) => n,
                Err(e) => {
                    drop(file);
                    cleanup_part_files(&model_dir, file_set.files);
                    let mut p = progress.lock().unwrap();
                    p.state = DownloadState::Failed {
                        message: format!("Read error for {filename}: {e}"),
                    };
                    return Err(CoreError::IoError(format!("Read error: {e}")));
                }
            };

            if n == 0 {
                break;
            }

            file.write_all(&buf[..n]).map_err(|e| {
                cleanup_part_files(&model_dir, file_set.files);
                let mut p = progress.lock().unwrap();
                p.state = DownloadState::Failed {
                    message: format!("Write error for {filename}: {e}"),
                };
                CoreError::IoError(format!("Write error: {e}"))
            })?;

            downloaded += n as u64;
            {
                let mut p = progress.lock().unwrap();
                p.bytes_downloaded = downloaded;
            }
        }

        // Verify downloaded size matches Content-Length if available
        if content_length > 0 && downloaded != content_length {
            drop(file);
            cleanup_part_files(&model_dir, file_set.files);
            let msg = format!(
                "Size mismatch for {filename}: expected {content_length} bytes, got {downloaded}"
            );
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed { message: msg.clone() };
            return Err(CoreError::IoError(msg));
        }

        // Rename .part to final name
        fs::rename(&part_path, &dest).map_err(|e| {
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: format!("Failed to rename {}: {e}", part_path.display()),
            };
            CoreError::IoError(format!("Rename failed: {e}"))
        })?;

        log::info!("Downloaded {filename} ({downloaded} bytes, verified)");
    }

    // All files done
    {
        let mut p = progress.lock().unwrap();
        p.state = DownloadState::Completed;
        p.file_index = total_files;
        p.current_file = String::new();
    }

    Ok(())
}

/// Remove all `.part` temp files for the given file list.
fn cleanup_part_files(model_dir: &Path, files: &[&str]) {
    for filename in files {
        let part = model_dir.join(format!("{filename}.part"));
        if part.exists() {
            let _ = fs::remove_file(&part);
        }
    }
}
