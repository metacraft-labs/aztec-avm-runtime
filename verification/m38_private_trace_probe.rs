// M38's evidence, as a program: **an Aztec private function stepped by the Noir tracer**, with the
// oracle answers supplied by M35's own handler and nothing fabricated.
//
// ---------------------------------------------------------------------------------------------
// THE SYNCHRONY BOUNDARY, WHICH IS WHAT THIS PROGRAM EXISTS TO CROSS.
//
// `nargo trace` IS an ACVM stepper — `TracingContext` drives `DebugContext::step_into_opcode()` in a
// loop — and `noir_tracer::trace_circuit_with_executor` now takes the foreign-call executor as a
// parameter, so an embedder can answer the calls the recorder knows nothing about. What it cannot
// do is answer them the way M35 answers them: `ForeignCallExecutor::execute` is **synchronous
// Rust**, and M35's thirty-five implementations are **TypeScript returning promises**. A
// synchronous Rust call cannot await a JavaScript one, in a browser or anywhere else.
//
// So the answers are PRE-FETCHED rather than computed here, which is the milestone's own stated
// remedy for exactly this case. `browser/src/wallet/private_execution.ts` records the wire values
// of every oracle call the real handler answers — `PrivateExecutionRequest.recordTape` — and this
// program replays that tape into the same circuit. **Nothing in this file implements an Aztec
// oracle.** It has no notion of what a capsule is, or a nullifier, or a contract instance; it can
// only hand back a value M35's handler produced, for the same oracle, at the same point in the
// sequence, in answer to the same inputs.
//
// THE REFUSAL IS THEREFORE THE INTERESTING HALF. Four things make this executor refuse, each BY
// NAME, and each is a case where a permissive version would be invisible afterwards:
//
//   * the tape has run out (the frame is asking for more than was recorded);
//   * the tape's next entry is a DIFFERENT oracle (the replay has diverged from the recording);
//   * it is the right oracle but the INPUTS differ (same call, different question);
//   * the call is past the recording's own SERVED prefix — the tape carries the call that stopped
//     the frame too, and that one was never answered.
//
// The last one matters most, and the discriminator for it comes from the recording rather than
// from the tape: a refused call and a genuinely void oracle both appear with empty `outputs`, so
// the executor is told how many calls the recording's handler ANSWERED (`oraclesServed`) and
// refuses everything past that prefix. An executor that handed back "no fields" instead would be
// handing back a fabricated answer of length zero — which fails loudly for a circuit expecting
// fields and SUCCEEDS for one expecting none, walking the frame past an oracle nobody served.
//
// ---------------------------------------------------------------------------------------------
// WHAT IS NOT HERE.
//
// * **No second writer.** The container is written by `NimWriterSink` over
//   `create_trace_writer(..., Ctfs)` — literally the sink and the writer `nargo trace` uses
//   (`tooling/nargo_cli/src/cli/trace_cmd.rs`), reached through the same `TraceSink` seam. This
//   program's whole difference from `nargo trace` is that it starts from an Aztec artifact instead
//   of a Noir package, and that it supplies an executor.
// * **No compilation.** The ACIR is the one in the published `@aztec/noir-test-contracts.js`
//   artifact, deserialised as it stands.
//
// Built by `verification/build_m38_private_trace_probe.sh`. Arms are chosen by the spec's `arm`
// field; see `SPEC` below.

use std::collections::BTreeMap;
use std::error::Error;
use std::io::Read;
use std::path::PathBuf;

use acvm::{AcirField, FieldElement};
use acvm::acir::brillig::ForeignCallResult;
use acvm::acir::circuit::Program;
use acvm::acir::native_types::{Witness, WitnessMap};
use acvm::pwg::ForeignCallWaitInfo;
use base64::Engine;
use bn254_blackbox_solver::Bn254BlackBoxSolver;
use codetracer_trace_writer::{TraceEventsFileFormat, create_trace_writer};
use nargo::foreign_calls::{ForeignCallError, ForeignCallExecutor};
use noir_debugger::context::{DebugCommandResult, DebugContext};
use noir_debugger::foreign_calls::DefaultDebugForeignCallExecutor;
use noir_tracer::sink::NimWriterSink;
use noir_tracer::tracer_glue::{begin_trace, finish_trace};
use noir_tracer::{TraceForeignCallExecutor, TraceOptions, TraceSink, trace_circuit_with_executor};
use noirc_artifacts::debug::{DebugArtifact, DebugFile, ProgramDebugInfo, StackFrame};
use codetracer_trace_types::{Line, NONE_TYPE_ID, TypeKind, ValueRecord};

