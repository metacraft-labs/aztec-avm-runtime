# Private execution — what runs, what refuses, and what the refusals are worth

M35's write-up.

**Every figure in §1's registry counts, §2's vendoring table, §3's partition, §4's two frames and
§6's packaging table is re-derived from the artefacts and compared AGAINST THIS FILE on every run**,
by `verify_oracle_coverage_is_measured` §8 — each looked for on the line that NAMES ITS SUBJECT
rather than anywhere in the file, and each matched as a DELIMITED figure on that line rather than as
a run of characters anywhere in it. Both halves of that sentence were earned by somebody else: the
row anchoring is M24's review's remedy after a document stated the reverse of its own data with every
figure present, and the field anchoring is M33's review's, which found two of nineteen figures that
could not fail because `245.87` supplies an `8` and `0` is a substring of every number containing a
zero digit.

---

## 1. THE REGISTRY: 68, RE-DERIVED, WITH A CONTROL THAT DECLARES 53

**Owned by `verify_oracle_coverage_is_measured` §1–§3.**

The milestone's fifth deliverable is *"the registry count re-derived, never remembered"*, and RI-65
says why in one sentence: **the `upstream/tsavm` worktree that is already checked out declares 53
entries against the anchor's 68**, and carries neither `acir_callback.ts` nor
`legacy_oracle_registry.ts`. Vendoring from the tree that happens to be on disk — the way RI-25
vendored the simulator files — would have shipped a 53-oracle surface against 68-oracle bytecode.

| | derived |
|---|---|
| entries in `ORACLE_REGISTRY` at the `cpp` anchor | **68** |
| of which `misc` | **3** |
| of which `utl` | **49** |
| of which `prv` | **16** |
| legacy oracle aliases beside them | **3** |
| entries in the checked-out `upstream/tsavm` copy | **53** |

The derivation is a **structural parse**, not a grep: `verification/_m35_oracles.py` finds
`export const ORACLE_REGISTRY = {`, scans to its balanced closing brace with a reader that knows
about `'`, `"`, `` ` ``, `//` and `/* */`, and takes the identifiers at depth 1 followed by a `:`.
Everything else it sees at depth 1 is **printed as residue** — at this anchor exactly one `makeEntry`
token per entry, the value half of each pair, and the check asserts that. A `grep -c` over
`^  <name>: makeEntry(` gives the same answer here and is one upstream reformat from giving a
different one; `grep -c '^  [A-Za-z0-9_]*:'` over the whole file gives **70**, and the two extra are
members of an interface below the object.

The same derivation runs over the anchor's object store, over the vendored copy (which must agree
name for name) and over the worktree (which must **not**). That third one is the control: a parse
that had silently stopped matching would report one number for all three.

**The oracle version is honoured against the pinned anchor**, which is the fourth deliverable:

| | derived |
|---|---|
| the environment's oracle version, from the vendored `oracle_version.ts` | **30.8** |
| the version the executed bytecode declared | **30.0** |

`aztec_misc_assertCompatibleOracleVersion` is the FIRST oracle every private function calls — the
`#[aztec]` macro injects it — and this handler throws `OracleVersionIncompatible` on a major
disagreement rather than continuing. The two MINORS differ, deliberately: the artefacts this tree
carries are the `deletion_era` line (2026-06-26) and the wire layer is the `cpp` anchor's
(2026-08-19), and upstream's own rule is that a minor gap in that direction is not breaking
(`environment minor >= contract minor`). That is what makes the comparison a comparison rather than
an identity, and the check asserts the two are unequal for exactly that reason.

---

## 2. WHAT WAS VENDORED, AND THE ONE PACKAGE EDGE THAT HAD TO BE SEVERED

**Owned by `just check-drift`, `verify_provenance_complete` and
`e2e_private_function_executes_in_browser` §7.**

| what | files | lines | provenance |
|---|---|---|---|
| `acvm_wasm.ts` alone — RI-64's own figure, reproduced to the unit | **6** | **711** | — |
| `@aztec/simulator/client`, the whole entry point | **13** | **923** | V10, RI-64 |
| the oracle WIRE layer, relative closure of `acir_callback.ts` | **36** | **3,947** | V11, RI-97 |
| vendored in total | **50** | **4,961** | |

