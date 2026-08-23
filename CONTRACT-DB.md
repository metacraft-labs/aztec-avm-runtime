# The shippable contract DB, and who owns the two checkpoint stacks

The world-state half of the AVM's host surface has been Aztec's since M6: `MemoryMerkleDB` over
`world_state_reference`, already running in wasm. The contract-DB half was not yet exercised in the
shape we would ship, and the two halves have independent checkpoint stacks that must move together.
Both are closed here.

Everything below is **measured**, from a tree built by `verification/lib_m13_contract_db.sh` out of
the pinned anchor `233d8e0993` plus ten patches: M12's nine and M13's own overlay. Reproduce with
`just verify-m13`.

## The reuse question, answered by enumeration

### The enumeration

One regular expression over the whole fork at the anchor, re-run by
`verify_contract_db_reuse_decision_recorded` on every run rather than kept as a list:

```
class [A-Za-z_]+ (final )?: public ([A-Za-z0-9_]+::)*ContractDBInterface
```

**Eight implementations.** The milestone's own text names three.

| # | class | where | kind |
|---|---|---|---|
| 1 | `ContractDB` | `vm2/simulation/gadgets/concrete_dbs.hpp` | **decorator**, event-emitting, over a raw one |
| 2 | `PureContractDB` | `vm2/simulation/standalone/concrete_dbs.hpp` | **decorator**, event-free, over a raw one |
| 3 | `HintingContractsDB` | `vm2/simulation/lib/hinting_dbs.hpp` | **decorator** that records hints as it forwards |
| 4 | `HintedRawContractDB` | `vm2/simulation/lib/raw_data_dbs.hpp` | raw, in-memory, backed by a transaction's `ExecutionHints` |
| 5 | `MockContractDB` | `vm2/simulation/testing/mock_dbs.hpp` | gmock |
| 6 | `TestContractDB` | `vm2/testing/public_tx_simulation_tester.hpp` | raw, in-memory |
| 7 | `FuzzerContractDB` | `avm_fuzzer/common/interfaces/dbs.hpp` | raw, in-memory |
| 8 | `CdbIpcContractDB` | `cdb/cdb_ipc_client.hpp` | raw, native, IPC transport adapter |

**Number 7 is the one the milestone's framing does not mention**, and it is the omission-by-
enumeration this campaign has now made six times. `avm_fuzzer/` is a *barretenberg subdirectory*,
not anything under `vm2/`, so an enumeration that walked `vm2/` misses it — and it is the only place
in upstream's C++ where a contract-deployment log is decoded at all, which turned out to be the
single most useful thing the enumeration found.

### Why each candidate is or is not fit, with the fact rather than the impression

Every one of these is re-derived from the fork at the anchor by the check, not quoted from here.

**`TestContractDB` cannot ship**, and not on grounds of taste. Two of this milestone's six
deliverables are *unimplementable* against it:

- `add_contracts` has an **empty body** — "Not used: tests deploy directly via add_contract_class /
  add_contract_instance". Deliverable 2 asks for contract-class and instance registrations observed
  during execution through `add_contracts`; against this store there are none, ever, and a
  transaction that publishes a class and then calls into it cannot work.
- `get_debug_function_name` is `return std::nullopt;` unconditionally. Deliverable 3 asks for it to
  be wired properly; against this store every trace frame M25 ever produces is labelled
  `<selector: 0x…>`.

It also drags `vm2/testing/` — and `PublicTxSimulationTester`, which owns a second `MemoryMerkleDB`
— into the link closure of a browser artefact, for one class.

**`FuzzerContractDB` implements both**, which is exactly why it had to be enumerated. It is still
not shippable, for a build-graph reason: its module is `if(FUZZING_AVM)`-gated and declared
`barretenberg_module_with_sources(avm_fuzzer … DEPENDENCIES vm2)` — the *proving* `vm2`, which is
the module M6's forbidden list exists to keep out.

And its decoder is **wrong**. `from_logs(const PrivateLog&)` reads the instance log as
`(tag, version, contract address, salt, …)` — its own comment says so — where upstream's
`ContractInstancePublishedEvent.fromLog` writes `(tag, address, version, salt, …)`. It therefore
takes the *version* for the address, then walks straight from `initializationHash` into the public
keys, taking `immutablesHash` for `npkMHash` and stopping two fields short of the seven `PublicKeys`
has. Nothing catches it because the fuzzer publishes and consumes its own logs, so its encoder and
its decoder are wrong together. `e2e_deploy_call_revert_roundtrip` uses that layout as a **negative
control**: applied to the same bytes it must disagree with upstream's reader, or the agreement it
asserts would hold for any layout at all.

