#!/usr/bin/env bash
# verify_txe_private_flow_prior_art_consulted — M21, the eighth deliverable.
#
# "TXE's `privateCallNewFlow` and `addAuthWitness` consulted before this path is written. Whatever
# verdict M23's enumeration reached on TXE as a COMPONENT, it has already assembled a
# private-execution-to-Tx flow with auth witnesses for a dev chain, and its handling of the pieces
# this milestone assembles is prior art."
#
# "CONSULTED" IS NOT A CHECKABLE WORD, so what is checked is what consulting it PRODUCED: a set of
# specific facts about TXE's flow, each re-derived from the anchor here, each of which either
# changed a decision in this milestone or is a trap the next agent would otherwise fall into. A
# deliverable that says "we read it" and asserts nothing is the shape this campaign has found
# twenty-one times.
#
# WHAT CONSULTING IT ACTUALLY CHANGED, and each is asserted below:
#
#   1. TXE DOES NOT USE `PrivateSimulationResult.toSimulatedTx()` AT ALL. It inlines
#      `Tx.create({ …, contractClassLogFields: [] })`. So does `wallet-sdk`. PXE is the ONLY one of
#      the three that goes through `toSimulatedTx`, and the difference is real: the inlined form
#      passes an EMPTY `contractClassLogFields` where `toSimulatedTx` passes
#      `collectSortedContractClassLogs(privateExecutionResult)`. A transaction that published a
#      contract class comes out different. This runtime takes PXE's, and `form_b.ts` says why.
#   2. TXE PASSES A `minRevertibleSideEffectCounterOverride` OF 1, and its own comment says why —
#      it bypasses the account contract, which is what sets the counter in production. PXE passes
#      no override at all. That is a fork in the path, and picking one without knowing the other
#      existed would have been picking blind.
#   3. TXE'S NODE ARGUMENT IS A REAL `AztecNodeService`, not a narrow object. So TXE is NOT prior
#      art for the adapter — it is the opposite, and OQ-1's answer had to come from upstream's own
#      `Pick<>` rather than from copying what TXE did.
#   4. TXE USES `WASMSimulator`, and constructs it inline at the call site. That is the RI-64
#      decision's evidence that the wasm ACVM path is the production-shaped one rather than a
#      fallback.
#   5. `addAuthWitness` STORES INTO A MAP THE SESSION OWNS, and `privateCallNewFlow` snapshots the
#      whole map into the oracle. The witnesses are not a parameter of the private call; they are
#      ambient state. That is the shape M21's successor has to reproduce, and it is why the auth
#      witness store is one of the 68 oracles RI-65 counts rather than an argument.

set -uo pipefail
TEST_NAME="verify_txe_private_flow_prior_art_consulted"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

CPP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
       "$REPO_ROOT/pins.json")"
at() { ( cd "$FORK_ROOT" && git show "$CPP:$1" ) 2>/dev/null; }

TXE="$(at yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts)"
PXE="$(at yarn-project/pxe/src/pxe.ts)"
WSDK="$(at yarn-project/wallet-sdk/src/base-wallet/utils.ts)"
STDLIB="$(at yarn-project/stdlib/src/tx/simulated_tx.ts)"
for pair in "TXE:$TXE" "PXE:$PXE" "WSDK:$WSDK" "STDLIB:$STDLIB"; do
  name="${pair%%:*}"; body="${pair#*:}"
  assert_ge "$name was read at the anchor" 50 "$(printf '%s\n' "$body" | grep -c . || true)"
done

# ---------------------------------------------------------------------------
echo "== 1. all three upstream call sites, and the ONE that goes through toSimulatedTx"
# ---------------------------------------------------------------------------
for pair in "TXE:$TXE" "PXE:$PXE" "WSDK:$WSDK"; do
  name="${pair%%:*}"; body="${pair#*:}"
  if str_has_word "$body" "generateSimulatedProvingResult"; then calls=yes; else calls=no; fi
  assert_eq "$name calls generateSimulatedProvingResult" "yes" "$calls"
done
for pair in "TXE:$TXE" "WSDK:$WSDK"; do
  name="${pair%%:*}"; body="${pair#*:}"
  if str_has_word "$body" "PrivateSimulationResult"; then uses=yes; else uses=no; fi
  assert_eq "…but $name does NOT go through PrivateSimulationResult" "no" "$uses"
  if str_has_sub "$body" "Tx.create({"; then inlines=yes; else inlines=no; fi
  assert_eq "…it inlines Tx.create instead" "yes" "$inlines"
  if str_has_sub "$body" "contractClassLogFields: []"; then empty=yes; else empty=no; fi
  assert_eq "…with an EMPTY contractClassLogFields, which is the divergence" "yes" "$empty"
