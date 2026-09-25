fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // ORT copies Dawn beside examples. Resolve it without DYLD environment overrides.
        println!("cargo:rustc-link-arg-examples=-Wl,-rpath,@executable_path");
    }
    // UniFFI proc macros handle everything via setup_scaffolding!()
    // No UDL file needed.
}
