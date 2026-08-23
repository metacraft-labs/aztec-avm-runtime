#!/usr/bin/env bash
# e2e_deploy_call_revert_roundtrip
#
# Registering a contract class and instance DURING execution, calling into the contract, then
# reverting — with both stacks unwinding together.
#
# NOTHING IN THE HOST PERFORMS THE DEPLOYMENT OR THE REVERT. The input differs from the ordinary one
# in exactly one field, `tx.revertible_contract_deployment_data`, and upstream's own
# `TxExecution::insert_revertibles` hands that field to `contract_db.add_contracts` inside the
# checkpoint it opened at the end of setup. So:
#
#   * on a program whose app logic succeeds, the contract that arrived as a published-event log is
#     still there when the transaction returns;
#   * on one that reverts, it is gone — together with the tree writes, and with both checkpoint
#     stacks back where they started.
#
# THIS IS ALSO THE ARM THAT DISCRIMINATES THE MILESTONE'S DECISION. `TestContractDB::add_contracts`
# is a no-op, so against it the contract would be absent after the SUCCEEDING program too, and the
# two rows would read the same. Five programs succeed and two revert, so the check has both.
#
# THE WIRE FORMAT IS NOT OURS TO DEFINE, and this check is where that is established. The driver
# prints the raw log fields; `diffsim/decode_deployment_logs.mjs` decodes those same fields with
# upstream's `ContractClassPublishedEvent.fromLog` and `ContractInstancePublishedEvent.fromLog` from
# the pinned npm packages, and every field of the result must equal what the C++ side says the
# contract is. A round trip through our own encoder and our own decoder would prove only that they
# were written from the same page. The `FuzzerContractDB` layout is applied to the same bytes as a
# negative control, because a comparison that cannot fail establishes nothing.

TEST_NAME="e2e_deploy_call_revert_roundtrip"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

m13_measured

OUT="$M13_WORK/e2e.out"
ERR="$M13_WORK/e2e.err"
m13_run_host e2e "$OUT" "$ERR"
rc=$?
assert_eq "the host ran the deploy/call/revert roundtrip" "0" "$rc"
assert_file "it produced a transcript" "$OUT"
[ -s "$OUT" ] || die "the transcript is empty — see $ERR"
m13_assert_field "it ran to completion" "$OUT" "e2e.done" "1"
m13_assert_field "over all seven corpus programs" "$OUT" "e2e.programs.count" "$M13_EXPECTED_PROGRAMS"
m13_assert_field "and leaked no linear-memory allocation" "$OUT" "e2e.ownedAllocationsAtExit" "0"

kept=0
dropped=0
for prog in $M13_PROGRAMS; do
  p="e2e.$prog"
  deployed_addr="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.deployed.address")"
  registered_addr="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.address")"
  assert_eq "$prog: the deployed contract is at a different address from the registered one" "1" \
    "$([ -n "$deployed_addr" ] && [ "$deployed_addr" != "$registered_addr" ] && echo 1 || echo 0)"
  m13_assert_field "$prog: the transcript names that address" "$OUT" "$p.deployed.address" "$deployed_addr"
  m13_assert_field "$prog: and nothing has registered it before the transaction runs" \
    "$OUT" "$p.deployedInstanceBefore" "0"
  m13_assert_field "$prog: the outer checkpoint is open on both stacks" "$OUT" "$p.ids.before" "1/1/1"
  m13_assert_field "$prog: the transaction leaves both stacks where it found them" \
    "$OUT" "$p.ids.after" "1/1/1"
  m13_assert_field "$prog: and the module's own lockstep assertion succeeds afterwards" \
    "$OUT" "$p.assertAfterSimulate" "0"
  m13_assert_field "$prog: the simulation moved the trees, so the revert below has something to undo" \
    "$OUT" "$p.rootsAfterSimulate" "moved"
  m13_assert_field "$prog: the explicitly registered contract is untouched throughout" \
    "$OUT" "$p.registeredInstancePresent" "1"

  present="$(m13_field "$OUT" "$p.deployedInstancePresent")"
  case " $M13_REVERTING_PROGRAMS " in
    *" $prog "*)
      m13_assert_field "$prog: reverts" "$OUT" "$p.revertCode" "1"
      assert_eq "$prog: and the contract deployed during execution is GONE with the revert" "0" "$present"
      dropped=$((dropped + 1)) ;;
    *)
      m13_assert_field "$prog: succeeds" "$OUT" "$p.revertCode" "0"
      assert_eq "$prog: and the contract deployed during execution SURVIVES the transaction" "1" "$present"
      kept=$((kept + 1)) ;;
  esac

  # The outer unwind: both stacks to zero, every root restored, and the deployed contract gone in
  # every case — including the ones where the transaction itself kept it.
  m13_assert_field "$prog: unwinding the outer checkpoint leaves both stacks at zero" \
    "$OUT" "$p.ids.end" "0/0/0"
  m13_assert_field "$prog: and restores every tree root" "$OUT" "$p.rootsRestored" "1"
  m13_assert_field "$prog: the contract deployed during execution is gone with it" \
    "$OUT" "$p.deployedInstanceAfterOuterRevert" "0"
  m13_assert_field "$prog: while the one registered before it is still there" \
    "$OUT" "$p.registeredInstanceAfterOuterRevert" "1"
