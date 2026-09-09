//! Path B — the Nim writer, reached through its C ABI, behind [`CtWriterBackend`].
//!
//! # What is on the other side of these declarations
//!
//! `codetracer_trace_writer_ffi.nim` in `codetracer-trace-format-nim`, compiled to a static
//! library for `wasm32-unknown-unknown` by this crate's `build.rs` and linked into the same module
//! as this Rust code. One linear memory, one allocator (see `nim_host_shim.c`), no wasm imports.
//! The functions declared below are a SUBSET of that ABI's one hundred and thirty; this file names
//! the ones this module needs and nothing else, so a reader can see the whole of what crosses.
//!
//! # The two things the sandbox cannot supply, and how Path B differs from Path A about them
//!
//! `wasm32-unknown-unknown` has no wall clock and no CSPRNG. The Nim writer mints a UUIDv7
//! recording identity inside its constructor when the caller supplies none, and on this target
//! that mint draws on host stubs. `nim_host_shim.c` makes the entropy stub REFUSE rather than
//! answer a constant, so the mint fails rather than producing an identity every browser tab would
//! share. The consequence is visible here: [`NimBackend::open`] REQUIRES a recording id, and says
//! so, where Path A accepts an empty one and lets the writer choose. That is one of the named
//! differences in `verify_container_equivalence_characterised` rather than a defect in either.
//!
//! # Strings
//!
//! Every string this ABI takes is a NUL-terminated `cstring`, and every one this module passes
//! comes from a host buffer that has already been validated as UTF-8 by `read_str`. A NUL in the
//! middle of one would truncate silently, so [`CStr`] refuses it instead — a host that manages to
//! send an embedded NUL gets a named failure rather than a short path.

use core::ffi::{c_char, c_int, c_void};
use std::path::Path;

use crate::backend::{CT_WRITER_KIND_PATH_B_NIM, CtWriterBackend, TypeKind, Value};
use crate::set_error;

type Handle = *mut c_void;
type Encoder = *mut c_void;

/// `FFI_TRACE_FORMAT_BINARY`, the multi-stream format. The single-stream formats cannot carry the
/// step columns, values and calls this module writes.
const FFI_TRACE_FORMAT_BINARY: c_int = 2;
/// `FFI_TYPE_INT`, from `include/codetracer_trace_writer.h`.
const FFI_TYPE_INT: c_int = 7;
/// `FFI_TYPE_NONE`, from the same header.
const FFI_TYPE_NONE: c_int = 30;
/// `FFI_EVENT_TRACE_LOG_EVENT`, from the same header.
const FFI_EVENT_TRACE_LOG_EVENT: c_int = 12;

extern "C" {
    // -- the shim (nim_host_shim.c), not part of the Nim ABI --
    fn ct_nim_shim_bind(
        alloc: extern "C" fn(usize) -> *mut c_void,
        free: extern "C" fn(*mut c_void),
        realloc: extern "C" fn(*mut c_void, usize) -> *mut c_void,
    );
    fn ct_nim_shim_bound() -> c_int;

    // -- lifecycle --
    fn codetracer_trace_writer_init();
    fn trace_writer_new(program: *const c_char, format: c_int) -> Handle;
    fn trace_writer_free(handle: Handle);
    fn trace_writer_set_recording_id(handle: Handle, recording_id: *const c_char) -> c_int;
    fn trace_writer_begin_in_memory(handle: Handle) -> c_int;
    fn trace_writer_close(handle: Handle) -> c_int;
    fn trace_writer_container_ready(handle: Handle) -> c_int;
    fn trace_writer_container_len(handle: Handle) -> usize;
    fn trace_writer_container_ptr(handle: Handle) -> *const u8;
    fn trace_writer_last_error() -> *const c_char;

    // -- metadata and interning --
    fn trace_writer_set_workdir(handle: Handle, workdir: *const c_char);
    fn trace_writer_start(handle: Handle, path: *const c_char, line: i64);
    fn trace_writer_ensure_type_id(handle: Handle, kind: c_int, lang_type: *const c_char) -> usize;
    fn trace_writer_ensure_function_id(
        handle: Handle,
        name: *const c_char,
        path: *const c_char,
        line: i64,
    ) -> usize;
    fn trace_writer_register_path_with_line_lengths(
        handle: Handle,
        path: *const c_char,
        line_count: c_int,
        line_lengths: *const u32,
    ) -> c_int;

    // -- columns --
    fn trace_writer_enable_column_aware_steps(handle: Handle);
    fn trace_writer_enable_column_breakpoints_support(handle: Handle);
    fn trace_writer_enable_column_motions_support(handle: Handle);
    fn trace_writer_register_delta_column(handle: Handle, column_delta: i64);

    // -- events --
    fn trace_writer_register_step(handle: Handle, path: *const c_char, line: i64);
    fn trace_writer_register_call(handle: Handle, function_id: usize);
    fn trace_writer_register_call_arg(
        handle: Handle,
        name: *const c_char,
        cbor_data: *const u8,
        cbor_len: usize,
    );
    fn trace_writer_register_return(handle: Handle);
    fn trace_writer_register_variable_cbor(
        handle: Handle,
        name: *const c_char,
        cbor_data: *const u8,
        cbor_len: usize,
    );
    fn trace_writer_register_special_event(
        handle: Handle,
        kind: c_int,
        metadata: *const c_char,
        content: *const c_char,
    );

    // -- the value encoder, used to build a ValueRecord's CBOR exactly --
    fn ct_value_encoder_new() -> Encoder;
    fn ct_value_encoder_free(h: Encoder);
    fn ct_value_encoder_reset(h: Encoder);
    fn ct_value_write_int(h: Encoder, value: i64, type_id: u64) -> c_int;
    fn ct_value_write_string(h: Encoder, data: *const u8, len: usize, type_id: u64) -> c_int;
    fn ct_value_get_bytes(h: Encoder, out_len: *mut usize) -> *const u8;
}