*(Every one of those eight figures is re-derived and compared on every run. The last row was the
reason: it said **4,870** — which is 923 + 3,947, the 36-file relative CLOSURE — on a row stating
that 37 files are vendored, because the closure and the tree differ by
`transient_array_service.ts`. The file count was right, so nothing looked wrong. The three closure
rows come from `_import_closure.py` over the materialised anchor and the total from the TRACKED tree
measured against the anchor's own blobs, with a vendored file that does not resolve upstream
reported rather than counted as zero lines.)*

The wire layer is vendored as **37** files rather than 36: `transient_array_service.ts` is taken too,
because it IS the store the seven `transient` oracles are, and it is outside the closure only because
the wire does not reach a handler's collaborator.

**All fifty are `local-edits: none`**, byte-identical to the anchor with only the generated
provenance header added. That is a decision rather than luck, and it cost three shims:

**The DD-9 edge.** `oracle_registry.ts:5` is `import { toACVMField } from '@aztec/simulator/client'` —
a VALUE edge, so type erasure does not remove it, and `@aztec/simulator`'s own hard dependencies are
`@aztec/native` and `@aztec/world-state`. Editing that import to a relative path would have been one
line and would have taken those bytes out of `check-drift`'s byte-identity arm for good. The
specifier is **aliased** instead, at the build, to that same package's own entry point vendored from
the same anchor. `acir_callback.ts` and `oracle_type_mappings.ts` take the same specifier as
`import type` and are erased.

**The anchor-versus-pin gap, and it is the campaign's third instance of a family it already names.**
`CAMPAIGN-BRIEF.md`: *"read the anchor to understand the design; read the INSTALLED PIN to know what
will parse."* M23 met it as `AztecNodeDebug` (five methods at the anchor, three at the pin), M34 twice
in upstream's zod schemas. M35 met it three times in one file set:

| symbol | at `deletion_era` 5.0.0-nightly.20260626 | at `current` 5.3.0-nightly.20260819 | how it surfaced |
|---|---|---|---|
| `allToCompletion` (`@aztec/foundation/promise`) | absent | present | esbuild: `No matching export` |
| `computeFeeJuiceMessageNullifier` (`@aztec/stdlib/messaging`) | absent | present | esbuild: `No matching export` |
| `AztecAddress.fromFieldUnsafe` and three siblings | named `fromField` etc. | renamed with the `Unsafe` suffix | **inside the ACVM, at run time** |

The first two are a build failure, which is the cheap direction. **The third is not**: a missing
STATIC is not a missing export, so the bundle built and the failure arrived from inside the ACVM as
`Error awaiting \`foreign_call_handler\`` — eleven words naming nothing — with
`TypeError: U.fromFieldUnsafe is not a function` on `err.cause`. Reading that cause is why
`executePrivateFunction` walks the whole chain now and reports it as `errorChain`.

Each gap is a shim in `browser/src/shims/` that re-exports the installed module and adds the one
missing thing from upstream's own source at the anchor, and each is **scoped to the importers that
have the gap** — `browser/src/vendor/pxe/` and nothing else — by an esbuild plugin that fails the
build if any entry matches nothing. The scoping was measured rather than assumed: aliasing the two
subpaths globally gives **265.37 KB either way** for `browser.js`'s eager set, so it did not cost
what a first comment claimed it did; it stays because a shim is a stand-in for a gap one directory
has, and applying it to importers that do not have it makes its own "every entry must fire" assertion
weaker.

The four renames are a rename and not new behaviour, measured on both sides: `fromField(fr)` and
`fromFieldUnsafe(fr)` are the same one-line body, `new AztecAddress(fr)`.

---

## 3. THE SURFACE: 68 ORACLES, 33 SERVED, 35 REFUSED BY NAME

**Owned by `verify_oracle_coverage_is_measured` §4–§5 and
`test_unimplemented_oracle_refuses_by_name`.**

| | derived |
|---|---|
| oracles in the registry | **68** |
| implemented | **33** |
| refusing | **35** |
| refusals carrying a declared reason | **35** |
| implemented oracles EXERCISED in the browser | **33** |

