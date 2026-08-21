# Tier E, family 2 — CodeTracer trace output

**Authored. Upstream produces no trace artefact of any kind, so there is nothing to compare a
recording against.** The claims below are re-verified against the pinned fork on every run by
`verify_tier_e_authored_fixtures_justified`.

Fixtures here are written under **M24** (the `.ct` writer binding) and **M25** (step-level tracing
from the observation hook). What M2 owes is the entry and its justification.

## What upstream DOES have, and why none of it is a trace

Enumerated rather than summarised, because "upstream has no equivalent" is the claim most likely to
be false by omission.

| upstream seam | what it is | why it is not a trace |
|---|---|---|
| `yarn-project/simulator/src/public/side_effect_trace.ts` — `PublicSideEffectTraceInterface` | 15 methods recording transaction-level side effects, forked and merged in lockstep with the state manager. | Transaction-level, for limit enforcement. No instruction, no program counter, no memory. |
| `yarn-project/simulator/src/public/avm/avm_simulator.ts:177` — `tallyInstructionFunction` | Called once per instruction. | Its whole signature is `(_b: string, _c: Gas) => {}` (`avm_simulator.ts:41`): a class *name* and a gas delta. No operands, no memory, no PC. It is a metrics tally. |
| `yarn-project/simulator/src/public/avm/avm_simulator.ts` per-step log line | A `[PC:…] [IC:…]` line at trace level. | Goes to a logger, not to an artefact, and is not in any stable format. |
| `barretenberg/cpp/src/barretenberg/vm2/simulation/events/execution_event.hpp` — `ExecutionEvent` | A genuine per-instruction record, emitted into `EventEmitterInterface<ExecutionEvent>`. | In-memory only, drained into tracegen for proving. Nothing serialises it, and the fast `HybridExecution` path we actually run never emits it (REUSE-INVENTORY.md RI-08). |
| `barretenberg/cpp/src/barretenberg/vm2/tooling/debugger.cpp` | An interactive REPL over circuit rows. | `#ifndef NDEBUG`, interactive, and about circuit rows rather than execution steps. |
| `DumpingPublicTxSimulator` → `avm-circuit-inputs-tx-<hash>.bin` | The one thing upstream *does* write to disk per transaction. | msgpack **prover inputs** for proving benchmarks (see `yarn-project/end-to-end/bootstrap.sh:269`), not an execution trace: it is the input to proving, not a record of what executed. |

## The three claims that make this family necessary

1. **Upstream ships no trace file of any kind.** `git ls-tree -r --name-only <cpp anchor>` finds
   **zero** files with a `.ct` extension anywhere in aztec-packages. There is no golden trace to
   compare against because there is no producer. (Claim id: `no-ct-artifacts-upstream`.)

2. **The one per-instruction TypeScript hook carries no trace-shaped data.**
   `yarn-project/simulator/src/public/avm/avm_simulator.ts:41` declares
   `private tallyInstructionFunction = (_b: string, _c: Gas) => {};` — the entire payload is a
   string and a `Gas`. A trace needs at minimum the program counter and the operands, and this seam
   cannot carry them however it is wired. (Claim id: `tally-hook-carries-name-and-gas-only`.)

3. **The per-instruction C++ observer we drive is OURS, not upstream's.**
   `barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp` **does not
   exist** at the `cpp` anchor; `git cat-file -e` on it fails. It is the spike's addition, and M9
   prepares it as an upstream contribution shaped after the existing
   `CallStackMetadataCollectorInterface`. Until it lands, any trace fixture written against it is a
   fixture for our fork. (Claim id: `execution-observer-not-upstream`.)

## Fixtures to author (M24, M25)

Written for a small pinned set of transactions — the minimal `SET`/`SET`/`ADD`/`RETURN` tx, one
Token transfer, one reverting tx, one nested external call — each producing a golden `.ct`
recording checked four ways:

| check | what it asserts | why it is worth having |
|---|---|---|
| reader round-trip | the recording parses with `codetracer-trace-format`'s own reader | the format tooling is ours and already exists (RI-42), so this costs nothing |
| `ct-print --full` comparison | the rendered trace equals the checked-in golden | catches format drift, which is the failure mode a binary round-trip misses |
| **step count equals the engine's own instruction tally** | the recorded step count equals the AVM's `total_instructions_executed` statistic | the cheap, self-checking one: it cross-checks the tracer against a number the engine already computes independently, so it cannot be satisfied by an empty or padded trace |
| side-effect agreement | the side-effect events in the trace match `PublicTxResult.publicTxEffect` | ties the trace to the result the differential oracle already compares |

The third is deliberately the load-bearing one. A trace fixture that only asserts "a file was
written and it parses" is exactly the tagged-but-content-free failure this campaign has already
been caught by once.

## The structural risk, recorded rather than discovered later

Both TypeScript seams live **inside** the TypeScript interpreter. If the interpreter is the C++/wasm
AVM — which it is, per RI-01 — `tallyInstructionFunction` does not survive the swap at all, because
there is no TypeScript loop to hook. Any trace fixture written against the TypeScript interpreter is
implicitly a fixture for *that* interpreter. The fixtures above are therefore to be written against
**both** seams, so the two interpreters can be compared step for step, and so the C++ observer's
non-perturbation (`sameResult` between an observed and an unobserved run, already asserted by
`avm_run.cpp`'s `StepRecorder`) stays checked.

## Licence

Authored here. `codetracer-trace-format` is ours (RI-42).
