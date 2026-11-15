fn main() {
    // ORT rc.15 no longer links Apple's compiler runtime automatically.
    // The statically linked CoreML objects use its OS-availability helpers.
    // This flag must be emitted by the binary crate, not the core library.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg=-fapple-link-rtlib");
    }
}
