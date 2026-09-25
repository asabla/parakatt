/// Model downloading with progress reporting and cancellation.
///
/// Downloads model files from HuggingFace in chunks, writing to `.part`
/// temp files and renaming on completion. Progress is reported via a
/// shared `Mutex<DownloadProgress>` that Swift polls across the FFI boundary.
use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::models;
use crate::CoreError;

/// Lock the progress mutex, recovering the inner value if a previous holder
/// panicked. Download progress is a polled, write-only snapshot — losing a
/// few intermediate updates because a writer panicked is far better than
/// poisoning the mutex and crashing every subsequent progress update.
fn lock_progress(progress: &Mutex<DownloadProgress>) -> MutexGuard<'_, DownloadProgress> {
    progress.lock().unwrap_or_else(|poisoned| {
        log::warn!("Download progress mutex was poisoned; recovering inner value");
        poisoned.into_inner()
    })
}

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

/// Download into revision-specific staging. Existing installations are untouched.
pub fn download_model(
    models_dir: &Path,
    model_id: &str,
    progress: Arc<Mutex<DownloadProgress>>,
    cancel: Arc<AtomicBool>,
) -> Result<(), CoreError> {
    let result = download_inner(models_dir, model_id, &progress, &cancel);
    if let Err(error) = &result {
        lock_progress(&progress).state = DownloadState::Failed {
            message: error.to_string(),
        };
    }
    result
}
/// Explicit benchmark-only candidates. These are not selectable by the app.
pub fn download_candidate(root: &Path, id: &str) -> Result<(), CoreError> {
    let candidates: Vec<models::ModelManifest> =
        serde_json::from_str(include_str!("../model-candidates.json"))
            .expect("candidate manifests");
    let manifest = candidates
        .iter()
        .find(|m| m.id == id)
        .ok_or_else(|| CoreError::ModelNotFound(id.into()))?;
    download_manifest(
        root,
        manifest,
        &Mutex::new(DownloadProgress::idle()),
        &AtomicBool::new(false),
        None,
    )
}
fn download_inner(
    root: &Path,
    id: &str,
    progress: &Mutex<DownloadProgress>,
    cancel: &AtomicBool,
) -> Result<(), CoreError> {
    let manifest = models::model_file_set(id).ok_or_else(|| CoreError::ModelNotFound(id.into()))?;
    download_manifest(root, manifest, progress, cancel, None)
}
fn download_manifest(
    root: &Path,
    manifest: &models::ModelManifest,
    progress: &Mutex<DownloadProgress>,
    cancel: &AtomicBool,
    test_url: Option<&str>,
) -> Result<(), CoreError> {
    let id = &manifest.id;
    let url = |name: &str| {
        test_url
            .map(|url| format!("{url}/{name}"))
            .unwrap_or_else(|| manifest.url(name))
    };
    let stage = root
        .join(".staging")
        .join(format!("{id}-{}", manifest.revision));
    let active = root.join(id).join(&manifest.revision);
    fs::create_dir_all(&stage).map_err(io_error)?;
    *lock_progress(progress) = DownloadProgress {
        model_id: id.into(),
        state: DownloadState::Downloading,
        current_file: String::new(),
        file_index: 0,
        total_files: manifest.files.len() as u32,
        bytes_downloaded: 0,
        bytes_total: 0,
    };
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(30))
        .timeout(std::time::Duration::from_secs(1800))
        .build()
        .map_err(|e| CoreError::IoError(e.to_string()))?;
    for (index, file) in manifest.files.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            lock_progress(progress).state = DownloadState::Cancelled;
            return Ok(());
        }
        let destination = stage.join(&file.name);
        {
            let mut p = lock_progress(progress);
            p.file_index = index as u32;
            p.current_file = file.name.clone();
            p.bytes_total = file.size;
            p.bytes_downloaded = 0;
        }
        if models::verify_file(&destination, file).is_ok() {
            continue;
        }
        let part = stage.join(format!("{}.part", file.name));
        let mut existing = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        if existing == file.size && models::verify_file(&part, file).is_ok() {
            fs::rename(&part, &destination).map_err(io_error)?;
            continue;
        }
        if existing >= file.size {
            fs::remove_file(&part).map_err(io_error)?;
            existing = 0;
        }
        let mut request = client.get(url(&file.name));
        if existing > 0 {
            request = request.header("Range", format!("bytes={existing}-"));
        }
        let mut response = request
            .send()
            .map_err(|e| CoreError::IoError(e.to_string()))?;
        if response.status().as_u16() == 416 {
            existing = 0;
            response = client
                .get(url(&file.name))
                .send()
                .map_err(|e| CoreError::IoError(e.to_string()))?;
        }
        response
            .error_for_status_ref()
            .map_err(|e| CoreError::IoError(e.to_string()))?;
        if response.status().as_u16() == 206 {
            let range = response
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !range.starts_with(&format!("bytes {existing}-"))
                || !range.ends_with(&format!("/{}", file.size))
            {
                return Err(CoreError::IoError("Invalid resume range".into()));
            }
        } else {
            existing = 0;
        }
        let mut output = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(existing == 0)
            .append(existing > 0)
            .open(&part)
            .map_err(io_error)?;
        let mut total = existing;
        let mut buffer = vec![0; 1024 * 1024];
        loop {
            if cancel.load(Ordering::Relaxed) {
                lock_progress(progress).state = DownloadState::Cancelled;
                return Ok(());
            }
            let n = response.read(&mut buffer).map_err(io_error)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > file.size {
                return Err(CoreError::IoError("Download exceeds manifest size".into()));
            }
            output.write_all(&buffer[..n]).map_err(io_error)?;
            lock_progress(progress).bytes_downloaded = total;
        }
        output.sync_all().map_err(io_error)?;
        drop(output);
        if let Err(error) = models::verify_file(&part, file) {
            let _ = fs::remove_file(&part);
            return Err(error);
        }
        fs::rename(&part, &destination).map_err(io_error)?;
    }
    models::verify_model(&stage, manifest)?;
    if cancel.load(Ordering::Relaxed) {
        lock_progress(progress).state = DownloadState::Cancelled;
        return Ok(());
    }
    fs::create_dir_all(root.join(id)).map_err(io_error)?;
    if active.exists() {
        if models::verify_model(&active, manifest).is_ok() {
            fs::remove_dir_all(&stage).map_err(io_error)?;
        } else {
            let rejected = root
                .join(".staging")
                .join(format!("{id}-rejected-{}", uuid::Uuid::new_v4()));
            fs::rename(&active, &rejected).map_err(io_error)?;
            if let Err(error) = fs::rename(&stage, &active) {
                let _ = fs::rename(&rejected, &active);
                return Err(io_error(error));
            }
        }
    } else {
        fs::rename(&stage, &active).map_err(io_error)?;
    }
    let mut p = lock_progress(progress);
    p.state = DownloadState::Completed;
    p.file_index = p.total_files;
    p.current_file.clear();
    Ok(())
}
fn io_error(e: std::io::Error) -> CoreError {
    CoreError::IoError(e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    fn fixture() -> models::ModelManifest {
        let mut m = models::manifests()[0].clone();
        m.id = "test-model".into();
        m.files = vec![models::ModelFile {
            name: "weights".into(),
            size: 6,
            sha256: format!("{:x}", Sha256::digest(b"abcdef")),
        }];
        m
    }
    fn server(
        body: &'static str,
        status: u16,
        header: &'static str,
    ) -> (String, std::thread::JoinHandle<String>) {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            loop {
                let mut b = [0; 1024];
                let n = socket.read(&mut b).unwrap();
                assert!(n > 0);
                request.extend_from_slice(&b[..n]);
                if request.windows(4).any(|v| v == b"\r\n\r\n") {
                    break;
                }
            }
            write!(socket,"HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nConnection: close\r\n{header}\r\n{body}",body.len()).unwrap();
            String::from_utf8(request).unwrap()
        });
        (address, worker)
    }
    #[test]
    fn resumes_only_with_verified_range_and_activates_complete_files() {
        let root = tempfile::tempdir().unwrap();
        let m = fixture();
        let stage = root
            .path()
            .join(".staging")
            .join(format!("{}-{}", m.id, m.revision));
        fs::create_dir_all(&stage).unwrap();
        fs::write(stage.join("weights.part"), b"abc").unwrap();
        let (url, server) = server("def", 206, "Content-Range: bytes 3-5/6\r\n");
        let progress = Mutex::new(DownloadProgress::idle());
        download_manifest(
            root.path(),
            &m,
            &progress,
            &AtomicBool::new(false),
            Some(&url),
        )
        .unwrap();
        assert!(server
            .join()
            .unwrap()
            .to_lowercase()
            .contains("range: bytes=3-"));
        assert_eq!(progress.lock().unwrap().state, DownloadState::Completed);
        models::verify_model(&root.path().join(&m.id).join(&m.revision), &m).unwrap();
    }
    #[test]
    fn corruption_keeps_the_previous_installation() {
        let root = tempfile::tempdir().unwrap();
        let m = fixture();
        let legacy = root.path().join(&m.id);
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("weights"), b"abcdef").unwrap();
        let (url, server) = server("wrong!", 200, "");
        assert!(download_manifest(
            root.path(),
            &m,
            &Mutex::new(DownloadProgress::idle()),
            &AtomicBool::new(false),
            Some(&url)
        )
        .is_err());
        server.join().unwrap();
        models::verify_model(&legacy, &m).unwrap();
        assert!(!legacy.join(&m.revision).exists());
    }
    #[test]
    fn cancellation_does_not_activate_staging() {
        let root = tempfile::tempdir().unwrap();
        let m = fixture();
        let progress = Mutex::new(DownloadProgress::idle());
        download_manifest(root.path(), &m, &progress, &AtomicBool::new(true), None).unwrap();
        assert_eq!(progress.lock().unwrap().state, DownloadState::Cancelled);
        assert!(!root.path().join(&m.id).join(&m.revision).exists());
    }
    #[test]
    fn invalid_resume_range_is_rejected() {
        let root = tempfile::tempdir().unwrap();
        let m = fixture();
        let (url, server) = server("def", 206, "Content-Range: bytes 3-5/6\r\n");
        assert!(download_manifest(
            root.path(),
            &m,
            &Mutex::new(DownloadProgress::idle()),
            &AtomicBool::new(false),
            Some(&url)
        )
        .is_err());
        server.join().unwrap();
    }
}
