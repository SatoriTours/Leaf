use crate::model::{Response, Snapshot};
use serde_json::{Value, json};
use std::ffi::{CStr, c_char, c_void};
#[cfg(test)]
thread_local! { static JSON_BRIDGE_CALLS: std::cell::Cell<u64> = const {std::cell::Cell::new(0)}; }
#[cfg(test)]
pub(crate) fn json_bridge_calls() -> u64 {
    JSON_BRIDGE_CALLS.get()
}
pub type Callback = unsafe extern "C" fn(*mut c_void, *const u8, usize) -> *const c_char;
#[derive(Clone, Copy)]
pub struct Bridge {
    pub callback: Callback,
    pub context: *mut c_void,
}
pub struct TaskTickReply {
    pub pending: bool,
    pub response: Option<Response>,
    pub error: Option<String>,
}
impl Bridge {
    fn transport_value(&self, value: Value) -> Result<Value, String> {
        #[cfg(test)]
        JSON_BRIDGE_CALLS.set(JSON_BRIDGE_CALLS.get() + 1);
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
        Ok(value)
    }
    fn request_value(&self, value: Value) -> Result<Value, String> {
        let value = self.transport_value(value)?;
        Snapshot::parse(&value["snapshot"].to_string())?;
        Ok(value)
    }
    pub fn tasks(&self) -> Result<TaskTickReply, String> {
        let value = self.transport_value(json!({"op":"tasks"}))?;
        let pending = value["tasks_pending"]
            .as_bool()
            .ok_or("invalid tasks_pending boolean")?;
        let error: Option<String> =
            serde_json::from_value(value.get("error").cloned().unwrap_or(Value::Null))
                .map_err(|e| e.to_string())?;
        let error = error.filter(|error| !error.is_empty());
        let response = if value.get("snapshot").is_some() {
            Snapshot::parse(&value["snapshot"].to_string())?;
            Some(serde_json::from_value(value).map_err(|e| e.to_string())?)
        } else {
            None
        };
        Ok(TaskTickReply {
            pending,
            response,
            error,
        })
    }
    pub fn request(&self, value: Value) -> Result<Response, String> {
        serde_json::from_value(self.request_value(value)?).map_err(|e| e.to_string())
    }
    pub fn ready(&self, rendering: Value) -> Result<(Response, bool, bool), String> {
        let value = self.request_value(json!({"op":"ready", "rendering":rendering}))?;
        let capability = value["capabilities"]["rendering_diagnostics"] == Value::Bool(true);
        let tasks = value["capabilities"]["task_pump"] == Value::Bool(true);
        let response: Response = serde_json::from_value(value).map_err(|e| e.to_string())?;
        let supported = capability && response.error.as_deref().is_none_or(str::is_empty);
        let task_supported = tasks && response.error.as_deref().is_none_or(str::is_empty);
        Ok((response, supported, task_supported))
    }
    pub fn rendering(&self, rendering: Value) -> Result<Response, String> {
        self.request(json!({"op":"rendering", "rendering":rendering}))
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn leaf_gpui_task_pump_version() -> u32 {
    1
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
                let (_, supported, _) = bridge.ready(sample.clone()).unwrap();
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

#[cfg(test)]
mod task_pump_tests {
    use super::*;
    use std::ffi::CString;
    unsafe extern "C" fn callback(ctx: *mut c_void, _: *const u8, _: usize) -> *const c_char {
        unsafe { (&*(ctx as *const CString)).as_ptr() }
    }
    #[test]
    fn task_pump_empty_tick_has_no_snapshot_but_normal_request_stays_strict() {
        let mut response = CString::new(r#"{"tasks_pending":false}"#).unwrap();
        let bridge = Bridge {
            callback,
            context: &mut response as *mut _ as *mut c_void,
        };
        let reply = bridge.tasks().unwrap();
        assert!(!reply.pending);
        assert!(reply.response.is_none());
        assert!(bridge.request(json!({"op":"status"})).is_err());
    }
    #[test]
    fn task_pump_application_error_keeps_pending_and_optional_snapshot() {
        for snapshot in [false, true] {
            let mut value = json!({"tasks_pending":true,"error":"scope refused"});
            if snapshot {
                value["snapshot"] = json!({"title":"task","width":200,"height":200,
                    "root":{"id":"root","kind":"text","text":"accepted"}});
                value["rows"] = json!([]);
            }
            let mut response = CString::new(value.to_string()).unwrap();
            let bridge = Bridge {
                callback,
                context: &mut response as *mut _ as *mut c_void,
            };
            let reply = bridge
                .tasks()
                .expect("application error is a valid task envelope");
            assert!(reply.pending);
            assert_eq!(reply.error.as_deref(), Some("scope refused"));
            assert_eq!(reply.response.is_some(), snapshot);
            // The first consumer-visible application error must survive as well.
            if let Some(response) = reply.response {
                assert_eq!(response.error.as_deref(), Some("scope refused"));
            }
        }
    }
    #[test]
    fn task_pump_malformed_envelopes_remain_transport_errors() {
        for text in [
            "{",
            r#"{"tasks_pending":true,"error":7}"#,
            r#"{"tasks_pending":true,"snapshot":null}"#,
        ] {
            let mut response = CString::new(text).unwrap();
            let bridge = Bridge {
                callback,
                context: &mut response as *mut _ as *mut c_void,
            };
            assert!(bridge.tasks().is_err());
        }
    }
    #[test]
    fn task_pump_pending_is_a_strict_boolean() {
        for value in [json!(null), json!("true"), json!(1), json!({})] {
            let mut response = CString::new(json!({"tasks_pending":value}).to_string()).unwrap();
            let bridge = Bridge {
                callback,
                context: &mut response as *mut _ as *mut c_void,
            };
            assert!(bridge.tasks().is_err());
        }
    }
}
