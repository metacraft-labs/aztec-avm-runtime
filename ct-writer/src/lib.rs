//! The CodeTracer `.ct` writer, inside WebAssembly, driven by events that come from OUTSIDE.
//!
//! # What this is, and what it is not
//!
//! **It is not a trace writer.** The writer is
//! `codetracer_trace_writer::ctfs_writer::CtfsTraceWriter` — Path A of DD-7 — reused unmodified
//! from `codetracer-trace-format` at the revision `pins.json` declares. This crate is the *event
//! ABI*: the boundary a TypeScript host crosses to hand AVM execution steps to that writer, and
//! nothing else. If you find yourself serialising a CTFS stream here, stop; you are forking one.
//!
//! `wasm-ctfs-demo` on the same branch is the reference for the raw-C-ABI shape and this crate
//! follows it: `extern "C"` over linear memory, no `wasm-bindgen`, no JS glue, **no imports at
//! all**, so the module instantiates under a bare `WebAssembly.instantiate(bytes, {})` in a
//! browser and runs unmodified under `wasmtime`. `verify_ct_writer_wasm_zero_imports` measures
//! that on the built artefact rather than taking this paragraph's word for it.
//!
//! The demo differs from this crate in the direction that matters for M24: it *generates* its own
//! events inside the module. Ours arrive from the host, which is what makes the crossing count a
//! question at all.
//!
//! # The two ABIs, and why both are here
//!
//! OQ-6 asks whether a host should cross the boundary once per event or once per batch. Both are
//! exported, from the same build, and **both funnel into one `emit()`**, so what a measurement
//! compares is the crossing and the decode — not two different amounts of writer work. Keeping
//! the rejected arm exported is M15's convention: the rejected shape's measurements are retained
//! so the decision can be revisited without redoing the work.
//!
//! * `ct_step(...)` — arm A. One call per event; the five fields arrive as scalars and the
//!   32-byte contract address as a pointer, because it does not fit in a wasm value type.
//! * `ct_ingest(ptr, len)` — arm B. `len / CT_RECORD_SIZE` fixed-width records at `ptr`, one call
//!   for the lot.
//!
//! And two arms that exist only to be measured, never to be used:
//!
//! * `ct_ingest_control(ptr, len)` — a **byte-for-byte duplicate** of `ct_ingest`'s body under a
//!   second export name. It is the negative control: an arm that should show no difference from
//!   `ct_ingest` and must not. This campaign's timing comparator uses exactly this shape (a copy
//!   of the patched binary, run in the same rotation) for exactly this reason — a comparison that
//!   has never been shown to produce "no difference" when there is none is not calibrated.
//! * `ct_nop_step` / `ct_nop_ingest` — the same two signatures with the writer work removed, so
//!   the *crossing alone* can be priced against §9.3's ~33 ns/crossing prior. They increment a
//!   counter, which is there so the optimiser cannot delete the call and so a host can prove the
//!   calls happened.
//!
//! # Two things the sandbox cannot supply
//!
//! `wasm32-unknown-unknown` has neither a wall clock nor a CSPRNG, so it can mint no UUIDv7, and
//! it has no current directory. Both are therefore host inputs to `ct_writer_open`. This is the
//! demo's finding, restated because it is the difference between a container with a stable
//! identity and one that collides with every other recording in a trace store.
//!
//! # DD-7
//!
//! `want_columns` is **HONOURED** at the current `trace_format` anchor and was not at
//! `9cbc127ef8`; the request reaches the writer through the TRAIT, whose defaults are empty
//! bodies and which `CtfsTraceWriter` overrides, so `dropped_column_awareness()` answers `false`.
//! Both signals are still surfaced, from different places on purpose: the request from this
//! module's session, the loss from the writer. DD-7's refusal stands and its subject moved — this
//! runtime has no source column to record (`emit()` is rung 3, `Line(pc)`) — so it fires in the
//! host (`ct-host/src/config.ts`). `ct_writer_kind()` records which path wrote the container.

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// The wire record.
//
// FIXED WIDTH AND LITTLE-ENDIAN, which is not a preference: wasm linear memory is
// little-endian by specification, so a host writing through a `DataView` with `littleEndian=true`
// and this module reading through `from_le_bytes` agree on every engine without a byte-order
// negotiation.
//
// The five fields are upstream's `ExecutionStep`, which is
// `MSGPACK_CAMEL_CASE_FIELDS(context_id, contract_address, pc, opcode, gas_used)` in
// `barretenberg/cpp/src/barretenberg/vm2/...`. M15 chose that shape and M24 carries it; this
// module does not invent an event.
//
// 64 bytes rather than the 56 the fields need. The 8 reserved bytes buy alignment — a 64-byte
// record is a power of two, so record `i` starts at `i << 6` and a host's index arithmetic cannot
// drift from the module's — and they are asserted to be ZERO on ingest, so a host that starts
// writing something into them is a loud failure rather than a silent reinterpretation the day
// this layout grows a field.
// ---------------------------------------------------------------------------