// ---------------------------------------------------------------------------
// The allocator the Nim side uses. See `nim_host_shim.c` for why these are passed as pointers
// rather than called by name.
//
// The size header exists because Rust's `dealloc` needs the layout `alloc` was given and C's
// `free` is handed only the pointer. Sixteen bytes rather than eight so the returned pointer keeps
// 16-byte alignment, which is the alignment the header requests and which `long double` and
// vector types on other targets would need; paying it here keeps the shim's contract independent
// of what the Nim side happens to allocate.
// ---------------------------------------------------------------------------

const HDR: usize = 16;

extern "C" fn nim_alloc(n: usize) -> *mut c_void {
    // A zero-byte `malloc` may return a unique pointer or null; returning a real one-byte
    // allocation keeps `free` symmetric and avoids a null that the Nim side would read as OOM.
    let want = if n == 0 { 1 } else { n };
    unsafe {
        let layout = core::alloc::Layout::from_size_align_unchecked(want + HDR, 16);
        let p = std::alloc::alloc(layout);
        if p.is_null() {
            return core::ptr::null_mut();
        }
        *(p as *mut usize) = want;
        p.add(HDR) as *mut c_void
    }
}

extern "C" fn nim_free(p: *mut c_void) {
    if p.is_null() {
        return;
    }
    unsafe {
        let base = (p as *mut u8).sub(HDR);
        let n = *(base as *mut usize);
        let layout = core::alloc::Layout::from_size_align_unchecked(n + HDR, 16);
        std::alloc::dealloc(base, layout);
    }
}

