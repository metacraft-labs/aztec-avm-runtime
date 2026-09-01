// M40's evidence, as a wasm module: **an Aztec private TRANSACTION stepped by the Noir tracer,
// inside a browser**, with the oracle answers supplied by M35's own handler and nothing fabricated.
//
// ---------------------------------------------------------------------------------------------
// WHAT THIS IS, AND WHY IT IS NOT `m38_private_trace_probe.rs` WITH A DIFFERENT TARGET
// ---------------------------------------------------------------------------------------------
//
// M38's probe is a NATIVE binary. It reads its artifacts off disk with `std::fs`, and it writes its
// container with `NimWriterSink` over `create_trace_writer(…, Ctfs)` — a Nim static library and
// `zstd-sys`, neither of which can target wasm. Both of those are the reason M38 and M39 step a
// private half on a developer's machine and not in the page that executed it.
//
// This module is the same idea with both of those removed:
//
//   * **No filesystem.** Every artifact arrives INSIDE the request, as JSON, because a page has
//     already fetched them and a wasm module has no disk to read them from.
//   * **No writer.** The sink is `noir_tracer_wasm::MemorySink`, which accumulates the CodeTracer
//     low-level event stream in memory; the CONTAINER is written by the page's own
//     `ct_writer.wasm`, which is DD-7's Path A and is already there. So the Noir tracer links no
//     writer at all on this path and `JOIN-SHAPE.md` §2's facts 6 and 7 are untouched — this is a
//     different answer to the same need rather than the answer OQ-7 ruled out.
//
// It is deliberately a SECOND implementation of the tape executor rather than a shared one. M38's
// probe is native, links the Nim writer and is read by two milestones' checks; moving its executor
// into a library would move their figures. What ties the two together is not a shared file, it is
// a DIFFERENTIAL: `e2e_transaction_steps_in_the_browser` compares this module's step stream against
// the native probe's over the SAME transaction and the same tape, position for position and column
// for column. Two independent implementations agreeing is a stronger statement than one
// implementation used twice, and it is the only one that can catch a defect in either.
//
// ---------------------------------------------------------------------------------------------
// THE REFUSALS ARE M38's, BY NAME, AND FOR ITS REASONS
// ---------------------------------------------------------------------------------------------
//
//   * the tape has run out (the frame is asking for more than was recorded);
//   * the tape's next entry is a DIFFERENT oracle (the replay has diverged from the recording);
//   * it is the right oracle but the INPUTS differ (same call, different question);
//   * the call is past the recording's own SERVED prefix — the tape carries the call that stopped
//     the frame too, and that one was never answered.
//
// The last one's discriminator comes from the recording (`servedCalls`) rather than from the tape,
// because a refused call and a genuinely void oracle both appear with empty `outputs`.
//
// ---------------------------------------------------------------------------------------------
// THE OUTPUT IS AN OP LIST, NOT A CONTAINER
// ---------------------------------------------------------------------------------------------
//
// A `TraceLowLevelEvent` stream is not something `ct_writer.wasm` can be handed: its ABI is
// `ct_intern_path` / `ct_source_step` / `ct_call` / `ct_return` / `ct_log_event`. So the module
// emits exactly those calls as data, in order, and the host replays them. Deriving the op list HERE
// rather than in TypeScript keeps the decision about what a `Call` costs — which `Function` record
// it names, which path and line it opens at, which argument it carries — beside the sink that
// produced the events, and leaves the host a loop with no judgement in it.
//
// Built for `wasm32-unknown-unknown` by `verification/build_m40_private_trace_wasm.sh`.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use acvm::acir::brillig::{ForeignCallParam, ForeignCallResult};
use acvm::acir::circuit::Program;
use acvm::acir::native_types::{Witness, WitnessMap};
use acvm::pwg::ForeignCallWaitInfo;
use acvm::{AcirField, FieldElement};
use base64::Engine;
use bn254_blackbox_solver::Bn254BlackBoxSolver;
use codetracer_trace_types::{
    EventLogKind, Line, NONE_TYPE_ID, TraceLowLevelEvent, TypeKind, ValueRecord,
};
use nargo::foreign_calls::{ForeignCallError, ForeignCallExecutor};
use noir_debugger::foreign_calls::DefaultDebugForeignCallExecutor;
use noir_tracer::tracer_glue::{begin_trace, finish_trace};
use noir_tracer::{TraceForeignCallExecutor, TraceOptions, TraceSink, trace_circuit_with_executor};
use noir_tracer_wasm::{MemorySink, MemoryTrace};
use noirc_artifacts::debug::{DebugArtifact, DebugFile, ProgramDebugInfo, StackFrame};

// These exist only so their wasm-enabling features are on for the whole build graph, exactly as
// `tooling/tracer_wasm/src/lib.rs` does it. `uuid` refuses to compile on wasm32 without an explicit
// source of randomness, and `codetracer_trace_types` mints a UUIDv7 `recording_id`.
#[cfg(target_arch = "wasm32")]
use getrandom as _;
#[cfg(target_arch = "wasm32")]
use getrandom_v2 as _;
#[cfg(target_arch = "wasm32")]
use getrandom_v4 as _;
#[cfg(target_arch = "wasm32")]
use uuid as _;

