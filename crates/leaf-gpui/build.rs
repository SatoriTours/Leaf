use std::{env, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=resources/windows/leaf_gpui.manifest");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        // A dynamically loaded DLL needs manifest resource 2. GPUI's resource 1
        // is an EXE manifest, so a plain Nim host otherwise loads Common Controls
        // v5, which does not export TaskDialogIndirect.
        let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
            .join("resources/windows/leaf_gpui.manifest");
        println!("cargo:rustc-cdylib-link-arg=/MANIFEST:EMBED,ID=2");
        println!("cargo:rustc-cdylib-link-arg=/MANIFESTINPUT:{}", manifest.display());
    }
}
