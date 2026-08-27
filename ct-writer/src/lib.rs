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

use codetracer_trace_types::{EventLogKind, Line, TypeId, TypeKind, ValueRecord};
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
// 64 bytes rather than the 60 the fields need. The 4 reserved bytes buy alignment — a 64-byte
// record is a power of two, so record `i` starts at `i << 6` and a host's index arithmetic cannot
// drift from the module's — and they are asserted to be ZERO on ingest, so a host that starts
// writing something into them is a loud failure rather than a silent reinterpretation the day
// this layout grows a field.
//
// **M25 CORRECTED THE TWO FIGURES IN THE PARAGRAPH ABOVE, AND `TRACE-ABI.md` §7 WITH THEM.** Both
// this comment and that section said "the 8 reserved bytes at offset 12" and "the 56 the fields
// need". The offsets below are the measurement: 4 + 4 + 4 + 8 + 8 + 32 = **60** used and **4**
// reserved, and `const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN == CT_RECORD_SIZE)` has been
// pinning 64 the whole time. The numbers mattered because §7 offered those 8 bytes as the
// wire-format extension point M25 was expected to use, and half of them do not exist. Both are
// constants now, asserted against the OFFSETS at compile time (below) and by the native test
// `the_record_layout_figures_are_four_and_sixty`, which the module build runs with
// `--native-tests` — so the pair cannot drift from the layout again the way the prose did.
//
// M25 DID NOT SPEND THEM. The source position a rung-1 recording needs is a `(path_id, line,
// column)` triple — twelve bytes against four — so M25 adds a SEPARATE, ADDITIVE side channel
// (`ct_positions`, below) rather than growing this record. The consequence is the point: with no
// positions supplied, every byte this module writes is what M24 measured, `ct_record_size()` is
// still 64, `CT_ERR_RESERVED_NOT_ZERO` is still reachable, and OQ-6's twelve-session benchmark is
// still a measurement of the artefact it was taken on.
// ---------------------------------------------------------------------------

/// Bytes per event record on the batched path.
pub const CT_RECORD_SIZE: usize = 64;

/// Bytes the five step fields occupy. The rest of [`CT_RECORD_SIZE`] is reserved.
pub const CT_RECORD_FIELD_BYTES: usize = 60;

/// Reserved bytes in a step record. **Four, not eight** — see the block comment above.
pub const CT_RECORD_RESERVED_BYTES: usize = CT_RECORD_SIZE - CT_RECORD_FIELD_BYTES;

const OFF_CONTEXT_ID: usize = 0; // u32
const OFF_PC: usize = 4; // u32
const OFF_OPCODE: usize = 8; // u32
const OFF_RESERVED: usize = 12; // u32, must be zero
const OFF_L2_GAS: usize = 16; // u64
const OFF_DA_GAS: usize = 24; // u64
const OFF_ADDRESS: usize = 32; // [u8; 32]
const ADDRESS_LEN: usize = 32;

const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN == CT_RECORD_SIZE);
// The two figures the block comment above states, asserted against the offsets rather than typed
// beside them. This is the whole reason the old "8 reserved / 56 used" pair survived two
// milestones: nothing compared it to the layout.
const _: () = assert!(OFF_RESERVED + 4 == OFF_L2_GAS);
const _: () = assert!(CT_RECORD_FIELD_BYTES == 4 + 4 + 4 + 8 + 8 + ADDRESS_LEN);
const _: () = assert!(CT_RECORD_RESERVED_BYTES == 4);

