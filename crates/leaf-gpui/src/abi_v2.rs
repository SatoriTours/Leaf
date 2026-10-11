//! C ABI 2 declarations; header is include/leaf_gpui_v2.h.
#![allow(dead_code)]
pub const LEAF_V2_ABI: u64 = 2;
pub const LEAF_V2_MAX_WIRE_BYTES: u64 = 67108864;
pub const LEAF_V2_MAX_OPS: u64 = 40064;
pub const LEAF_V2_MAX_NODES: u64 = 10000;
pub const LEAF_V2_MAX_DEPTH: u64 = 64;
pub const LEAF_V2_MAX_STRING: u64 = 1048576;
pub const LEAF_V2_MAX_TREE: u64 = 16777216;
pub const LEAF_V2_MAX_LIST: u64 = 100000;
pub const LEAF_P_WIDTH: u64 = 1;
pub const LEAF_P_HEIGHT: u64 = 2;
pub const LEAF_P_GAP: u64 = 4;
pub const LEAF_P_PADDING: u64 = 8;
pub const LEAF_P_FLEX_GROW: u64 = 16;
pub const LEAF_P_FLEX_SHRINK: u64 = 32;
pub const LEAF_P_MIN_WIDTH: u64 = 64;
pub const LEAF_P_MIN_HEIGHT: u64 = 128;
pub const LEAF_P_MAX_WIDTH: u64 = 256;
pub const LEAF_P_MAX_HEIGHT: u64 = 512;
pub const LEAF_P_RADIUS: u64 = 1024;
pub const LEAF_P_BORDER_WIDTH: u64 = 2048;
pub const LEAF_P_OPACITY: u64 = 4096;
pub const LEAF_P_FONT_SIZE: u64 = 8192;
pub const LEAF_P_PROGRESS: u64 = 16384;
pub const LEAF_P_COLOR: u64 = 32768;
pub const LEAF_P_BACKGROUND: u64 = 65536;
pub const LEAF_P_BORDER_COLOR: u64 = 131072;
pub const LEAF_P_ALIGN: u64 = 262144;
pub const LEAF_P_JUSTIFY: u64 = 524288;
pub const LEAF_P_OVERFLOW: u64 = 1048576;
pub const LEAF_P_WEIGHT: u64 = 2097152;
pub const LEAF_P_VARIANT: u64 = 4194304;
pub const LEAF_P_ENABLED: u64 = 8388608;
pub const LEAF_P_CHECKED: u64 = 16777216;
pub const LEAF_P_RESET: u64 = 33554432;
pub const LEAF_P_LIST: u64 = 67108864;
pub const LEAF_STATUS_OK: u64 = 0;
pub const LEAF_STATUS_INVALID: u64 = 1;
pub const LEAF_STATUS_INCOMPATIBLE: u64 = 2;
pub const LEAF_STATUS_STALE: u64 = 3;
pub const LEAF_STATUS_FAULTED: u64 = 4;
pub const LEAF_STATUS_REJECTED: u64 = 5;
pub const LEAF_STATUS_ACCEPTED_SCOPE_ERROR: u64 = 6;
pub const LEAF_OP_CREATE: u64 = 1;
pub const LEAF_OP_UPDATE: u64 = 2;
pub const LEAF_OP_SET_CHILDREN: u64 = 3;
pub const LEAF_OP_REMOVE: u64 = 4;
pub const LEAF_OP_BOUNDARY: u64 = 5;
pub const LEAF_OP_WINDOW: u64 = 6;
pub const LEAF_REQUEST_EVENT: u64 = 1;
pub const LEAF_REQUEST_VIEWPORT: u64 = 2;
pub const LEAF_REQUEST_STATUS: u64 = 3;
pub const LEAF_REQUEST_READY: u64 = 4;
pub const LEAF_REQUEST_LOCATE: u64 = 5;
pub const LEAF_REQUEST_RENDERING: u64 = 6;
pub const LEAF_REQUEST_FRAME: u64 = 7;
pub type LeafPrepareFn =
    Option<unsafe extern "C" fn(*mut std::ffi::c_void, *const LeafBatch, *mut LeafError) -> i32>;