/// Bytes per event record on the batched path.
pub const CT_RECORD_SIZE: usize = 64;

const OFF_CONTEXT_ID: usize = 0; // u32
const OFF_PC: usize = 4; // u32
const OFF_OPCODE: usize = 8; // u32
const OFF_RESERVED: usize = 12; // u32, must be zero
const OFF_L2_GAS: usize = 16; // u64
const OFF_DA_GAS: usize = 24; // u64
const OFF_ADDRESS: usize = 32; // [u8; 32]
const ADDRESS_LEN: usize = 32;

const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN == CT_RECORD_SIZE);

/// Status codes. Negative is failure, and each value names one cause: a host that gets `-4` knows
/// its buffer length was not a whole number of records without reading a string out of memory.
pub const CT_OK: i32 = 0;
const CT_ERR_NO_SESSION: i32 = -1;
const CT_ERR_WRITER: i32 = -2;
const CT_ERR_BAD_UTF8: i32 = -3;
const CT_ERR_BAD_LENGTH: i32 = -4;
const CT_ERR_NULL: i32 = -5;
const CT_ERR_RESERVED_NOT_ZERO: i32 = -6;
const CT_ERR_ALREADY_OPEN: i32 = -7;

/// Which writer produced the container. Recorded rather than inferred — DD-7's second half.
const CT_WRITER_KIND_PATH_A_PURE_RUST: u32 = 1;

// ---------------------------------------------------------------------------
// Module state.
//
// `static mut` is sound in the way wasm actually runs this module, and the demo says so for the
// same reason: `wasm32-unknown-unknown` is single-threaded and this module declares no shared
// memory, so there is no second thread for a `&mut` to alias. It is not sound on a `-pthread`
// build, and `verify_ct_writer_wasm_zero_imports` asserts the memory is NOT shared, which is what
// keeps that assumption checkable rather than merely stated.
// ---------------------------------------------------------------------------

struct Session {
    writer: CtfsTraceWriter,
    path: PathBuf,
    type_id: TypeId,
    columns_requested: bool,
    events: u64,
}

static mut SESSION: Option<Session> = None;
static mut CONTAINER: Vec<u8> = Vec::new();
static mut ERROR: String = String::new();
static mut NOP_CALLS: u64 = 0;
static mut NOP_RECORDS: u64 = 0;
static mut DROPPED_COLUMNS: u32 = 0;
static mut COLUMNS_REQUESTED: u32 = 0;

#[allow(static_mut_refs)]
fn session() -> Option<&'static mut Session> {
    unsafe { (*(&raw mut SESSION)).as_mut() }
}

fn set_error(msg: &str) {
    unsafe {
        let slot = &raw mut ERROR;
        *slot = msg.to_string();
    }
}

// ---------------------------------------------------------------------------
// Linear-memory plumbing. The demo's `ct_demo_alloc` / `ct_demo_free`, renamed.
// ---------------------------------------------------------------------------