// ---------------------------------------------------------------------------
// THE POSITION SIDE CHANNEL — M25's rung-1 carrier.
//
// One 16-byte record per step, in the SAME ORDER as the step records it accompanies, handed over
// through `ct_positions(ptr, len)` immediately before the `ct_ingest` batch it belongs to. The
// module holds them in a FIFO and `emit()` consumes one per step.
//
// WHY A SIDE CHANNEL AND NOT A WIDER STEP RECORD. A `(path_id, line, column)` triple is twelve
// bytes and the step record has four spare, so carrying it inline means `CT_RECORD_SIZE` 64 -> 80.
// That is a wire-format change `ct_record_size()` is built to survive — and it would also move
// every container size M24 measured, invalidate §3's byte-identical-container claim, and require
// OQ-6's twelve-session benchmark to be re-taken over a different module. The side channel costs
// ONE extra crossing per batch (25 -> 50 at 100,000 events and batch 4,096, against a recording
// that costs ~1,290x its crossings) and only when a mapping exists at all.
//
// POSITIONAL PAIRING IS A DELIBERATE CHOICE AND ITS FAILURE MODE IS LOUD. The alternative — a
// (contract, pc) -> position map inside the module — would silently mis-attribute a step whose pc
// repeats across contracts. Pairing by ORDER makes a host that supplies the wrong number of
// positions produce a countable mismatch: `ct_steps_positioned()` and `ct_steps_unpositioned()`
// are both exported, they sum to the event count, and a rung-1 contract with a non-zero
// unpositioned count is a RUNG VIOLATION rather than a quietly line-only recording.
// ---------------------------------------------------------------------------

/// Bytes per position record on the side channel.
pub const CT_POSITION_SIZE: usize = 16;

const POS_OFF_PATH_ID: usize = 0; // u32
const POS_OFF_LINE: usize = 4; // u32, 1-based; 0 means "no mapping for this step"
const POS_OFF_COLUMN: usize = 8; // u32, 1-based; 0 means "line only"
const POS_OFF_RESERVED: usize = 12; // u32, must be zero

const _: () = assert!(POS_OFF_RESERVED + 4 == CT_POSITION_SIZE);

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
/// A position record names a `path_id` this session never interned.
const CT_ERR_BAD_PATH_ID: i32 = -8;
/// A rung outside [`CT_RUNG_SOURCE`]..=[`CT_RUNG_BYTECODE`] was declared.
const CT_ERR_BAD_RUNG: i32 = -9;

/// Which writer produced the container. Recorded rather than inferred — DD-7's second half.
const CT_WRITER_KIND_PATH_A_PURE_RUST: u32 = 1;

// ---------------------------------------------------------------------------
// §9.2's SOURCE-MAPPING LADDER, AS THREE NUMBERS THE MODULE ENFORCES.
//
// The milestone's words are "the runtime states which rung it is on, per contract, in the trace
// metadata, and **never silently degrades**". Those are two separate obligations and this module
// carries both, in two different places on purpose:
//
//   STATES IT  — `ct_declare_rung` writes one `TraceLogEvent` per contract into the trace itself,
//                so a reader of the container learns the rung from the container. A rung that
//                lived only in a host-side variable would be a claim about a recording rather
//                than a property of one.
//   NEVER SILENTLY DEGRADES — a contract declared at rung 1 whose steps arrive WITHOUT positions
//                is counted as a violation, per contract, with the first offending pc kept. The
//                module counts; `ct-host` refuses. Both, because a signal nothing enforces is
//                decoration (M24 learnt that from `dropped_column_awareness`) and an enforcement
//                with nothing to read is unfalsifiable.
// ---------------------------------------------------------------------------

/// Rung 1 — full source-level stepping: every step carries a path, a line and a column.
pub const CT_RUNG_SOURCE: u32 = 1;
/// Rung 2 — function-level attribution: a position per frame, not per instruction.
pub const CT_RUNG_FUNCTION: u32 = 2;
/// Rung 3 — bytecode-level stepping: `Line(pc)`, the rung M24 shipped on.
pub const CT_RUNG_BYTECODE: u32 = 3;

/// The metadata key every rung declaration is written under, so a reader greps one string.
pub const CT_RUNG_EVENT_METADATA: &str = "ct.mapping-rung";

// ---------------------------------------------------------------------------
// Module state.
//
// `static mut` is sound in the way wasm actually runs this module, and the demo says so for the
// same reason: `wasm32-unknown-unknown` is single-threaded and this module declares no shared
// memory, so there is no second thread for a `&mut` to alias. It is not sound on a `-pthread`
// build, and `verify_ct_writer_wasm_zero_imports` asserts the memory is NOT shared, which is what
// keeps that assumption checkable rather than merely stated.
// ---------------------------------------------------------------------------

