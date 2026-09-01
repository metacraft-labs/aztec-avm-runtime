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

// ---------------------------------------------------------------------------
// The spec the driver hands over.
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct Spec {
    /// `replay` — answer from the tape. `refuse-all` — an empty tape, so the first oracle refuses.
    /// `truncate` — drop the last tape entry, so the frame runs out mid-way.
    arm: String,
    /// The Aztec contract artifact, as installed.
    artifact: String,
    /// The private function inside it.
    function: String,
    /// The M35 arm report to take the tape and the initial witness from.
    tape_source: String,
    /// A JSON path into that report, `a.b.c`, naming the frame.
    tape_frame: String,
    /// Where the `.ct` container goes.
    out_dir: String,
}

#[derive(Clone, serde::Deserialize)]
struct TapeEntry {
    seq: usize,
    oracle: String,
    inputs: Vec<Vec<String>>,
    outputs: Vec<Vec<String>>,
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
        for (slot_index, slot) in entry.outputs.iter().enumerate() {
            let mut fields = Vec::with_capacity(slot.len());
            for hex in slot {
                match field_of(hex, &format!("{name} output slot {slot_index}")) {
                    Ok(f) => fields.push(f),
                    Err(reason) => return Err(self.refuse(&name, reason)),
                }
            }
            values.push(if fields.len() == 1 {
                acvm::acir::brillig::ForeignCallParam::Single(fields[0])
            } else {
                acvm::acir::brillig::ForeignCallParam::Array(fields)
            });
        }

        self.ledger.push(Answered {
            seq: self.cursor,
            oracle: name.clone(),
            outcome: "replayed",
            reason: format!("{} output slot(s) from the tape", entry.outputs.len()),
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
    let acir_opcodes = program.functions.iter().map(|c| c.opcodes.len()).sum();
    Ok(Loaded {
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

fn json_at<'a>(v: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let mut cur = v;
    for part in path.split('.') {
        cur = cur.get(part)?;
    }
    Some(cur)
}

fn main() {
    let spec_path = std::env::args()
        .nth(1)
        .expect("usage: m38probe <spec.json>");
    let spec: Spec = serde_json::from_reader(std::fs::File::open(&spec_path).unwrap()).unwrap();

    let loaded = match load(&spec.artifact, &spec.function) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("m38probe: {e}");
            std::process::exit(2);
        }
    };

    let report: serde_json::Value =
        serde_json::from_reader(std::fs::File::open(&spec.tape_source).unwrap()).unwrap();
    let frame = json_at(&report, &spec.tape_frame)
        .unwrap_or_else(|| panic!("no frame at `{}` in {}", spec.tape_frame, spec.tape_source));

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

    std::fs::create_dir_all(&spec.out_dir).expect("out dir");

    let error_types: BTreeMap<acvm::acir::circuit::ErrorSelector, noirc_abi::AbiErrorType> =
        BTreeMap::new();

    let mut writer = create_trace_writer(&spec.function, &[], TraceEventsFileFormat::Ctfs);
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
    begin_trace(&mut sink, &spec.out_dir, &spec.function, None);

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
    // rather than by reading it afterwards.
    let ledger = std::rc::Rc::new(std::cell::RefCell::new(Vec::<Answered>::new()));
    let refused = std::rc::Rc::new(std::cell::RefCell::new(Vec::<String>::new()));
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
        &error_types,
        &options,
        &mut sink,
        Some(executor),
    );

    let finish = finish_trace(&mut sink);

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

    let container = std::fs::read_dir(&spec.out_dir)
        .ok()
        .and_then(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| e.path())
                .find(|p| p.extension().is_some_and(|x| x == "ct"))
        })
        .map(|p| p.display().to_string());

    let out = serde_json::json!({
        "arm": spec.arm,
        "artifact": spec.artifact,
        "function": spec.function,
        "tapeEntriesRecorded": tape_len_before,
        "servedCallsInRecording": served_calls,
        "acirOpcodes": loaded.acir_opcodes,
        "brilligFunctions": loaded.brillig_functions,
        "bytecodeBytes": loaded.bytecode_bytes,
        "fileMapEntries": loaded.file_map_entries,
        "initialWitnessEntries": witness_entries.len(),
        "traceResult": match &result { Ok(()) => "ok".to_string(), Err(e) => e.to_string() },
        "finish": match &finish { Ok(()) => "ok".to_string(), Err(e) => e.to_string() },
        "steps": sink.steps.len(),
        "opcodesStepped": opcodes_stepped,
        "opcodesPositioned": opcodes_positioned,
        "distinctPositions": positions_distinct,
        "opcodesWithPositionedCallStack": call_stack_positioned,
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