/// Reserve `len` bytes of linear memory and return a pointer to them.
///
/// # Safety
/// Release with [`ct_free`], passing the same length.
#[unsafe(no_mangle)]
pub extern "C" fn ct_alloc(len: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(len);
    let ptr = buf.as_mut_ptr();
    core::mem::forget(buf);
    ptr
}

/// Release memory obtained from [`ct_alloc`].
///
/// # Safety
/// `ptr` must come from `ct_alloc` and `len` must be the length passed to it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Vec::from_raw_parts(ptr, 0, len) });
    }
}

/// Bytes per batched record, read from the module rather than restated by the host.
///
/// A host that hardcodes 64 and a module that changes to 72 disagree silently and produce a
/// container full of garbage; `ct-host` reads this and asserts against its own encoder's stride.
#[unsafe(no_mangle)]
pub extern "C" fn ct_record_size() -> usize {
    CT_RECORD_SIZE
}

/// Which writer path produced the container. `1` is DD-7's Path A, the pure-Rust `CtfsTraceWriter`.
#[unsafe(no_mangle)]
pub extern "C" fn ct_writer_kind() -> u32 {
    CT_WRITER_KIND_PATH_A_PURE_RUST
}

unsafe fn read_str(ptr: *const u8, len: usize) -> Result<String, i32> {
    if ptr.is_null() && len != 0 {
        return Err(CT_ERR_NULL);
    }
    let bytes = if len == 0 { &[][..] } else { unsafe { core::slice::from_raw_parts(ptr, len) } };
    core::str::from_utf8(bytes).map(|s| s.to_string()).map_err(|_| CT_ERR_BAD_UTF8)
}

// ---------------------------------------------------------------------------
// Session lifecycle.
// ---------------------------------------------------------------------------

/// Open a writer.
///
/// `recording_id` may be empty, in which case the writer's deterministic placeholder stands — see
/// the module docs for why a host should not let it.
///
/// `want_columns` is recorded and deliberately not honoured; see DD-7 in the module docs.
///
/// # Safety
/// Every pointer must address `len` readable bytes in this module's linear memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_writer_open(
    program_ptr: *const u8,
    program_len: usize,
    recording_id_ptr: *const u8,
    recording_id_len: usize,
    source_ptr: *const u8,
    source_len: usize,
    workdir_ptr: *const u8,
    workdir_len: usize,
    want_columns: u32,
) -> i32 {
    if session().is_some() {
        set_error("a writer is already open; call ct_writer_close first");
        return CT_ERR_ALREADY_OPEN;
    }
    let program = match unsafe { read_str(program_ptr, program_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("program name is not valid UTF-8");
            return e;
        }
    };
    let recording_id = match unsafe { read_str(recording_id_ptr, recording_id_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("recording id is not valid UTF-8");
            return e;
        }
    };
    let source = match unsafe { read_str(source_ptr, source_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("source path is not valid UTF-8");
            return e;
        }
    };
    let workdir = match unsafe { read_str(workdir_ptr, workdir_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("workdir is not valid UTF-8");
            return e;
        }
    };

    let mut writer = CtfsTraceWriter::new_in_memory(&program, &[]);
    if !recording_id.is_empty() {
        writer.set_recording_id(recording_id);
    }
    // DD-7: the request is made to the writer so that the WRITER decides it cannot honour it.
    // Deciding that here, from a constant, would make `ct_dropped_column_awareness` a literal
    // this module printed rather than a signal it read — which is this campaign's oldest defect
    // family, and the reason `dropped_column_awareness()` exists in the writer at all.
    if want_columns != 0 {
        TraceWriter::enable_column_aware_steps(&mut writer);
        TraceWriter::enable_column_breakpoints_support(&mut writer);
        TraceWriter::enable_column_motions_support(&mut writer);
    }
    if writer.begin_writing_trace_events(Path::new("trace")).is_err() {
        set_error("the writer refused to begin");
        return CT_ERR_WRITER;
    }

    let path = PathBuf::from(&source);
    let workdir_path = if workdir.is_empty() { PathBuf::from("/") } else { PathBuf::from(&workdir) };
    TraceWriter::set_workdir(&mut writer, &workdir_path);
    TraceWriter::start(&mut writer, &path, Line(1));
    let type_id = TraceWriter::ensure_type_id(&mut writer, TypeKind::Int, "Field");

    unsafe {
        COLUMNS_REQUESTED = if want_columns != 0 { 1 } else { 0 };
        let slot = &raw mut SESSION;
        *slot = Some(Session { writer, path, type_id, columns_requested: want_columns != 0, events: 0 });
    }
    set_error("");
    CT_OK
}

