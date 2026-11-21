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
            file_backend: !cfg!(any(target_os = "macos", target_os = "linux")),
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
            #[cfg(target_os = "linux")]
            {
                let entry = linux_entry()?;
                read_linux_store(&self.root, &entry)?
            }
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
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
            #[cfg(target_os = "linux")]
            {
                linux_entry()?.set_secret(&bytes).map_err(keyring_error)
            }
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            {
                Err(error("storage", "Credential backend unavailable"))
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn linux_entry() -> Result<keyring::Entry, CoreError> {
    keyring::Entry::new("com.parakatt.chatgpt", "accounts-v1").map_err(keyring_error)
}

#[cfg(target_os = "linux")]
fn keyring_error(_: keyring::Error) -> CoreError {
    error(
        "storage",
        "Cannot access ChatGPT accounts in Secret Service. Unlock your desktop keyring and retry.",
    )
}

// Called under accounts.lock: the desktop and CLI share one secure store. The
// old Linux file is removed only after an exact, verified keyring write.
#[cfg(target_os = "linux")]
fn read_linux_store(root: &Path, entry: &keyring::Entry) -> Result<Vec<u8>, CoreError> {
    let saved = match entry.get_secret() {
        Ok(bytes) => Some(bytes),
        Err(keyring::Error::NoEntry) => None,
        Err(e) => return Err(keyring_error(e)),
    };
    let legacy = root.join("accounts.json");
    let bytes = match fs::read(&legacy) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return match saved {
                Some(bytes) => Ok(bytes),
                None => serde_json::to_vec(&State::default())
                    .map_err(|_| error("storage", "Cannot initialize ChatGPT accounts")),
            };
        }
        Err(e) => return Err(storage_error(e)),
    };
    // Validate before moving data; corrupt files and conflicting stores require
    // intervention, rather than overwriting either set of accounts.
    serde_json::from_slice::<State>(&bytes)
        .map_err(|_| error("storage", "Cannot read the saved ChatGPT accounts"))?;
    if saved.as_ref().is_some_and(|value| value != &bytes) {
        return Err(error("storage", "ChatGPT file and keyring accounts differ. Resolve the old accounts.json store before continuing."));
    }
    entry.set_secret(&bytes).map_err(keyring_error)?;
    if entry.get_secret().map_err(keyring_error)? != bytes {
        return Err(error(
            "storage",
            "Cannot verify migrated ChatGPT accounts in Secret Service",
        ));
    }
    fs::remove_file(legacy).map_err(storage_error)?;
    Ok(bytes)
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

#[cfg(all(test, target_os = "linux"))]
mod linux_tests {
    use super::*;

    fn entry() -> keyring::Entry {
        keyring::Entry::new_with_credential(Box::new(keyring::mock::MockCredential::default()))
    }

    #[test]
    fn empty_keyring_initializes_without_a_plaintext_file() {
        let directory = tempfile::tempdir().unwrap();
        let bytes = read_linux_store(directory.path(), &entry()).unwrap();
        let state: State = serde_json::from_slice(&bytes).unwrap();
        assert!(state.credentials.is_empty());
        assert!(!directory.path().join("accounts.json").exists());
    }

    #[test]
    fn legacy_store_is_removed_only_after_verified_migration() {
        let directory = tempfile::tempdir().unwrap();
        let legacy = directory.path().join("accounts.json");
        let state = State {
            host_id: "legacy-host".into(),
            ..State::default()
        };
        let bytes = serde_json::to_vec(&state).unwrap();
        fs::write(&legacy, &bytes).unwrap();
        let entry = entry();
        assert_eq!(read_linux_store(directory.path(), &entry).unwrap(), bytes);
        assert_eq!(entry.get_secret().unwrap(), bytes);
        assert!(!legacy.exists());
        assert_eq!(read_linux_store(directory.path(), &entry).unwrap(), bytes);
    }

    #[test]
    fn unavailable_keyring_preserves_legacy_data_without_falling_back() {
        let directory = tempfile::tempdir().unwrap();
        let legacy = directory.path().join("accounts.json");
        let bytes = serde_json::to_vec(&State::default()).unwrap();
        fs::write(&legacy, &bytes).unwrap();
        let entry = entry();
        entry
            .get_credential()
            .downcast_ref::<keyring::mock::MockCredential>()
            .unwrap()
            .set_error(keyring::Error::NoStorageAccess(Box::new(
                std::io::Error::other("locked"),
            )));
        assert!(read_linux_store(directory.path(), &entry).is_err());
        assert_eq!(fs::read(legacy).unwrap(), bytes);
        assert!(matches!(entry.get_secret(), Err(keyring::Error::NoEntry)));
    }

    #[test]
    fn conflicting_stores_are_not_overwritten() {
        let directory = tempfile::tempdir().unwrap();
        let legacy = directory.path().join("accounts.json");
        let bytes = serde_json::to_vec(&State::default()).unwrap();
        fs::write(&legacy, &bytes).unwrap();
        let entry = entry();
        entry.set_secret(b"different account state").unwrap();
        assert!(read_linux_store(directory.path(), &entry).is_err());
        assert_eq!(entry.get_secret().unwrap(), b"different account state");
        assert_eq!(fs::read(legacy).unwrap(), bytes);
    }

    #[test]
    fn corrupt_legacy_file_is_not_migrated_or_deleted() {
        let directory = tempfile::tempdir().unwrap();
        let legacy = directory.path().join("accounts.json");
        fs::write(&legacy, b"not JSON").unwrap();
        let entry = entry();
        assert!(read_linux_store(directory.path(), &entry).is_err());
        assert!(legacy.exists());
        assert!(matches!(entry.get_secret(), Err(keyring::Error::NoEntry)));
    }
}