done
assert_eq "five succeeding programs kept the contract they deployed" "5" "$kept"
assert_eq "and two reverting ones dropped it" "2" "$dropped"

# ---------------------------------------------------------------------------
# The wire format, against upstream's own TypeScript readers.
# ---------------------------------------------------------------------------
DECODE="$M13_WORK/upstream-decode.out"
DECODE_ERR="$M13_WORK/upstream-decode.err"
assert_file "the upstream log decoder is present" "$M13_DECODER"
m6_in_devshell '
  repo="$1"; inputs="$2"; out="$3"; err="$4"
  cd "$repo/diffsim" || exit 90
  node decode_deployment_logs.mjs "$inputs" >"$out" 2>"$err"
' "$REPO_ROOT" "$(m13_inputs)" "$DECODE" "$DECODE_ERR" >/dev/null
decode_rc=$?
assert_eq "upstream's own readers decoded the deployment logs" "0" "$decode_rc"
[ -s "$DECODE" ] || die "the upstream decode produced nothing — see $DECODE_ERR"
m13_assert_field "for all seven programs" "$DECODE" "upstreamDecode.programs" "$M13_EXPECTED_PROGRAMS"

compared=0
mismatched=0
for prog in $M13_PROGRAMS; do
  for field in classId artifactHash privateFunctionsRoot bytecodeBytes address salt deployer \
               initializationHash immutablesHash \
               publicKey.0 publicKey.1 publicKey.2 publicKey.3 publicKey.4 publicKey.5 publicKey.6; do
    ts="$(m13_field "$DECODE" "upstreamDecode.$prog.$field")"
    cpp="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.deployed.$field")"
    compared=$((compared + 1))
    if [ -z "$ts" ] || [ "$ts" != "$cpp" ]; then
      fail "$prog.$field: upstream's reader says [$ts], the C++ side says [$cpp]"
      mismatched=$((mismatched + 1))
    fi
  done
done
# Sixteen fields per program, as a PRODUCT rather than a constant, so a program added to the corpus
# cannot leave a stale total behind.
assert_eq "sixteen fields per program compared across the two decoders" \
  "$((16 * M13_EXPECTED_PROGRAMS))" "$compared"
assert_eq "and none disagreed" "0" "$mismatched"

# THE NEGATIVE CONTROL. `FuzzerContractDB::from_logs` reads the instance log as
# (tag, version, address, …) where upstream writes (tag, address, version, …) — its own comment says
# so — and then takes `immutablesHash` for a public key and stops two keys short. Applied to these
# same fields it must disagree, or the comparison above would pass for any layout at all.
fuzzer_disagreements=0
for prog in $M13_PROGRAMS; do
  fuzzer_address="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.logs.instance.2")"
  upstream_address="$(m13_field "$DECODE" "upstreamDecode.$prog.address")"
  [ -n "$fuzzer_address" ] || { fail "$prog: the transcript carries no instance log field 2"; continue; }
  if [ "$fuzzer_address" != "$upstream_address" ]; then
    fuzzer_disagreements=$((fuzzer_disagreements + 1))
  else
    fail "$prog: the fuzzer's field order gives the same address as upstream's — the comparison above proves nothing"
  fi
done
assert_eq "the fuzzer's field order disagrees on the address for every program" \
  "$M13_EXPECTED_PROGRAMS" "$fuzzer_disagreements"
# And the field it takes for the first public key is upstream's `immutablesHash`, which is the
# second half of the same defect.
assert_eq "the field the fuzzer reads as the first public key is upstream's immutablesHash" \
  "$(m13_field "$DECODE" "upstreamDecode.add.immutablesHash")" \
  "$(m13_field "$(m13_inputs)" "contractDbInputs.add.logs.instance.6")"

finish