// ---------------------------------------------------------------------------
// The request.
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct Request {
    /// The container's program name.
    #[serde(default)]
    program: String,
    /// Every artifact any frame names, keyed by a name the frames refer to.
    ///
    /// A map rather than a field per frame: this transaction's two frames are the SAME contract
    /// calling itself, and a 2.2 MB artifact crossing linear memory twice would be two copies of
    /// one fact.
    artifacts: BTreeMap<String, serde_json::Value>,
    /// The transaction's frames, in pre-order.
    frames: Vec<FrameRequest>,
    /// The join this container is one half of. Absent means no record; see `JOIN-SHAPE.md` §4.
    #[serde(default)]
    join: Option<JoinSpec>,
}

#[derive(serde::Deserialize)]
struct FrameRequest {
    /// A key into [`Request::artifacts`].
    artifact: String,
    function: String,
    /// 0 for the transaction's entry frame; one more per nesting level.
    #[serde(default)]
    depth: usize,
    /// Written as the frame's ONE call argument — M26's rule: a frame must be attributable
    /// without stepping into it.
    #[serde(default, rename = "contractAddress")]
    contract_address: String,
    /// The wire values of every oracle call this frame's handler saw, in order.
    tape: Vec<TapeEntry>,
    /// How many of them the handler ANSWERED. See the refusal it decides.
    #[serde(rename = "servedCalls")]
    served_calls: usize,
    /// `[witnessIndex, hexValue]` pairs — the frame's initial witness.
    #[serde(rename = "initialWitnessEntries")]
    initial_witness_entries: Vec<(u32, String)>,
}

#[derive(Clone, serde::Deserialize)]
struct JoinSpec {
    id: String,
    half: String,
    halves: u32,
    arm: String,
}

#[derive(Clone, serde::Deserialize)]
struct TapeEntry {
    seq: usize,
    oracle: String,
    inputs: Vec<Vec<String>>,
    outputs: Vec<Vec<String>>,
    /// Whether each output slot crossed the wire as a `Single` field or as an `Array` of fields.
    ///
    /// A ONE-ELEMENT ARRAY AND A SINGLE FIELD ARE INDISTINGUISHABLE ON A NORMALISED TAPE, and the
    /// ACVM tells them apart: `aztec_prv_getHashPreimage` returns `[Field; 1]` for a function
    /// returning one field, and replaying that as a `Single` hands a Brillig heap array of width 1
    /// a scalar. M39 paid 167 opcodes and a bare `Failed assertion` for that.
    #[serde(default, rename = "outputKinds")]
    output_kinds: Vec<String>,
}

// ---------------------------------------------------------------------------
// The executor.
// ---------------------------------------------------------------------------

#[derive(serde::Serialize)]
struct Answered {
    seq: usize,
    oracle: String,
    outcome: &'static str,
    reason: String,
}

struct TapeExecutor<D> {
    inner: D,
    tape: Vec<TapeEntry>,
    served_calls: usize,
    cursor: usize,
    ledger: Vec<Answered>,
    refused: Vec<String>,
}

/// Everything an Aztec contract's foreign calls are named. Derived from the shape upstream's own
/// `parseOracleName` requires (`^aztec_(\w+?)_(.+)$`) rather than from a list of the sixty-eight.
fn is_aztec_oracle(name: &str) -> bool {
    name.strip_prefix("aztec_")
        .and_then(|rest| rest.split_once('_'))
        .is_some_and(|(scope, method)| !scope.is_empty() && !method.is_empty())
}

fn field_of(hex: &str, what: &str) -> Result<FieldElement, String> {
    let trimmed = hex.strip_prefix("0x").unwrap_or(hex);
    FieldElement::try_from_str(&format!("0x{trimmed}"))
        .ok_or_else(|| format!("{what}: `{hex}` is not a field element"))
}

fn hex_of(f: &FieldElement) -> String {
    format!("0x{}", f.to_hex())
}

fn render_inputs(inputs: &[ForeignCallParam<FieldElement>]) -> Vec<Vec<String>> {
    inputs
        .iter()
        .map(|p| match p {
            ForeignCallParam::Single(f) => vec![hex_of(f)],
            ForeignCallParam::Array(a) => a.iter().map(hex_of).collect(),
        })
        .collect()
}

/// Both sides of the input comparison go through this, so a leading-zero or case difference in the
/// recording cannot read as a divergence.
fn normalise(slots: &[Vec<String>]) -> Vec<Vec<String>> {
    slots
        .iter()
        .map(|slot| {
            slot.iter()
                .map(|h| match field_of(h, "tape input") {
                    Ok(f) => hex_of(&f),
                    Err(_) => h.clone(),
                })
                .collect()
        })
        .collect()
}

impl<D> TapeExecutor<D> {
    fn refuse(&mut self, oracle: &str, reason: String) -> ForeignCallError {
        self.ledger.push(Answered {
            seq: self.cursor,
            oracle: oracle.to_string(),
            outcome: "refused",
            reason: reason.clone(),
        });
        self.refused.push(oracle.to_string());
        // `NoHandler` is the ACVM's own "nobody answered this" and it carries the text into the
        // execution error. A handler that returned an empty result would let the circuit continue
        // over a value nobody produced.
        ForeignCallError::NoHandler(format!("{oracle}: {reason}"))
    }
}