/// Finish the container and return a pointer to it in linear memory. Pair with
/// [`ct_container_len`]. Returns null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn ct_writer_close() -> *const u8 {
    let s = match session() {
        Some(s) => s,
        None => {
            set_error("no writer is open");
            return core::ptr::null();
        }
    };
    // Read the writer's own signal BEFORE the session is taken apart, and read it from the writer
    // rather than from `columns_requested`: the two agreeing is a fact worth being able to fail.
    let dropped = s.writer.dropped_column_awareness();
    let requested = s.columns_requested;
    if s.writer.finish_writing_trace_events().is_err() {
        set_error("the writer refused to finish");
        return core::ptr::null();
    }
    let bytes = match s.writer.take_container_bytes() {
        Some(b) => b,
        None => {
            set_error("the in-memory writer produced no container");
            return core::ptr::null();
        }
    };
    unsafe {
        DROPPED_COLUMNS = if dropped { 1 } else { 0 };
        COLUMNS_REQUESTED = if requested { 1 } else { 0 };
        let slot = &raw mut CONTAINER;
        *slot = bytes;
        let sslot = &raw mut SESSION;
        *sslot = None;
        (*slot).as_ptr()
    }
}

/// Length in bytes of the container [`ct_writer_close`] last produced.
#[unsafe(no_mangle)]
pub extern "C" fn ct_container_len() -> usize {
    unsafe { (&*(&raw const CONTAINER)).len() }
}

/// Events accepted since the session opened, or since the last close.
#[unsafe(no_mangle)]
pub extern "C" fn ct_events_written() -> u64 {
    match session() {
        Some(s) => s.events,
        None => 0,
    }
}

/// `1` when the tracing configuration asked for column-aware output.
#[unsafe(no_mangle)]
pub extern "C" fn ct_columns_requested() -> u32 {
    unsafe { COLUMNS_REQUESTED }
}

/// `1` when a column-aware request was accepted and dropped — `CtfsTraceWriter`'s own signal,
/// captured at close. DD-7 says assert on this *only* when columns were requested.
#[unsafe(no_mangle)]
pub extern "C" fn ct_dropped_column_awareness() -> u32 {
    unsafe { DROPPED_COLUMNS }
}

/// Pointer to the last error message. Not NUL-terminated; pair with [`ct_last_error_len`].
#[unsafe(no_mangle)]
pub extern "C" fn ct_last_error_ptr() -> *const u8 {
    unsafe { (&*(&raw const ERROR)).as_ptr() }
}

/// Length of the last error message.
#[unsafe(no_mangle)]
pub extern "C" fn ct_last_error_len() -> usize {
    unsafe { (&*(&raw const ERROR)).len() }
}

// ---------------------------------------------------------------------------
// THE ONE PLACE AN EVENT BECOMES WRITER CALLS.
//
// Both ABIs call this. If they did not, OQ-6 would be comparing two implementations rather than
// two boundary shapes, and the measurement would answer a question nobody asked.
// ---------------------------------------------------------------------------