// ---------------------------------------------------------------------------
// The spec the driver hands over.
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct Spec {
    /// `replay` — answer from the tape. `refuse-all` — an empty tape, so the first oracle refuses.
    /// `truncate` — drop the last tape entry, so the frame runs out mid-way.
    arm: String,
    /// The Aztec contract artifact, as installed. The SINGLE-FRAME form; see `frames`.
    #[serde(default)]
    artifact: String,
    /// The private function inside it. The SINGLE-FRAME form; see `frames`.
    #[serde(default)]
    function: String,
    /// The M35 arm report to take the tape and the initial witness from.
    tape_source: String,
    /// A JSON path into that report, `a.b.c`, naming the frame. The SINGLE-FRAME form.
    #[serde(default)]
    tape_frame: String,
    /// Where the `.ct` container goes.
    out_dir: String,
    /// The container's program name. Defaults to the first frame's function, which is what the
    /// single-frame form always produced.
    #[serde(default)]
    program: String,
    /// **A TRANSACTION'S FRAMES, IN PRE-ORDER, WHEN THERE IS MORE THAN ONE.**
    ///
    /// Empty means the three fields above describe one frame, which is exactly what every spec
    /// written before nested private calls existed says — so those specs deserialise unchanged and
    /// produce a byte-identical container. The same discipline `trace_circuit` used when it grew an
    /// executor parameter: the old entry point keeps its meaning and delegates.
    #[serde(default)]
    frames: Vec<FrameSpec>,
}

/// One frame of a transaction: which bytecode ran, whose tape answers it, and how deep it sat.
#[derive(Clone, serde::Deserialize)]
struct FrameSpec {
    artifact: String,
    function: String,
    /// A JSON path into `tape_source` naming THIS frame's own tape. A transaction's tape is per
    /// frame because a CIRCUIT is per frame: the tracer steps one circuit at a time, and which tape
    /// belongs to which circuit is what a flattened tape throws away.
    tape_frame: String,
    /// 0 for the transaction's entry frame; one more per nesting level.
    #[serde(default)]
    depth: usize,
    /// The contract this frame ran at. Written as the frame's ONE call argument, which is M26's own
    /// rule for the public half: it is what makes a frame attributable without reading its steps.
    #[serde(default)]
    contract_address: String,
}

#[derive(Clone, serde::Deserialize)]
struct TapeEntry {
    seq: usize,
    oracle: String,
    inputs: Vec<Vec<String>>,
    outputs: Vec<Vec<String>>,
    /// Whether each output slot crossed the wire as a `Single` field or as an `Array` of fields.
    ///
    /// **A ONE-ELEMENT ARRAY AND A SINGLE FIELD ARE INDISTINGUISHABLE ON A NORMALISED TAPE, AND
    /// THE ACVM TELLS THEM APART.** `ForeignCallParam` is `Single(f) | Array(fs)`, and a Brillig
    /// destination for an array return is a heap array of a declared width; handing it a scalar is
    /// an out-of-bounds read reported as a bare `Failed assertion`.
    ///
    /// Absent on a tape recorded before the kinds were written down. The fallback below is the
    /// length guess this field exists to remove, and it is REPORTED per call rather than applied
    /// silently — a replay that had to guess is a replay whose result carries an assumption.
    #[serde(default, rename = "outputKinds")]
    output_kinds: Vec<String>,
}

// ---------------------------------------------------------------------------
// The executor.
// ---------------------------------------------------------------------------

/// One thing that happened at the wire, from this side.
#[derive(serde::Serialize)]
struct Answered {
    seq: usize,
    oracle: String,
    outcome: &'static str,
    reason: String,
}

/// Replays a recorded tape, refusing anything it cannot answer FROM the tape.
///
/// `inner` is the executor the tracer would have built for itself. It is consulted for the
/// recorder's own traffic (`__debug_*`, `print`) and for nothing else — an Aztec oracle never
/// reaches it, because the default's base layer is `layers::Empty`, which answers *everything*
/// with an empty result. Delegating an Aztec oracle to it would therefore not be a fallback, it
/// would be a fabrication with an extra step.
struct TapeExecutor<D> {
    inner: D,
    tape: Vec<TapeEntry>,
    /// How many of those calls the recording's own handler ANSWERED. Read off the M35 report
    /// rather than inferred from the tape — see the refusal it decides.
    served_calls: usize,
    cursor: usize,
    ledger: Vec<Answered>,
    refused: Vec<String>,
}

/// Everything an Aztec contract's foreign calls are named. Derived from the shape upstream's own
/// `parseOracleName` requires (`^aztec_(\w+?)_(.+)$`) rather than from a list of the sixty-eight,
/// so an oracle upstream adds is covered on the day it appears.
fn is_aztec_oracle(name: &str) -> bool {
    name.strip_prefix("aztec_")
        .and_then(|rest| rest.split_once('_'))
        .is_some_and(|(scope, method)| !scope.is_empty() && !method.is_empty())
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
        // `NoHandler` is the ACVM's own "nobody answered this", and it carries the text into the
        // execution error. A handler that returned an empty result instead would let the circuit
        // continue over a value nobody produced.
        ForeignCallError::NoHandler(format!("{oracle}: {reason}"))
    }
}

fn field_of(hex: &str, what: &str) -> Result<FieldElement, String> {
    let trimmed = hex.strip_prefix("0x").unwrap_or(hex);
    FieldElement::try_from_str(&format!("0x{trimmed}"))
        .ok_or_else(|| format!("{what}: `{hex}` is not a field element"))
}

