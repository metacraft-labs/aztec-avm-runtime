// OQ-7's evidence, as a program: **one `CtfsTraceWriter` instance, two producers**, one container.
//
// The question M26 has to settle is whether the Rust-side Noir tracer and this TypeScript-side
// runtime can share one writer instance across the language boundary. M24 answered the half it
// could: the module holds ONE session (`ct_writer_open` returns `CT_ERR_ALREADY_OPEN`, −7, for a
// second) and a wasm instance's linear memory is its own, so "share an instance" can only mean ONE
// MODULE INSTANCE WITH TWO PRODUCERS. This probe is the other half, and it is a demonstration
// rather than an argument:
//
//   producer 1 — the REAL Noir tracer. `noir_tracer::trace_circuit` driving the real ACVM through
//                the real debugger, over a `TraceSink` this file implements that forwards into the
//                writer below. Not a mock and not a replay: the Noir source is compiled here by
//                `noirc_driver` and executed here.
//   producer 2 — the AVM half, reproducing `ct-writer/src/lib.rs`'s `emit()` call for call: one
//                `register_step`, then `opcode`, `contextId`, `l2Gas`, `daGas` and OQ-4's
//                `contractAddress` as `0x` + 64 lowercase big-endian hex in `ValueRecord::String`
//                under `(TypeKind::Int, "Field")`.
//
// **WHY THE `TraceSink` IS THE WHOLE POINT.** `noir_tracer` is writer-agnostic — `trace_circuit`'s
// last parameter is `&mut dyn TraceSink`, its `codetracer_trace_writer` dependency is OPTIONAL
// behind a `nim-writer` feature that defaults OFF, and `tooling/tracer_wasm/src/ctfs_sink.rs`
// already wears that trait over a pure-Rust `CtfsTraceWriter`. So nothing about the Noir tracer
// prevents sharing; what decides OQ-7 is whether the two halves resolve the SAME writer crate, and
// that is a fact about branches rather than about code. `verify_oq7_shared_writer_verdict_recorded`
// measures it; this probe measures what happens when they do.
//
// THE THREE OVERRIDDEN `TraceSink` METHODS ARE `ctfs_sink.rs`'s, FOR `ctfs_sink.rs`'s REASONS, and
// they are reproduced rather than reused because this file must be readable as the whole of what a
// shared sink does. `start`, `register_call` and `register_path_with_line_lengths` each differ from
// `AbstractTraceWriter`'s default in a way that would otherwise shift the step count or the path
// table; the module docs of `tooling/tracer_wasm/src/ctfs_sink.rs` state each one.
//
// FRAME NESTING IS THE MILESTONE'S OWN SHAPE AND NOT A CONVENIENCE. The public calls are written
// AFTER `trace_compiled_program` returns and BEFORE `finish_trace`, so they land inside the still
// open `<toplevel>` private frame. That is not an ordering trick: an Aztec transaction's enqueued
// public calls really do run after the private half has finished, and the private half is what
// enqueued them. A private-half step and a public-half step are therefore distinguishable BY FRAME
// — the public ones are inside a `Call` whose function id was interned from the contract's own
// debug function name — and not merely by looking at what a step's variables happen to contain.
//
// Built by `verification/build_oq7_shared_writer_probe.sh`. Arms:
//
//   shared  — one writer, both producers, ONE container.        -> <out>.ct
//   split   — the PRIVATE half alone, carrying an explicit join
//             record that declares a two-half join. The public
//             half of that join is written by the shipped
//             `ct_writer.wasm` module, not here.                -> <out>.private.ct

use std::collections::BTreeMap;
use std::error::Error;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{
    CallRecord, EventLogKind, FullValueRecord, FunctionId, Line, NONE_TYPE_ID, PathId, StepRecord,
    TOP_LEVEL_FUNCTION_ID, TraceLowLevelEvent, TypeId, TypeKind, ValueRecord,
};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use noir_tracer::{TraceOptions, TraceSink};
use noir_tracer_wasm::{compile_source, trace_compiled_program};
use noirc_abi::input_parser::Format;

/// The metadata key an explicit join record is written under, in BOTH halves.
///
/// It is the same shape as M25's `ct.mapping-rung`: a `TraceLogEvent` whose metadata is a fixed
/// key a reader can grep for and whose content carries the fields. `ct.trace-join` exists so that
/// a joined recording is joined because it SAYS so, never because a reader inferred it from two
/// files that happen to sit in one directory or share a timestamp.
const JOIN_EVENT_METADATA: &str = "ct.trace-join";