The partition is never typed against a list of names: `ORACLE_NAMES` is
`Object.keys(ORACLE_REGISTRY)` — the vendored registry's own keys — and `ORACLE_REFUSING` is that set
minus the served one, so a sixty-ninth oracle upstream adds is refused on the day the anchor moves
with no edit. The two are asserted disjoint, summing to the re-derived count, and their **union is
the registry's key set compared as a set** rather than as a size.

**"Implemented" means "observed to answer".** The `surface` arm exercises every served oracle through
the handler and reports the SET it reached; the check asserts that set equals the declared one, in
both directions. A handler whose unexercised methods returned plausible defaults would satisfy every
other assertion on this page. And the exercises are behavioural rather than smoke: a capsule that was
written reads back with the right width and one that was deleted reads back as a miss; a nullifier
this contract created is pending FOR THIS CONTRACT and not for another; the revertible phase answers
`false` before it starts and discriminates the counter after.

### What M35 serves

The **in-memory bookkeeping tier**, which is the milestone's own first: capsules (4), ephemeral
arrays (7), transient arrays (7), the execution cache (`setHashPreimage`, `getHashPreimage`,
`assertValidPublicCalldata`), the `notify*` family (5) and the two questions answered from it
(`isNullifierPending`, `isExecutionInRevertiblePhase`), the two execution-state sinks
(`setContractSyncCacheInvalid`, `emitOffchainEffect`), and the three `misc` oracles.

`aztec_misc_getRandomField` is served **deterministically** — a counter hashed with a seed that is an
argument and is never generated. `DEV-WALLET.md` §1 records no-ambient-randomness as the design
property easiest to "harden" away by accident; `crypto.getRandomValues` is the obvious implementation
and is exactly the one that would make a recording unreplayable. The same seed draws the same fields
in the same order twice, a different seed draws different ones, and the draws WITHIN one seed are
asserted distinct — because a generator that returned one field forever would satisfy both
equalities.

### Four validations that are upstream's, and would have been invisible if they were missing

Serving an oracle is not answering it: upstream's handlers REFUSE things, and a permissive version of
each of these is not visibly wrong afterwards. All four were found by reading upstream's own bodies
against this one, and all four are exercised with their negative case:

- **An overlapping capsule copy.** `CapsuleStore.copyCapsule` reverses the index order when the
  destination is ahead of the source, because a forward walk overwrites source entries before it
  reads them. Slots 10..12 holding 1, 2, 3 copied three-wide from 10 to 11 must leave 1, 2, 3 — a
  forward-only loop leaves 1, 1, 1, and the store reads back cleanly either way. Asserted on the
  DESTINATION rather than on the call.
- **A duplicate siloed nullifier.** `#recordNullifier` throws; `Set.add` of an existing member is a
  no-op, so a handler that accepted one would look identical to a handler that refused — while having
  waved a double-spend WITHIN ONE TRANSACTION through the only layer that can see it.
- **Consuming a note nobody created.** `nullifyNote` refuses a non-empty note hash that is not in the
  pending set, which is the fabricated-note shape arriving from the other direction.
- **The whole-transaction calldata cap.** The oracle is named `assertValidPublicCalldata`; a handler
  that looked the calldata up and asserted nothing about it would be a validator that validates
  nothing. The bound is `MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS`, read from `@aztec/constants` and
  compared against that file by the check rather than typed.

### What M35 refuses, and what it would take

Every refusal names the oracle, the TIER it belongs to and the milestone that owns it. Four of the
reasons are **measurements** rather than plans:

- **`aztec_utl_getContractInstance` is the gate.** It is the first oracle every real private function
  reaches after the version check — measured on `Token.transfer`, `Token.mint_to_private` and
  `PrivateVoting.cast_vote`, all three of which stop there. It is tier 2's first rung.
- **`aztec_utl_getNoteHashMembershipWitness` needs a value-to-index lookup**, and
  `ResidentMerkleWriteOperations.findLeafIndices` REFUSES by name (RI-67). A sibling path can be
  taken by INDEX here and not by value; that is a gap in the runtime, not a gap in the handler.
