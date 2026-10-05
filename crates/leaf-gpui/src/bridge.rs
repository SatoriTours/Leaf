use crate::model::{Response, Snapshot};
use serde_json::{Value, json};
use std::ffi::{CStr, c_char, c_void};
pub type Callback = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> *const c_char;
#[derive(Clone, Copy)]
pub struct Bridge {
    pub callback: Callback,
    pub context: *mut c_void,
}
impl Bridge {
    pub fn request(&self, value: Value) -> Result<Response, String> {
        let bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
        let pointer = unsafe { (self.callback)(self.context, bytes.as_ptr(), bytes.len()) };
        if pointer.is_null() {
            return Err("Nim callback returned null".into());
        }
        // Nim owns this buffer until the next callback. Deserialize before returning.
        let bytes = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .map_err(|e| e.to_string())?;
        let value: Value = serde_json::from_str(bytes).map_err(|e| e.to_string())?;
        Snapshot::parse(&value["snapshot"].to_string())?;
        serde_json::from_value(value).map_err(|e| e.to_string())
    }
    pub fn ready(&self) -> Result<Response, String> {
        self.request(json!({"op":"ready"}))
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn leaf_gpui_abi_version() -> u32 {
    1
}
/// # Safety
/// `data` contains `len` readable bytes and the callback/context remain valid until this call returns.
unsafe fn run(
    data: *const u8,
    len: usize,
    callback: Option<Callback>,
    context: *mut c_void,
    frames: bool,
) -> i32 {
    if data.is_null() || len == 0 || len > 32 * 1024 * 1024 || callback.is_none() {
        return 1;
    }
    let result = std::panic::catch_unwind(|| {
        let data = unsafe { std::slice::from_raw_parts(data, len) };
        let text = std::str::from_utf8(data).map_err(|e| e.to_string())?;
        let snapshot = Snapshot::parse(text)?;
        crate::desktop::run(
            snapshot,
            Bridge {
                callback: callback.unwrap(),
                context,
            },
            frames,
        )
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            eprintln!("leaf GPUI: {e}");
            1
        }
        Err(_) => {
            eprintln!("leaf GPUI: renderer panicked");
            1
        }
    }
}

/// # Safety
/// Data and callback context must remain readable throughout the synchronous run.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn leaf_gpui_run(
    data: *const u8,
    len: usize,
    callback: Option<Callback>,
    context: *mut c_void,
) -> i32 {
    unsafe { run(data, len, callback, context, false) }
}
/// # Safety
/// Same ownership contract as `leaf_gpui_run`; callback accepts frame requests and closes explicitly.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn leaf_gpui_run_frames(
    data: *const u8,
    len: usize,
    callback: Option<Callback>,
    context: *mut c_void,
) -> i32 {
    unsafe { run(data, len, callback, context, true) }
}