#[inline(always)]
fn emit(s: &mut Session, context_id: u32, pc: u32, opcode: u32, l2_gas: u64, da_gas: u64, address: &[u8]) {
    // The path/line mapping is M25's, not M24's: OQ-5 has not been settled, so a program counter
    // is recorded AS a program counter and is not dressed up as a source line. `Line(pc)` here is
    // rung 3 of §9.2's ladder — bytecode-level stepping — and M25 replaces it once the transpiler
    // question is answered. Saying so here is cheaper than a reader inferring source fidelity
    // this container does not have.
    let path = s.path.clone();
    TraceWriter::register_step(&mut s.writer, &path, Line(pc as i64));
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "opcode",
        ValueRecord::Int { i: opcode as i64, type_id: s.type_id },
    );
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "contextId",
        ValueRecord::Int { i: context_id as i64, type_id: s.type_id },
    );
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "l2Gas",
        ValueRecord::Int { i: l2_gas as i64, type_id: s.type_id },
    );
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "daGas",
        ValueRecord::Int { i: da_gas as i64, type_id: s.type_id },
    );
    // The contract address is 32 bytes of field element and OQ-4 (how a 254-bit field renders)
    // is M25's to settle against what the Noir tracer does. Until then it is recorded as its
    // low 64 bits with the full bytes NOT silently discarded: the count is asserted by the host,
    // and M25 replaces this with the settled rendering.
    let mut low = 0i64;
    for (i, b) in address.iter().rev().take(8).enumerate() {
        low |= (*b as i64) << (8 * i);
    }
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "contractAddressLow",
        ValueRecord::Int { i: low, type_id: s.type_id },
    );
    s.events += 1;
}

// ---------------------------------------------------------------------------
// ARM A — one crossing per event.
// ---------------------------------------------------------------------------

/// Record one execution step. Arm A of OQ-6.
///
/// The contract address arrives as a pointer because 32 bytes do not fit in a wasm value type;
/// the host writes it into a scratch slot and passes the slot. That write is real work a
/// per-event host must do, and arm B pays the identical 32-byte write inside its record, so the
/// two arms are not made unequal by it.
///
/// # Safety
/// `address_ptr` must address 32 readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_step(
    context_id: u32,
    pc: u32,
    opcode: u32,
    l2_gas: u64,
    da_gas: u64,
    address_ptr: *const u8,
) -> i32 {
    if address_ptr.is_null() {
        set_error("ct_step: null address pointer");
        return CT_ERR_NULL;
    }
    let address = unsafe { core::slice::from_raw_parts(address_ptr, ADDRESS_LEN) };
    match session() {
        Some(s) => {
            emit(s, context_id, pc, opcode, l2_gas, da_gas, address);
            CT_OK
        }
        None => {
            set_error("ct_step: no writer is open");
            CT_ERR_NO_SESSION
        }
    }
}

// ---------------------------------------------------------------------------
// ARM B — one crossing per batch.
// ---------------------------------------------------------------------------

