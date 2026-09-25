//! Explicit installation using the same verified staging protocol as Settings.
use std::sync::{atomic::AtomicBool, Arc, Mutex};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let root = args.next().ok_or("missing model root")?;
    let id = args.next().ok_or("missing model ID")?;
    if args.next().as_deref() == Some("--candidate") {
        parakatt_core::download::download_candidate(std::path::Path::new(&root), &id)?;
        return Ok(());
    }
    parakatt_core::download::download_model(
        std::path::Path::new(&root),
        &id,
        Arc::new(Mutex::new(parakatt_core::download::DownloadProgress::idle())),
        Arc::new(AtomicBool::new(false)),
    )?;
    Ok(())
}
