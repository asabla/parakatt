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

        // Check for existing partial download to resume
        let existing_bytes: u64 = if part_path.exists() {
            fs::metadata(&part_path).map(|m| m.len()).unwrap_or(0)
        } else {
            0
        };

        if existing_bytes > 0 {
            log::info!("Resuming {url} from byte {existing_bytes}");
        } else {
            log::info!("Downloading {url}");
        }

        // Update progress for this file
        {
            let mut p = progress.lock().unwrap();
            p.current_file = filename.to_string();
            p.file_index = i as u32;
            p.bytes_downloaded = existing_bytes;
            p.bytes_total = 0;
        }

        // Send Range header if resuming
        let mut req = client.get(&url);
        if existing_bytes > 0 {
            req = req.header("Range", format!("bytes={existing_bytes}-"));
        }

        let response = req.send().map_err(|e| {
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: format!("Failed to download {filename}: {e}"),
            };
            CoreError::IoError(format!("Download failed for {filename}: {e}"))
        })?;

        let status = response.status();
        if !status.is_success() && status.as_u16() != 206 {
            // If Range request fails (416 = range not satisfiable), start fresh
            if status.as_u16() == 416 {
                log::warn!("Range not satisfiable for {filename}, restarting download");
                let _ = fs::remove_file(&part_path);
            } else {
                let msg = format!("HTTP {} for {filename}", status);
                let mut p = progress.lock().unwrap();
                p.state = DownloadState::Failed {
                    message: msg.clone(),
                };
                return Err(CoreError::IoError(msg));
            }
        }

        // Determine total file size from Content-Range or Content-Length
        let total_size = if status.as_u16() == 206 {
            // Parse Content-Range: bytes 1000-9999/10000
            response
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.rsplit('/').next())
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(existing_bytes + response.content_length().unwrap_or(0))
        } else {
            response.content_length().unwrap_or(0)
        };

        {
            let mut p = progress.lock().unwrap();
            p.bytes_total = total_size;
        }

        // Open file in append mode if resuming, create if starting fresh
        let mut file = if existing_bytes > 0 && status.as_u16() == 206 {
            fs::OpenOptions::new().append(true).open(&part_path)
        } else {
            fs::File::create(&part_path).map(|f| f)
        }
        .map_err(|e| {
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: format!("Cannot open {}: {e}", part_path.display()),
            };
            CoreError::IoError(format!("Cannot open file: {e}"))
        })?;

        let mut reader = response;
        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut downloaded: u64 = existing_bytes;

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

        // Verify downloaded size matches total expected size
        if total_size > 0 && downloaded != total_size {
            drop(file);
            cleanup_part_files(&model_dir, file_set.files);
            let msg = format!(
                "Size mismatch for {filename}: expected {total_size} bytes, got {downloaded}"
            );
            let mut p = progress.lock().unwrap();
            p.state = DownloadState::Failed {
                message: msg.clone(),
            };
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