/// One contract's declared rung, and what actually happened to its steps.
struct RungDeclaration {
    address: [u8; ADDRESS_LEN],
    rung: u32,
    positioned: u64,
    unpositioned: u64,
    /// The pc of the FIRST step that broke the declaration. `u32::MAX` means none did.
    first_violation_pc: u32,
}

/// One step's resolved source position, as it arrived on the side channel.
#[derive(Clone, Copy)]
struct Position {
    path_id: u32,
    line: u32,
    column: u32,
}

struct Session {
    writer: CtfsTraceWriter,
    path: PathBuf,
    type_id: TypeId,
    field_type_id: TypeId,
    columns_requested: bool,
    events: u64,
    /// Paths interned through `ct_intern_path`, in id order. Index is the id a host quotes.
    paths: Vec<PathBuf>,
    /// The FIFO `emit()` consumes one entry of per step.
    positions: std::collections::VecDeque<Position>,
    rungs: Vec<RungDeclaration>,
    positioned: u64,
    unpositioned: u64,
}

static mut SESSION: Option<Session> = None;
static mut CONTAINER: Vec<u8> = Vec::new();
static mut ERROR: String = String::new();
static mut NOP_CALLS: u64 = 0;
static mut NOP_RECORDS: u64 = 0;
static mut DROPPED_COLUMNS: u32 = 0;
static mut COLUMNS_REQUESTED: u32 = 0;
// Survive `ct_writer_close`, which takes the session apart — a host reads them after the close
// that produced the container, exactly as it reads `DROPPED_COLUMNS`.
static mut RUNG_VIOLATIONS: u32 = 0;
static mut RUNG_VIOLATION_PC: u32 = 0;
static mut STEPS_POSITIONED: u64 = 0;
static mut STEPS_UNPOSITIONED: u64 = 0;

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
    // OQ-4: the SAME `(TypeKind::Int, "Field")` the Noir tracer registers
    // (`noir/tooling/tracer/src/tracer_glue.rs:371`), reused rather than a second type, because
    // the cross-half requirement is about the type table as much as about the value.
    let field_type_id = type_id;

    unsafe {
        COLUMNS_REQUESTED = if want_columns != 0 { 1 } else { 0 };
        RUNG_VIOLATIONS = 0;
        RUNG_VIOLATION_PC = 0;
        STEPS_POSITIONED = 0;
        STEPS_UNPOSITIONED = 0;
        let slot = &raw mut SESSION;
        *slot = Some(Session {
            writer,
            path,
            type_id,
            field_type_id,
            columns_requested: want_columns != 0,
            events: 0,
            paths: Vec::new(),
            positions: std::collections::VecDeque::new(),
            rungs: Vec::new(),
            positioned: 0,
            unpositioned: 0,
        });
    }
    set_error("");
    CT_OK
}

// ---------------------------------------------------------------------------
// Rung declarations, path interning and the position side channel.
// ---------------------------------------------------------------------------

/// Declare the source-mapping rung this session achieved for one contract, with its reason.
///
/// Written into the trace as a `TraceLogEvent` under [`CT_RUNG_EVENT_METADATA`], so the rung is a
/// property of the container rather than of the host that made it. Declaring the same address
/// twice replaces the earlier declaration and does NOT emit a second event.
///
/// # Safety
/// `address_ptr` must address 32 readable bytes; `reason_ptr` must address `reason_len` of them.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_declare_rung(
    address_ptr: *const u8,
    rung: u32,
    reason_ptr: *const u8,
    reason_len: usize,
) -> i32 {
    if address_ptr.is_null() {
        set_error("ct_declare_rung: null address pointer");
        return CT_ERR_NULL;
    }
    if !(CT_RUNG_SOURCE..=CT_RUNG_BYTECODE).contains(&rung) {
        set_error("ct_declare_rung: rung must be 1, 2 or 3");
        return CT_ERR_BAD_RUNG;
    }
    let reason = match unsafe { read_str(reason_ptr, reason_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("ct_declare_rung: reason is not valid UTF-8");
            return e;
        }
    };
    let mut address = [0u8; ADDRESS_LEN];
    address.copy_from_slice(unsafe { core::slice::from_raw_parts(address_ptr, ADDRESS_LEN) });
    let s = match session() {
        Some(s) => s,
        None => {
            set_error("ct_declare_rung: no writer is open");
            return CT_ERR_NO_SESSION;
        }
    };
    if let Some(existing) = s.rungs.iter_mut().find(|d| d.address == address) {
        existing.rung = rung;
        return CT_OK;
    }
    let content = format!("{} rung={} reason={}", hex32(&address), rung, reason);
    TraceWriter::register_special_event(
        &mut s.writer,
        EventLogKind::TraceLogEvent,
        CT_RUNG_EVENT_METADATA,
        &content,
    );
    s.rungs.push(RungDeclaration {
        address,
        rung,
        positioned: 0,
        unpositioned: 0,
        first_violation_pc: u32::MAX,
    });
    set_error("");
    CT_OK
}