**`CdbIpcContractDB` is upstream's shippable raw one, and it is not a store.** It is a transport
adapter: `cdb_ipc_client` links `barretenberg` and `ipc_runtime`, and on the far side of the socket
`yarn-project/simulator/src/public/cdb_ipc_server.ts` serves all eight methods out of the TypeScript
`PublicContractsDB`. So *upstream's shippable raw contract DB is TypeScript*, reached over a unix
socket that a browser does not have. That is the most important single fact in this enumeration, and
it is asserted by counting the eight handler methods in that file rather than by reading the
architecture.

**`HintedRawContractDB` is raw, in-memory and wasm-reachable** — it is already inside `avm.wasm`,
because `avm_simulate_with_hinted_dbs` uses it. It cannot serve here for a reason that is about what
it is for: it answers only what a *previous hint-collecting run* already asked, and
`add_contracts` on it is `[[maybe_unused]]`. It is the replay half of a two-pass simulation, not a
store.

**`PureContractDB` is a decorator, not a store**: `ContractDBInterface& raw_contract_db;`. At the
anchor it was the *only* `ContractDBInterface` in `simulation/standalone/`, a directory whose name
records that it is deliberately dependency-free — a decorator with nothing to decorate.

### The three dispositions

- **ship TestContractDB as it is** — rejected on the two unimplementable deliverables above, and on
  the `vm2/testing/` link closure.
- **upstream an in-memory store under `standalone/` beside `PureContractDB`** — taken.
- **write one of our own** — rejected. It would be a *third* copy of the same little map-backed
  store, in our tree, whose drift we would own forever. The eight methods are small enough that
  writing them is not the cost; keeping them correct against a moving `ContractClass`,
  `ContractInstance` and published-event layout is, and that cost is exactly what the campaign's
  governing principle exists to avoid.

**DECISION: upstream it.** `simulation::MemoryContractDB` in
`vm2/simulation/standalone/memory_contract_db.{hpp,cpp}`, beside the decorator that needs a raw one,
in Aztec's module and in a shape they could take.

### What it adds over the two existing copies

Each of the three is a behaviour they get *wrong*, not a feature they lack — which is what makes the
contribution arguable on upstream's own terms rather than on ours:

1. **`add_contracts` is implemented**, against the field layouts the TypeScript publishers define.
2. **`get_debug_function_name` answers from registered `DebugFunctionNameHint`s** — upstream's own
   type, the one `ExecutionHints` already carries and `HintedRawContractDB` already consumes — so a
   consumer with hints and a consumer with artifacts populate the same store with the same type.
3. **Committing or reverting with no checkpoint open throws**, with the TypeScript
   `PublicContractsDB`'s own two messages, `No checkpoint to commit` and `No checkpoint to revert`.
   Both existing copies return silently, which turns an unbalanced sequence into a plausible-looking
   wrong state instead of an error.

It also exposes `get_checkpoint_id()` with the same semantics `LowLevelMerkleDBInterface` already
declares — a stack seeded with 0, `parent + 1` pushed on create — so a coordinating owner compares
two integers for **equality** instead of inferring agreement from two vocabularies.
`ContractDBInterface` does not declare that method and this does not add it there: doing so would
oblige all eight implementations, and it is the one change to that interface worth proposing on its
own.

### What has NOT been done

The store is written in Aztec's module and in a shape they could take, and it is **not** prepared as
a sixth upstream contribution. Filing one needs a published branch on the fork and a sixth entry in
`carry/series.json`, and M13 opens no pull requests and pushes nothing. It is carried as the tenth
overlay under `verification/m13/`, exactly as M12's reactor overlay is carried. See "Outstanding
Tasks" in the milestone.

## Checkpoint coordination

### The problem, precisely

`ContractDBInterface` and `LowLevelMerkleDBInterface` each declare their own `create_checkpoint`,
`commit_checkpoint` and `revert_checkpoint`, and nothing in either type relates one to the other.

*Inside* a transaction the pairing is upstream's and we do not second-guess it:
`TxExecution::simulate` runs `merkle_db.create_checkpoint(); contract_db.create_checkpoint();` at the
end of setup and the matching pairs on the app-logic and teardown paths — five paired sites in
`tx_execution.cpp`. What it does **not** pair is the per-call-frame checkpoint: `ContextProvider` and
`Execution` open and close one on the *merkle db alone*, deliberately, because a nested call can
write storage and cannot publish a contract class.

So the two stacks are **not at equal depth part-way through a transaction**, and a check that
asserted they were would be wrong. The gap is *outside* a simulation, where a consumer opens a
checkpoint per transaction or per block across both DBs itself.

### The owner