impl<D: TraceForeignCallExecutor> ForeignCallExecutor<FieldElement> for TapeExecutor<D> {
    fn execute(
        &mut self,
        call: &ForeignCallWaitInfo<FieldElement>,
    ) -> Result<ForeignCallResult<FieldElement>, ForeignCallError> {
        let name = call.function.clone();
        if !is_aztec_oracle(&name) {
            // The recorder's own traffic (`__debug_*`, `print`) and nothing else. Delegating an
            // Aztec oracle here would not be a fallback: the default's base layer is
            // `layers::Empty`, which answers everything with an empty result.
            return self.inner.execute(call);
        }

        let Some(entry) = self.tape.get(self.cursor).cloned() else {
            let (len, at) = (self.tape.len(), self.cursor + 1);
            return Err(self.refuse(
                &name,
                format!(
                    "the recorded tape holds {len} call(s) and this is call {at}; \
                     the frame is asking for more than the handler answered"
                ),
            ));
        };

        if entry.oracle != name {
            let (seq, other) = (entry.seq, entry.oracle.clone());
            return Err(self.refuse(
                &name,
                format!(
                    "the tape's call {seq} is `{other}`; the replay has diverged from the recording"
                ),
            ));
        }

        let observed = render_inputs(&call.inputs);
        let recorded = normalise(&entry.inputs);
        if observed != recorded {
            let seq = entry.seq;
            return Err(self.refuse(
                &name,
                format!(
                    "the tape's call {seq} asked {recorded:?} and this frame asks {observed:?}"
                ),
            ));
        }

        if entry.seq >= self.served_calls {
            let (served, seq) = (self.served_calls, entry.seq);
            return Err(self.refuse(
                &name,
                format!(
                    "the recording answered {served} call(s) and this is its call {seq}: \
                     the handler did not answer this one"
                ),
            ));
        }

        let mut values: Vec<ForeignCallParam<FieldElement>> = Vec::new();
        let mut guessed_kinds = 0usize;
        for (slot_index, slot) in entry.outputs.iter().enumerate() {
            let mut fields = Vec::with_capacity(slot.len());
            for hex in slot {
                match field_of(hex, &format!("{name} output slot {slot_index}")) {
                    Ok(f) => fields.push(f),
                    Err(reason) => return Err(self.refuse(&name, reason)),
                }
            }
            let recorded_kind = entry.output_kinds.get(slot_index).map(String::as_str);
            if recorded_kind.is_none() {
                guessed_kinds += 1;
            }
            values.push(match recorded_kind {
                Some("single") => ForeignCallParam::Single(fields[0]),
                Some("array") => ForeignCallParam::Array(fields),
                Some(other) => {
                    let other = other.to_string();
                    return Err(self.refuse(
                        &name,
                        format!("output slot {slot_index} declares an unknown wire kind `{other}`"),
                    ));
                }
                None if fields.len() == 1 => ForeignCallParam::Single(fields[0]),
                None => ForeignCallParam::Array(fields),
            });
        }

        self.ledger.push(Answered {
            seq: self.cursor,
            oracle: name.clone(),
            outcome: "replayed",
            reason: if guessed_kinds == 0 {
                format!("{} output slot(s) from the tape", entry.outputs.len())
            } else {
                format!(
                    "{} output slot(s) from the tape, {guessed_kinds} of them with the wire kind GUESSED from the slot length",
                    entry.outputs.len()
                )
            },
        });
        self.cursor += 1;
        Ok(ForeignCallResult { values })
    }
}

impl<D: TraceForeignCallExecutor> TraceForeignCallExecutor for TapeExecutor<D> {
    fn get_variables(&self) -> Vec<StackFrame<'_, FieldElement>> {
        self.inner.get_variables()
    }
    fn current_stack_frame(&self) -> Option<StackFrame<'_, FieldElement>> {
        self.inner.current_stack_frame()
    }
    fn restart(&mut self, artifact: &DebugArtifact) {
        self.inner.restart(artifact);
    }
}

// ---------------------------------------------------------------------------
// Loading a frame's circuit out of an artifact that arrived as JSON.
// ---------------------------------------------------------------------------

struct Loaded {
    program: Program<FieldElement>,
    debug: DebugArtifact,
    error_types: BTreeMap<acvm::acir::circuit::ErrorSelector, noirc_abi::AbiErrorType>,
    acir_opcodes: usize,
    brillig_functions: usize,
    bytecode_bytes: usize,
    file_map_entries: usize,
}

