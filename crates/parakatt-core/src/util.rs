//! Internal helpers shared across the core crate.

use std::sync::{Mutex, MutexGuard};

use crate::CoreError;

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