done
if str_has_word "$PXE" "PrivateSimulationResult"; then uses=yes; else uses=no; fi
assert_eq "PXE is the one that DOES use PrivateSimulationResult" "yes" "$uses"
if str_has_sub "$PXE" ".toSimulatedTx()"; then calls=yes; else calls=no; fi
assert_eq "…and calls toSimulatedTx on it" "yes" "$calls"
# The difference is in stdlib, read rather than described.
if str_has_sub "$STDLIB" "collectSortedContractClassLogs(this.privateExecutionResult)"; then c=yes; else c=no; fi
assert_eq "toSimulatedTx collects the sorted contract-class logs, which the inlined form drops" \
  "yes" "$c"
# AND OUR OWN CHOICE IS THE ONE THIS SECTION ARGUES FOR, asserted against the shipped source rather
# than left as a comment.
FORMB="$(cat "$REPO_ROOT/orchestration/src/form_b.ts")"
if str_has_sub "$FORMB" "new PrivateSimulationResult(privateExecutionResult, publicInputs).toSimulatedTx()"; then ours=pxe; else ours=other; fi
assert_eq "this runtime takes PXE's path, not the inlined one" "pxe" "$ours"
# `Tx.create({` DOES appear in this file — in the header comment, quoting what TXE and wallet-sdk
# do, which is the whole point of the paragraph. A citation is not a call. The needle is therefore
# a CALL shape (`await Tx.create` / `= Tx.create`), with the citation shown to be found by the bare
# text so the narrowing is not an excuse — M20's review had to make exactly this correction to
# `verify_differential_job_separate_failure_domain`.
if str_has_re "$FORMB" '(await|=|return) Tx\.create\('; then calls=yes; else calls=no; fi
assert_eq "…and does not CALL Tx.create anywhere" "no" "$calls"
if str_has_sub "$FORMB" "Tx.create({"; then cited=yes; else cited=no; fi
assert_eq "…while it does CITE it, so the call-shaped needle is a narrowing and not a miss" "yes" \
  "$cited"

# ---------------------------------------------------------------------------
echo "== 2. the minRevertibleSideEffectCounter override, which is a fork in the path"
# ---------------------------------------------------------------------------
if str_has_word "$TXE" "minRevertibleSideEffectCounter"; then has=yes; else has=no; fi
assert_eq "TXE names a minRevertibleSideEffectCounter" "yes" "$has"
assert_true "…and says WHY, in its own words: it bypasses the account contract" \
  str_has_sub "$TXE" "Since TXE bypasses the account contract"
assert_true "…and the value is 1" str_has_sub "$TXE" "minRevertibleSideEffectCounter = 1"
if str_has_word "$WSDK" "minRevertibleSideEffectCounter"; then has=yes; else has=no; fi
assert_eq "wallet-sdk passes one too" "yes" "$has"
# PXE's call site passes THREE arguments, so no override. Read as the call's own shape rather than
# as an absence of the identifier, which would also be true of a file that spelled it differently.
PXE_CALL="$(printf '%s\n' "$PXE" | awk '/await generateSimulatedProvingResult\(/{ inside=1 } inside { print } inside && /\)\);/{ exit }')"
assert_ge "PXE's call site was extracted" 4 "$(printf '%s\n' "$PXE_CALL" | grep -c . || true)"
if str_has_word "$PXE_CALL" "minRevertibleSideEffectCounter"; then has=yes; else has=no; fi
assert_eq "…and PXE's own call passes NO override, which is the fork" "no" "$has"
assert_true "…it passes the node as its last argument" str_has_sub "$PXE_CALL" "this.node,"

# ---------------------------------------------------------------------------
echo "== 3. TXE's node is a REAL node, so it is not prior art for the adapter"
#
# This is the finding that stopped M21 from copying TXE here. TXE hands
# `generateSimulatedProvingResult` a whole `AztecNodeService`; if that had been taken as the
# pattern, Form B would have grown the dependency surface OQ-1 exists to bound.
# ---------------------------------------------------------------------------
assert_true "TXE passes its state machine's node straight through" \
  str_has_sub "$TXE" "this.stateMachine.node,"
SM="$(at yarn-project/txe/src/state_machine/index.ts)"
assert_ge "TXE's state machine was read" 50 "$(printf '%s\n' "$SM" | grep -c . || true)"
assert_true "…and that node is a real AztecNodeService" str_has_sub "$SM" "new AztecNodeService("
assert_true "…imported from @aztec/aztec-node, a package this runtime does not depend on" \
  str_has_sub "$SM" "@aztec/aztec-node"
MANIFEST="$(cat "$REPO_ROOT/orchestration/package.json")"
assert_false "…and orchestration does not declare it" str_has_sub "$MANIFEST" '"@aztec/aztec-node"'