fn load(doc: &serde_json::Value, function: &str) -> Result<Loaded, String> {
    let f = doc["functions"]
        .as_array()
        .ok_or("the artifact has no `functions` array")?
        .iter()
        .find(|f| f["name"] == function)
        .ok_or_else(|| format!("the artifact declares no function `{function}`"))?;

    let b64 = f["bytecode"]
        .as_str()
        .ok_or("the function has no `bytecode`")?;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|e| format!("bytecode base64: {e}"))?;
    let program = Program::<FieldElement>::deserialize_program(&raw)
        .map_err(|e| format!("the ACIR did not deserialise: {e:?}"))?;

    let ds = f["debug_symbols"]
        .as_str()
        .ok_or("the function has no `debug_symbols`")?;
    let dsraw = base64::engine::general_purpose::STANDARD
        .decode(ds)
        .map_err(|e| format!("debug_symbols base64: {e}"))?;
    let mut inflated = Vec::new();
    flate2::read::DeflateDecoder::new(&dsraw[..])
        .read_to_end(&mut inflated)
        .map_err(|e| format!("debug_symbols inflate: {e}"))?;
    let program_debug: ProgramDebugInfo = serde_json::from_slice(&inflated)
        .map_err(|e| format!("debug_symbols is not a ProgramDebugInfo: {e}"))?;

    // The artifact's `file_map` is keyed by a STRING in JSON and by `FileId` in the struct, and
    // `FileId`'s field is private with `FileId::dummy()` — which always answers 0 — as its only
    // public constructor. Building the map by hand would collapse seventy-eight files onto one id
    // and every step would resolve to whichever file happened to be last, so each key goes through
    // serde and keeps the artifact's own numbering.
    let mut file_map: BTreeMap<fm::FileId, DebugFile> = BTreeMap::new();
    for (key, value) in doc["file_map"]
        .as_object()
        .ok_or("the artifact has no `file_map`")?
    {
        let id: fm::FileId = serde_json::from_str(key)
            .map_err(|e| format!("file_map key `{key}` is not a file id: {e}"))?;
        let file: DebugFile =
            serde_json::from_value(value.clone()).map_err(|e| format!("file_map[{key}]: {e}"))?;
        file_map.insert(id, file);
    }

    // THE ABI's ERROR SELECTORS, so an assertion renders as the sentence the contract wrote. An
    // empty map makes every assertion read ` Failed assertion` over an artifact that declares its
    // messages by name — a diagnostic that names nothing is the expensive kind.
    let mut error_types: BTreeMap<acvm::acir::circuit::ErrorSelector, noirc_abi::AbiErrorType> =
        BTreeMap::new();
    if let Some(map) = f["abi"]["error_types"].as_object() {
        for (key, value) in map {
            let selector: acvm::acir::circuit::ErrorSelector = key
                .parse::<u64>()
                .map(acvm::acir::circuit::ErrorSelector::new)
                .map_err(|e| format!("error_types key `{key}` is not a selector: {e}"))?;
            let kind: noirc_abi::AbiErrorType = serde_json::from_value(value.clone())
                .map_err(|e| format!("error_types[{key}]: {e}"))?;
            error_types.insert(selector, kind);
        }
    }

    let acir_opcodes = program.functions.iter().map(|c| c.opcodes.len()).sum();
    Ok(Loaded {
        error_types,
        acir_opcodes,
        brillig_functions: program.unconstrained_functions.len(),
        bytecode_bytes: raw.len(),
        file_map_entries: file_map.len(),
        debug: DebugArtifact {
            debug_symbols: program_debug.debug_infos,
            file_map,
        },
        program,
    })
}

/// Where a nested frame's `Call` is anchored: the callee's own contract source, and line 1.
///
/// A `Call` needs a `(path, line)` BEFORE the callee has stepped, so the position cannot be the
/// callee's first step. It is the shortest path ending in `/src/main.nr` — where an `#[aztec]`
/// contract is declared — with the lexicographically first entry as the fallback, and the chosen
/// path is REPORTED per frame so a container whose frames all opened in the same wrong file is
/// visible rather than plausible. Identical to `m38_private_trace_probe.rs`'s `declaration_site`.
fn declaration_site(loaded: &Loaded) -> (String, i64) {
    let mut candidates: Vec<String> = loaded
        .debug
        .file_map
        .values()
        .map(|f| f.path.display().to_string())
        .collect();
    candidates.sort();
    let main = candidates
        .iter()
        .filter(|p| p.ends_with("/src/main.nr"))
        .min_by_key(|p| p.len())
        .cloned();
    let path = main
        .or_else(|| candidates.first().cloned())
        .unwrap_or_else(|| "<no source>".into());
    (path, 1)
}

/// The `ct.trace-join` record's metadata key, spelled as
/// `orchestration/src/trace_join.ts`'s `JOIN_EVENT_METADATA` spells it.
const JOIN_EVENT_METADATA: &str = "ct.trace-join";

/// The explicit join record. **THE BYTES ARE THE GRAMMAR**: field order, spacing and the constant
/// `reason` are compared byte for byte against what `trace_join.ts` renders, so this is deliberately
/// the same `format!` as `m38_private_trace_probe.rs` and `oq7_shared_writer_probe.rs` rather than
/// a fourth spelling.
fn write_join_record(sink: &mut dyn TraceSink, join: &JoinSpec) {
    let content = format!(
        "join={} half={} halves={} arm={} \
         reason=recorded-by-the-producer-not-inferred-by-a-reader",
        join.id, join.half, join.halves, join.arm
    );
    TraceSink::register_special_event(
        sink,
        EventLogKind::TraceLogEvent,
        JOIN_EVENT_METADATA,
        &content,
    );
}

// ---------------------------------------------------------------------------
// The op list the host replays into `ct_writer.wasm`.
// ---------------------------------------------------------------------------

#[derive(serde::Serialize)]
#[serde(tag = "k")]
enum Op {
    /// Intern a source path with its per-line addressable column counts (`paths.dat` Layout A).
    #[serde(rename = "path")]
    PathOp {
        path: String,
        #[serde(rename = "lineLengths")]
        line_lengths: Vec<u32>,
    },
    /// One source step. `column` is `0` for a step that carries none, which is what
    /// `ct_source_step` reads as "line only".
    #[serde(rename = "step")]
    Step { path: usize, line: i64, column: i64 },
    /// Open a frame. `address` is the frame's one call argument.
    #[serde(rename = "call")]
    Call {
        name: String,
        path: usize,
        line: i64,
        address: String,
    },
    #[serde(rename = "ret")]
    Return,
    #[serde(rename = "event")]
    Event { metadata: String, content: String },
}