/// How many contracts this session has declared a rung for.
#[unsafe(no_mangle)]
pub extern "C" fn ct_rung_count() -> u32 {
    match session() {
        Some(s) => s.rungs.len() as u32,
        None => 0,
    }
}

/// Intern a source path, optionally with its per-line addressable column counts, and return the id
/// a position record must quote. Negative on failure.
///
/// `line_lengths[i]` is the number of addressable columns on line `i + 1`; the writer needs that
/// table to build the `(line, column)` address space a column-aware `steps.dat` encodes into. It
/// is accepted and ignored on a line-only recording, which is upstream's own contract for
/// `register_path_with_line_lengths`, so a host may pass it unconditionally.
///
/// # Safety
/// `path_ptr` must address `path_len` readable bytes; `line_lengths_ptr` must address
/// `line_lengths_count` readable `u32`s.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_intern_path(
    path_ptr: *const u8,
    path_len: usize,
    line_lengths_ptr: *const u32,
    line_lengths_count: usize,
) -> i32 {
    let path = match unsafe { read_str(path_ptr, path_len) } {
        Ok(s) => s,
        Err(e) => {
            set_error("ct_intern_path: path is not valid UTF-8");
            return e;
        }
    };
    if path.is_empty() {
        set_error("ct_intern_path: the empty path is not a path");
        return CT_ERR_BAD_LENGTH;
    }
    if line_lengths_ptr.is_null() && line_lengths_count != 0 {
        set_error("ct_intern_path: null line-lengths pointer with a non-zero count");
        return CT_ERR_NULL;
    }
    let line_lengths: Vec<u32> = if line_lengths_count == 0 {
        Vec::new()
    } else {
        unsafe { core::slice::from_raw_parts(line_lengths_ptr, line_lengths_count) }.to_vec()
    };
    let s = match session() {
        Some(s) => s,
        None => {
            set_error("ct_intern_path: no writer is open");
            return CT_ERR_NO_SESSION;
        }
    };
    let buf = PathBuf::from(&path);
    if let Some(i) = s.paths.iter().position(|p| *p == buf) {
        return i as i32;
    }
    let _ = CtfsTraceWriter::register_path_with_line_lengths(&mut s.writer, &buf, &line_lengths);
    s.paths.push(buf);
    set_error("");
    (s.paths.len() - 1) as i32
}

/// Paths interned this session.
#[unsafe(no_mangle)]
pub extern "C" fn ct_path_count() -> u32 {
    match session() {
        Some(s) => s.paths.len() as u32,
        None => 0,
    }
}

/// Bytes per position record, read from the module rather than restated by the host — the same
/// discipline `ct_record_size()` exists for.
#[unsafe(no_mangle)]
pub extern "C" fn ct_position_size() -> usize {
    CT_POSITION_SIZE
}

