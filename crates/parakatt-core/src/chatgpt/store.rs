//! One shared store and OS lock for the app and CLI. No config/profile secrets.
use super::{error, Account, Credentials};
use crate::CoreError;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Default, Serialize, Deserialize)]
pub(super) struct State {
    pub host_id: String,
    pub active: Option<String>,
    pub accounts: Vec<Account>,
    pub credentials: std::collections::BTreeMap<String, Credentials>,
}

pub(super) struct Store {
    pub root: PathBuf,
    // Tests use isolated files even on macOS; never access a user's Keychain.
    pub file_backend: bool,
}
impl Store {
    pub fn new() -> Result<Self, CoreError> {
        let base = if cfg!(target_os = "macos") {
            dirs::data_dir()
        } else {
            dirs::config_dir()
        }
        .ok_or_else(|| error("storage", "Cannot locate the account directory"))?;
        Ok(Self {
            root: base
                .join(if cfg!(target_os = "macos") {
                    "Parakatt"
                } else {
                    "parakatt"
                })
                .join("accounts"),
            file_backend: !cfg!(target_os = "macos"),
        })
    }
    pub fn lock(&self) -> Result<File, CoreError> {
        fs::create_dir_all(&self.root).map_err(storage_error)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.root, fs::Permissions::from_mode(0o700))
                .map_err(storage_error)?;
        }
        let mut options = OpenOptions::new();
        options.create(true).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options
            .open(self.root.join("accounts.lock"))
            .map_err(storage_error)?;
        file.lock().map_err(storage_error)?;
        Ok(file)
    }
    pub fn read(&self) -> Result<State, CoreError> {
        let bytes = if self.file_backend {
            match fs::read(self.root.join("accounts.json")) {
                Ok(bytes) => bytes,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(State::default()),
                Err(e) => return Err(storage_error(e)),
            }
        } else {
            #[cfg(target_os = "macos")]
            {
                match security_framework::passwords::get_generic_password(
                    "com.parakatt.chatgpt",
                    "accounts-v1",
                ) {
                    Ok(bytes) => bytes,
                    Err(e) if e.code() == -25300 => return Ok(State::default()),
                    Err(_) => {
                        return Err(error(
                            "storage",
                            "Cannot read ChatGPT credentials from Keychain",
                        ))
                    }
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                return Err(error("storage", "Credential backend unavailable"));
            }
        };
        serde_json::from_slice(&bytes)
            .map_err(|_| error("storage", "Cannot read the saved ChatGPT accounts"))
    }
    pub fn write(&self, state: &State) -> Result<(), CoreError> {
        let bytes = serde_json::to_vec(state)
            .map_err(|_| error("storage", "Cannot encode ChatGPT accounts"))?;
        if self.file_backend {
            atomic_write(&self.root.join("accounts.json"), &bytes)
        } else {
            #[cfg(target_os = "macos")]
            {
                security_framework::passwords::set_generic_password(
                    "com.parakatt.chatgpt",
                    "accounts-v1",
                    &bytes,
                )
                .map_err(|_| error("storage", "Cannot save ChatGPT credentials in Keychain"))
            }
            #[cfg(not(target_os = "macos"))]
            {
                Err(error("storage", "Credential backend unavailable"))
            }
        }
    }
}
fn storage_error(_: std::io::Error) -> CoreError {
    error(
        "storage",
        "Cannot access the protected ChatGPT account store",
    )
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), CoreError> {
    let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(storage_error)?;
        file.write_all(bytes).map_err(storage_error)?;
        file.sync_all().map_err(storage_error)?;
        fs::rename(&temporary, path).map_err(storage_error)?;
        File::open(
            path.parent()
                .ok_or_else(|| error("storage", "Account directory missing"))?,
        )
        .and_then(|f| f.sync_all())
        .map_err(storage_error)
    })();
    if result.is_err() {
        let _cleanup = fs::remove_file(temporary);
    }
    result
}