`simulation::CheckpointCoordinator`, beside the store. One `create_checkpoint` here is one on each
DB; likewise commit and revert. The `ContractDBInterface&` it hands out is a **`PureContractDB`
decorator over the store, never the store itself**, so a consumer inherits whatever that decorator
does today and whatever it grows to do — deliverable 5, structurally rather than by convention.

And because "they were driven together" is a claim about a program rather than about a state, it
carries the state form too: `assert_lockstep()` compares **three integers that must be equal** — its
own depth, the contract DB's checkpoint id, the merkle DB's — before and after every operation, and
names *which side* moved when they are not. "They disagree" sends a reader to both stacks, and one
of the two is always innocent.

It also refuses to underflow. `world_state::MemoryMerkleDB::commit_checkpoint` pops a `std::stack`
without testing it, so the coordinator's depth guard is what stands between a host and undefined
behaviour in upstream's code.

### The injected desynchronisation, and the wrong state it otherwise produces

`test_checkpoint_lockstep_contract_and_merkle` runs the **same injection twice**.

Through the coordinator, one extra `avm_merkle_db_create_checkpoint` behind its back gives:

```
checkpoint stacks are not in lockstep: the MERKLE db stack moved outside the coordinator
(coordinator=1 contractDb=1 merkleDb=2)
```

— and every subsequent coordinated create, revert and simulate refuses. The mirror injection on the
contract side produces the mirror message, and the check asserts that each names *only* its own
side.

Driven by hand, as a consumer without a coordinating owner would, the same injection produces this:

| | |
|---|---|
| the injection moved the trees | yes |
| the hand-driven transaction registered a contract | yes |
| the contract DB unwound exactly as expected | **yes** |
| the trees returned to where the transaction found them | **no** |
| the trees returned to the *injected* level instead | **yes** |
| contract DB checkpoint id / merkle DB checkpoint id | **0 / 1** |
| any call returned an error | **no** |
| any root is malformed | **no** |

That is the failure this milestone exists to prevent, produced deliberately so that "detected rather
than producing a plausible-looking wrong state" is a comparison of two measured runs rather than an
assurance. A coordinator placed over that same state catches it immediately.

## The two population paths

Deliverable 2 asks for both, and they are checked against each other rather than one being defined
as the other:

- **explicit registration** — `avm_contract_db_register_class` / `_register_instance` /
  `_register_debug_function_names`, for a consumer that already holds the artifacts;
- **observed during execution** — `add_contracts`, which upstream's own `TxExecution` calls with
  `tx.non_revertible_contract_deployment_data` and `tx.revertible_contract_deployment_data`.

`test_contract_db_eight_methods_covered` populates two stores, one each way, and compares every
answer: class id, artifact hash, private-functions root, the packed bytecode byte for byte, the
instance's salt, deployer, `immutablesHash` and all seven public keys — including `mspkMHash` and
`fbpkMHash`, the two the fuzzer's decoder never reaches. The bytecode commitment is *computed* from
the decoded bytecode on the observed side, by the same function the TypeScript publisher uses, and
must equal the one the tester supplied on the registered side.

### The wire format is upstream's, established across the language boundary

The decoders in `MemoryContractDB` are written from `contract_class_published_event.ts` and
`contract_instance_published_event.ts`, and that is not sufficient: an encoder and a decoder written
from the same page agree with each other and prove nothing. So the driver prints the raw log
**fields**, and `diffsim/decode_deployment_logs.mjs` decodes those same fields with upstream's own
`ContractClassPublishedEvent.fromLog` and `ContractInstancePublishedEvent.fromLog` from the pinned
npm packages.

**7 programs, 112 field comparisons, 0 mismatches.**

The fixed-size padding a real contract-class log carries is restored on the TypeScript side from
upstream's own `CONTRACT_CLASS_LOG_SIZE_IN_FIELDS`, rather than from a number written down here;
3,023 hex lines per program in the transcript would have bought no information.

## The debug function name, wired rather than stubbed

`get_debug_function_name` already exists on `ContractDBInterface`, so the names on M25's frames come
from upstream. Three things are asserted, and the third is the one that matters:

1. **The names are the artifacts'.** Derived by rule from `fixtures/contracts/artifacts.json` —
   itself generated from the six compiled Noir contracts by `diffsim/check_contract_artifacts.mjs` —
   and checked in both directions: every name the DB returns is a public function the corpus calls on
   the artifact it names, and the list is what the rule derives rather than one that was typed.
2. **The type is upstream's.** `DebugFunctionNameHint { address, selector, name }`, with
   `SERIALIZATION_FIELDS(address, selector, name)`, already inside `ExecutionHints` and already
   consumed by `HintedRawContractDB`. Nothing of ours crosses.
