//! Internal helpers shared across the core crate.

use std::sync::{Mutex, MutexGuard, TryLockError};

use crate::CoreError;

/// Preserve the lowercase, zero-padded encoding used by persisted SHA-256 values.
pub(crate) fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Lock a mutex, mapping a poison error to a `CoreError` via the
/// supplied variant constructor. Always logs at `error!` on poison so
/// we leave a breadcrumb even when the caller bubbles the error past a
/// boundary that drops the message.
///
/// Replaces the repeated:
/// ```ignore
/// self.x.lock().map_err(|e| CoreError::Variant(format!("X lock poisoned: {e}")))?
/// ```
/// with:
/// ```ignore
/// lock_named(&self.x, "X", CoreError::Variant)?
/// ```
pub(crate) fn lock_named<'a, T>(
    m: &'a Mutex<T>,
    name: &'static str,
    ctor: fn(String) -> CoreError,
) -> Result<MutexGuard<'a, T>, CoreError> {
    m.lock().map_err(|e| {
        log::error!("{name} lock poisoned: {e}");
        ctor(format!("{name} lock poisoned: {e}"))
    })
}

/// Optional work must not queue behind required work on the same resource.
pub(crate) fn try_lock_named<'a, T>(
    m: &'a Mutex<T>,
    name: &'static str,
    ctor: fn(String) -> CoreError,
) -> Result<Option<MutexGuard<'a, T>>, CoreError> {
    match m.try_lock() {
        Ok(guard) => Ok(Some(guard)),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Poisoned(error)) => {
            log::error!("{name} lock poisoned: {error}");
            Err(ctor(format!("{name} lock poisoned: {error}")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::hex_lower;
    use sha2::{Digest, Sha256};

    #[test]
    fn sha256_encoding_matches_existing_persisted_values() {
        assert_eq!(hex_lower(&[0, 1, 15, 16, 255]), "00010f10ff");
        assert_eq!(
            hex_lower(&Sha256::digest(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