/// Turn a `MemoryTrace` into the op list, and count what a check reads.
///
/// **THE HOST'S WRITER OPENS ITS OWN TOPLEVEL**, so the sink's `<toplevel>` `Call` is dropped here
/// rather than replayed — `ct_writer_open` already emits one. The entry STEPS are kept: they are
/// real positions (`TraceSink::start` emits one per traced circuit, at the frame's first file), and
/// dropping them would make the browser container's step count disagree with the native one for a
/// reason that has nothing to do with either.
fn ops_of(
    trace: &MemoryTrace,
    functions: &[(String, usize, i64)],
    call_args: &[String],
) -> (Vec<Op>, usize, usize, usize, usize) {
    let mut ops = Vec::new();
    let mut next_path = 0usize;
    let mut step_index = 0usize;
    let mut steps = 0usize;
    let mut with_column = 0usize;
    let mut calls = 0usize;
    let mut returns = 0usize;
    let mut call_index = 0usize;
    let mut function_index = 0usize;
    for event in &trace.events {
        match event {
            TraceLowLevelEvent::Path(p) => {
                let line_lengths = trace
                    .line_lengths
                    .get(next_path)
                    .cloned()
                    .unwrap_or_default();
                next_path += 1;
                ops.push(Op::PathOp {
                    path: p.display().to_string(),
                    line_lengths,
                });
            }
            TraceLowLevelEvent::Step(s) => {
                let column = trace
                    .step_columns
                    .get(step_index)
                    .copied()
                    .flatten()
                    .map(|c| c.0)
                    .unwrap_or(0);
                step_index += 1;
                steps += 1;
                if column != 0 {
                    with_column += 1;
                }
                ops.push(Op::Step {
                    path: s.path_id.0,
                    line: s.line.0,
                    column,
                });
            }
            TraceLowLevelEvent::Function(_) => {
                function_index += 1;
            }
            TraceLowLevelEvent::Call(c) => {
                // Function id 0 is `<toplevel>`; the host's writer opens that one itself.
                if c.function_id.0 == 0 {
                    continue;
                }
                let (name, path, line) = functions
                    .get(c.function_id.0)
                    .cloned()
                    .unwrap_or_else(|| (format!("function{}", c.function_id.0), 0, 1));
                let address = call_args.get(call_index).cloned().unwrap_or_default();
                call_index += 1;
                calls += 1;
                ops.push(Op::Call {
                    name,
                    path,
                    line,
                    address,
                });
            }
            TraceLowLevelEvent::Return(_) => {
                returns += 1;
                ops.push(Op::Return);
            }
            TraceLowLevelEvent::Event(e) => {
                ops.push(Op::Event {
                    metadata: e.metadata.clone(),
                    content: e.content.clone(),
                });
            }
            _ => {}
        }
    }
    let _ = function_index;
    (ops, steps, with_column, calls, returns)
}

// ---------------------------------------------------------------------------
// The trace itself.
// ---------------------------------------------------------------------------

/// A sink that tees: `MemorySink` plus the per-step census this module reports.
struct CensusSink {
    inner: MemorySink,
    steps: Vec<(String, i64, Option<i64>)>,
    errors: Vec<String>,
}

impl TraceSink for CensusSink {
    fn begin_writing_trace_events(
        &mut self,
        path: &Path,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.inner.begin_writing_trace_events(path)
    }
    fn finish_writing_trace_events(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        self.inner.finish_writing_trace_events()
    }
    fn close(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        self.inner.close()
    }
    fn set_workdir(&mut self, workdir: &Path) {
        self.inner.set_workdir(workdir);
    }
    fn start(&mut self, path: &Path, line: Line) {
        self.steps.push((path.display().to_string(), line.0, None));
        self.inner.start(path, line);
    }
    fn enable_column_aware_steps(&mut self) {
        self.inner.enable_column_aware_steps();
    }
    fn enable_column_breakpoints_support(&mut self) {
        self.inner.enable_column_breakpoints_support();
    }
    fn enable_column_motions_support(&mut self) {
        self.inner.enable_column_motions_support();
    }
    fn register_path_with_line_lengths(
        &mut self,
        path: &Path,
        line_lengths: &[u32],
    ) -> Result<codetracer_trace_types::PathId, Box<dyn std::error::Error>> {
        self.inner
            .register_path_with_line_lengths(path, line_lengths)
    }
    fn ensure_function_id(
        &mut self,
        function_name: &str,
        path: &Path,
        line: Line,
    ) -> codetracer_trace_types::FunctionId {
        self.inner.ensure_function_id(function_name, path, line)
    }
    fn register_source_view(
        &mut self,
        path: &Path,
        view_kind: u8,
        view_name: &str,
        content: &[u8],
        sourcemap: &[u8],
    ) -> Result<u64, Box<dyn std::error::Error>> {
        self.inner
            .register_source_view(path, view_kind, view_name, content, sourcemap)
    }
    fn ensure_type_id(
        &mut self,
        kind: TypeKind,
        lang_type: &str,
    ) -> codetracer_trace_types::TypeId {
        self.inner.ensure_type_id(kind, lang_type)
    }
    fn register_step_with_column(&mut self, path: &Path, line: Line, column: Option<Line>) {
        self.steps
            .push((path.display().to_string(), line.0, column.map(|c| c.0)));
        self.inner.register_step_with_column(path, line, column);
    }
    fn register_variable_with_full_value(&mut self, name: &str, value: ValueRecord) {
        self.inner.register_variable_with_full_value(name, value);
    }
    fn arg(&mut self, name: &str, value: ValueRecord) -> codetracer_trace_types::FullValueRecord {
        self.inner.arg(name, value)
    }
    fn register_call(
        &mut self,
        function_id: codetracer_trace_types::FunctionId,
        args: Vec<codetracer_trace_types::FullValueRecord>,
    ) {
        self.inner.register_call(function_id, args);
    }
    fn register_return(&mut self, return_value: ValueRecord) {
        self.inner.register_return(return_value);
    }
    fn register_special_event(&mut self, kind: EventLogKind, metadata: &str, content: &str) {
        if metadata.contains("error") || format!("{kind:?}").contains("Error") {
            self.errors.push(format!("{metadata}: {content}"));
        }
        self.inner.register_special_event(kind, metadata, content);
    }
}