3. **The name reaches the frame label.** `TxExecution::get_debug_function_name` reads `calldata[0]`
   as a selector, asks the contract DB, and falls back to `<selector: …>` when there is no name. The
   corpus is run **twice**, and the two arms are the discrimination:

| arm | frame labels carrying the artifact's name | labels falling back to a selector |
|---|---|---|
| names registered | **7** | **0** |
| names not registered | **0** | **7** |

The second row is what `TestContractDB` would have produced for every frame, forever.

The name is part of the **checkpointed** state: registered inside a checkpoint and reverted, it is
gone. A debug name that survived a revert would leak one transaction's state into the next.

## The module surface after the decision

| | M12 | M13 |
|---|---|---|
| exports | 39 | **49** |
| imports | 12 (11 WASI + `env.memory`) | **12, the same twelve name for name** |
| `avm.wasm` raw | 1,565,773 | **1,591,391** |
| `avm.wasm.gz` | 350,104 | **357,558** |
| translation units in the reactor target | 6 (`avm_reactor.cpp` + five from `vm2/testing/`) | **1** |

The ten new exports are `avm_contract_db_get_checkpoint_id`,
`avm_contract_db_register_debug_function_names`, and eight `avm_coordinator_*`: `create`, `destroy`,
`create_checkpoint`, `commit_checkpoint`, `revert_checkpoint`, `checkpoint_ids`, `assert_lockstep`
and `simulate`. Every one of M12's thirty-nine survives, asserted by name.

**The artefact grew by 25,618 bytes raw and 7,454 gzipped, and the write-up says so rather than
claiming a saving.** Dropping `vm2/testing/` removes five translation units from the reactor's link
closure; the store, the coordinator, `PureContractDB`'s own translation unit and ten more exported
roots cost more than that saves. The check reports the delta and requires its SIGN to be the one
stated here, which is the assertion a growth deserves; the magnitude is not pinned, because `-Oz`
output moves with a toolchain bump and pinning it would fail a correct build. It is still comfortably inside M12's budget of 1,800,000 raw and 400,000 gzipped — the budget
chosen so that *both* link-option controls fail it — and that budget is deliberately unchanged here:
raising a budget to fit a measurement is how a budget stops being one.

**The import surface did not move.** That is the claim worth making: a contract DB that decodes
published-event logs, computes bytecode commitments and holds a name map cost the artefact **not one
new host import**. Asserted by name against M12's twelve, not by count.

The per-DB checkpoint exports are deliberately **still there**. They are eight-of-eight and
fourteen-of-fourteen of the two interfaces, and a module that removed three of each could no longer
say its export list is the interface. They are also what an injected desynchronisation uses, and what
the coordinator then catches.

## Upstream's own suite

The store's own tests are `.test.cpp` beside it, so `AVM_SIM_TESTS`'s recursive glob picks them up
and they are built by barretenberg's own module machinery into `vm2_sim_tests` — which is the shape
upstream would take rather than a runner of ours. **Twelve tests**, and the check establishes that
number by listing the binary twice, once whole and once with the two new suites filtered out, so no
constant here can go stale. The whole binary passes with the overlay applied, and the number that
passes is required to equal the number the binary carries.

Measured: **403 tests native, 391 of them upstream's, 12 the overlay's, 0 failures.**

*That 391 is not M7's 391 and must never be quoted as it.* M7's figure is the number of tests in
`vm2_sim_tests` that RUN UNDER WASM after its enumerated exclusions; this one is the native binary's
total with the overlay's two suites filtered out. The two happening to coincide on this tree is a
coincidence, and it is written down here so that nobody later reads the agreement as a measurement.

## Coverage, stated so no number here can be quoted as another milestone's

The corpus is the **same seven hand-assembled programs** M8 and M12 compare, driven this time
through the contract DB's own surface. That is an integration check across a boundary. Breadth is
M7's 391 upstream tests; semantics is M19's 77-comparison oracle. The seven contracts are
pseudo-deployments of hand-assembled bytecode and have **no compiled artifact of their own** — the
function names they are given come from the six real Noir artifacts, which is what makes "the names
match the artifacts" checkable, but the *contracts* are not those artifacts and nothing here should
be read as exercising Token or AMM.

Only `x86_64-linux` was exercised, as in M6 through M12.

## CI

`.github/workflows/avm-wasm.yml` carries a fourth job, `avm-contract-db`, running `just verify-m13`
in its own `M13_WORK` — a different directory from the reactor job's, so neither can answer for the
other.

**It has never run.** Neither has any other job in that workflow: they all still abort at
`Generate CI token` on "Input required and not supplied: app-id", which M11 recorded as undiagnosed
after the `vars.` spelling did not fix it. So this job existing means it is wired and names the
check — not that a run has ever gated anything.
