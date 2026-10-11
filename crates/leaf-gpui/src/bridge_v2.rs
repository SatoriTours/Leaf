//! Typed callbacks use owned replies and never hold a store borrow across FFI.
#![allow(dead_code)]
use crate::{abi_v2::*, host_store::HostStore};
use std::{
    cell::{Cell, RefCell},
    ffi::c_void,
    rc::Rc,
};
#[derive(Debug)]
pub struct BridgeError {
    pub status: i32,
    pub revision: u64,
    pub message: String,
}
impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.message.fmt(f)
    }
}
impl std::error::Error for BridgeError {}
#[derive(Debug)]
pub struct HostRow {
    pub handle: u64,
    pub index: u64,
    pub key: String,
}
#[derive(Debug)]
pub struct HostReply {
    pub scope_error: Option<String>,
    pub status: u32,
    pub revision: u64,
    pub flags: u64,
    pub rows: Vec<HostRow>,
    pub bounds: [f64; 4],
}
#[derive(Clone)]
pub struct TypedBridge {
    callbacks: LeafHostCallbacks,
    context: *mut c_void,
    active: Rc<Cell<bool>>,
    session: u64,
    sequence: Rc<Cell<u64>>,
}
fn error(status: i32, revision: u64, message: impl Into<String>) -> BridgeError {
    BridgeError {
        status,
        revision,
        message: message.into(),
    }
}
/// # Safety
/// The bytes refer to readable memory for this synchronous callback.
unsafe fn text(bytes: LeafBytes) -> Result<String, BridgeError> {
    if bytes.len > LEAF_V2_MAX_STRING || (bytes.len > 0 && bytes.ptr.is_null()) {
        return Err(error(1, 0, "invalid reply bytes"));
    }
    let bytes = if bytes.len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len as usize) }
    };
    std::str::from_utf8(bytes)
        .map(str::to_owned)
        .map_err(|_| error(1, 0, "invalid reply UTF-8"))
}
impl TypedBridge {
    pub fn session(&self) -> u64 {
        self.session
    }
    pub fn next_sequence(&self) -> u64 {
        let next = self
            .sequence
            .get()
            .checked_add(1)
            .expect("event sequence exhausted");
        self.sequence.set(next);
        next
    }
    pub fn request(&self, request: &LeafRequest) -> Result<HostReply, BridgeError> {
        if !self.active.get() {
            return Err(error(4, 0, "typed callback has detached"));
        }
        let mut bytes = [0u8; 2048];
        let mut fault = LeafError {
            ptr: bytes.as_mut_ptr(),
            capacity: bytes.len() as u64,
            written: 0,
        };
        let mut reply = LeafReply {
            struct_size: size_of::<LeafReply>() as u32,
            ..Default::default()
        };
        let status = unsafe {
            self.callbacks.request.unwrap()(self.context, request, &mut reply, &mut fault)
        };
        if fault.written > bytes.len() as u64 {
            return Err(error(
                1,
                reply.accepted_revision,
                "invalid error buffer length",
            ));
        }
        if status != 0 && status != LEAF_STATUS_ACCEPTED_SCOPE_ERROR as i32 {
            return Err(error(
                status,
                reply.accepted_revision,
                String::from_utf8_lossy(&bytes[..fault.written as usize]).to_string(),
            ));
        }
        if reply.struct_size != size_of::<LeafReply>() as u32
            || reply.rows_len > LEAF_V2_MAX_NODES
            || (reply.rows_len > 0
                && (reply.rows.is_null()
                    || !(reply.rows as usize).is_multiple_of(align_of::<LeafRow>())))
        {
            return Err(error(1, reply.accepted_revision, "invalid typed reply"));
        }
        let scope_error = (status == LEAF_STATUS_ACCEPTED_SCOPE_ERROR as i32)
            .then(|| String::from_utf8_lossy(&bytes[..fault.written as usize]).to_string());
        let raw = if reply.rows_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(reply.rows, reply.rows_len as usize) }
        };
        let mut rows = Vec::with_capacity(raw.len());
        let mut bytes = 0u64;
        for row in raw {
            bytes = bytes
                .checked_add(row.key.len)
                .ok_or_else(|| error(1, reply.accepted_revision, "reply overflow"))?;
            if bytes > LEAF_V2_MAX_TREE {
                return Err(error(
                    1,
                    reply.accepted_revision,
                    "reply byte budget exceeded",
                ));
            }
            rows.push(HostRow {
                handle: row.handle,
                index: row.index,
                key: unsafe { text(row.key) }?,
            });
        }
        Ok(HostReply {
            scope_error,
            status: reply.status,
            revision: reply.accepted_revision,
            flags: reply.flags,
            rows,
            bounds: [reply.x, reply.y, reply.width, reply.height],
        })
    }
    pub fn command(&self, tag: u64) -> LeafRequest {
        LeafRequest {
            struct_size: size_of::<LeafRequest>() as u32,
            tag: tag as u32,
            session_id: self.session,
            ..Default::default()
        }
    }
}
struct RendererContext {
    store: Rc<RefCell<HostStore>>,
    closed: Cell<bool>,
}
fn guarded(error_ptr: *mut LeafError, body: impl FnOnce() -> Result<(), AbiError>) -> i32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            unsafe { write_error(error_ptr, &e.to_string()) };
            LEAF_STATUS_REJECTED as i32
        }
        Err(_) => {
            unsafe { write_error(error_ptr, "renderer boundary panicked") };
            LEAF_STATUS_FAULTED as i32
        }
    }
}
unsafe extern "C" fn prepare(
    ctx: *mut c_void,
    batch: *const LeafBatch,
    error: *mut LeafError,
) -> i32 {
    guarded(error, || {
        let ctx = unsafe { (ctx as *mut RendererContext).as_ref() }
            .ok_or_else(|| AbiError("null renderer context".into()))?;
        if ctx.closed.get() {
            return Err(AbiError("renderer detached".into()));
        }
        let batch = unsafe { batch.as_ref() }.ok_or_else(|| AbiError("null host batch".into()))?;
        ctx.store
            .borrow_mut()
            .prepare(&unsafe { decode_batch(batch) }?)
    })
}
unsafe extern "C" fn apply(ctx: *mut c_void, error: *mut LeafError) -> i32 {
    guarded(error, || {
        let ctx = unsafe { (ctx as *mut RendererContext).as_ref() }
            .ok_or_else(|| AbiError("null renderer context".into()))?;
        if ctx.closed.get() {
            return Err(AbiError("renderer detached".into()));
        }
        ctx.store.borrow_mut().apply()
    })
}
unsafe extern "C" fn accept(ctx: *mut c_void, revision: u64) {
    // No business/GPUI work or buffer allocation at publication.
    if let Some(ctx) = unsafe { (ctx as *mut RendererContext).as_ref() } {
        if !ctx.closed.get() {
            let _ = ctx.store.borrow_mut().accept(revision);
        }
    }
}
unsafe extern "C" fn discard(ctx: *mut c_void) {
    if let Some(ctx) = unsafe { (ctx as *mut RendererContext).as_ref() } {
        ctx.store.borrow_mut().discard();
    }
}
pub struct AttachedHost {
    renderer: Box<RendererContext>,
    bridge: TypedBridge,
}
impl AttachedHost {
    /// # Safety
    /// Callback functions/context remain live until the returned owner drops.
    pub unsafe fn attach(
        config: &LeafConfig,
        callbacks: &LeafHostCallbacks,
        context: *mut c_void,
    ) -> Result<Self, BridgeError> {
        if config.struct_size != size_of::<LeafConfig>() as u32
            || config.session_id == 0
            || !(1..=16384).contains(&config.width)
            || !(1..=16384).contains(&config.height)
            || config.flags & !1 != 0
            || callbacks.struct_size != size_of::<LeafHostCallbacks>() as u32
            || callbacks.attach.is_none()
            || callbacks.request.is_none()
            || callbacks.detach.is_none()
        {
            return Err(error(1, 0, "invalid typed run configuration"));
        }
        unsafe { text(config.title) }?;
        let renderer = Box::new(RendererContext {
            store: Rc::new(RefCell::new(HostStore::new(config.session_id))),
            closed: Cell::new(false),
        });
        let host = Self {
            renderer,
            bridge: TypedBridge {
                callbacks: *callbacks,
                context,
                active: Rc::new(Cell::new(true)),
                session: config.session_id,
                sequence: Rc::new(Cell::new(0)),
            },
        };
        let api = LeafRendererApi {
            struct_size: size_of::<LeafRendererApi>() as u32,
            abi: 2,
            prepare: Some(prepare),
            apply: Some(apply),
            accept: Some(accept),
            discard: Some(discard),
        };
        let mut bytes = [0u8; 2048];
        let mut fault = LeafError {
            ptr: bytes.as_mut_ptr(),
            capacity: bytes.len() as u64,
            written: 0,
        };
        let renderer_ctx = (&*host.renderer as *const RendererContext)
            .cast_mut()
            .cast();
        let status = unsafe { callbacks.attach.unwrap()(context, &api, renderer_ctx, &mut fault) };
        if status != 0 {
            return Err(error(
                status,
                0,
                String::from_utf8_lossy(&bytes[..(fault.written as usize).min(bytes.len())])
                    .to_string(),
            ));
        }
        Ok(host)
    }
    pub fn store(&self) -> Rc<RefCell<HostStore>> {
        self.renderer.store.clone()
    }
    pub fn bridge(&self) -> TypedBridge {
        self.bridge.clone()
    }
}
impl Drop for AttachedHost {
    fn drop(&mut self) {
        self.bridge.active.set(false);
        unsafe { self.bridge.callbacks.detach.unwrap()(self.bridge.context) };
        self.renderer.closed.set(true);
        self.renderer.store.borrow_mut().dispose();
    }
}
unsafe extern "C" fn run(
    config: *const LeafConfig,
    callbacks: *const LeafHostCallbacks,
    context: *mut c_void,
    error: *mut LeafError,
) -> i32 {
    guarded(error, || {
        let config = unsafe { config.as_ref() }.ok_or_else(|| AbiError("null config".into()))?;
        let callbacks =
            unsafe { callbacks.as_ref() }.ok_or_else(|| AbiError("null callbacks".into()))?;
        let host = unsafe { AttachedHost::attach(config, callbacks, context) }
            .map_err(|e| AbiError(e.message))?;
        crate::host_view::run(host.store(), host.bridge(), config.flags & 1 != 0).map_err(AbiError)
    })
}
/// # Safety
/// out/error and any nonempty error buffer are writable for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn leaf_gpui_query_v2(
    abi: u32,
    out: *mut LeafGpuiApiV2,
    out_size: u64,
    error: *mut LeafError,
) -> i32 {
    if abi != 2
        || out_size < size_of::<LeafGpuiApiV2>() as u64
        || out.is_null()
        || !(out as usize).is_multiple_of(align_of::<LeafGpuiApiV2>())
    {
        unsafe { write_error(error, "incompatible GPUI ABI 2 query") };
        return LEAF_STATUS_INCOMPATIBLE as i32;
    }
    unsafe {
        out.write(LeafGpuiApiV2 {
            struct_size: size_of::<LeafGpuiApiV2>() as u32,
            abi: 2,
            capabilities: 0,
            run: Some(run),
        })
    };
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static OPEN: AtomicUsize = AtomicUsize::new(0);
    unsafe extern "C" fn attach_fail(
        _: *mut std::ffi::c_void,
        _: *const LeafRendererApi,
        _: *mut std::ffi::c_void,
        _: *mut LeafError,
    ) -> i32 {
        5
    }
    unsafe extern "C" fn attach_ok(
        _: *mut std::ffi::c_void,
        api: *const LeafRendererApi,
        ctx: *mut std::ffi::c_void,
        _: *mut LeafError,
    ) -> i32 {
        let batch = LeafBatch {
            struct_size: size_of::<LeafBatch>() as u32,
            abi: 2,
            session_id: 9,
            next_revision: 1,
            ..Default::default()
        };
        assert_eq!(
            unsafe { ((*api).prepare.unwrap())(ctx, &batch, std::ptr::null_mut()) },
            0
        );
        assert_eq!(
            unsafe { ((*api).apply.unwrap())(ctx, std::ptr::null_mut()) },
            0
        );
        unsafe { ((*api).accept.unwrap())(ctx, 1) };
        0
    }
    unsafe extern "C" fn request(
        _: *mut std::ffi::c_void,
        _: *const LeafRequest,
        reply: *mut LeafReply,
        _: *mut LeafError,
    ) -> i32 {
        unsafe { (*reply).accepted_revision = 1 };
        0
    }
    unsafe extern "C" fn detach(_: *mut std::ffi::c_void) {}
    fn callbacks(fail: bool) -> LeafHostCallbacks {
        LeafHostCallbacks {
            struct_size: size_of::<LeafHostCallbacks>() as u32,
            attach: Some(if fail { attach_fail } else { attach_ok }),
            request: Some(request),
            detach: Some(detach),
            ..Default::default()
        }
    }
    fn config() -> LeafConfig {
        LeafConfig {
            struct_size: size_of::<LeafConfig>() as u32,
            session_id: 9,
            width: 640,
            height: 480,
            ..Default::default()
        }
    }
    #[test]
    fn query_preserves_abi_one_and_rejects_incompatible_tables() {
        let mut api = LeafGpuiApiV2::default();
        assert_eq!(crate::leaf_gpui_abi_version(), 1);
        assert_eq!(
            unsafe {
                leaf_gpui_query_v2(
                    2,
                    &mut api,
                    size_of::<LeafGpuiApiV2>() as u64,
                    std::ptr::null_mut(),
                )
            },
            0
        );
        assert_eq!(api.abi, 2);
        assert!(api.run.is_some());
        assert_ne!(
            unsafe {
                leaf_gpui_query_v2(
                    3,
                    &mut api,
                    size_of::<LeafGpuiApiV2>() as u64,
                    std::ptr::null_mut(),
                )
            },
            0
        );
    }
    #[test]
    fn failed_attach_never_opens_and_detach_invalidates_clones() {
        assert!(
            unsafe { AttachedHost::attach(&config(), &callbacks(true), std::ptr::null_mut()) }
                .is_err()
        );
        assert_eq!(OPEN.load(Ordering::SeqCst), 0);
        let host =
            unsafe { AttachedHost::attach(&config(), &callbacks(false), std::ptr::null_mut()) }
                .unwrap();
        assert_eq!(host.store().borrow().revision(), 1);
        let bridge = host.bridge();
        let req = LeafRequest {
            struct_size: size_of::<LeafRequest>() as u32,
            tag: 3,
            session_id: 9,
            ..Default::default()
        };
        assert!(bridge.request(&req).is_ok());
        drop(host);
        assert!(bridge.request(&req).is_err());
    }
    #[test]
    fn accepted_scope_error_keeps_diagnostic_without_replaying_request() {
        unsafe extern "C" fn accepted(
            _: *mut c_void,
            _: *const LeafRequest,
            reply: *mut LeafReply,
            error: *mut LeafError,
        ) -> i32 {
            unsafe {
                (*reply).accepted_revision = 2;
                (*reply).status = LEAF_STATUS_ACCEPTED_SCOPE_ERROR as u32;
                write_error(error, "scope cleanup failed");
            }
            LEAF_STATUS_ACCEPTED_SCOPE_ERROR as i32
        }
        let mut callbacks = callbacks(false);
        callbacks.request = Some(accepted);
        let host =
            unsafe { AttachedHost::attach(&config(), &callbacks, std::ptr::null_mut()) }.unwrap();
        let reply = host
            .bridge()
            .request(&host.bridge().command(LEAF_REQUEST_EVENT))
            .unwrap();
        assert_eq!(reply.revision, 2);
        assert_eq!(reply.scope_error.as_deref(), Some("scope cleanup failed"));
    }
}