// ---------------------------------------------------------------------------
// The spec the driver hands over.
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct Spec {
    arm: String,
    out: String,
    recording_id: String,
    /// The join identity. The same string goes into both halves on the `split` arm.
    join_id: String,
    noir: NoirSpec,
    public_calls: Vec<PublicCallSpec>,
}

#[derive(serde::Deserialize)]
struct NoirSpec {
    files: BTreeMap<String, String>,
    entry_point: String,
    inputs: String,
    package: String,
}

#[derive(serde::Deserialize)]
struct PublicCallSpec {
    /// Upstream's own debug function name, `<ArtifactName>.<fn>`, produced by
    /// `SimpleContractDataSource.getDebugFunctionName` on the TypeScript side.
    name: String,
    /// The 32-byte contract address, `0x` + 64 hex.
    contract_address: String,
    /// The source path a public-half step is recorded against.
    path: String,
    line: u32,
    steps: Vec<StepSpec>,
}

#[derive(serde::Deserialize)]
struct StepSpec {
    context_id: u32,
    pc: u32,
    opcode: u32,
    l2_gas: u64,
    da_gas: u64,
}

// ---------------------------------------------------------------------------
// The shared sink: `noir_tracer`'s trait over a writer this file does not own.
//
// `&mut CtfsTraceWriter` and not `CtfsTraceWriter`, because that IS the deliverable — the writer
// belongs to the session, and the Noir producer borrows it for the duration of its half. A sink
// that owned its writer could not be a second producer into somebody else's.
// ---------------------------------------------------------------------------

struct SharedSink<'a> {
    writer: &'a mut CtfsTraceWriter,
}

impl TraceSink for SharedSink<'_> {
    fn begin_writing_trace_events(&mut self, path: &Path) -> Result<(), Box<dyn Error>> {
        TraceWriter::begin_writing_trace_events(self.writer, path)
    }

    fn finish_writing_trace_events(&mut self) -> Result<(), Box<dyn Error>> {
        TraceWriter::finish_writing_trace_events(self.writer)
    }

    fn close(&mut self) -> Result<(), Box<dyn Error>> {
        TraceWriter::close(self.writer)
    }

    fn set_workdir(&mut self, workdir: &Path) {
        TraceWriter::set_workdir(self.writer, workdir);
    }

    /// `ctfs_sink.rs`'s override: `AbstractTraceWriter::start` emits no entry `Step`, and the
    /// recording must open with one or it is a step short.
    fn start(&mut self, path: &Path, line: Line) {
        let function_id = TraceWriter::ensure_function_id(self.writer, "<toplevel>", path, line);
        debug_assert_eq!(function_id, TOP_LEVEL_FUNCTION_ID);
        let path_id = TraceWriter::ensure_path_id(self.writer, path);
        TraceWriter::add_event(
            self.writer,
            TraceLowLevelEvent::Step(StepRecord { path_id, line }),
        );
        TraceWriter::add_event(
            self.writer,
            TraceLowLevelEvent::Call(CallRecord { function_id, args: vec![] }),
        );
        let none_type = TraceWriter::ensure_type_id(self.writer, TypeKind::None, "None");
        debug_assert_eq!(none_type, NONE_TYPE_ID);
    }

    fn enable_column_aware_steps(&mut self) {
        TraceWriter::enable_column_aware_steps(self.writer);
    }

    fn enable_column_breakpoints_support(&mut self) {
        TraceWriter::enable_column_breakpoints_support(self.writer);
    }

    fn enable_column_motions_support(&mut self) {
        TraceWriter::enable_column_motions_support(self.writer);
    }

    /// `ctfs_sink.rs`'s override: the trait default registers an unseen path twice.
    fn register_path_with_line_lengths(
        &mut self,
        path: &Path,
        _line_lengths: &[u32],
    ) -> Result<PathId, Box<dyn Error>> {
        Ok(TraceWriter::ensure_path_id(self.writer, path))
    }

    fn ensure_function_id(&mut self, function_name: &str, path: &Path, line: Line) -> FunctionId {
        TraceWriter::ensure_function_id(self.writer, function_name, path, line)
    }

    fn ensure_type_id(&mut self, kind: TypeKind, lang_type: &str) -> TypeId {
        TraceWriter::ensure_type_id(self.writer, kind, lang_type)
    }

    fn register_step_with_column(&mut self, path: &Path, line: Line, column: Option<Line>) {
        match column {
            Some(c) => TraceWriter::register_step_with_column(self.writer, path, line, Some(c)),
            None => TraceWriter::register_step(self.writer, path, line),
        }
    }

    fn register_variable_with_full_value(&mut self, name: &str, value: ValueRecord) {
        TraceWriter::register_variable_with_full_value(self.writer, name, value);
    }

    fn arg(&mut self, name: &str, value: ValueRecord) -> FullValueRecord {
        TraceWriter::arg(self.writer, name, value)
    }

    /// `ctfs_sink.rs`'s override: the default synthesizes a callee `Step` the recorder already emitted.
    fn register_call(&mut self, function_id: FunctionId, args: Vec<FullValueRecord>) {
        if function_id != TOP_LEVEL_FUNCTION_ID {
            for arg in &args {
                TraceWriter::add_event(self.writer, TraceLowLevelEvent::Value(arg.clone()));
            }
        }
        TraceWriter::add_event(
            self.writer,
            TraceLowLevelEvent::Call(CallRecord { function_id, args }),
        );
    }

    fn register_return(&mut self, return_value: ValueRecord) {
        TraceWriter::register_return(self.writer, return_value);
    }

    fn register_special_event(&mut self, kind: EventLogKind, metadata: &str, content: &str) {
        TraceWriter::register_special_event(self.writer, kind, metadata, content);
    }
}

