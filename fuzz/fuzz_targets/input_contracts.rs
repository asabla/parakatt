#![no_main]
#[path = "../../crates/parakatt-core/tests/support/input_contracts.rs"]
mod contracts;

libfuzzer_sys::fuzz_target!(|data: &[u8]| contracts::check(data));