- **AES-128 is not an export of `avm.wasm`.** Measured: there is no `aes` symbol in the linked module
  at all, so `decryptAes128` needs either a barretenberg overlay in M27's patch (the poseidon2 and
  grumpkin pattern) or WebCrypto's own AES-CBC.
- **The fact store is refused for a reason that is upstream's code rather than ours.** See §5.

---

## 4. TWO REAL PRIVATE CIRCUITS, IN CHROMIUM

**Owned by `e2e_private_function_executes_in_browser` and
`test_unimplemented_oracle_refuses_by_name` §5–§6.**

| | derived |
|---|---|
| `OracleVersionCheck.private_function` bytecode | **6,306** bytes |
| its context-input fields | **37** |
| its solved witness | **897** entries |
| oracle calls it made, all served | **4** |
| `Token.transfer` bytecode | **76,875** bytes |
| oracles it served before stopping | **2** |
| oracles it refused | **1** |
| programs measured to stop at that oracle | **3** |

The first frame **executes**: upstream's `WASMSimulator` drives the ACVM over real ACIR, upstream's
68-entry registry deserialises every oracle call and serialises every return, and the handler answers
four of them. The circuit's own `returnsHash` public input is asserted equal to the hash its
`setHashPreimage` call carried — two independent paths out of one execution, compared, which is
stronger than reading either and calling it well-formed.

The second frame **refuses, by name**, at `aztec_utl_getContractInstance`, after serving two oracles
on the way — the non-degeneracy that says the wire ran. A frame that refused at its first oracle
would satisfy the same assertions and say nothing.

**And the LADDER is measured on every run rather than once.** `Token.transfer`,
`Token.mint_to_private` and `PrivateVoting.cast_vote` — two contracts, three distinct bytecodes —
are all executed by the same arm, and `test_unimplemented_oracle_refuses_by_name` §5b asserts that
the SET of oracles they stop at is the singleton `{aztec_utl_getContractInstance}`. That is what makes
tier 2's boundary a property of the ORACLE rather than of one contract. It was a spike measurement
written into three documents until M35's **review** re-took it and wired it in: the claim was true,
and nothing re-derived it.

**And that is what a milestone about refusals owes.** The refusal is asserted three ways: directly on
the handler for all thirty-five, with the implemented ones answering on the same handler in the same
arm as the control; and through a 76,875-byte compiled Noir circuit, which is the one a well-behaved
unit test cannot give.

---

## 5. THE MEASUREMENT THAT DECIDED FOUR REFUSALS: `Fr.random()` INSIDE UPSTREAM'S OWN CODEC

**Owned by `verify_oracle_coverage_is_measured` §7.**

| | derived |
|---|---|
| oracles whose RETURN type carries an `EphemeralArray` | **8** |

`EphemeralArray.materializeSlot` — the serialisation path for an output-mode array — calls
`EphemeralArrayService.newArray`, which calls `allocateSlot`, which is
`do { slot = Fr.random(); } while (…)`. **So serialising any of those eight returns reads ambient
entropy**, and a recording made through one of them does not replay identically.

That is the first place in this campaign where upstream's own code sits on the other side of a
property this wallet declares. It decides the four `fact` oracles — the only ones of the eight that
M35 could otherwise have served — and their refusal reason says so rather than saying "not
implemented".

**The count is derived twice and the two do not agree on a number, which is the point.** The bundle's
set comes from each return `TypeMapping`'s own `label`, so it sees the combinator however deeply it is
nested; the parser's second derivation reads the anchor's SOURCE and sees only the entries where
`EPHEMERAL_ARRAY` is the outermost return type, which is **7**. The check asserts the SUBSET relation
and NAMES the residue — `aztec_utl_getFactCollection`, whose array is inside an `Option` — rather than
asserting an equality that is false or a floor both would pass while one had gone dead.

*(A first draft of the label derivation matched `ephemeral_array` with an underscore where the
mapping spells it `ephemeral-array(` with a hyphen, and returned **zero**. This campaign's oldest
needle defect, in the direction that reads as good news, caught by printing the matched labels beside
the count.)*

---