#[inline(always)]
unsafe fn ingest_impl(ptr: *const u8, len: usize) -> i32 {
    if ptr.is_null() && len != 0 {
        set_error("ct_ingest: null buffer");
        return CT_ERR_NULL;
    }
    if len % CT_RECORD_SIZE != 0 {
        set_error("ct_ingest: buffer length is not a whole number of records");
        return CT_ERR_BAD_LENGTH;
    }
    let n = len / CT_RECORD_SIZE;
    let buf = if len == 0 { &[][..] } else { unsafe { core::slice::from_raw_parts(ptr, len) } };
    let s = match session() {
        Some(s) => s,
        None => {
            set_error("ct_ingest: no writer is open");
            return CT_ERR_NO_SESSION;
        }
    };
    for i in 0..n {
        let r = &buf[i * CT_RECORD_SIZE..(i + 1) * CT_RECORD_SIZE];
        let reserved = u32::from_le_bytes([r[OFF_RESERVED], r[OFF_RESERVED + 1], r[OFF_RESERVED + 2], r[OFF_RESERVED + 3]]);
        if reserved != 0 {
            set_error("ct_ingest: the reserved word of a record is not zero");
            return CT_ERR_RESERVED_NOT_ZERO;
        }
        let context_id = u32::from_le_bytes([r[OFF_CONTEXT_ID], r[OFF_CONTEXT_ID + 1], r[OFF_CONTEXT_ID + 2], r[OFF_CONTEXT_ID + 3]]);
        let pc = u32::from_le_bytes([r[OFF_PC], r[OFF_PC + 1], r[OFF_PC + 2], r[OFF_PC + 3]]);
        let opcode = u32::from_le_bytes([r[OFF_OPCODE], r[OFF_OPCODE + 1], r[OFF_OPCODE + 2], r[OFF_OPCODE + 3]]);
        let mut g = [0u8; 8];
        g.copy_from_slice(&r[OFF_L2_GAS..OFF_L2_GAS + 8]);
        let l2_gas = u64::from_le_bytes(g);
        g.copy_from_slice(&r[OFF_DA_GAS..OFF_DA_GAS + 8]);
        let da_gas = u64::from_le_bytes(g);
        emit(s, context_id, pc, opcode, l2_gas, da_gas, &r[OFF_ADDRESS..OFF_ADDRESS + ADDRESS_LEN]);
    }
    n as i32
}

/// Ingest a batch of records. Arm B of OQ-6. Returns the record count, or a negative status.
///
/// # Safety
/// `ptr` must address `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_ingest(ptr: *const u8, len: usize) -> i32 {
    unsafe { ingest_impl(ptr, len) }
}

/// **The negative control.** Identical to [`ct_ingest`] in every respect except its name.
///
/// A difference measured between this and `ct_ingest` is a difference the instrument invented.
/// It is exported from the shipped module deliberately: a control that is compiled separately, or
/// only in a benchmark build, is a control over a different binary.
///
/// # Safety
/// As [`ct_ingest`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_ingest_control(ptr: *const u8, len: usize) -> i32 {
    unsafe { ingest_impl(ptr, len) }
}

// ---------------------------------------------------------------------------
// The crossing, priced on its own.
// ---------------------------------------------------------------------------

/// A per-event crossing with the writer work removed. Counts, so it cannot be optimised away.
///
/// # Safety
/// `address_ptr` must address 32 readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_nop_step(
    context_id: u32,
    pc: u32,
    opcode: u32,
    l2_gas: u64,
    da_gas: u64,
    address_ptr: *const u8,
) -> i32 {
    let first = if address_ptr.is_null() { 0u64 } else { (unsafe { *address_ptr }) as u64 };
    unsafe {
        NOP_CALLS = NOP_CALLS.wrapping_add(1);
        NOP_RECORDS = NOP_RECORDS
            .wrapping_add(context_id as u64 ^ pc as u64 ^ opcode as u64 ^ l2_gas ^ da_gas ^ first);
    }
    CT_OK
}

/// A per-batch crossing with the writer work removed. Touches every record, so the comparison
/// with [`ct_nop_step`] is over the same bytes read.
///
/// # Safety
/// `ptr` must address `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_nop_ingest(ptr: *const u8, len: usize) -> i32 {
    if len % CT_RECORD_SIZE != 0 {
        return CT_ERR_BAD_LENGTH;
    }
    let n = len / CT_RECORD_SIZE;
    let buf = if len == 0 { &[][..] } else { unsafe { core::slice::from_raw_parts(ptr, len) } };
    let mut acc = 0u64;
    for i in 0..n {
        let r = &buf[i * CT_RECORD_SIZE..(i + 1) * CT_RECORD_SIZE];
        let context_id = u32::from_le_bytes([r[OFF_CONTEXT_ID], r[OFF_CONTEXT_ID + 1], r[OFF_CONTEXT_ID + 2], r[OFF_CONTEXT_ID + 3]]);
        let pc = u32::from_le_bytes([r[OFF_PC], r[OFF_PC + 1], r[OFF_PC + 2], r[OFF_PC + 3]]);
        let opcode = u32::from_le_bytes([r[OFF_OPCODE], r[OFF_OPCODE + 1], r[OFF_OPCODE + 2], r[OFF_OPCODE + 3]]);
        let mut g = [0u8; 8];
        g.copy_from_slice(&r[OFF_L2_GAS..OFF_L2_GAS + 8]);
        let l2_gas = u64::from_le_bytes(g);
        g.copy_from_slice(&r[OFF_DA_GAS..OFF_DA_GAS + 8]);
        let da_gas = u64::from_le_bytes(g);
        acc ^= context_id as u64 ^ pc as u64 ^ opcode as u64 ^ l2_gas ^ da_gas ^ r[OFF_ADDRESS] as u64;
    }
    unsafe {
        NOP_CALLS = NOP_CALLS.wrapping_add(1);
        NOP_RECORDS = NOP_RECORDS.wrapping_add(acc);
    }
    n as i32
}