extern "C" fn nim_realloc(p: *mut c_void, n: usize) -> *mut c_void {
    if p.is_null() {
        return nim_alloc(n);
    }
    unsafe {
        let base = (p as *mut u8).sub(HDR);
        let old = *(base as *mut usize);
        let want = if n == 0 { 1 } else { n };
        let layout = core::alloc::Layout::from_size_align_unchecked(old + HDR, 16);
        let grown = std::alloc::realloc(base, layout, want + HDR);
        if grown.is_null() {
            return core::ptr::null_mut();
        }
        *(grown as *mut usize) = want;
        grown.add(HDR) as *mut c_void
    }
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

/// A NUL-terminated copy of a `&str`, refusing an embedded NUL rather than truncating at it.
struct CStr(Vec<u8>);

impl CStr {
    fn new(s: &str) -> Result<CStr, String> {
        if s.as_bytes().contains(&0) {
            return Err(format!(
                "the string {s:?} contains a NUL and cannot cross a C ABI"
            ));
        }
        let mut v = Vec::with_capacity(s.len() + 1);
        v.extend_from_slice(s.as_bytes());
        v.push(0);
        Ok(CStr(v))
    }

    fn path(p: &Path) -> Result<CStr, String> {
        match p.to_str() {
            Some(s) => CStr::new(s),
            None => Err(format!("the path {p:?} is not valid UTF-8")),
        }
    }

    fn ptr(&self) -> *const c_char {
        self.0.as_ptr() as *const c_char
    }
}

/// The writer's own last error, or a stand-in saying it did not set one.
///
/// A refusal with no message is worse than a refusal with a bad one: the caller is told something
/// failed and nothing about what, and the empty string reads as "no error" to anyone who checks
/// truthiness. So the absence is named.
fn last_error() -> String {
    unsafe {
        let p = trace_writer_last_error();
        if p.is_null() {
            return "the Nim writer refused and set no message".to_string();
        }
        let mut n = 0usize;
        while *p.add(n) != 0 {
            n += 1;
        }
        if n == 0 {
            return "the Nim writer refused and set an empty message".to_string();
        }
        String::from_utf8_lossy(core::slice::from_raw_parts(p as *const u8, n)).into_owned()
    }
}

// ---------------------------------------------------------------------------

pub struct NimBackend {
    handle: Handle,
    encoder: Encoder,
    /// Set once `finish` has run, so `take_container_bytes` can tell "no container yet" from "a
    /// container that turned out to be empty". `trace_writer_container_len` cannot: CTFS allocates
    /// in blocks, and an empty recording still has a `meta.dat`, so zero is not a sentinel.
    finished: bool,
}

impl NimBackend {
    /// Encode one value to CBOR through the writer's own encoder and return the bytes' extent.
    ///
    /// The encoder is used rather than `trace_writer_register_variable_int` / `_raw` because those
    /// two intern a type by `(kind, name)` on every call and pick their own id, while this module
    /// has already interned `None` and `Int`/`"Field"` and needs the values to point at THOSE ids.
    /// A value under a second `Int`/`"Field"` id would read back correctly and would put a second
    /// row in the type table, which is a container difference with no cause.
    fn encode(&mut self, v: Value<'_>) -> Result<(*const u8, usize), String> {
        unsafe {
            ct_value_encoder_reset(self.encoder);
            let rc = match v {
                Value::Int(i, t) => ct_value_write_int(self.encoder, i, t),
                Value::Str(s, t) => ct_value_write_string(self.encoder, s.as_ptr(), s.len(), t),
            };
            if rc != 0 {
                return Err(format!("the value encoder refused: {}", last_error()));
            }
            let mut len = 0usize;
            let ptr = ct_value_get_bytes(self.encoder, &mut len);
            if ptr.is_null() || len == 0 {
                return Err("the value encoder produced no bytes".to_string());
            }
            Ok((ptr, len))
        }
    }
}

impl Drop for NimBackend {
    fn drop(&mut self) {
        unsafe {
            if !self.encoder.is_null() {
                ct_value_encoder_free(self.encoder);
            }
            if !self.handle.is_null() {
                trace_writer_free(self.handle);
            }
        }
    }
}

impl CtWriterBackend for NimBackend {
    fn kind() -> u32 {
        CT_WRITER_KIND_PATH_B_NIM
    }

    fn open(
        program: &str,
        recording_id: &str,
        want_columns: bool,
        workdir: &Path,
        source: &Path,
    ) -> Result<Self, String> {
        // Bound BEFORE the first Nim call, because Nim's module initialisation allocates.
        unsafe {
            ct_nim_shim_bind(nim_alloc, nim_free, nim_realloc);
            if ct_nim_shim_bound() == 0 {
                return Err("the Nim host shim did not take the allocator binding".to_string());
            }
            codetracer_trace_writer_init();
        }

        if recording_id.is_empty() {
            // Not a limitation of this backend but of the target, and naming it here is the only
            // place a host will read it. See this file's header.
            return Err(
                "Path B requires a recording id: this target has no CSPRNG, so a writer left to \
                 mint its own would mint the same identity in every session"
                    .to_string(),
            );
        }

        let c_program = CStr::new(program)?;
        let c_recording = CStr::new(recording_id)?;
        let c_workdir = CStr::path(workdir)?;
        let c_source = CStr::path(source)?;

        unsafe {
            let handle = trace_writer_new(c_program.ptr(), FFI_TRACE_FORMAT_BINARY);
            if handle.is_null() {
                return Err(format!("trace_writer_new refused: {}", last_error()));
            }
            let encoder = ct_value_encoder_new();
            if encoder.is_null() {
                trace_writer_free(handle);
                return Err(format!("ct_value_encoder_new refused: {}", last_error()));
            }
            let me = NimBackend {
                handle,
                encoder,
                finished: false,
            };

            // The identity is pinned BEFORE `begin`, because `begin` is where the Nim writer
            // resolves it. After that there is an id in the metadata already and a second one
            // could only overwrite it, which the ABI refuses.
            if trace_writer_set_recording_id(handle, c_recording.ptr()) != 0 {
                return Err(format!(
                    "the writer refused the recording id: {}",
                    last_error()
                ));
            }
            trace_writer_set_workdir(handle, c_workdir.ptr());
            if trace_writer_begin_in_memory(handle) != 0 {
                return Err(format!("the writer refused to begin: {}", last_error()));
            }
            // AFTER `begin`, which is the opposite of Path A's order and is not a choice: the Nim
            // ABI's three column opt-ins are no-ops until the multi-stream writer exists, and it
            // does not exist until `begin`. Both orders reach the same three capability bits.
            if want_columns {
                trace_writer_enable_column_aware_steps(handle);
                trace_writer_enable_column_breakpoints_support(handle);
                trace_writer_enable_column_motions_support(handle);
            }
            trace_writer_start(handle, c_source.ptr(), 1);
            Ok(me)
        }
    }

    fn ensure_type_id(&mut self, kind: TypeKind, lang_type: &str) -> u64 {
        let k = match kind {
            TypeKind::None => FFI_TYPE_NONE,
            TypeKind::Int => FFI_TYPE_INT,
        };
        // A type name that cannot cross is a caller error this module cannot make: the two names
        // it interns are `"None"` and `"Field"`, both literals. `0` is returned rather than
        // panicking because a panic in a `panic = "abort"` wasm module is a trap with no message —
        // and the reason is RECORDED, because a `0` returned silently is a real type id in a real
        // table and nothing downstream could tell it from an intern that worked.
        match CStr::new(lang_type) {
            Ok(c) => unsafe { trace_writer_ensure_type_id(self.handle, k, c.ptr()) as u64 },
            Err(e) => {
                set_error(&e);
                0
            }
        }
    }

    fn ensure_function_id(&mut self, name: &str, path: &Path, line: i64) -> u64 {
        let (c_name, c_path) = match (CStr::new(name), CStr::path(path)) {
            (Ok(n), Ok(p)) => (n, p),
            (Err(e), _) | (_, Err(e)) => {
                set_error(&e);
                return 0;
            }
        };
        unsafe {
            trace_writer_ensure_function_id(self.handle, c_name.ptr(), c_path.ptr(), line) as u64
        }
    }

    fn register_special_event(&mut self, metadata: &str, content: &str) {
        let (m, c) = match (CStr::new(metadata), CStr::new(content)) {
            (Ok(m), Ok(c)) => (m, c),
            (Err(e), _) | (_, Err(e)) => return set_error(&e),
        };
        unsafe {
            trace_writer_register_special_event(
                self.handle,
                FFI_EVENT_TRACE_LOG_EVENT,
                m.ptr(),
                c.ptr(),
            );
        }
    }

    fn register_call(&mut self, function_id: u64, arg: Option<(&str, Value<'_>)>) {
        if let Some((name, v)) = arg {
            match (CStr::new(name), self.encode(v)) {
                (Ok(c_name), Ok((ptr, len))) => unsafe {
                    trace_writer_register_call_arg(self.handle, c_name.ptr(), ptr, len)
                },
                // The frame is opened anyway, WITHOUT the argument, and the reason is recorded. A
                // frame missing an argument is a visible loss; no frame at all would leave
                // `ct_return` with nothing to close and desynchronise every later frame.
                (Err(e), _) | (_, Err(e)) => set_error(&e),
            }
        }
        unsafe { trace_writer_register_call(self.handle, function_id as usize) };
    }

    fn register_return(&mut self, _none_type_id: u64) {
        // The Nim ABI's `register_return` takes no value: it writes a `None` return itself. The
        // type id is therefore UNUSED on this path, and that is a difference from Path A rather
        // than an oversight here — `verify_container_equivalence_characterised` names it.
        unsafe { trace_writer_register_return(self.handle) };
    }

    fn register_path_with_line_lengths(&mut self, path: &Path, line_lengths: &[u32]) {
        let c_path = match CStr::path(path) {
            Ok(p) => p,
            Err(e) => return set_error(&e),
        };
        let ptr = if line_lengths.is_empty() {
            core::ptr::null()
        } else {
            line_lengths.as_ptr()
        };
        unsafe {
            trace_writer_register_path_with_line_lengths(
                self.handle,
                c_path.ptr(),
                line_lengths.len() as c_int,
                ptr,
            );
        }
    }

    fn register_step(&mut self, path: &Path, line: i64) {
        let c_path = match CStr::path(path) {
            Ok(p) => p,
            Err(e) => return set_error(&e),
        };
        unsafe { trace_writer_register_step(self.handle, c_path.ptr(), line) };
    }

    fn register_step_with_column(&mut self, path: &Path, line: i64, column: Option<i64>) {
        self.register_step(path, line);
        if let Some(col) = column {
            // MINUS ONE, AND THE ONE IS THE WHOLE POINT.
            //
            // The Nim ABI takes a DELTA from the step's own global position, and a step just
            // registered sits at its line's START — which in a column-aware trace is column 1, not
            // column 0. So a delta of `col` yields column `col + 1`.
            //
            // The first version of this passed `col` and every column in the container came back
            // exactly one too high: a driver that asked for columns 3, 4, 5 got 4, 5, 6 back
            // through the reference reader. Nothing refused it — a column one to the right is a
            // real position in a real line — so it is the silent-wrong-answer shape, and it was
            // found by `e2e_runtime_traces_through_nim_writer` comparing the positions read back
            // against the positions the driver asked for, rather than by anything noticing on its
            // own.
            //
            // `column` is `None` for a line-only step, and that branch makes NO call at all: with
            // no delta the step stays at its line's start, which is column 1, which is what
            // line-only means positionally.
            unsafe { trace_writer_register_delta_column(self.handle, col - 1) };
        }
    }

    fn register_variable(&mut self, name: &str, value: Value<'_>) {
        // A value that cannot cross is DROPPED, and the reason is recorded. `CtWriterBackend`'s
        // `register_variable` returns nothing because the Path A call it mirrors cannot fail; the
        // C ABI boundary can. Dropping a value with no record anywhere that it had been asked for
        // is the silent-wrong-answer shape, and `ct_last_error_ptr` is where a host already looks.
        let (c_name, ptr, len) = match (CStr::new(name), self.encode(value)) {
            (Ok(n), Ok((p, l))) => (n, p, l),
            (Err(e), _) | (_, Err(e)) => return set_error(&e),
        };
        unsafe { trace_writer_register_variable_cbor(self.handle, c_name.ptr(), ptr, len) };
    }

    fn dropped_column_awareness(&self) -> bool {
        // The Nim writer has no such signal to read, and the reason is that it has nothing to
        // report: it carries columns unconditionally, so there is no accepted-then-dropped state
        // for it to be in. Answering `false` here is therefore the writer's answer and not a
        // constant this module chose — but it is answered from a comment rather than from the
        // writer, which is exactly the shape this campaign distrusts. The check that keeps it
        // honest is `verify_container_equivalence_characterised`: it asserts the column-aware
        // capability BITS in the two containers' `meta.dat` agree, which is the observable this
        // signal is about.
        false
    }

    fn finish(&mut self) -> Result<(), String> {
        unsafe {
            if trace_writer_close(self.handle) != 0 {
                return Err(format!("the writer refused to close: {}", last_error()));
            }
            if trace_writer_container_ready(self.handle) != 1 {
                return Err("the writer closed without retaining a container".to_string());
            }
        }
        self.finished = true;
        Ok(())
    }

    fn take_container_bytes(&mut self) -> Option<Vec<u8>> {
        if !self.finished {
            return None;
        }
        unsafe {
            let n = trace_writer_container_len(self.handle);
            if n == 0 {
                // A zero-length container is a real answer for a writer that retained one, and it
                // is not this module's to reinterpret. An empty `Vec` says "a container, and it is
                // empty"; `None` would say "no container", which is what `!self.finished` means.
                return Some(Vec::new());
            }
            let p = trace_writer_container_ptr(self.handle);
            if p.is_null() {
                return None;
            }
            Some(core::slice::from_raw_parts(p, n).to_vec())
        }
    }
}