/// Queue `len / CT_POSITION_SIZE` resolved positions for the steps that follow. Returns the count
/// accepted, or a negative status. Every `path_id` is validated HERE rather than at `emit()` time,
/// because a bad id discovered mid-batch would have already written good steps beside it.
///
/// # Safety
/// `ptr` must address `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_positions(ptr: *const u8, len: usize) -> i32 {
    if ptr.is_null() && len != 0 {
        set_error("ct_positions: null buffer");
        return CT_ERR_NULL;
    }
    if len % CT_POSITION_SIZE != 0 {
        set_error("ct_positions: buffer length is not a whole number of position records");
        return CT_ERR_BAD_LENGTH;
    }
    let n = len / CT_POSITION_SIZE;
    let buf = if len == 0 { &[][..] } else { unsafe { core::slice::from_raw_parts(ptr, len) } };
    let s = match session() {
        Some(s) => s,
        None => {
            set_error("ct_positions: no writer is open");
            return CT_ERR_NO_SESSION;
        }
    };
    let path_count = s.paths.len() as u32;
    let mut staged = Vec::with_capacity(n);
    for i in 0..n {
        let r = &buf[i * CT_POSITION_SIZE..(i + 1) * CT_POSITION_SIZE];
        let at = |o: usize| u32::from_le_bytes([r[o], r[o + 1], r[o + 2], r[o + 3]]);
        if at(POS_OFF_RESERVED) != 0 {
            set_error("ct_positions: the reserved word of a position record is not zero");
            return CT_ERR_RESERVED_NOT_ZERO;
        }
        let path_id = at(POS_OFF_PATH_ID);
        let line = at(POS_OFF_LINE);
        // A line of 0 is the host saying "this step has no mapping" and is the ONE case where a
        // path_id is not required to name anything.
        if line != 0 && path_id >= path_count {
            set_error("ct_positions: a position record names a path id this session never interned");
            return CT_ERR_BAD_PATH_ID;
        }
        staged.push(Position { path_id, line, column: at(POS_OFF_COLUMN) });
    }
    for p in staged {
        s.positions.push_back(p);
    }
    set_error("");
    n as i32
}

/// Positions queued and not yet consumed by a step. A host asserts this is zero at the end of a
/// recording; a non-zero value is a host that supplied more positions than steps.
#[unsafe(no_mangle)]
pub extern "C" fn ct_positions_pending() -> u32 {
    match session() {
        Some(s) => s.positions.len() as u32,
        None => 0,
    }
}

/// Steps recorded at a resolved source position. Survives close.
#[unsafe(no_mangle)]
pub extern "C" fn ct_steps_positioned() -> u64 {
    unsafe { STEPS_POSITIONED }
}

/// Steps recorded as `Line(pc)` because no position was available. Survives close.
#[unsafe(no_mangle)]
pub extern "C" fn ct_steps_unpositioned() -> u64 {
    unsafe { STEPS_UNPOSITIONED }
}

/// How many contracts declared rung 1 and then produced an unpositioned step. Survives close.
///
/// **THIS IS THE "NEVER SILENTLY DEGRADES" MEASUREMENT.** It is not the enforcement — `ct-host`
/// throws on it — but it is what makes the enforcement a reading rather than an assumption.
#[unsafe(no_mangle)]
pub extern "C" fn ct_rung_violations() -> u32 {
    unsafe { RUNG_VIOLATIONS }
}

/// The pc of the first step that broke a rung declaration, or `u32::MAX` if none did.
#[unsafe(no_mangle)]
pub extern "C" fn ct_rung_violation_pc() -> u32 {
    unsafe { RUNG_VIOLATION_PC }
}

