fn main() {
    // sherpa-onnx's dylibs are copied next to the binary in target/<profile>.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg-bins=-Wl,-rpath,@executable_path");
    }
}