// ---------------------------------------------------------------------------
// Producer 2 — the AVM half, reproducing `ct-writer/src/lib.rs`'s `emit()`.
// ---------------------------------------------------------------------------

fn hex32(b: &[u8]) -> String {
    let mut s = String::with_capacity(66);
    s.push_str("0x");
    for x in b {
        s.push_str(&format!("{x:02x}"));
    }
    s
}

fn parse_hex32(s: &str) -> [u8; 32] {
    let body = s.strip_prefix("0x").unwrap_or(s);
    assert_eq!(body.len(), 64, "a contract address is 0x + 64 hex, got {s}");
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&body[i * 2..i * 2 + 2], 16).expect("hex");
    }
    out
}

/// One AVM step, written exactly as the shipped module writes it.
///
/// The five variable names and the OQ-4 rendering are `emit()`'s, so a step in this container and a
/// step in a container the wasm module produced are the same five records under the same five names
/// with the same type id. `test_private_public_frame_nesting` compares them.
fn emit_avm_step(
    w: &mut CtfsTraceWriter,
    path: &Path,
    type_id: TypeId,
    step: &StepSpec,
    address: &[u8; 32],
) {
    TraceWriter::register_step(w, path, Line(step.pc as i64));
    TraceWriter::register_variable_with_full_value(
        w,
        "opcode",
        ValueRecord::Int { i: step.opcode as i64, type_id },
    );
    TraceWriter::register_variable_with_full_value(
        w,
        "contextId",
        ValueRecord::Int { i: step.context_id as i64, type_id },
    );
    TraceWriter::register_variable_with_full_value(
        w,
        "l2Gas",
        ValueRecord::Int { i: step.l2_gas as i64, type_id },
    );
    TraceWriter::register_variable_with_full_value(
        w,
        "daGas",
        ValueRecord::Int { i: step.da_gas as i64, type_id },
    );
    TraceWriter::register_variable_with_full_value(
        w,
        "contractAddress",
        ValueRecord::String { text: hex32(address), type_id },
    );
}

/// Write the public half's frames into `sink`'s writer, nested where the writer currently is.
///
/// Returns the number of steps written, so the caller asserts a count it did not choose.
fn write_public_half(sink: &mut SharedSink<'_>, calls: &[PublicCallSpec]) -> u64 {
    let field_type = TraceSink::ensure_type_id(sink, TypeKind::Int, "Field");
    let mut steps = 0u64;
    for call in calls {
        let path = PathBuf::from(&call.path);
        // The frame's NAME is upstream's own debug function name, forwarded from the TypeScript
        // side rather than invented here. `ContractDBInterface::get_debug_function_name` and
        // `SimpleContractDataSource.getDebugFunctionName` both spell it `<Artifact>.<fn>`.
        let fid = TraceSink::ensure_function_id(sink, &call.name, &path, Line(call.line as i64));
        let address_arg = TraceSink::arg(
            sink,
            "contractAddress",
            ValueRecord::String { text: call.contract_address.clone(), type_id: field_type },
        );
        TraceSink::register_call(sink, fid, vec![address_arg]);
        let address = parse_hex32(&call.contract_address);
        for step in &call.steps {
            emit_avm_step(sink.writer, &path, field_type, step, &address);
            steps += 1;
        }
        TraceSink::register_return(sink, ValueRecord::None { type_id: NONE_TYPE_ID });
    }
    steps
}

