//! Pinned, verified model installations. Call verification on a worker thread.
use crate::{CoreError, ModelInfo, ModelInstallationState};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::SystemTime,
};

#[derive(Debug, Clone, serde::Deserialize)]
pub struct ModelFile {
    pub name: String,
    pub size: u64,
    pub sha256: String,
}
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ModelManifest {
    pub id: String,
    pub display_name: String,
    pub provider_type: String,
    pub repo: String,
    pub revision: String,
    pub subdirectory: String,
    pub precision: String,
    pub languages: Vec<String>,
    pub files: Vec<ModelFile>,
}
impl ModelManifest {
    pub fn url(&self, name: &str) -> String {
        format!(
            "https://huggingface.co/{}/resolve/{}/{}{}",
            self.repo, self.revision, self.subdirectory, name
        )
    }
}
pub fn manifests() -> &'static [ModelManifest] {
    static MANIFESTS: OnceLock<Vec<ModelManifest>> = OnceLock::new();
    MANIFESTS.get_or_init(|| {
        serde_json::from_str(include_str!("../model-manifests.json"))
            .expect("checked-in model manifests must be valid")
    })
}
pub fn model_file_set(id: &str) -> Option<&'static ModelManifest> {
    manifests().iter().find(|m| m.id == id)
}
pub fn model_path(root: &Path, id: &str) -> PathBuf {
    let legacy = root.join(id);
    if let Some(manifest) = model_file_set(id) {
        let pinned = legacy.join(&manifest.revision);
        if pinned.is_dir() {
            return pinned;
        }
    }
    legacy
}

pub fn verify_file(path: &Path, file: &ModelFile) -> Result<(), CoreError> {
    let mut input = fs::File::open(path).map_err(io_error)?;
    if input.metadata().map_err(io_error)?.len() != file.size {
        return Err(CoreError::ModelLoadFailed(format!(
            "Size mismatch: {}",
            file.name
        )));
    }
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        let n = input.read(&mut buffer).map_err(io_error)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    if format!("{:x}", hash.finalize()) != file.sha256 {
        return Err(CoreError::ModelLoadFailed(format!(
            "Checksum mismatch: {}",
            file.name
        )));
    }
    Ok(())
}
fn io_error(e: std::io::Error) -> CoreError {
    CoreError::IoError(e.to_string())
}
type Signature = Vec<(String, u64, SystemTime)>;
static VERIFIED: OnceLock<Mutex<HashMap<PathBuf, Signature>>> = OnceLock::new();

pub fn verify_model(directory: &Path, manifest: &ModelManifest) -> Result<(), CoreError> {
    let signature: Signature = manifest
        .files
        .iter()
        .map(|file| {
            let metadata = fs::metadata(directory.join(&file.name)).map_err(io_error)?;
            Ok((
                file.sha256.clone(),
                metadata.len(),
                metadata.modified().map_err(io_error)?,
            ))
        })
        .collect::<Result<_, CoreError>>()?;
    let cache = VERIFIED.get_or_init(|| Mutex::new(HashMap::new()));
    if cache.lock().unwrap().get(directory) == Some(&signature) {
        return Ok(());
    }
    for file in &manifest.files {
        verify_file(&directory.join(&file.name), file)?;
    }
    cache
        .lock()
        .unwrap()
        .insert(directory.to_path_buf(), signature);
    Ok(())
}

pub fn available_models() -> Vec<ModelInfo> {
    manifests()
        .iter()
        .map(|m| ModelInfo {
            id: m.id.clone(),
            provider_type: m.provider_type.clone(),
            display_name: m.display_name.clone(),
            description: Some(format!(
                "{}; {}. Verified revision {}.",
                if m.languages.len() == 1 {
                    "English".to_string()
                } else {
                    format!(
                        "{} languages, including English and Swedish",
                        m.languages.len()
                    )
                },
                m.precision,
                &m.revision[..8]
            )),
            size_bytes: m.files.iter().map(|f| f.size).sum(),
            downloaded: false,
            installation: ModelInstallationState::Missing,
            revision: m.revision.clone(),
        })
        .collect()
}
pub fn list_models_with_status(root: &Path) -> Vec<ModelInfo> {
    available_models()
        .into_iter()
        .map(|mut model| {
            let directory = model_path(root, &model.id);
            model.installation = if !directory.exists() {
                ModelInstallationState::Missing
            } else {
                match verify_model(&directory, model_file_set(&model.id).unwrap()) {
                    Ok(()) => ModelInstallationState::Verified,
                    Err(_) => ModelInstallationState::RepairRequired { message: "This installation is incomplete or does not match the pinned model revision. Repair verifies all required files before activation.".into() },
                }
            };
            model.downloaded = matches!(model.installation, ModelInstallationState::Verified);
            model
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_same_size_corruption_and_missing_files() {
        let directory = tempfile::tempdir().unwrap();
        let file = ModelFile {
            name: "encoder".into(),
            size: 3,
            sha256: format!("{:x}", Sha256::digest(b"abc")),
        };
        let path = directory.path().join(&file.name);
        assert!(verify_file(&path, &file).is_err());
        fs::write(&path, b"abc").unwrap();
        assert!(verify_file(&path, &file).is_ok());
        fs::write(&path, b"abd").unwrap();
        assert!(verify_file(&path, &file).is_err());
    }
    #[test]
    fn manifests_are_complete_and_pinned() {
        for m in manifests() {
            assert_eq!(m.revision.len(), 40);
            assert_eq!(m.files.len(), 4);
            for file in &m.files {
                assert_eq!(file.sha256.len(), 64);
                assert!(file.size > 0);
                assert!(!file.name.contains('/'));
            }
        }
        assert!(model_file_set("../anything").is_none());
    }
}
