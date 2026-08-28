//! A bare C ABI over Aztec's `avm-transpiler`, for `wasm32-unknown-unknown`.
//!
//! # Why this crate exists at all
//!
//! Upstream already ships the entry point a browser needs: `avm_transpile_bytecode`
//! (`avm-transpiler/src/lib.rs:148`) takes `(*const u8, usize)` holding a compiled ACIR
//! contract artifact's JSON and returns a `TranspileResult` holding the transpiled artifact's
//! JSON. It reads no file, no clock and no environment variable — the sibling
//! `avm_transpile_file` is the one that does, and it is a different function.
//!
//! Two things are missing for a wasm host, and neither is upstream's business:
//!
//! 1. **An allocator export.** A page has to put the input JSON *into* the module's linear
//!    memory before it can pass a pointer to it. `wasm32-unknown-unknown` exports none by
//!    default. (`__wbindgen_malloc` happens to be exported because `chrono` drags
//!    `wasm-bindgen` in, and building on that would be building on an accident.)
//! 2. **A flat return.** `TranspileResult` is returned *by value*; on wasm32 that is an sret
//!    pointer the caller must allocate and then walk field by field. Two extra exports remove
//!    the struct from the boundary entirely.
//!
//! # The ABI, and why it is spelled this way
//!
//! Deliberately the same shape as M30's `nv_alloc` / `nv_free` / `nv_result_len` /
//! `nv_compile_vfs` in `noir/compiler/wasm/src/compile_vfs.rs`, so one page and one loader can
//! drive the compile module and the transpile module without knowing which is which:
//!
//! ```text
//!   p   = avmt_alloc(len)                    reserve len bytes
//!         <copy the artifact JSON into memory at p>
//!   out = avmt_transpile(p, len)             transpile
//!   ok  = avmt_ok()                          1 = success, 0 = refusal
//!   n   = avmt_result_len()                  bytes at `out`
//!         <read n bytes at out: the transpiled artifact JSON, or the error message>
//!   avmt_free(out, n); avmt_free(p, len)
//! ```
//!
//! **There is no fallback and no default.** A refusal comes back with `ok == 0` and the
//! transpiler's own message in the buffer; the caller never receives a plausible-looking
//! artifact it did not ask for.

#![forbid(unsafe_op_in_unsafe_fn)]

use std::alloc::{Layout, alloc, dealloc};
use std::cell::Cell;
use std::ffi::CStr;

thread_local! {
    static RESULT_LEN: Cell<usize> = const { Cell::new(0) };
    static RESULT_OK: Cell<i32> = const { Cell::new(-1) };
}

/// Reserve `len` bytes in the module's linear memory.
///
/// Returns null for `len == 0`.
///
/// # Safety
/// The caller must eventually pass the returned pointer and the same `len` to [`avmt_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn avmt_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    let layout = Layout::from_size_align(len, 1).expect("valid layout");
    unsafe { alloc(layout) }
}

/// Release a buffer from [`avmt_alloc`] or [`avmt_transpile`].
///
/// # Safety
/// `ptr`/`len` must come from one of those calls and must not be used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn avmt_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let layout = Layout::from_size_align(len, 1).expect("valid layout");
    unsafe { dealloc(ptr, layout) };
}

/// Byte length of the buffer the last [`avmt_transpile`] call returned.
#[unsafe(no_mangle)]
pub extern "C" fn avmt_result_len() -> usize {
    RESULT_LEN.with(Cell::get)
}

/// Outcome of the last [`avmt_transpile`] call: `1` success, `0` refusal, `-1` never called.
///
/// The `-1` is not decoration. A host that reads `avmt_ok()` without having called
/// `avmt_transpile` gets an answer that cannot be mistaken for either outcome, rather than a
/// `0` that reads as "it failed" or a `1` that reads as "it worked".
#[unsafe(no_mangle)]
pub extern "C" fn avmt_ok() -> i32 {
    RESULT_OK.with(Cell::get)
}

/// Transpile a compiled ACIR contract artifact.
///
/// `(ptr, len)` is the artifact's JSON, exactly the bytes `nargo` writes and exactly the bytes
/// the native `avm-transpiler` binary reads from its input path. The returned buffer holds the
/// transpiled artifact's JSON when [`avmt_ok`] is `1`, and the transpiler's own error message
/// when it is `0`.
///
/// # Safety
/// `(ptr, len)` must describe an initialised buffer that stays valid for the duration of the
/// call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn avmt_transpile(ptr: *const u8, len: usize) -> *mut u8 {
    RESULT_LEN.with(|c| c.set(0));
    RESULT_OK.with(|c| c.set(0));

    if ptr.is_null() {
        return publish(b"the input pointer is null".to_vec(), false);
    }

    // The one call. Everything else in this file is marshalling.
    let mut result = unsafe { avm_transpiler::avm_transpile_bytecode(ptr, len) };

    let (bytes, ok) = if result.success == 1 && !result.data.is_null() {
        let body = unsafe { std::slice::from_raw_parts(result.data, result.length) }.to_vec();
        (body, true)
    } else if !result.error_message.is_null() {
        (unsafe { CStr::from_ptr(result.error_message) }.to_bytes().to_vec(), false)
    } else {
        (b"the transpiler failed and gave no message".to_vec(), false)
    };

    // SAFETY: `result` came from `avm_transpile_bytecode` and is freed exactly once.
    unsafe { avm_transpiler::avm_free_result(&mut result as *mut _) };

    publish(bytes, ok)
}

fn publish(bytes: Vec<u8>, ok: bool) -> *mut u8 {
    RESULT_LEN.with(|c| c.set(bytes.len()));
    RESULT_OK.with(|c| c.set(if ok { 1 } else { 0 }));
    if bytes.is_empty() {
        return std::ptr::null_mut();
    }
    let mut boxed = bytes.into_boxed_slice();
    let p = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    p
}
