//! Runtime selection between normal logs and content-free core diagnostics.
use std::sync::{
    atomic::{AtomicBool, Ordering},
    OnceLock,
};

static DEBUG: AtomicBool = AtomicBool::new(false);
static LOGGER: OnceLock<RuntimeLogger> = OnceLock::new();

struct RuntimeLogger {
    normal: env_logger::Logger,
    diagnostic: env_logger::Logger,
}
impl RuntimeLogger {
    fn active(&self) -> &env_logger::Logger {
        if DEBUG.load(Ordering::Acquire) {
            &self.diagnostic
        } else {
            &self.normal
        }
    }
}
impl log::Log for RuntimeLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        self.active().enabled(metadata)
    }
    fn log(&self, record: &log::Record<'_>) {
        self.active().log(record);
    }
    fn flush(&self) {
        self.active().flush();
    }
}

pub(crate) fn set_debug(enabled: bool) {
    DEBUG.store(enabled, Ordering::Release);
}

pub(crate) fn init(default_level: Option<String>) {
    let logger = LOGGER.get_or_init(|| {
        let mut normal = env_logger::Builder::new();
        normal.parse_env(
            env_logger::Env::default()
                .default_filter_or(default_level.as_deref().unwrap_or("info")),
        );
        let mut diagnostic = env_logger::Builder::new();
        // UI diagnostics raise only core logging; dependency debug logs may contain payloads.
        diagnostic
            .filter_level(log::LevelFilter::Info)
            .filter_module("parakatt_core", log::LevelFilter::Debug);
        // Preserve the explicit RUST_LOG override supported by the normal logger.
        diagnostic.parse_env(env_logger::Env::default());
        for builder in [&mut normal, &mut diagnostic] {
            builder
                .format_timestamp_millis()
                .format_module_path(false)
                .target(env_logger::Target::Stderr);
        }
        RuntimeLogger {
            normal: normal.build(),
            diagnostic: diagnostic.build(),
        }
    });
    if log::set_logger(logger).is_ok() {
        // Both filters remain available when the runtime switch changes.
        log::set_max_level(log::LevelFilter::Trace);
    }
}