/// A 32-byte field element as `0x` + 64 lowercase big-endian hex characters. OQ-4's rendering.
fn hex32(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push('0');
    s.push('x');
    for b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0x0f) as usize] as char);
    }
    s
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
    // The rung tallies, read off the session before it is taken apart, for the same reason
    // `dropped` is: a host asks after the close that produced the container.
    let mut violations = 0u32;
    let mut violation_pc = u32::MAX;
    for d in &s.rungs {
        if d.rung == CT_RUNG_SOURCE && d.unpositioned > 0 {
            violations += 1;
            if d.first_violation_pc < violation_pc {
                violation_pc = d.first_violation_pc;
            }
        }
    }
    let positioned = s.positioned;
    let unpositioned = s.unpositioned;
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
        RUNG_VIOLATIONS = violations;
        RUNG_VIOLATION_PC = violation_pc;
        STEPS_POSITIONED = positioned;
        STEPS_UNPOSITIONED = unpositioned;
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
    // M25 SETTLED OQ-5 AND THIS IS WHERE THE ANSWER LANDS.
    //
    // `avm-transpiler` re-keys a contract's `brillig_locations` by AVM pc on the way through
    // (`avm-transpiler/src/transpile.rs:1803`, called at `transpile_contract.rs:116`), so rung 1 —
    // full source-level stepping — is reachable with no upstream change for any contract whose
    // artifact the host holds. The resolution itself is the HOST's, because the artifact and its
    // 86-file `file_map` live there; what arrives here is the answer, on the position side
    // channel, one record per step in step order.
    //
    // A step with a position is recorded at `(path, line, column)` — rung 1. A step without one
    // falls back to `Line(pc)` — rung 3, exactly what M24 shipped — and **the fallback is
    // counted, per contract, against that contract's declared rung**, so a recording cannot
    // quietly stop being what it says it is. That is the milestone's "never silently degrades",
    // and it is a tally rather than a promise.
    let positioned = match s.positions.pop_front() {
        Some(p) if p.line != 0 => {
            let path = s.paths[p.path_id as usize].clone();
            let column = if p.column == 0 { None } else { Some(Line(p.column as i64)) };
            TraceWriter::register_step_with_column(&mut s.writer, &path, Line(p.line as i64), column);
            true
        }
        // A queued record whose line is 0 is the host saying "no mapping for THIS step", which is
        // a different statement from "no positions at all" and must still consume its slot — if it
        // did not, every later step in the batch would take the wrong position.
        Some(_) => {
            let path = s.path.clone();
            TraceWriter::register_step(&mut s.writer, &path, Line(pc as i64));
            false
        }
        None => {
            let path = s.path.clone();
            TraceWriter::register_step(&mut s.writer, &path, Line(pc as i64));
            false
        }
    };
    if positioned {
        s.positioned += 1;
    } else {
        s.unpositioned += 1;
    }
    if let Some(d) = s.rungs.iter_mut().find(|d| d.address[..] == address[..]) {
        if positioned {
            d.positioned += 1;
        } else {
            d.unpositioned += 1;
            if d.rung == CT_RUNG_SOURCE && d.first_violation_pc == u32::MAX {
                d.first_violation_pc = pc;
            }
        }
    }
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
    // OQ-4, SETTLED BY MEASUREMENT AND NOT BY PREFERENCE — see `SOURCE-MAPPING.md` §3.
    //
    // M24 recorded this as `contractAddressLow`, the low 64 bits, and said so. The replacement is
    // the full 254 bits as `0x` + 64 lowercase big-endian hex, in `ValueRecord::String`, under the
    // SAME `(TypeKind::Int, "Field")` type the Noir tracer registers
    // (`noir/tooling/tracer/src/tracer_glue.rs:371`).
    //
    // Three variants can carry 32 bytes and only two of them survive the readers this campaign
    // pins. `ValueRecord::BigInt` — the obvious, full-precision choice — is REFUSED by `ct-print`
    // at `trace_format_nim`'s pinned commit with `cbor: expected byte string (major 2), got major
    // 3`, because `codetracer_trace_types`' `base64` serde module writes `b` as a CBOR text
    // string while the reference Nim reader reads a byte string. Measured over five arms sharing
    // one control, four green and that one red; `test_fr_rendering_matches_noir_tracer` re-runs
    // all five on every run so the day the reader is fixed, this comment goes red rather than
    // stale. `Raw` also survives, and is not used: `Raw` is Noir's escape hatch for values it
    // CANNOT represent (`"()"`, `"fn"`), and an address is not one of those.
    TraceWriter::register_variable_with_full_value(
        &mut s.writer,
        "contractAddress",
        ValueRecord::String { text: hex32(address), type_id: s.field_type_id },
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

    fn position(path_id: u32, line: u32, column: u32) -> [u8; CT_POSITION_SIZE] {
        let mut r = [0u8; CT_POSITION_SIZE];
        r[POS_OFF_PATH_ID..POS_OFF_PATH_ID + 4].copy_from_slice(&path_id.to_le_bytes());
        r[POS_OFF_LINE..POS_OFF_LINE + 4].copy_from_slice(&line.to_le_bytes());
        r[POS_OFF_COLUMN..POS_OFF_COLUMN + 4].copy_from_slice(&column.to_le_bytes());
        r
    }

    unsafe fn intern(path: &str) -> i32 {
        unsafe { ct_intern_path(path.as_ptr(), path.len(), core::ptr::null(), 0) }
    }

    unsafe fn declare(addr: &[u8; ADDRESS_LEN], rung: u32) -> i32 {
        let why = b"test";
        unsafe { ct_declare_rung(addr.as_ptr(), rung, why.as_ptr(), why.len()) }
    }

    /// OQ-4. The rendering is a MEASUREMENT of the bytes, not a re-statement of the constant, so
    /// changing the byte order or dropping a nibble fails here rather than in a reader.
    #[test]
    fn the_contract_address_renders_as_full_width_big_endian_hex() {
        assert_eq!(
            hex32(&[0xffu8; 32]),
            format!("0x{}", "ff".repeat(32)),
            "all-ones must be 64 f's and nothing else"
        );
        let mut a = [0u8; 32];
        a[0] = 0x2f; // most significant
        a[31] = 0x0c; // least significant
        let h = hex32(&a);
        assert_eq!(h.len(), 66, "0x plus 64 hex characters, always, with no leading-zero stripping");
        assert!(h.starts_with("0x2f"), "byte 0 is the MOST significant: {h}");
        assert!(h.ends_with("0c"), "byte 31 is the LEAST significant: {h}");
        // The negative control for the two assertions above: a byte-order flip would satisfy
        // neither, and this is the value it would produce.
        let mut flipped = a;
        flipped.reverse();
        assert_ne!(hex32(&flipped), h, "big-endian and little-endian must not render alike");
    }

    /// The rung-1 path end to end: intern a path, queue a position, ingest a step, and read back
    /// that it was positioned and that nothing violated its declaration.
    #[test]
    fn a_positioned_step_satisfies_a_rung_one_declaration() {
        let _g = serial();
        unsafe { assert_eq!(open(1), CT_OK) };
        assert_eq!(unsafe { intern("/aztec/token.nr") }, 0, "the first interned path is id 0");
        let r = record(1);
        let mut addr = [0u8; ADDRESS_LEN];
        addr.copy_from_slice(&r[OFF_ADDRESS..]);
        assert_eq!(unsafe { declare(&addr, CT_RUNG_SOURCE) }, CT_OK);
        assert_eq!(ct_rung_count(), 1);
        let p = position(0, 41, 9);
        assert_eq!(unsafe { ct_positions(p.as_ptr(), p.len()) }, 1);
        assert_eq!(ct_positions_pending(), 1, "queued and not yet consumed");
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, 1);
        assert_eq!(ct_positions_pending(), 0, "the step consumed it");
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_steps_positioned(), 1);
        assert_eq!(ct_steps_unpositioned(), 0);
        assert_eq!(ct_rung_violations(), 0, "a rung-1 contract whose steps all carry positions");
        assert_eq!(ct_rung_violation_pc(), u32::MAX);
    }

    /// THE CONTROL FOR THE TEST ABOVE, AND THE MILESTONE'S HEADLINE PROPERTY.
    ///
    /// The same declaration with NO position queued must not pass quietly. Without this, "never
    /// silently degrades" would be a sentence in a document rather than a thing that can fail.
    #[test]
    fn a_rung_one_declaration_with_no_position_is_a_violation() {
        let _g = serial();
        unsafe { assert_eq!(open(1), CT_OK) };
        assert_eq!(unsafe { intern("/aztec/token.nr") }, 0);
        let r = record(1);
        let mut addr = [0u8; ADDRESS_LEN];
        addr.copy_from_slice(&r[OFF_ADDRESS..]);
        assert_eq!(unsafe { declare(&addr, CT_RUNG_SOURCE) }, CT_OK);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, 1);
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_steps_positioned(), 0);
        assert_eq!(ct_steps_unpositioned(), 1);
        assert_eq!(ct_rung_violations(), 1, "a rung-1 contract that produced an unpositioned step");
        assert_eq!(ct_rung_violation_pc(), 3, "record(1)'s pc is 1*3, and it is the first offender");
    }

    /// A rung-3 declaration over the SAME unpositioned step is not a violation. Without this arm
    /// the counter above would pass for a contract that simply never declared anything.
    #[test]
    fn a_rung_three_declaration_over_the_same_step_is_not_a_violation() {
        let _g = serial();
        unsafe { assert_eq!(open(0), CT_OK) };
        let r = record(1);
        let mut addr = [0u8; ADDRESS_LEN];
        addr.copy_from_slice(&r[OFF_ADDRESS..]);
        assert_eq!(unsafe { declare(&addr, CT_RUNG_BYTECODE) }, CT_OK);
        assert_eq!(unsafe { ct_ingest(r.as_ptr(), r.len()) }, 1);
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_steps_unpositioned(), 1);
        assert_eq!(ct_rung_violations(), 0);
    }

    /// A queued position whose LINE is zero must still consume its slot. If it did not, one
    /// unmapped step would shift every later position by one and the whole batch would be
    /// mis-attributed — silently, because every step would still have A position.
    #[test]
    fn an_unmapped_position_consumes_its_slot() {
        let _g = serial();
        unsafe { assert_eq!(open(1), CT_OK) };
        assert_eq!(unsafe { intern("/aztec/token.nr") }, 0);
        let mut buf = Vec::new();
        buf.extend_from_slice(&position(0, 0, 0)); // step 0: no mapping
        buf.extend_from_slice(&position(0, 77, 3)); // step 1: mapped
        assert_eq!(unsafe { ct_positions(buf.as_ptr(), buf.len()) }, 2);
        let mut steps = Vec::new();
        steps.extend_from_slice(&record(1));
        steps.extend_from_slice(&record(2));
        assert_eq!(unsafe { ct_ingest(steps.as_ptr(), steps.len()) }, 2);
        assert!(!ct_writer_close().is_null());
        assert_eq!(ct_steps_positioned(), 1, "exactly the one whose line was non-zero");
        assert_eq!(ct_steps_unpositioned(), 1);
        assert_eq!(ct_positions_pending(), 0);
    }

    #[test]
    fn a_bad_position_record_is_refused_before_any_step_sees_it() {
        let _g = serial();
        unsafe { assert_eq!(open(0), CT_OK) };
        // An id nothing has interned.
        let p = position(7, 1, 1);
        assert_eq!(unsafe { ct_positions(p.as_ptr(), p.len()) }, CT_ERR_BAD_PATH_ID);
        assert_eq!(ct_positions_pending(), 0, "a refused batch queues nothing");
        // A short buffer.
        let mut short = p.to_vec();
        short.truncate(CT_POSITION_SIZE - 1);
        assert_eq!(unsafe { ct_positions(short.as_ptr(), short.len()) }, CT_ERR_BAD_LENGTH);
        // A dirty reserved word.
        assert_eq!(unsafe { intern("/aztec/token.nr") }, 0);
        let mut dirty = position(0, 1, 1);
        dirty[POS_OFF_RESERVED] = 1;
        assert_eq!(unsafe { ct_positions(dirty.as_ptr(), dirty.len()) }, CT_ERR_RESERVED_NOT_ZERO);
        // …and a rung outside the ladder.
        let addr = [3u8; ADDRESS_LEN];
        assert_eq!(unsafe { declare(&addr, 0) }, CT_ERR_BAD_RUNG);
        assert_eq!(unsafe { declare(&addr, 4) }, CT_ERR_BAD_RUNG);
        assert_eq!(ct_rung_count(), 0, "neither refusal declared anything");
        assert!(!ct_writer_close().is_null());
    }

    /// The record layout's two published figures, against the offsets. The `const _` assertions
    /// beside them are compile-time; this one is what a reader of the test suite sees.
    #[test]
    fn the_record_layout_figures_are_four_and_sixty() {
        assert_eq!(CT_RECORD_SIZE, 64);
        assert_eq!(CT_RECORD_FIELD_BYTES, 60, "not the 56 the module doc and TRACE-ABI.md said");
        assert_eq!(CT_RECORD_RESERVED_BYTES, 4, "not the 8 the module doc and TRACE-ABI.md said");
        assert_eq!(CT_POSITION_SIZE, 16);
        assert_eq!(ct_record_size(), CT_RECORD_SIZE);
        assert_eq!(ct_position_size(), CT_POSITION_SIZE);
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