impl<D: TraceForeignCallExecutor> ForeignCallExecutor<FieldElement> for TapeExecutor<D> {
    fn execute(
        &mut self,
        call: &ForeignCallWaitInfo<FieldElement>,
    ) -> Result<ForeignCallResult<FieldElement>, ForeignCallError> {
        let name = call.function.clone();
        if !is_aztec_oracle(&name) {
            return self.inner.execute(call);
        }

        let Some(entry) = self.tape.get(self.cursor).cloned() else {
            return Err(self.refuse(
                &name,
                format!(
                    "the recorded tape holds {} call(s) and this is call {}; \
                     the frame is asking for more than M35's handler answered",
                    self.tape.len(),
                    self.cursor + 1
                ),
            ));
        };

        if entry.oracle != name {
            return Err(self.refuse(
                &name,
                format!(
                    "the tape's call {} is `{}`; the replay has diverged from the recording",
                    entry.seq, entry.oracle
                ),
            ));
        }

        // THE INPUTS ARE COMPARED, NOT ASSUMED. Two calls to the same oracle in one frame can ask
        // different questions — `isExecutionInRevertiblePhase` is called twice here — and an
        // executor that matched on the NAME alone would answer the second with the first's answer
        // whenever the order shifted. Rendering both sides through the same formatter is what
        // makes the comparison about values rather than about spelling.
        let observed = render_inputs(&call.inputs);
        let recorded = normalise(&entry.inputs);
        if observed != recorded {
            return Err(self.refuse(
                &name,
                format!(
                    "the tape's call {} asked {:?} and this frame asks {:?}",
                    entry.seq, recorded, observed
                ),
            ));
        }

        // A CALL M35's HANDLER DID NOT ANSWER IS NOT AN ANSWER OF LENGTH ZERO.
        //
        // The tape carries every call that was MADE, including the one that stopped the frame:
        // a refusal is recorded with empty `outputs`, and so is a genuinely void oracle. The two
        // are indistinguishable from the tape alone, so the discriminator comes from the recording
        // rather than from a guess — `served_calls` is the recording's own count of the calls its
        // handler ANSWERED, and every call past that prefix is one it did not.
        //
        // Getting this wrong in the permissive direction is the milestone's own forbidden failure:
        // an empty result handed to a circuit expecting fields fails loudly, but handed to one
        // expecting none it succeeds, and the frame walks past an oracle nobody served.
        if entry.seq >= self.served_calls {
            return Err(self.refuse(
                &name,
                format!(
                    "the recording answered {} call(s) and this is its call {}: \
                     M35's handler did not answer this one",
                    self.served_calls, entry.seq
                ),
            ));
        }

        let mut values: Vec<acvm::acir::brillig::ForeignCallParam<FieldElement>> = Vec::new();
        let mut guessed_kinds = 0usize;
        for (slot_index, slot) in entry.outputs.iter().enumerate() {
            let mut fields = Vec::with_capacity(slot.len());
            for hex in slot {
                match field_of(hex, &format!("{name} output slot {slot_index}")) {
                    Ok(f) => fields.push(f),
                    Err(reason) => return Err(self.refuse(&name, reason)),
                }
            }
            // THE RECORDED KIND WHEN THERE IS ONE, AND THE LENGTH GUESS ONLY WHEN THERE IS NOT.
            // `aztec_prv_getHashPreimage` returns `[Field; 1]` for a function returning one field,
            // and the guess made that a `Single` — which halted `Parent.entry_point` inside Brillig
            // 167 opcodes in, with five of its seven recorded calls replayed. Every oracle M38's
            // arms exercised happened to be a real `Single` or a multi-field array, which is why a
            // wrong rule looked like a right one.
            let recorded_kind = entry.output_kinds.get(slot_index).map(String::as_str);
            if recorded_kind.is_none() {
                guessed_kinds += 1;
            }
            values.push(match recorded_kind {
                Some("single") => acvm::acir::brillig::ForeignCallParam::Single(fields[0]),
                Some("array") => acvm::acir::brillig::ForeignCallParam::Array(fields),
                Some(other) => {
                    return Err(self.refuse(
                        &name,
                        format!("output slot {slot_index} declares an unknown wire kind `{other}`"),
                    ));
                }
                None if fields.len() == 1 => acvm::acir::brillig::ForeignCallParam::Single(fields[0]),
                None => acvm::acir::brillig::ForeignCallParam::Array(fields),
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

fn render_inputs(
    inputs: &[acvm::acir::brillig::ForeignCallParam<FieldElement>],
) -> Vec<Vec<String>> {
    inputs
        .iter()
        .map(|p| match p {
            acvm::acir::brillig::ForeignCallParam::Single(f) => vec![hex_of(f)],
            acvm::acir::brillig::ForeignCallParam::Array(a) => a.iter().map(hex_of).collect(),
        })
        .collect()
}

fn hex_of(f: &FieldElement) -> String {
    format!("0x{}", f.to_hex())
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
// A sink that tees: the real container writer, plus a census this program reports.
// ---------------------------------------------------------------------------

struct CountingSink<'a> {
    inner: NimWriterSink<'a>,
    steps: Vec<(String, i64, Option<i64>)>,
    paths: Vec<String>,
    calls: usize,
    returns: usize,
    errors: Vec<String>,
}

impl<'a> TraceSink for CountingSink<'a> {
    fn begin_writing_trace_events(&mut self, path: &std::path::Path) -> Result<(), Box<dyn Error>> {
        self.inner.begin_writing_trace_events(path)
    }
    fn finish_writing_trace_events(&mut self) -> Result<(), Box<dyn Error>> {
        self.inner.finish_writing_trace_events()
    }
    fn close(&mut self) -> Result<(), Box<dyn Error>> {
        self.inner.close()
    }
    fn set_workdir(&mut self, workdir: &std::path::Path) {
        self.inner.set_workdir(workdir);
    }
    fn start(&mut self, path: &std::path::Path, line: codetracer_trace_types::Line) {
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
        path: &std::path::Path,
        line_lengths: &[u32],
    ) -> Result<codetracer_trace_types::PathId, Box<dyn Error>> {
        self.paths.push(path.display().to_string());
        self.inner
            .register_path_with_line_lengths(path, line_lengths)
    }
    fn ensure_function_id(
        &mut self,
        function_name: &str,
        path: &std::path::Path,
        line: codetracer_trace_types::Line,
    ) -> codetracer_trace_types::FunctionId {
        self.inner.ensure_function_id(function_name, path, line)
    }
    fn ensure_type_id(
        &mut self,
        kind: codetracer_trace_types::TypeKind,
        lang_type: &str,
    ) -> codetracer_trace_types::TypeId {
        self.inner.ensure_type_id(kind, lang_type)
    }
    fn register_source_view(
        &mut self,
        path: &std::path::Path,
        view_kind: u8,
        view_name: &str,
        content: &[u8],
        sourcemap: &[u8],
    ) -> Result<u64, Box<dyn Error>> {
        self.inner
            .register_source_view(path, view_kind, view_name, content, sourcemap)
    }
    fn register_step_with_column(
        &mut self,
        path: &std::path::Path,
        line: codetracer_trace_types::Line,
        column: Option<codetracer_trace_types::Line>,
    ) {
        self.steps
            .push((path.display().to_string(), line.0, column.map(|c| c.0)));
        self.inner.register_step_with_column(path, line, column);
    }
    fn register_variable_with_full_value(
        &mut self,
        name: &str,
        value: codetracer_trace_types::ValueRecord,
    ) {
        self.inner.register_variable_with_full_value(name, value);
    }
    fn arg(
        &mut self,
        name: &str,
        value: codetracer_trace_types::ValueRecord,
    ) -> codetracer_trace_types::FullValueRecord {
        self.inner.arg(name, value)
    }
    fn register_call(
        &mut self,
        function_id: codetracer_trace_types::FunctionId,
        args: Vec<codetracer_trace_types::FullValueRecord>,
    ) {
        self.calls += 1;
        self.inner.register_call(function_id, args);
    }
    fn register_return(&mut self, return_value: codetracer_trace_types::ValueRecord) {
        self.returns += 1;
        self.inner.register_return(return_value);
    }
    fn register_special_event(
        &mut self,
        kind: codetracer_trace_types::EventLogKind,
        metadata: &str,
        content: &str,
    ) {
        if metadata.contains("error") || format!("{kind:?}").to_lowercase().contains("error") {
            self.errors.push(format!("{metadata} {content}"));
        }
        self.inner.register_special_event(kind, metadata, content);
    }
}

// ---------------------------------------------------------------------------
// Loading the Aztec artifact.
// ---------------------------------------------------------------------------

struct Loaded {
    program: Program<FieldElement>,
    debug: DebugArtifact,
    /// The ABI's own error selectors, so an assertion renders as the sentence the contract wrote.
    ///
    /// **It was an empty map, and that made every assertion message blank.** The ACVM reports a
    /// failed constraint by SELECTOR and the renderer looks the sentence up here; handing it
    /// nothing produced `Failed assertion` with a leading space over an artifact that declares
    /// `Preimage mismatch` by name. A diagnostic that names nothing is the expensive kind, and this
    /// one was costing a real halt its explanation.
    error_types: BTreeMap<acvm::acir::circuit::ErrorSelector, noirc_abi::AbiErrorType>,
    acir_opcodes: usize,
    brillig_functions: usize,
    bytecode_bytes: usize,
    file_map_entries: usize,
}

fn load(artifact_path: &str, function: &str) -> Result<Loaded, String> {
    let doc: serde_json::Value = serde_json::from_reader(
        std::fs::File::open(artifact_path).map_err(|e| format!("{artifact_path}: {e}"))?,
    )
    .map_err(|e| format!("{artifact_path}: {e}"))?;

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

    // The artifact's `file_map` is keyed by a STRING in JSON and by `FileId` in the struct, so it
    // is rebuilt entry by entry rather than deserialised wholesale.
    let mut file_map: BTreeMap<fm::FileId, DebugFile> = BTreeMap::new();
    for (key, value) in doc["file_map"].as_object().ok_or("the artifact has no `file_map`")? {
        // `FileId` is a newtype over `usize` whose field is private, so it is DESERIALISED from
        // the key rather than constructed. That is not a workaround: `FileId::dummy()` is the only
        // public constructor and it always answers 0, so building the map by hand would collapse
        // sixty files onto one id and every step would resolve to whichever file happened to be
        // last. Going through serde keeps the artifact's own numbering.
        let id: fm::FileId = serde_json::from_str(key)
            .map_err(|e| format!("file_map key `{key}` is not a file id: {e}"))?;
        let file: DebugFile =
            serde_json::from_value(value.clone()).map_err(|e| format!("file_map[{key}]: {e}"))?;
        file_map.insert(id, file);
    }
    // The ABI's error types are keyed by a decimal selector STRING in JSON and by `ErrorSelector`
    // in the struct, so they are rebuilt entry by entry for the same reason `file_map` is.
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
/// **A `Call` needs a `(path, line)` BEFORE the callee has stepped**, because `register_call` has
/// to precede the steps it brackets — so the position cannot be the callee's first STEP, which is
/// only known afterwards. It is the callee's own declaration file instead, taken from the
/// artifact's `file_map`.
///
/// The choice is the shortest path ending in `/src/main.nr`, which is where an `#[aztec]` contract
/// is declared, and the fallback is the lexicographically first entry. **The chosen path is
/// REPORTED per frame**, so a container whose frames all opened in the same wrong file is visible
/// rather than plausible; a helper that silently picked one of sixty files would be a position
/// nobody could check.
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
    let path = main.or_else(|| candidates.first().cloned()).unwrap_or_else(|| "<no source>".into());
    (path, 1)
}

// ---------------------------------------------------------------------------

/// How many distinct `(path, line)` pairs the trace stepped through. A step count alone cannot
/// tell a loop from a walk; this is the other half of that pair.
fn distinct_lines(steps: &[(String, i64, Option<i64>)]) -> usize {
    let mut s: Vec<(String, i64)> = steps.iter().map(|(p, l, _)| (p.clone(), *l)).collect();
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

/// A dotted path into a JSON document, where a NUMERIC segment indexes an array.
///
/// A transaction's report is a TREE — a frame's children hang off `nested` — so naming the second
/// frame means walking through an array, and `Value::get(&str)` answers `None` for one. Object keys
/// are still tried first, so a document whose object really has a key `"0"` is unaffected; nothing
/// in this repository's reports does, and preferring the object keeps the change additive.
fn json_at<'a>(v: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let mut cur = v;
    for part in path.split('.') {
        cur = match cur.get(part) {
            Some(next) => next,
            None => cur.get(part.parse::<usize>().ok()?)?,
        };
    }
    Some(cur)
}

fn main() {
    let spec_path = std::env::args()
        .nth(1)
        .expect("usage: m38probe <spec.json>");
    let spec: Spec = serde_json::from_reader(std::fs::File::open(&spec_path).unwrap()).unwrap();

    // THE FRAME LIST, WHICH IS ONE FRAME WHEN NOBODY SAID OTHERWISE. A spec written before nested
    // private calls existed carries `artifact` / `function` / `tape_frame` and no `frames`; it
    // becomes a one-element list here and everything below runs once, which is what those specs
    // have always done.
    let frames: Vec<FrameSpec> = if spec.frames.is_empty() {
        vec![FrameSpec {
            artifact: spec.artifact.clone(),
            function: spec.function.clone(),
            tape_frame: spec.tape_frame.clone(),
            depth: 0,
            contract_address: String::new(),
        }]
    } else {
        spec.frames.clone()
    };
    if frames.iter().any(|f| f.artifact.is_empty() || f.function.is_empty() || f.tape_frame.is_empty()) {
        eprintln!("m38probe: every frame needs an artifact, a function and a tape_frame");
        std::process::exit(2);
    }
    // A FRAME LIST IN PRE-ORDER CANNOT SKIP A LEVEL. `depth` decides which frame a `Call` nests
    // inside, so a list that jumped 0 -> 2 would open a frame under a parent that is not there and
    // the container's depths would be a fiction. Refused rather than repaired.
    for (i, f) in frames.iter().enumerate() {
        let previous = if i == 0 { 0 } else { frames[i - 1].depth };
        if i == 0 && f.depth != 0 {
            eprintln!("m38probe: the first frame must be at depth 0, not {}", f.depth);
            std::process::exit(2);
        }
        if i > 0 && f.depth > previous + 1 {
            eprintln!(
                "m38probe: frame {} is at depth {} after a frame at depth {}; a pre-order list cannot skip a level",
                i, f.depth, previous
            );
            std::process::exit(2);
        }
    }

    let report: serde_json::Value =
        serde_json::from_reader(std::fs::File::open(&spec.tape_source).unwrap()).unwrap();

    std::fs::create_dir_all(&spec.out_dir).expect("out dir");

    // THE CONTAINER'S PROGRAM NAME. `spec.program` when the driver named one; the FIRST FRAME's
    // function otherwise, which is exactly what the single-frame form always produced.
    let program_name = if spec.program.is_empty() { frames[0].function.clone() } else { spec.program.clone() };

    // ONE WRITER FOR THE WHOLE TRANSACTION. Two writers would be two containers, and a transaction
    // whose frames sit in different files is the thing `JOIN-SHAPE.md` refuses to let a reader
    // infer. `create_trace_writer` is `nargo trace`'s own, unchanged.
    let mut writer = create_trace_writer(&program_name, &[], TraceEventsFileFormat::Ctfs);
    let mut sink = CountingSink {
        inner: NimWriterSink::new(&mut *writer),
        steps: vec![],
        paths: vec![],
        calls: 0,
        returns: 0,
        errors: vec![],
    };

    // The workdir is `None` so the artifact's own paths are registered verbatim. There is no
    // package on disk to be relative to: the sources come out of the artifact's `file_map`.
    let options = TraceOptions::with_workdir(None::<PathBuf>);
    begin_trace(&mut sink, &spec.out_dir, &program_name, None);

    // THE OPEN FRAME STACK. A frame at depth d nests inside the last frame at depth d-1, so the
    // list is walked in pre-order and every deeper frame is closed before a shallower one opens.
    //
    // **THE CHILD'S FRAME OPENS AFTER THE PARENT'S STEP STREAM, NOT AT THE PARENT'S CALL
    // INSTRUCTION, AND THAT IS STATED RATHER THAN GLOSSED.** `trace_circuit_with_executor` steps a
    // whole circuit in one pass; there is no point inside that pass at which this program can
    // interleave a second circuit's steps. So the nesting expresses the CALL RELATIONSHIP and not
    // the instruction order. That is `JOIN-SHAPE.md` §3's own shape one level down — its public
    // frames open at depth 2 inside `main` after the private half has stepped, for the same reason
    // — and it is why a reader sees the parent's frame with the child's inside it rather than the
    // child's steps spliced into the parent's.
    let mut open_frames: Vec<String> = vec![];
    let mut frame_reports: Vec<serde_json::Value> = vec![];
    let mut all_tape_entries = 0usize;
    let mut all_served = 0usize;
    let mut all_opcodes_stepped = 0usize;
    let mut all_opcodes_positioned = 0usize;
    let mut all_positions_distinct = 0usize;
    let mut all_call_stack_positioned = 0usize;
    let mut all_witness_entries = 0usize;
    let mut acir_opcodes_total = 0usize;
    let mut brillig_total = 0usize;
    let mut bytecode_total = 0usize;
    let mut file_map_total = 0usize;
    let mut trace_results: Vec<String> = vec![];
    let ledger = std::rc::Rc::new(std::cell::RefCell::new(Vec::<Answered>::new()));
    let refused = std::rc::Rc::new(std::cell::RefCell::new(Vec::<String>::new()));

    for frame_spec in &frames {
        let loaded = match load(&frame_spec.artifact, &frame_spec.function) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("m38probe: {e}");
                std::process::exit(2);
            }
        };
        let frame = json_at(&report, &frame_spec.tape_frame).unwrap_or_else(|| {
            panic!("no frame at `{}` in {}", frame_spec.tape_frame, spec.tape_source)
        });
        let mut tape: Vec<TapeEntry> =
            serde_json::from_value(frame["tape"].clone()).expect("the frame carries no `tape`");
        let served_calls: usize = frame["oraclesServed"]
            .as_u64()
            .expect("the frame carries no `oraclesServed`") as usize;
        let witness_entries: Vec<(u32, String)> =
            serde_json::from_value(frame["initialWitnessEntries"].clone())
                .expect("the frame carries no `initialWitnessEntries`");
        // THE ARMS ARE MUTATIONS OF THE TAPE, NOT OF THE CODE. Each is a case the executor must refuse,
        // and each is produced by removing something rather than by adding a flag to the executor —
        // so the refusal path under test is the shipped one.
        let tape_len_before = tape.len();
        match spec.arm.as_str() {
            "replay" => {}
            "refuse-all" => tape.clear(),
            "truncate" => {
                tape.pop();
            }
            // ONE FIELD OF ONE RECORDED INPUT IS CHANGED, AND NOTHING ELSE. The oracle name, the
            // sequence and the outputs stay as they were, so the only thing that can refuse this is
            // the INPUT comparison. Without an arm that reaches it, that comparison is a branch nothing
            // executes — a replay is faithful by construction, so removing the comparison altogether
            // changes no other arm's result. Measured: it did not, and this arm is why it now does.
            "permute-inputs" => {
                let mut done = false;
                for entry in tape.iter_mut() {
                    if let Some(slot) = entry.inputs.first_mut() {
                        if let Some(first) = slot.first_mut() {
                            *first = "0x00000000000000000000000000000000000000000000000000000000deadbeef"
                                .to_string();
                            done = true;
                            break;
                        }
                    }
                }
                if !done {
                    eprintln!("m38probe: the tape has no input field to permute");
                    std::process::exit(2);
                }
            }
            other => {
                eprintln!("m38probe: unknown arm `{other}`");
                std::process::exit(2);
            }
        }

        let tape_for_second_pass = tape.clone();

        let mut initial_witness = WitnessMap::<FieldElement>::new();
        for (index, hex) in &witness_entries {
            initial_witness.insert(
                Witness(*index),
                field_of(hex, "initial witness").expect("witness field"),
            );
        }

        // THE FRAME BRACKET. Deeper frames close before a shallower one opens, and a frame at depth
        // zero is the tracer's own toplevel and is not bracketed at all — which is why a single-frame
        // run emits no Call and no Return, exactly as it did before this loop existed.
        while open_frames.len() >= frame_spec.depth && frame_spec.depth > 0 {
            TraceSink::register_return(&mut sink, ValueRecord::None { type_id: NONE_TYPE_ID });
            open_frames.pop();
        }
        if frame_spec.depth > 0 {
            let (site_path, site_line) = declaration_site(&loaded);
            let function_id = TraceSink::ensure_function_id(
                &mut sink,
                &frame_spec.function,
                std::path::Path::new(&site_path),
                Line(site_line),
            );
            // ONE CALL ARGUMENT, AND IT IS THE CONTRACT ADDRESS. M26's rule for the public half, for
            // its reason: it is what makes a frame attributable in a reader without stepping into it.
            let type_id = TraceSink::ensure_type_id(&mut sink, TypeKind::String, "AztecAddress");
            let arg = TraceSink::arg(
                &mut sink,
                "contractAddress",
                ValueRecord::String { text: frame_spec.contract_address.clone(), type_id },
            );
            TraceSink::register_call(&mut sink, function_id, vec![arg]);
            open_frames.push(frame_spec.function.clone());
        }

        let steps_before = sink.steps.len();

        let inner = DefaultDebugForeignCallExecutor::from_artifact(
            std::io::sink(),
            None,
            &loaded.debug,
            None,
            String::new(),
        );
        let executor = Box::new(TapeExecutor {
            inner,
            tape,
            served_calls,
            cursor: 0,
            ledger: vec![],
            refused: vec![],
        });
        // The executor is moved into the tracer, so its ledger comes back out through a shared handle
        // rather than by reading it afterwards. The handles are the TRANSACTION's: a per-frame ledger
        // would make "which oracle stopped this transaction" a question with one answer per frame.
        let executor = Box::new(Reporting {
            inner: *executor,
            ledger: std::rc::Rc::clone(&ledger),
            refused: std::rc::Rc::clone(&refused),
        });

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
            Some(executor),
        );

        // THE SECOND PASS: THE ACVM'S OWN OPCODE COUNT, over the same circuit and the same tape.
        //
        // A step record is emitted when the SOURCE LOCATION changes, not when an opcode is solved, so
        // "the tracer produced N steps" and "the circuit is N opcodes long" are different numbers and
        // comparing them directly would be comparing two things nobody said were equal. What CAN be
        // compared is a step count against the number of opcodes that carry a source location at all —
        // and taking that number needs the same stepper the tracer drives, run over the same
        // execution. `DebugContext` is public and `step_into_opcode` is its own loop body, so this is
        // the tracer's inner loop with the recording removed.
        let (opcodes_stepped, opcodes_positioned, positions_distinct, call_stack_positioned) = {
            let mut witness2 = WitnessMap::<FieldElement>::new();
            for (index, hex) in &witness_entries {
                witness2.insert(Witness(*index), field_of(hex, "initial witness").expect("witness"));
            }
            let inner2 = DefaultDebugForeignCallExecutor::from_artifact(
                std::io::sink(),
                None,
                &loaded.debug,
                None,
                String::new(),
            );
            let exec2 = Box::new(TapeExecutor {
                inner: inner2,
                tape: tape_for_second_pass,
                served_calls,
                cursor: 0,
                ledger: vec![],
                refused: vec![],
            });
            let solver2 = Bn254BlackBoxSolver::default();
            let mut ctx = DebugContext::new(
                &solver2,
                &loaded.program.functions,
                &loaded.debug,
                witness2,
                exec2,
                &loaded.program.unconstrained_functions,
            );
            let mut stepped = 0usize;
            let mut positioned = 0usize;
            let mut call_stack_positioned = 0usize;
            let mut seen: Vec<String> = vec![];
            loop {
                if ctx.get_current_debug_location().is_none() {
                    break;
                }
                if let Some(locations) = ctx.get_current_source_location() {
                    positioned += 1;
                    if let Some(last) = locations.last() {
                        seen.push(format!("{:?}:{}", last.file, last.span.start()));
                    }
                }
                // THE TRACER READS THE CALL STACK, NOT THE CURRENT LOCATION, and the two can
                // disagree — `TracingContext::step_debugger` proceeds on
                // `get_current_source_location()` and then records what
                // `get_call_stack()` resolves to, skipping the step when that is empty. Both are
                // counted so a step count of zero over a positioned execution names which of the two
                // was empty rather than leaving a reader to guess.
                if ctx
                    .get_call_stack()
                    .iter()
                    .any(|l| !ctx.get_source_location_for_debug_location(l).is_empty())
                {
                    call_stack_positioned += 1;
                }
                match ctx.step_into_opcode() {
                    DebugCommandResult::Ok => stepped += 1,
                    _ => {
                        stepped += 1;
                        break;
                    }
                }
                if stepped > 5_000_000 {
                    break;
                }
            }
            seen.sort();
            seen.dedup();
            (stepped, positioned, seen.len(), call_stack_positioned)
        };


        all_tape_entries += tape_len_before;
        all_served += served_calls;
        all_opcodes_stepped += opcodes_stepped;
        all_opcodes_positioned += opcodes_positioned;
        all_positions_distinct += positions_distinct;
        all_call_stack_positioned += call_stack_positioned;
        all_witness_entries += witness_entries.len();
        acir_opcodes_total += loaded.acir_opcodes;
        brillig_total += loaded.brillig_functions;
        bytecode_total += loaded.bytecode_bytes;
        file_map_total += loaded.file_map_entries;
        trace_results.push(match &result { Ok(()) => "ok".to_string(), Err(e) => e.to_string() });

        let frame_steps: Vec<(String, i64, Option<i64>)> = sink.steps[steps_before..].to_vec();
        frame_reports.push(serde_json::json!({
            "artifact": frame_spec.artifact,
            "function": frame_spec.function,
            "depth": frame_spec.depth,
            "contractAddress": frame_spec.contract_address,
            "tapeFrame": frame_spec.tape_frame,
            "callSite": if frame_spec.depth > 0 { serde_json::json!(declaration_site(&loaded).0) } else { serde_json::Value::Null },
            "tapeEntriesRecorded": tape_len_before,
            "servedCallsInRecording": served_calls,
            "acirOpcodes": loaded.acir_opcodes,
            "brilligFunctions": loaded.brillig_functions,
            "bytecodeBytes": loaded.bytecode_bytes,
            "fileMapEntries": loaded.file_map_entries,
            "initialWitnessEntries": witness_entries.len(),
            "traceResult": match &result { Ok(()) => "ok".to_string(), Err(e) => e.to_string() },
            "steps": frame_steps.len(),
            "opcodesStepped": opcodes_stepped,
            "opcodesPositioned": opcodes_positioned,
            "distinctPositions": positions_distinct,
            "opcodesWithPositionedCallStack": call_stack_positioned,
            "distinctLines": distinct_lines(&frame_steps),
            "stepPaths": step_paths(&frame_steps),
            "firstSteps": frame_steps.iter().take(5).map(|(p, l, c)| format!("{p}:{l}:{}", c.map(|c| c.to_string()).unwrap_or_else(|| "-".into()))).collect::<Vec<_>>(),
            "stepsWithColumn": frame_steps.iter().filter(|(_, _, c)| c.is_some()).count(),
        }));
    }

    // EVERY FRAME THE LIST OPENED IS CLOSED, in reverse. A container whose frames never return ends
    // at a non-zero depth, and `ct_call_depth` / `ct_calls_opened` exist because a recording with no
    // frames and one whose frames all closed both end at depth 0 — so both are asserted, not one.
    while open_frames.pop().is_some() {
        TraceSink::register_return(&mut sink, ValueRecord::None { type_id: NONE_TYPE_ID });
    }

    let finish = finish_trace(&mut sink);

    let container = std::fs::read_dir(&spec.out_dir)
        .ok()
        .and_then(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| e.path())
                .find(|p| p.extension().is_some_and(|x| x == "ct"))
        })
        .map(|p| p.display().to_string());