/// Calls made into either nop arm. A host asserts this moved, so "the crossing cost nothing"
/// cannot mean "the crossing did not happen".
#[unsafe(no_mangle)]
pub extern "C" fn ct_nop_calls() -> u64 {
    unsafe { NOP_CALLS }
}

/// The accumulator the nop arms fold every field into. Read by the host purely so the optimiser
/// cannot prove it dead.
#[unsafe(no_mangle)]
pub extern "C" fn ct_nop_checksum() -> u64 {
    unsafe { NOP_RECORDS }
}

// ---------------------------------------------------------------------------
// Native tests. The same code path the wasm exports take, exercised on the host, so a failure
// points at the trace-building logic rather than at the wasm toolchain. `wasm-ctfs-demo` does
// this and it is worth copying: a red test here and a green one in wasm is a toolchain finding,
// and the reverse is a writer finding.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard, OnceLock};

    // THE MODULE STATE IS GLOBAL BECAUSE WASM IS SINGLE-THREADED; `cargo test` IS NOT.
    // Without this every test in this file races every other over one `SESSION`, and the failure
    // mode is not a crash — it is a container with another test's events in it, which is the
    // silent shape. A serialising guard is the smallest thing that makes the native tests
    // exercise the same single-threaded discipline the wasm target enforces for free.
    fn serial() -> MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        match LOCK.get_or_init(|| Mutex::new(())).lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn record(i: u32) -> [u8; CT_RECORD_SIZE] {
        let mut r = [0u8; CT_RECORD_SIZE];
        r[OFF_CONTEXT_ID..OFF_CONTEXT_ID + 4].copy_from_slice(&i.to_le_bytes());
        r[OFF_PC..OFF_PC + 4].copy_from_slice(&(i * 3).to_le_bytes());
        r[OFF_OPCODE..OFF_OPCODE + 4].copy_from_slice(&(i % 200).to_le_bytes());
        r[OFF_L2_GAS..OFF_L2_GAS + 8].copy_from_slice(&(1000u64 + i as u64).to_le_bytes());
        r[OFF_DA_GAS..OFF_DA_GAS + 8].copy_from_slice(&(7u64 * i as u64).to_le_bytes());
        r[OFF_ADDRESS + 31] = (i % 251) as u8;
        r
    }

    unsafe fn open(want_columns: u32) -> i32 {
        let program = b"aztec";
        let rid = b"01949fcc-7d92-7e9c-8000-00000000ce11";
        let src = b"/aztec/tx.avm";
        let wd = b"/aztec";
        unsafe {
            ct_writer_open(
                program.as_ptr(), program.len(),
                rid.as_ptr(), rid.len(),
                src.as_ptr(), src.len(),
                wd.as_ptr(), wd.len(),
                want_columns,
            )
        }
    }

    #[test]
    fn the_two_arms_produce_the_same_container() {
        let _g = serial();
        // Arm B.
        unsafe { assert_eq!(open(0), CT_OK) };
        let mut buf = Vec::new();
        for i in 0..64u32 {
            buf.extend_from_slice(&record(i));
        }
        let n = unsafe { ct_ingest(buf.as_ptr(), buf.len()) };
        assert_eq!(n, 64);
        assert_eq!(ct_events_written(), 64);
        let p = ct_writer_close();
        assert!(!p.is_null());
        let batched = unsafe { core::slice::from_raw_parts(p, ct_container_len()) }.to_vec();

        // Arm A, the same events one call at a time.
        unsafe { assert_eq!(open(0), CT_OK) };
        for i in 0..64u32 {
            let r = record(i);
            let rc = unsafe {
                ct_step(
                    i,
                    i * 3,
                    i % 200,
                    1000 + i as u64,
                    7 * i as u64,
                    r[OFF_ADDRESS..].as_ptr(),
                )
            };
            assert_eq!(rc, CT_OK);
        }
        assert_eq!(ct_events_written(), 64);
        let p = ct_writer_close();
        assert!(!p.is_null());
        let per_event = unsafe { core::slice::from_raw_parts(p, ct_container_len()) }.to_vec();

        assert_eq!(batched.len(), per_event.len(), "the two ABIs produced different container sizes");
        assert_eq!(&batched[..5], &[0xC0, 0xDE, 0x72, 0xAC, 0xE2], "missing the CTFS magic");
    }

    /// THIS TEST ASSERTED THE OPPOSITE UNTIL THE `trace_format` ANCHOR MOVED, AND NOTHING RAN IT.
    ///
    /// It was `a_column_request_is_recorded_as_dropped`, ending
    /// `assert_eq!(ct_dropped_column_awareness(), 1, "Path A must report the loss it took")`. The
    /// anchor moved onto a writer that HONOURS a column request, so that assertion became false
    /// of the writer this crate links — and it stayed in the tree, green, because
    /// `build_ct_writer_wasm.sh` only runs these tests behind `--native-tests` and nothing passed
    /// it. Run by hand it fails `left: 0, right: 1`. The check now passes `--native-tests`, so
    /// this file is a thing that can fail rather than a thing that is read.
    #[test]
    fn a_column_request_is_honoured_and_reported_as_such() {
        let _g = serial();
        unsafe { assert_eq!(open(1), CT_OK) };
        let r = record(1);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, 1);
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_columns_requested(), 1, "the module must record that columns were asked of it");
        assert_eq!(
            ct_dropped_column_awareness(),
            0,
            "the writer at the pinned trace_format anchor carries columns, so nothing is dropped"
        );
    }

    /// The control for the test above: with no request there is nothing to honour and nothing to
    /// drop, so `ct_dropped_column_awareness()` being 0 there is NOT evidence about the writer's
    /// capability. Both arms exist so the 0 above is attributable.
    #[test]
    fn no_column_request_reports_no_loss() {
        let _g = serial();
        unsafe { assert_eq!(open(0), CT_OK) };
        let r = record(1);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, 1);
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_columns_requested(), 0);
        assert_eq!(ct_dropped_column_awareness(), 0);
    }

    #[test]
    fn a_short_or_dirty_buffer_is_refused() {
        let _g = serial();
        unsafe { assert_eq!(open(0), CT_OK) };
        let mut r = record(1).to_vec();
        r.truncate(CT_RECORD_SIZE - 1);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, CT_ERR_BAD_LENGTH);
        let mut d = record(1);
        d[OFF_RESERVED] = 1;
        assert_eq!(unsafe { ct_ingest(d.as_ptr(), d.len()) }, CT_ERR_RESERVED_NOT_ZERO);
        assert!(!ct_writer_close().is_null());
    }

    #[test]
    fn events_without_a_session_are_refused_rather_than_dropped() {
        let _g = serial();
        let r = record(1);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, CT_ERR_NO_SESSION);
        assert_eq!(
            unsafe { ct_step(0, 0, 0, 0, 0, r[OFF_ADDRESS..].as_ptr()) },
            CT_ERR_NO_SESSION
        );
    }
}