# ---------------------------------------------------------------------------
echo "== 4. TXE's circuit simulator is WASMSimulator, which is RI-64's evidence"
# ---------------------------------------------------------------------------
assert_true "TXE constructs a WASMSimulator" str_has_sub "$TXE" "new WASMSimulator()"
assert_true "…from @aztec/simulator/client" str_has_sub "$TXE" "@aztec/simulator/client"
if str_has_word "$TXE" "NativeACVMSimulator"; then native=yes; else native=no; fi
assert_eq "…and no native ACVM path anywhere in it, so wasm is the shape and not the fallback" \
  "no" "$native"

# ---------------------------------------------------------------------------
echo "== 5. auth witnesses are AMBIENT STATE, not an argument"
#
# The shape M21's successor has to reproduce, and the reason the auth-witness store is one of
# RI-65's 68 oracles rather than a parameter.
# ---------------------------------------------------------------------------
assert_true "addAuthWitness is a method on the top-level context" \
  str_has_line_re "$TXE" '^ *async addAuthWitness\('
assert_true "…and it writes into a map keyed by the request hash" \
  str_has_sub "$TXE" "this.authwits.set(authWitness.requestHash.toString(), authWitness)"
assert_true "…which privateCallNewFlow snapshots wholesale into the oracle" \
  str_has_sub "$TXE" "authWitnesses: Array.from(this.authwits.values())"
SESSION="$(at yarn-project/txe/src/txe_session.ts)"
assert_ge "the TXE session was read" 100 "$(printf '%s\n' "$SESSION" | grep -c . || true)"
assert_true "…and the map itself is owned by the SESSION, so it outlives one call" \
  str_has_sub "$SESSION" "private authwits: Map<string, AuthWitness>"
ORACLE="$(at yarn-project/pxe/src/contract_function_simulator/oracle/utility_execution_oracle.ts)"
assert_ge "the utility execution oracle was read" 200 "$(printf '%s\n' "$ORACLE" | grep -c . || true)"
assert_true "…and getAuthWitness is what reads them back during execution" \
  str_has_line_re "$ORACLE" '^ *public getAuthWitness\('
assert_true "…searching the snapshot by request hash" \
  str_has_sub "$ORACLE" "this.authWitnesses.find(w => w.requestHash.equals(messageHash))"

# ---------------------------------------------------------------------------
echo "== 6. the oracle surface TXE needs, counted — RI-65's number, re-derived"
#
# A count restated in prose rots. This re-derives it from upstream's own registry so that the
# inventory entry's "68 entries" is a measurement rather than a memory.
# ---------------------------------------------------------------------------
REG="$(at yarn-project/pxe/src/contract_function_simulator/oracle/oracle_registry.ts)"
assert_ge "the oracle registry was read" 400 "$(printf '%s\n' "$REG" | grep -c . || true)"
# The entries are `aztec_<scope>_<name>: makeEntry({`, not `: {`. The first spelling of this needle
# scored ZERO on a 628-line file and the check reported "declares 0 entries" — a needle that matches
# nothing, which is the campaign's own most-repeated defect and is why the non-emptiness assertion
# below sits beside the equality rather than after it.
N_ORACLES="$(printf '%s\n' "$REG" | grep -cE "^  aztec_(misc|utl|prv)_[A-Za-z0-9_]+: makeEntry\(" || true)"
note "ORACLE_REGISTRY declares $N_ORACLES entries at the cpp anchor"
assert_eq "…and it is the number RI-65 records" "68" "$N_ORACLES"
for prefix in misc utl prv; do
  N="$(printf '%s\n' "$REG" | grep -cE "^  aztec_${prefix}_[A-Za-z0-9_]+: makeEntry\(" || true)"
  note "  aztec_${prefix}_: $N"
  assert_ge "…and the $prefix prefix contributes some of them" 3 "$N"
done
INV="$(cat "$REPO_ROOT/REUSE-INVENTORY.md")"
assert_true "RI-65 records the count" str_has_sub "$INV" "declares **68 entries**"

# THE PARALLEL-SUBDIRECTORY TRAP, measured rather than warned about: the tsavm worktree that is
# already checked out carries a DIFFERENT registry, and vendoring from it — the way RI-25 vendored
# the simulator files — would ship a smaller oracle surface than the bytecode expects.
TSAVM_REG="$REPO_ROOT/upstream/tsavm/yarn-project/pxe/src/contract_function_simulator/oracle/oracle_registry.ts"
assert_file "the tsavm worktree carries its own copy of the registry" "$TSAVM_REG"
N_TSAVM="$(grep -cE "^  aztec_(misc|utl|prv)_[A-Za-z0-9_]+: makeEntry\(" "$TSAVM_REG" || true)"
note "the tsavm worktree's copy declares $N_TSAVM"
assert_eq "…and it is FIFTEEN SHORT, which is why RI-65 says to vendor from the cpp anchor" "53" \
  "$N_TSAVM"
assert_ge "…so the two really differ, and the warning is not about a difference of zero" 1 \
  "$((N_ORACLES - N_TSAVM))"
assert_true "…and RI-65 records that number too" str_has_sub "$INV" "**53 entries**"

finish