pub type LeafApplyFn = Option<unsafe extern "C" fn(*mut std::ffi::c_void, *mut LeafError) -> i32>;
pub type LeafAcceptFn = Option<unsafe extern "C" fn(*mut std::ffi::c_void, u64) -> ()>;
pub type LeafDiscardFn = Option<unsafe extern "C" fn(*mut std::ffi::c_void) -> ()>;
pub type LeafAttachFn = Option<
    unsafe extern "C" fn(
        *mut std::ffi::c_void,
        *const LeafRendererApi,
        *mut std::ffi::c_void,
        *mut LeafError,
    ) -> i32,
>;
pub type LeafRequestFn = Option<
    unsafe extern "C" fn(
        *mut std::ffi::c_void,
        *const LeafRequest,
        *mut LeafReply,
        *mut LeafError,
    ) -> i32,
>;
pub type LeafDetachFn = Option<unsafe extern "C" fn(*mut std::ffi::c_void) -> ()>;
pub type LeafRunFn = Option<
    unsafe extern "C" fn(
        *const LeafConfig,
        *const LeafHostCallbacks,
        *mut std::ffi::c_void,
        *mut LeafError,
    ) -> i32,
>;
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafBytes {
    pub ptr: *const u8,
    pub len: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafSpan {
    pub offset: u64,
    pub len: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafError {
    pub ptr: *mut u8,
    pub capacity: u64,
    pub written: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafDimension {
    pub tag: u32,
    pub reserved: u32,
    pub value: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafProps {
    pub present: u64,
    pub width: LeafDimension,
    pub height: LeafDimension,
    pub numbers: [f64; 13],
    pub colors: [u32; 3],
    pub align: u32,
    pub justify: u32,
    pub overflow: u32,
    pub weight: u32,
    pub variant: u32,
    pub enabled: u32,
    pub checked: u32,
    pub event_mask: u32,
    pub reset_token: u64,
    pub text: LeafSpan,
    pub placeholder: LeafSpan,
    pub list_generation: u64,
    pub list_count: u64,
    pub height_mode: u32,
    pub overscan: u32,
    pub row_height: f64,
    pub estimate: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafOp {
    pub tag: u32,
    pub kind: u32,
    pub handle: u64,
    pub parent: u64,
    pub node_id: LeafSpan,
    pub props: LeafProps,
    pub children: LeafSpan,
    pub boundary_id: u64,
    pub boundary_parent: u64,
    pub width: u32,
    pub height: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafBatch {
    pub struct_size: u32,
    pub abi: u32,
    pub session_id: u64,
    pub base_revision: u64,
    pub next_revision: u64,
    pub ops: *const LeafOp,
    pub ops_len: u64,
    pub children: *const u64,
    pub children_len: u64,
    pub strings: *const u8,
    pub strings_len: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafProtected {
    pub index: u64,
    pub key: LeafBytes,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafRequest {
    pub struct_size: u32,
    pub tag: u32,
    pub session_id: u64,
    pub handle: u64,
    pub generation: u64,
    pub binding_generation: u64,
    pub sequence: u64,
    pub revision: u64,
    pub kind: u32,
    pub composition: u32,
    pub checked: u32,
    pub reserved: u32,
    pub first: u64,
    pub finish: u64,
    pub value: LeafBytes,
    pub protected_rows: *const LeafProtected,
    pub protected_len: u64,
    pub scale: f64,
    pub width: f64,
    pub height: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafRow {
    pub handle: u64,
    pub index: u64,
    pub key: LeafBytes,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafReply {
    pub struct_size: u32,
    pub status: u32,
    pub accepted_revision: u64,
    pub flags: u64,
    pub rows: *const LeafRow,
    pub rows_len: u64,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LeafConfig {
    pub struct_size: u32,
    pub flags: u32,
    pub session_id: u64,
    pub width: u32,
    pub height: u32,
    pub title: LeafBytes,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LeafRendererApi {
    pub struct_size: u32,
    pub abi: u32,
    pub prepare: LeafPrepareFn,
    pub apply: LeafApplyFn,
    pub accept: LeafAcceptFn,
    pub discard: LeafDiscardFn,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LeafHostCallbacks {
    pub struct_size: u32,
    pub reserved: u32,
    pub attach: LeafAttachFn,
    pub request: LeafRequestFn,
    pub detach: LeafDetachFn,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LeafGpuiApiV2 {
    pub struct_size: u32,
    pub abi: u32,
    pub capabilities: u64,
    pub run: LeafRunFn,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn empty_batch() -> LeafBatch {
        LeafBatch {
            struct_size: std::mem::size_of::<LeafBatch>() as u32,
            abi: 2,
            session_id: 1,
            next_revision: 1,
            ..LeafBatch::default()
        }
    }
    #[test]
    fn decode_rejects_bad_ranges_and_preserves_empty_utf8() {
        let mut batch = empty_batch();
        assert!(unsafe { decode_batch(&batch) }.is_ok());
        batch.ops_len = 1;
        assert!(unsafe { decode_batch(&batch) }.is_err());
        batch.ops_len = 0;
        batch.strings_len = u64::MAX;
        assert!(unsafe { decode_batch(&batch) }.is_err());
        let strings = "你好".as_bytes();
        batch.strings = strings.as_ptr();
        batch.strings_len = strings.len() as u64;
        let decoded = unsafe { decode_batch(&batch) }.unwrap();
        assert_eq!(
            decoded.text(LeafSpan { offset: 0, len: 6 }).unwrap(),
            "你好"
        );
        assert!(
            decoded
                .text(LeafSpan {
                    offset: u64::MAX,
                    len: 6
                })
                .is_err()
        );
        assert!(decoded.text(LeafSpan { offset: 1, len: 5 }).is_err());
        let invalid = [255u8];
        batch.strings = invalid.as_ptr();
        batch.strings_len = 1;
        assert!(unsafe { decode_batch(&batch) }.is_err());
    }
    #[test]
    fn error_buffer_is_bounded_utf8_and_not_nul_terminated() {
        let mut storage = [42u8; 8];
        let mut error = LeafError {
            ptr: storage.as_mut_ptr(),
            capacity: 4,
            written: 0,
        };
        unsafe { write_error(&mut error, "中文错误") };
        assert_eq!(error.written, 3);
        assert_eq!(&storage[..3], "中".as_bytes());
        assert_eq!(storage[3], 42);
        error.ptr = std::ptr::null_mut();
        error.capacity = 0;
        unsafe { write_error(&mut error, "ignored") };
        assert_eq!(error.written, 0);
    }
    #[test]
    fn decode_checks_tags_limits_presence_and_nonfinite_numbers() {
        let mut ops = [LeafOp {
            tag: 1,
            kind: 2,
            handle: 1,
            ..LeafOp::default()
        }];
        let mut batch = empty_batch();
        batch.ops = ops.as_ptr();
        batch.ops_len = 1;
        assert!(unsafe { decode_batch(&batch) }.is_ok());
        ops[0].props.numbers[0] = f64::NAN;
        assert!(unsafe { decode_batch(&batch) }.is_err());
        ops[0].props.numbers[0] = 0.0;
        ops[0].tag = 99;
        assert!(unsafe { decode_batch(&batch) }.is_err());
        ops[0].tag = 1;
        ops[0].props.present = 1u64 << 63;
        assert!(unsafe { decode_batch(&batch) }.is_err());
        ops[0].props.present = LEAF_P_LIST;
        ops[0].props.list_count = 100001;
        ops[0].props.list_generation = 1;
        ops[0].props.height_mode = 1;
        ops[0].props.estimate = 40.0;
        batch.ops = ops.as_ptr();
        assert!(unsafe { decode_batch(&batch) }.is_err());
        let bytes = vec![b'x'; LEAF_V2_MAX_STRING as usize];
        batch.ops_len = 0;
        batch.strings = bytes.as_ptr();
        batch.strings_len = bytes.len() as u64;
        let decoded = unsafe { decode_batch(&batch) }.unwrap();
        assert_eq!(
            decoded
                .text(LeafSpan {
                    offset: 0,
                    len: LEAF_V2_MAX_STRING
                })
                .unwrap()
                .len(),
            1048576
        );
        assert!(
            decoded
                .text(LeafSpan {
                    offset: 0,
                    len: LEAF_V2_MAX_STRING + 1
                })
                .is_err()
        );
    }
}

#[derive(Debug, Clone)]
pub struct AbiError(pub String);
impl std::fmt::Display for AbiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}
impl std::error::Error for AbiError {}
fn invalid(message: &str) -> AbiError {
    AbiError(message.into())
}
pub struct DecodedBatch<'a> {
    pub header: &'a LeafBatch,
    pub ops: &'a [LeafOp],
    pub children: &'a [u64],
    pub strings: &'a [u8],
}
impl<'a> DecodedBatch<'a> {
    pub fn text(&self, span: LeafSpan) -> Result<&'a str, AbiError> {
        if span.len > LEAF_V2_MAX_STRING {
            return Err(invalid("string exceeds 1 MiB"));
        }
        let end = span
            .offset
            .checked_add(span.len)
            .ok_or_else(|| invalid("string range overflow"))?;
        let bytes = self
            .strings
            .get(
                span.offset as usize
                    ..usize::try_from(end).map_err(|_| invalid("string range overflow"))?,
            )
            .ok_or_else(|| invalid("string range outside arena"))?;
        std::str::from_utf8(bytes).map_err(|_| invalid("invalid UTF-8 string"))
    }
    pub fn child_handles(&self, span: LeafSpan) -> Result<&'a [u64], AbiError> {
        let end = span
            .offset
            .checked_add(span.len)
            .ok_or_else(|| invalid("children range overflow"))?;
        self.children
            .get(
                usize::try_from(span.offset).map_err(|_| invalid("children range overflow"))?
                    ..usize::try_from(end).map_err(|_| invalid("children range overflow"))?,
            )
            .ok_or_else(|| invalid("children range outside arena"))
    }
}
/// # Safety
/// Non-null pointers refer to readable, correctly aligned arrays for this call.
unsafe fn borrowed<'a, T>(ptr: *const T, len: u64, limit: u64) -> Result<&'a [T], AbiError> {
    if len > limit || len > isize::MAX as u64 / std::mem::size_of::<T>() as u64 {
        return Err(invalid("ABI array too large"));
    }
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() || !(ptr as usize).is_multiple_of(std::mem::align_of::<T>()) {
        return Err(invalid("null or misaligned ABI array"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len as usize) })
}
pub fn validate_props(props: &LeafProps) -> Result<(), AbiError> {
    if props.present >= 1 << 27
        || props.event_mask & !7 != 0
        || props.enabled > 1
        || props.checked > 1
    {
        return Err(invalid("unknown property flags"));
    }
    for dim in [&props.width, &props.height] {
        if dim.tag > 2 || !dim.value.is_finite() || dim.value < 0.0 || dim.value > 1_000_000.0 {
            return Err(invalid("invalid dimension"));
        }
    }
    if props
        .numbers
        .iter()
        .any(|n| !n.is_finite() || *n < 0.0 || *n > 1_000_000.0)
        || props.present & LEAF_P_OPACITY != 0 && props.numbers[10] > 1.0
        || props.present & LEAF_P_PROGRESS != 0 && props.numbers[12] > 100.0
    {
        return Err(invalid("invalid property number"));
    }
    if props.align > 3
        || props.justify > 5
        || props.overflow > 2
        || props.weight > 3
        || props.variant > 8
    {
        return Err(invalid("unknown property tag"));
    }
    if props.present & LEAF_P_LIST != 0
        && (props.list_generation == 0
            || props.list_count > LEAF_V2_MAX_LIST
            || props.height_mode > 1
            || props.overscan > 32
            || !props.row_height.is_finite()
            || !props.estimate.is_finite()
            || props.row_height < 0.0
            || props.row_height > 1_000_000.0
            || props.estimate <= 0.0
            || props.estimate > 1_000_000.0
            || props.height_mode == 0 && props.row_height == 0.0
            || props.height_mode == 1 && props.row_height != 0.0)
    {
        return Err(invalid("invalid list metadata"));
    }
    Ok(())
}
/// # Safety
/// The header and every indicated nonempty array must be readable for `'a`.
pub unsafe fn decode_batch(batch: &LeafBatch) -> Result<DecodedBatch<'_>, AbiError> {
    if batch.abi != 2 || batch.struct_size != std::mem::size_of::<LeafBatch>() as u32 {
        return Err(invalid("incompatible batch ABI"));
    }
    let total = batch
        .ops_len
        .checked_mul(std::mem::size_of::<LeafOp>() as u64)
        .and_then(|n| {
            batch
                .children_len
                .checked_mul(8)
                .and_then(|c| n.checked_add(c))
        })
        .and_then(|n| n.checked_add(batch.strings_len))
        .ok_or_else(|| invalid("wire size overflow"))?;
    if total > LEAF_V2_MAX_WIRE_BYTES {
        return Err(invalid("wire budget exceeded"));
    }
    let decoded = DecodedBatch {
        header: batch,
        ops: unsafe { borrowed(batch.ops, batch.ops_len, LEAF_V2_MAX_OPS)? },
        children: unsafe {
            borrowed(
                batch.children,
                batch.children_len,
                LEAF_V2_MAX_OPS * LEAF_V2_MAX_NODES,
            )?
        },
        strings: unsafe { borrowed(batch.strings, batch.strings_len, LEAF_V2_MAX_TREE)? },
    };
    std::str::from_utf8(decoded.strings).map_err(|_| invalid("invalid UTF-8 arena"))?;
    for op in decoded.ops {
        if !(1..=6).contains(&op.tag) {
            return Err(invalid("unknown operation"));
        }
        match op.tag {
            1 | 2 => {
                if op.kind > 12 || op.handle == 0 {
                    return Err(invalid("invalid host kind/handle"));
                }
                validate_props(&op.props)?;
                decoded.text(op.node_id)?;
                decoded.text(op.props.text)?;
                decoded.text(op.props.placeholder)?;
            }
            3 => {
                if op.children.len > LEAF_V2_MAX_NODES {
                    return Err(invalid("too many children"));
                }
                decoded.child_handles(op.children)?;
            }
            5 => {
                validate_props(&op.props)?;
            }
            6 => {
                if !(1..=16384).contains(&op.width) || !(1..=16384).contains(&op.height) {
                    return Err(invalid("invalid window size"));
                }
                decoded.text(op.props.text)?;
            }
            _ => {}
        }
    }
    Ok(decoded)
}
/// # Safety
/// If present, the error pointer and its nonempty buffer are writable.
pub unsafe fn write_error(error: *mut LeafError, message: &str) {
    let Some(error) = (unsafe { error.as_mut() }) else {
        return;
    };
    error.written = 0;
    if error.ptr.is_null() {
        return;
    }
    let mut len = message
        .len()
        .min(usize::try_from(error.capacity).unwrap_or(usize::MAX));
    while !message.is_char_boundary(len) {
        len -= 1;
    }
    unsafe { std::ptr::copy_nonoverlapping(message.as_ptr(), error.ptr, len) };
    error.written = len as u64;
}