/// The explicit join record. Written into every half of a joined recording.
fn write_join_record(sink: &mut SharedSink<'_>, arm: &str, join_id: &str, half: &str, halves: u32) {
    let content = format!(
        "join={join_id} half={half} halves={halves} arm={arm} \
         reason=recorded-by-the-producer-not-inferred-by-a-reader"
    );
    TraceSink::register_special_event(
        sink,
        EventLogKind::TraceLogEvent,
        JOIN_EVENT_METADATA,
        &content,
    );
}

fn new_writer(program: &str, recording_id: &str) -> CtfsTraceWriter {
    let mut w = CtfsTraceWriter::new_in_memory(program, &[]);
    w.set_recording_id(recording_id.to_string());
    w
}

fn trace_noir_half(sink: &mut SharedSink<'_>, noir: &NoirSpec) -> Result<(), String> {
    let program = compile_source(&noir.files, &noir.entry_point).map_err(|e| e.to_string())?;
    let input_map =
        Format::Toml.parse(&noir.inputs, &program.abi).map_err(|e| e.to_string())?;
    let options = TraceOptions::default();
    noir_tracer::tracer_glue::begin_trace(sink, "", &noir.package, None);
    trace_compiled_program(&program, &input_map, &options, sink).map_err(|e| e.to_string())?;
    Ok(())
}

fn main() {
    let spec_path = std::env::args().nth(1).expect("usage: oq7probe <spec.json>");
    let spec: Spec = serde_json::from_str(&std::fs::read_to_string(&spec_path).expect("spec"))
        .expect("spec json");

    match spec.arm.as_str() {
        // ------------------------------------------------------------------
        // ONE WRITER, TWO PRODUCERS, ONE CONTAINER.
        // ------------------------------------------------------------------
        "shared" => {
            let mut writer = new_writer(&spec.noir.package, &spec.recording_id);
            let mut sink = SharedSink { writer: &mut writer };
            trace_noir_half(&mut sink, &spec.noir).expect("the Noir half");
            write_join_record(&mut sink, "shared", &spec.join_id, "both", 1);
            let public_steps = write_public_half(&mut sink, &spec.public_calls);
            noir_tracer::tracer_glue::finish_trace(&mut sink).expect("finish");
            let bytes = writer.take_container_bytes().expect("no container");
            let out = format!("{}.ct", spec.out);
            std::fs::write(&out, &bytes).expect("write");
            println!("ARM\tshared");
            println!("CONTAINERS\t1");
            println!("PUBLIC_STEPS\t{public_steps}");
            println!("BYTES\t{}\t{}", out, bytes.len());
            println!("JOIN_ID\t{}", spec.join_id);
        }
        // ------------------------------------------------------------------
        // THE PRIVATE HALF ALONE, CARRYING AN EXPLICIT JOIN RECORD.
        //
        // The fallback's other half is NOT written here: it is written by the shipped
        // `ct_writer.wasm` module through `ct_log_event` and `ct_ingest`, which is the point of
        // the fallback being a deliverable rather than a probe. If this arm wrote both halves,
        // M26 would have demonstrated that a probe can produce a joined recording and left open
        // whether the runtime can.
        //
        // `halves=2` is declared HERE, in the half that is written first, and the module declares
        // the same 2 in the other. A reader handed only one of them can tell it is incomplete,
        // which is the property a filename-based join can never have.
        // ------------------------------------------------------------------
        "split" => {
            let mut writer = new_writer(&spec.noir.package, &spec.recording_id);
            let mut sink = SharedSink { writer: &mut writer };
            trace_noir_half(&mut sink, &spec.noir).expect("the Noir half");
            write_join_record(&mut sink, "split", &spec.join_id, "private", 2);
            noir_tracer::tracer_glue::finish_trace(&mut sink).expect("finish private");
            let bytes = writer.take_container_bytes().expect("no private container");
            let out = format!("{}.private.ct", spec.out);
            std::fs::write(&out, &bytes).expect("write private");
            println!("ARM\tsplit");
            println!("CONTAINERS\t1");
            println!("PUBLIC_STEPS\t0");
            println!("BYTES\t{}\t{}", out, bytes.len());
            println!("JOIN_ID\t{}", spec.join_id);
        }
        other => panic!("unknown arm {other}"),
    }
}
