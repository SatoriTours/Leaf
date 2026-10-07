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
    fn request_value(&self, value: Value) -> Result<Value, String> {
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
        Ok(value)
    }
    pub fn request(&self, value: Value) -> Result<Response, String> {
        serde_json::from_value(self.request_value(value)?).map_err(|e| e.to_string())
    }
    pub fn ready(&self, rendering: Value) -> Result<(Response, bool), String> {
        let value = self.request_value(json!({"op":"ready", "rendering":rendering}))?;
        let capability = value["capabilities"]["rendering_diagnostics"] == Value::Bool(true);
        let response: Response = serde_json::from_value(value).map_err(|e| e.to_string())?;
        let supported = capability && response.error.as_deref().is_none_or(str::is_empty);
        Ok((response, supported))
    }
    pub fn rendering(&self, rendering: Value) -> Result<Response, String> {
        self.request(json!({"op":"rendering", "rendering":rendering}))
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

#[cfg(test)]
mod dpi_tests {
    use super::*;
    use std::ffi::CString;
    struct Host {
        response: CString,
        requests: Vec<Value>,
    }
    unsafe extern "C" fn callback(ctx: *mut c_void, data: *const u8, len: usize) -> *const c_char {
        let host = unsafe { &mut *(ctx as *mut Host) };
        host.requests.push(
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, len) }).unwrap(),
        );
        host.response.as_ptr()
    }
    #[test]
    fn ready_requires_explicit_successful_capability_and_preserves_abi() {
        for capability in [
            Value::Null,
            json!(false),
            json!("true"),
            json!(1),
            json!(true),
        ] {
            for error in [None, Some("initial viewport failed")] {
                let mut value = json!({"snapshot":{"title":"DPI","width":640,"height":480,
                    "root":{"id":"root","kind":"text","text":"中文"}},"rows":[]});
                if !capability.is_null() {
                    value["capabilities"] = json!({"rendering_diagnostics":capability});
                }
                if let Some(error) = error {
                    value["error"] = json!(error);
                }
                let mut host = Host {
                    response: CString::new(value.to_string()).unwrap(),
                    requests: vec![],
                };
                let bridge = Bridge {
                    callback,
                    context: &mut host as *mut Host as *mut c_void,
                };
                let sample = json!({"scale_factor":1.5,"logical_size":{"width":640,"height":480},
                    "device_size_calculated":{"width":960,"height":720},"dpi_from_scale_calculated":144});
                let (_, supported) = bridge.ready(sample.clone()).unwrap();
                assert_eq!(supported, capability == json!(true) && error.is_none());
                assert_eq!(host.requests[0], json!({"op":"ready","rendering":sample}));
                bridge.rendering(sample.clone()).unwrap();
                assert_eq!(
                    host.requests[1],
                    json!({"op":"rendering","rendering":sample})
                );
            }
        }
        assert_eq!(leaf_gpui_abi_version(), 1);
    }
}