## 6. PACKAGING: 4.4 MB THAT A PAGE PAYS FOR ONLY IF IT ASKS

**Owned by `e2e_private_function_executes_in_browser` §4–§6 and M27's
`verify_browser_chunk_budget`.**

| | derived |
|---|---|
| the wallet entry's eager set | **296.39 KB** gzipped across **9** files |
| the wallet demo page's eager set | **332.94 KB** gzipped across **13** files |
| `acvm_js_bg.wasm` | **3,601,516** bytes |
| `noirc_abi_wasm_bg.wasm` | **789,053** bytes |
| `@aztec/aztec.js` bytes in `browser.js`'s eager set | **0** |

Two budgets were bumped and both are recorded as data in `chunk-budgets.json` with a `bumps` entry
naming what grew: the wallet entry 300 -> 340 KB and the wallet demo 340 -> 380 KB. That cost is the
deliverable — a wallet that could not execute a private function would be a wallet the runtime had to
reach around, which is the shape M33's null wallet exists to refuse.

**The two wasm modules are in NEITHER number, and that is the DD-11 claim.**
`WASMSimulator.init()` calls wasm-bindgen's argument-less init, which resolves
`new URL('acvm_js_bg.wasm', import.meta.url)` — after esbuild, a chunk path that has never existed —
so the whole execution failed with `TypeError: fetch failed`, measured in Node over the built bundle
before anything asserted on it. `initPrivateExecution({acvmWasmUrl, noircAbiWasmUrl})` pre-initialises
with explicit URLs; wasm-bindgen's `__wbg_init` opens with `if (wasm !== undefined) return wasm;`, so
the vendored file's argument-less call becomes a no-op and needs no edit. **There is deliberately no
default URL**: `PrivateExecutionNotInitialised` names itself where the mistake is, rather than four
layers down.

And because the modules are fetched by URL at the moment a page asks, a page that never asks fetches
neither. That is an ABSENCE, so it is measured on a network log that CAN carry a wasm fetch: the
control arm is the SAME page running M34's wallet transfer, and its log carries `/assets/avm.wasm`
while carrying neither of the two — with the subject arm's log carrying all three as the positive
control that the scanner can find them at all. **Zero requests containing `barretenberg` in both.**

---

## 7. WHAT IS DELIBERATELY NOT HERE

- **`transfer` does not run.** The milestone's goal sentence is *"`transfer` works — private
  execution, in the wallet, in the browser"*, and it does not. `Token.transfer` executes into the
  oracle wire and stops at `aztec_utl_getContractInstance`, refusing by name. What is delivered is
  the executor, the wire, tier 1 of four, and a measured ladder to the rest. §3 names the first rung.
- **No nested calls.** `aztec_prv_callPrivateFunction` is tier 4 and refuses; this executes ONE frame.
  A contract that makes a nested private call fails at the oracle that would have made it, which is
  the correct failure and not a silent single-frame result.
- **No note discovery and no tagging.** The eight oracles M36 owns refuse by name.
- **No membership witnesses.** Tier 2 is enumerated, priced and refused; `getNoteHashMembershipWitness`
  additionally needs a runtime primitive that refuses today.
- **No AES-128 and no ECDH.** Tier 3, with the measurement that decides how: `avm.wasm` has no `aes`
  symbol linked, so it is a barretenberg overlay or WebCrypto, and `getSharedSecrets` is additionally
  one of the eight §5 refuses.
- **No proving.** Unchanged from every milestone before it; §8.4's disclosure still crosses the seam.

---

## 8. WHAT M36 INHERITS

- An executor that runs real ACIR in a page, so M36's oracles are a substitution rather than a
  construction: every one of them currently refuses by name, and the refusal names M36.
- The ordered oracle ledger, so "every oracle call visible" — `DEV-WALLET.md` §1's first design
  property — already covers the private path, refusals included.
- The measurement in §5, which M36 must answer before it can serve `getPendingTaggedLogsV2`,
  `getLogsByTagV2` or `getNotes`: three of the eight ephemeral-array returns are its own.
- `aztec_utl_getContractInstance` as the measured first rung of tier 2, which every real contract
  reaches before anything M36 owns.