fn distinct_lines(steps: &[(String, i64, Option<i64>)]) -> usize {
    let mut s: Vec<(String, i64)> = steps.iter().map(|(p, l, _)| (p.clone(), *l)).collect();
    s.sort();
    s.dedup();
    s.len()
}

fn distinct_positions(steps: &[(String, i64, Option<i64>)]) -> usize {
    let mut s: Vec<(String, i64, Option<i64>)> = steps.to_vec();
    s.sort();
    s.dedup();
    s.len()
}

fn step_paths(steps: &[(String, i64, Option<i64>)]) -> Vec<String> {
    let mut p: Vec<String> = steps.iter().map(|(p, _, _)| p.clone()).collect();
    p.sort();
    p.dedup();
    p
}

fn run(request_json: &str) -> Result<String, String> {
    let request: Request = serde_json::from_str(request_json)
        .map_err(|e| format!("the request did not parse: {e}"))?;
    if request.frames.is_empty() {
        return Err("the request names no frames".to_string());
    }
    if request.frames[0].depth != 0 {
        return Err(format!(
            "the first frame is at depth {}; a transaction's entry frame is at depth 0",
            request.frames[0].depth
        ));
    }
    let program_name = if request.program.is_empty() {
        request.frames[0].function.clone()
    } else {
        request.program.clone()
    };

    let mut sink = CensusSink {
        inner: MemorySink::new(),
        steps: vec![],
        errors: vec![],
    };
    // No workdir: the sources come out of the artifact's `file_map` and there is no package on
    // disk to be relative to.
    let options = TraceOptions::with_workdir(None::<PathBuf>);
    begin_trace(&mut sink, "", &program_name, None);

    // Function records, in the order `ensure_function_id` mints them, so an `Op::Call` can name its
    // function's path and line. `<toplevel>` is id 0.
    let mut functions: Vec<(String, usize, i64)> = vec![("<toplevel>".to_string(), 0, 1)];
    let mut call_args: Vec<String> = vec![];

    let mut open_frames: Vec<String> = vec![];
    let mut frame_reports: Vec<serde_json::Value> = vec![];
    let mut trace_results: Vec<String> = vec![];
    let mut ledger: Vec<Answered> = vec![];
    let mut refused: Vec<String> = vec![];
    let mut acir_total = 0usize;
    let mut brillig_total = 0usize;
    let mut bytecode_total = 0usize;
    let mut file_map_total = 0usize;
    let mut tape_total = 0usize;
    let mut served_total = 0usize;
    let mut witness_total = 0usize;

    for frame in &request.frames {
        let doc = request
            .artifacts
            .get(&frame.artifact)
            .ok_or_else(|| format!("no artifact named `{}` in the request", frame.artifact))?;
        let loaded = load(doc, &frame.function)?;

        let mut initial_witness = WitnessMap::<FieldElement>::new();
        for (index, hex) in &frame.initial_witness_entries {
            initial_witness.insert(Witness(*index), field_of(hex, "initial witness")?);
        }

        // THE FRAME BRACKET. Deeper frames close before a shallower one opens, and a frame at
        // depth zero is the tracer's own toplevel and is not bracketed at all.
        while open_frames.len() >= frame.depth && frame.depth > 0 {
            TraceSink::register_return(
                &mut sink,
                ValueRecord::None {
                    type_id: NONE_TYPE_ID,
                },
            );
            open_frames.pop();
        }
        let mut declaration = String::new();
        if frame.depth > 0 {
            let (site_path, site_line) = declaration_site(&loaded);
            declaration = site_path.clone();
            let function_id = TraceSink::ensure_function_id(
                &mut sink,
                &frame.function,
                Path::new(&site_path),
                Line(site_line),
            );
            if function_id.0 >= functions.len() {
                // A path id is needed for the op, and the sink has just interned the site.
                let path_index = sink
                    .inner
                    .trace()
                    .paths
                    .iter()
                    .position(|p| p.display().to_string() == site_path)
                    .unwrap_or(0);
                functions.resize(function_id.0 + 1, (String::new(), 0, 1));
                functions[function_id.0] = (frame.function.clone(), path_index, site_line);
            }
            let type_id = TraceSink::ensure_type_id(&mut sink, TypeKind::String, "AztecAddress");
            let arg = TraceSink::arg(
                &mut sink,
                "contractAddress",
                ValueRecord::String {
                    text: frame.contract_address.clone(),
                    type_id,
                },
            );
            call_args.push(frame.contract_address.clone());
            TraceSink::register_call(&mut sink, function_id, vec![arg]);
            open_frames.push(frame.function.clone());
        }

        let steps_before = sink.steps.len();
        let inner = DefaultDebugForeignCallExecutor::from_artifact(
            std::io::sink(),
            None,
            &loaded.debug,
            None,
            String::new(),
        );
        let executor = TapeExecutor {
            inner,
            tape: frame.tape.clone(),
            served_calls: frame.served_calls,
            cursor: 0,
            ledger: vec![],
            refused: vec![],
        };
        // The executor is MOVED into the tracer, which then drops it, so whatever it recorded has
        // to leave through a handle rather than by reading it afterwards. The handles are the
        // TRANSACTION's: a per-frame ledger would make "which oracle stopped this transaction" a
        // question with one answer per frame. Drained after EVERY call rather than at the end,
        // because a frame that halts still did everything up to the halt and that is exactly the
        // run a refusal is about.
        let collected: std::rc::Rc<std::cell::RefCell<(Vec<Answered>, Vec<String>)>> =
            std::rc::Rc::new(std::cell::RefCell::new((vec![], vec![])));
        let reporting = Reporting { inner: executor, out: std::rc::Rc::clone(&collected) };

        let solver = Bn254BlackBoxSolver::default();
        let result = trace_circuit_with_executor(
            &solver,
            &loaded.program.functions,
            &loaded.debug,
            initial_witness,
            &loaded.program.unconstrained_functions,
            &loaded.error_types,
            &options,
            &mut sink,
            Some(Box::new(reporting)),
        );
        {
            let mut c = collected.borrow_mut();
            ledger.append(&mut c.0);
            refused.append(&mut c.1);
        }

        acir_total += loaded.acir_opcodes;
        brillig_total += loaded.brillig_functions;
        bytecode_total += loaded.bytecode_bytes;
        file_map_total += loaded.file_map_entries;
        tape_total += frame.tape.len();
        served_total += frame.served_calls;
        witness_total += frame.initial_witness_entries.len();
        trace_results.push(match &result {
            Ok(()) => "ok".to_string(),
            Err(e) => e.to_string(),
        });

        let frame_steps: Vec<(String, i64, Option<i64>)> = sink.steps[steps_before..].to_vec();
        frame_reports.push(serde_json::json!({
            "artifact": frame.artifact,
            "function": frame.function,
            "depth": frame.depth,
            "contractAddress": frame.contract_address,
            "callSite": declaration,
            "tapeEntriesRecorded": frame.tape.len(),
            "servedCallsInRecording": frame.served_calls,
            "acirOpcodes": loaded.acir_opcodes,
            "brilligFunctions": loaded.brillig_functions,
            "bytecodeBytes": loaded.bytecode_bytes,
            "fileMapEntries": loaded.file_map_entries,
            "initialWitnessEntries": frame.initial_witness_entries.len(),
            "traceResult": trace_results.last().unwrap(),
            "steps": frame_steps.len(),
            "stepsWithColumn": frame_steps.iter().filter(|(_, _, c)| c.is_some()).count(),
            "distinctPositions": distinct_positions(&frame_steps),
            "distinctLines": distinct_lines(&frame_steps),
            "stepPaths": step_paths(&frame_steps),
            "firstSteps": frame_steps.iter().take(5)
                .map(|(p, l, c)| format!("{p}:{l}:{}", c.map(|c| c.to_string()).unwrap_or_else(|| "-".into())))
                .collect::<Vec<_>>(),
        }));
    }

    while open_frames.pop().is_some() {
        TraceSink::register_return(
            &mut sink,
            ValueRecord::None {
                type_id: NONE_TYPE_ID,
            },
        );
    }
    if let Some(join) = &request.join {
        write_join_record(&mut sink, join);
    }
    let finish = match finish_trace(&mut sink) {
        Ok(()) => "ok".to_string(),
        Err(e) => e.to_string(),
    };

    let steps = sink.steps.clone();
    let errors = sink.errors.clone();
    let trace = sink.inner.into_trace();
    let (ops, op_steps, op_with_column, op_calls, op_returns) =
        ops_of(&trace, &functions, &call_args);

    let out = serde_json::json!({
        "program": program_name,
        "frameCount": request.frames.len(),
        "maxDepth": request.frames.iter().map(|f| f.depth).max().unwrap_or(0),
        "frames": frame_reports,
        "steps": steps.len(),
        "stepsWithColumn": steps.iter().filter(|(_, _, c)| c.is_some()).count(),
        "distinctPositions": distinct_positions(&steps),
        "distinctLines": distinct_lines(&steps),
        "stepPaths": step_paths(&steps),
        "firstSteps": steps.iter().take(5)
            .map(|(p, l, c)| format!("{p}:{l}:{}", c.map(|c| c.to_string()).unwrap_or_else(|| "-".into())))
            .collect::<Vec<_>>(),
        // EVERY POSITION, IN ORDER, so a check can compare this module's step stream against the
        // NATIVE probe's container position for position and column for column. A count of steps
        // that agrees says two implementations produced the same NUMBER; a sequence that agrees
        // says they walked the same circuit. Rendered as `path:line:column` with `-` for a step
        // that carries no column, which is the same spelling `firstSteps` uses.
        "stepPositions": steps.iter()
            .map(|(p, l, c)| format!("{p}:{l}:{}", c.map(|c| c.to_string()).unwrap_or_else(|| "-".into())))
            .collect::<Vec<_>>(),
        "registeredPaths": trace.paths.len(),
        "sourceViews": trace.source_views.len(),
        "capabilities": trace.capabilities,
        "traceResults": trace_results,
        "finish": finish,
        "traceErrors": errors,
        "oracleLedger": ledger,
        "refusedOracles": refused,
        "tapeEntriesRecorded": tape_total,
        "servedCallsInRecording": served_total,
        "acirOpcodes": acir_total,
        "brilligFunctions": brillig_total,
        "bytecodeBytes": bytecode_total,
        "fileMapEntries": file_map_total,
        "initialWitnessEntries": witness_total,
        "join": request.join.as_ref().map(|j| serde_json::json!({
            "id": j.id, "half": j.half, "halves": j.halves, "arm": j.arm,
        })),
        "encode": {
            "ops": ops,
            "steps": op_steps,
            "stepsWithColumn": op_with_column,
            "calls": op_calls,
            "returns": op_returns,
        },
    });
    serde_json::to_string(&out).map_err(|e| format!("the report did not serialise: {e}"))
}