    // THE TOP-LEVEL FIGURES ARE THE TRANSACTION'S, AND FOR ONE FRAME THEY ARE THAT FRAME'S. Every
    // one is a sum or a whole-container reading, so a single-frame run reports exactly the numbers
    // it reported before this loop existed — which is what keeps M38's own checks unmoved.
    let out = serde_json::json!({
        "arm": spec.arm,
        "artifact": frames[0].artifact,
        "function": frames[0].function,
        "program": program_name,
        "frameCount": frames.len(),
        "maxDepth": frames.iter().map(|f| f.depth).max().unwrap_or(0),
        "frames": frame_reports,
        "tapeEntriesRecorded": all_tape_entries,
        "servedCallsInRecording": all_served,
        "acirOpcodes": acir_opcodes_total,
        "brilligFunctions": brillig_total,
        "bytecodeBytes": bytecode_total,
        "fileMapEntries": file_map_total,
        "initialWitnessEntries": all_witness_entries,
        "traceResult": if trace_results.iter().all(|r| r == "ok") { "ok".to_string() } else { trace_results.join(" | ") },
        "finish": match &finish { Ok(()) => "ok".to_string(), Err(e) => e.to_string() },
        "steps": sink.steps.len(),
        "stepsWithColumn": sink.steps.iter().filter(|(_, _, c)| c.is_some()).count(),
        "opcodesStepped": all_opcodes_stepped,
        "opcodesPositioned": all_opcodes_positioned,
        "distinctPositions": all_positions_distinct,
        "opcodesWithPositionedCallStack": all_call_stack_positioned,
        "distinctLines": distinct_lines(&sink.steps),
        "stepPaths": step_paths(&sink.steps),
        "firstSteps": sink.steps.iter().take(5).map(|(p, l, c)| format!("{p}:{l}:{}", c.map(|c| c.to_string()).unwrap_or_else(|| "-".into()))).collect::<Vec<_>>(),
        "registeredPaths": sink.paths.len(),
        "calls": sink.calls,
        "returns": sink.returns,
        "traceErrors": sink.errors,
        "oracleLedger": *ledger.borrow(),
        "refusedOracles": *refused.borrow(),
        "container": container,
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

/// Copies the inner executor's ledger out as it goes, because the executor itself is moved into
/// the tracer and cannot be read afterwards.
struct Reporting<D> {
    inner: TapeExecutor<D>,
    ledger: std::rc::Rc<std::cell::RefCell<Vec<Answered>>>,
    refused: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
}

impl<D: TraceForeignCallExecutor> ForeignCallExecutor<FieldElement> for Reporting<D> {
    fn execute(
        &mut self,
        call: &ForeignCallWaitInfo<FieldElement>,
    ) -> Result<ForeignCallResult<FieldElement>, ForeignCallError> {
        let before = self.inner.ledger.len();
        let out = self.inner.execute(call);
        for entry in self.inner.ledger.drain(before..) {
            self.ledger.borrow_mut().push(entry);
        }
        self.refused.borrow_mut().clear();
        self.refused
            .borrow_mut()
            .extend(self.inner.refused.iter().cloned());
        out
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