/// Collects a `TapeExecutor`'s ledger out through a shared handle, because the tracer takes
/// ownership of the executor and drops it.
struct Reporting<D> {
    inner: TapeExecutor<D>,
    out: std::rc::Rc<std::cell::RefCell<(Vec<Answered>, Vec<String>)>>,
}

impl<D: TraceForeignCallExecutor> ForeignCallExecutor<FieldElement> for Reporting<D> {
    fn execute(
        &mut self,
        call: &ForeignCallWaitInfo<FieldElement>,
    ) -> Result<ForeignCallResult<FieldElement>, ForeignCallError> {
        let r = self.inner.execute(call);
        let mut out = self.out.borrow_mut();
        out.0.append(&mut self.inner.ledger);
        out.1.append(&mut self.inner.refused);
        r
    }
}

impl<D: TraceForeignCallExecutor> TraceForeignCallExecutor for Reporting<D> {
    fn get_variables(&self) -> Vec<StackFrame<'_, FieldElement>> {
        self.inner.get_variables()
    }
    fn current_stack_frame(&self) -> Option<StackFrame<'_, FieldElement>> {
        self.inner.current_stack_frame()
    }
    fn restart(&mut self, artifact: &DebugArtifact) {
        self.inner.restart(artifact);
    }
}

// ---------------------------------------------------------------------------
// The bare ABI. No imports: strings cross as `(ptr, len)` pairs in linear memory.
//
// **THE PREFIX IS `pt_` AND NOT `ct_`, AND THAT IS A LINKER FACT RATHER THAN A STYLE.**
// `noir_tracer_wasm` is linked in as an rlib and its own `abi` module already exports `ct_alloc`,
// `ct_free`, `ct_result_len` and `ct_result_is_error` on wasm32. Four duplicate symbols is what the
// first build said, and reusing them is not an option either: their `RESULT_LEN` / `RESULT_IS_ERROR`
// cells are that crate's thread-locals and this module's entry point cannot set them, so a host
// reading `ct_result_len()` after `pt_trace_transaction` would read a length from a call nobody
// made. Distinct names for distinct state.
// ---------------------------------------------------------------------------

use std::alloc::{Layout, alloc, dealloc};

thread_local! {
    static RESULT_LEN: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static RESULT_IS_ERROR: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Reserve `len` bytes in the module's linear memory.
///
/// # Safety
/// The caller must eventually pass the returned pointer and the same `len` to [`pt_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    let layout = Layout::from_size_align(len, 1).expect("valid layout");
    unsafe { alloc(layout) }
}

/// Release a buffer previously returned by [`pt_alloc`] or [`pt_trace_transaction`].
///
/// # Safety
/// `ptr`/`len` must come from one of those calls and not be used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let layout = Layout::from_size_align(len, 1).expect("valid layout");
    unsafe { dealloc(ptr, layout) };
}

/// Byte length of the buffer the last [`pt_trace_transaction`] call returned.
#[unsafe(no_mangle)]
pub extern "C" fn pt_result_len() -> usize {
    RESULT_LEN.with(|c| c.get())
}

/// Non-zero if the last [`pt_trace_transaction`] returned an error message rather than a report.
#[unsafe(no_mangle)]
pub extern "C" fn pt_result_is_error() -> u32 {
    RESULT_IS_ERROR.with(|c| u32::from(c.get()))
}

/// Trace a transaction. Returns a pointer to UTF-8 bytes; the length is [`pt_result_len`] and
/// [`pt_result_is_error`] says which of the two shapes it holds.
///
/// # Safety
/// `(ptr, len)` must describe an initialised UTF-8 buffer valid for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pt_trace_transaction(ptr: *const u8, len: usize) -> *mut u8 {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    let result = match std::str::from_utf8(bytes) {
        Ok(s) => run(s),
        Err(_) => Err("the request is not valid UTF-8".to_string()),
    };
    let (bytes, is_error) = match result {
        Ok(json) => (json.into_bytes(), false),
        Err(message) => (message.into_bytes(), true),
    };
    RESULT_LEN.with(|c| c.set(bytes.len()));
    RESULT_IS_ERROR.with(|c| c.set(is_error));
    let mut boxed = bytes.into_boxed_slice();
    let out = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    out
}
