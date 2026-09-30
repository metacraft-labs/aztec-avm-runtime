#!/usr/bin/env bash
# test_contract_db_eight_methods_covered
#
# All EIGHT `ContractDBInterface` methods, exercised against every one of the seven corpus contracts
# through the implementation that ships — `simulation::MemoryContractDB` inside `avm.wasm`, called
# across the msgpack boundary from JavaScript.
#
# THE METHOD LIST IS THE INTERFACE'S, read out of the fork at the anchor rather than typed here, so
# a ninth method appearing upstream fails this check instead of being silently uncovered.
#
# EVERY GETTER IS CALLED TWICE. Once with an argument that is registered and once with one that is
# not, because "the DB answered" is not a finding: a store that returned a value for everything and
# a store that returned nothing for everything would both pass a check that only asked for the
# registered case. Each pair must be found-then-nil.
#
# The three checkpoint methods are exercised through the checkpoint id the store now exposes, so
# create/commit/revert are observed as a sequence of integers rather than as three calls that
# returned zero. And the underflow — committing with nothing open — must FAIL with the TypeScript
# `PublicContractsDB`'s own message, which is the behaviour that separates this store from the two
# existing in-memory copies, both of which return silently.

TEST_NAME="test_contract_db_eight_methods_covered"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

m13_measured

OUT="$M13_WORK/methods.out"
ERR="$M13_WORK/methods.err"
m13_run_host methods "$OUT" "$ERR"
rc=$?
assert_eq "the host ran the eight-method sweep" "0" "$rc"
assert_file "it produced a transcript" "$OUT"
[ -s "$OUT" ] || die "the transcript is empty — see $ERR"
m13_assert_field "it ran to completion" "$OUT" "methods.done" "1"
m13_assert_field "over all seven corpus contracts" "$OUT" "methods.programs.count" "$M13_EXPECTED_PROGRAMS"
m13_assert_field "and leaked no linear-memory allocation" "$OUT" "methods.ownedAllocationsAtExit" "0"

# --- the method list is the interface's -------------------------------------
iface="$(git -C "$FORK_ROOT" show \
  "$M6_BASE_REV:barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp" 2>/dev/null \
  | awk '/^class ContractDBInterface/ { inbody = 1; next } inbody && /^};/ { exit } inbody { print }' \
  | grep -oE 'virtual [^ ]+ [a-z_]+\(' | sed -E 's/.* ([a-z_]+)\($/\1/' | LC_ALL=C sort -u)"
assert_eq "ContractDBInterface declares exactly eight methods at the anchor" "8" \
  "$(printf '%s\n' "$iface" | grep -c . || true)"
assert_eq "and they are the eight this check covers" "$M13_CONTRACT_DB_METHODS" "$iface"

# --- every method, every program --------------------------------------------
covered=0
for prog in $M13_PROGRAMS; do
  p="methods.$prog"

  # 1/2/3. The three lookups, found-then-nil.
  cls_id="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.classId")"
  addr="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.address")"
  commitment="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.commitment")"
  m13_assert_field "$prog: get_contract_instance returns the registered instance's class id" \
    "$OUT" "$p.get_contract_instance.classId" "$cls_id"
  m13_assert_field "$prog: and nil for an address nobody registered" \
    "$OUT" "$p.get_contract_instance.absent" "nil"
  m13_assert_field "$prog: get_contract_class returns the registered class" \
    "$OUT" "$p.get_contract_class.id" "$cls_id"
  m13_assert_field "$prog: and nil for a class id nobody registered" \
    "$OUT" "$p.get_contract_class.absent" "nil"
  m13_assert_field "$prog: get_bytecode_commitment returns the tester's own commitment" \
    "$OUT" "$p.get_bytecode_commitment" "$commitment"
  m13_assert_field "$prog: and nil for a class id nobody registered" \
    "$OUT" "$p.get_bytecode_commitment.absent" "nil"

  # 4. get_debug_function_name, before and after registration, and for an unregistered selector.
  want_name="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.functionName")"
  m13_assert_field "$prog: get_debug_function_name is nil before anything is registered" \
    "$OUT" "$p.get_debug_function_name.beforeRegistration" "nil"
  m13_assert_field "$prog: and returns the registered name afterwards" \
    "$OUT" "$p.get_debug_function_name" "$want_name"
  m13_assert_field "$prog: and nil for a selector at the same address that was never registered" \
    "$OUT" "$p.get_debug_function_name.absent" "nil"

  # 5. add_contracts with an empty deployment: accepted, and it changes nothing.
  m13_assert_field "$prog: add_contracts accepts an empty deployment without losing what is there" \
    "$OUT" "$p.add_contracts.empty" "ok"
  m13_assert_field "$prog: and does not touch the checkpoint stack" \
    "$OUT" "$p.add_contracts.checkpointIdUnchanged" "1"

  # 6/7/8. create / commit / revert, as the id sequence 0 -> 1 -> 0 -> 0.
  m13_assert_field "$prog: create, commit, create+revert move the checkpoint id 0/1/0/0" \
    "$OUT" "$p.checkpointIds" "0/1/0/0"
  m13_assert_field "$prog: committing with nothing open FAILS rather than returning silently" \
    "$OUT" "$p.commitUnderflow.status" "1"
  m13_assert_field "$prog: with the TypeScript PublicContractsDB's own message" \
    "$OUT" "$p.commitUnderflow.message" "No checkpoint to commit"

  covered=$((covered + 1))
done
assert_eq "all seven corpus contracts were covered" "$M13_EXPECTED_PROGRAMS" "$covered"

# The call count, so "exercised" is a number rather than an impression. Twelve calls with arguments
# and four checkpoint calls per program, and the expected total is the PRODUCT rather than a
# constant, so adding a program to the corpus cannot leave a stale number behind.
m13_assert_field "the sweep made sixteen calls per contract into the module" \
  "$OUT" "methods.calls" "$((16 * M13_EXPECTED_PROGRAMS))"

# The controls are only controls if the arguments really differ.
assert_eq "the absent address is not the registered one" "1" \
  "$([ "$(m13_field "$(m13_inputs)" "contractDbInputs.add.args.absentAddress")" \
      != "$(m13_field "$(m13_inputs)" "contractDbInputs.add.args.address")" ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# THE TWO POPULATION PATHS, compared answer for answer.
#
# `add_contracts` is one of the eight, and covering it with an EMPTY deployment above establishes
# only that it does not lose what is already there. The deliverable asks for two sources — artifacts
# a consumer registers explicitly, and registrations observed during execution — and the way to
# check two sources is to populate two stores, one each way, and require every answer to agree.
# Neither is allowed to be the definition of the other: the registered side carries the tester's own
# values, and the observed side decodes a published-event log and COMPUTES the bytecode commitment
# from the decoded bytes with the same function the TypeScript publisher uses.
# ---------------------------------------------------------------------------
POUT="$M13_WORK/populate.out"
PERR="$M13_WORK/populate.err"
m13_run_host populate "$POUT" "$PERR"
prc=$?
assert_eq "the host ran the two population paths" "0" "$prc"
[ -s "$POUT" ] || die "the populate transcript is empty — see $PERR"
m13_assert_field "it ran to completion" "$POUT" "populate.done" "1"
m13_assert_field "over all seven corpus contracts" "$POUT" "populate.programs.count" "$M13_EXPECTED_PROGRAMS"
m13_assert_field "and leaked no linear-memory allocation" "$POUT" "populate.ownedAllocationsAtExit" "0"

agreed=0
for prog in $M13_PROGRAMS; do
  p="populate.$prog"
  for field in instance instance.salt instance.deployer instance.immutablesHash \
               instance.mspkMHash instance.fbpkMHash \
               class.bytecodeBytes class.artifactHash commitment; do
    reg="$(m13_field "$POUT" "$p.$field.registered")"
    obs="$(m13_field "$POUT" "$p.$field.observed")"
    if [ -z "$reg" ] || [ "$reg" = "nil" ]; then
      fail "$prog: the registered store has no $field — the comparison below would be vacuous"
    elif [ "$reg" = "$obs" ]; then
      agreed=$((agreed + 1))
    else
      fail "$prog: $field disagrees — registered [$reg], observed through add_contracts [$obs]"
    fi
  done
  # The packed bytecode, compared byte for byte rather than by length.
  m13_assert_field "$prog: the packed bytecode is identical byte for byte" "$POUT" "$p.class.bytecodeEqual" "1"
done
assert_eq "nine fields per contract agreed between the two population paths" \
  "$((9 * M13_EXPECTED_PROGRAMS))" "$agreed"

# And the comparison is only a comparison if the values are not all zero: the class id and the
# commitment are derived from real bytecode and must differ from the zero field.
zero="0x0000000000000000000000000000000000000000000000000000000000000000"
nontrivial=0
for prog in $M13_PROGRAMS; do
  for field in instance commitment; do
    v="$(m13_field "$POUT" "populate.$prog.$field.observed")"
    [ -n "$v" ] && [ "$v" != "$zero" ] && nontrivial=$((nontrivial + 1))
  done
done
assert_eq "the class id and the commitment are non-zero on both sides for every contract" \
  "$((2 * M13_EXPECTED_PROGRAMS))" "$nontrivial"

# THE COMPARISON ABOVE IS OVER UPSTREAM'S TESTER DEFAULTS, and five of its nine fields — salt,
# immutablesHash, the two public keys, artifactHash — are zero in every program, so they agree
# under any decoder. The same two population paths are therefore compared again over the SECOND
# contract, whose every preimage field is a distinct non-zero value, and each field is counted as
# evidence only when it is non-zero.
DEPLOYED_FIELDS="instance instance.salt instance.deployer instance.initializationHash instance.immutablesHash
instance.npkMHash instance.ovpkMHash instance.tpkMHash instance.mspkMHash instance.fbpkMHash
class.artifactHash class.privateFunctionsRoot"
populate_compare() { # <transcript> -> "agreed nonzero disagreed"
  local file="$1" a=0 nz=0 d=0 prog field reg obs
  for prog in $M13_PROGRAMS; do
    for field in $DEPLOYED_FIELDS; do
      reg="$(m13_field "$file" "populate.$prog.deployed.$field.registered")"
      obs="$(m13_field "$file" "populate.$prog.deployed.$field.observed")"
      if [ -n "$reg" ] && [ "$reg" != nil ] && [ "$reg" = "$obs" ]; then
        a=$((a + 1)); [ "$reg" != "$zero" ] && nz=$((nz + 1))
      else
        d=$((d + 1))
      fi
    done
  done
  printf '%s %s %s\n' "$a" "$nz" "$d"
}
read -r d_agreed d_nonzero d_disagreed <<<"$(populate_compare "$POUT")"
n_fields="$(printf '%s\n' $DEPLOYED_FIELDS | grep -c .)"
assert_eq "the second contract: all $n_fields fields agree between the two paths, in every program" \
  "$((n_fields * M13_EXPECTED_PROGRAMS))" "$d_agreed"
assert_eq "and every one of those agreements is on a NON-ZERO value" \
  "$((n_fields * M13_EXPECTED_PROGRAMS))" "$d_nonzero"
# The swapped-field control: the observed path's salt and immutablesHash exchanged, which is the
# shape of a decoder reading two fields from each other's positions. Over zero-valued fields this
# changes nothing; over these it must be seen in every program.
SWAPPED="$M13_WORK/populate.swapped.out"
awk '
  $1 ~ /^populate\.[a-z0-9]+\.deployed\.instance\.salt\.observed$/ { k = $1; sub(/instance\.salt/, "instance.immutablesHash", k); swap[k] = $2 }
  $1 ~ /^populate\.[a-z0-9]+\.deployed\.instance\.immutablesHash\.observed$/ { k = $1; sub(/instance\.immutablesHash/, "instance.salt", k); swap[k] = $2 }
  { lines[NR] = $0; keys[NR] = $1 }
  END { for (i = 1; i <= NR; i++) { if (keys[i] in swap) print keys[i], swap[keys[i]]; else print lines[i] } }
' "$POUT" >"$SWAPPED"
read -r _ _ s_disagreed <<<"$(populate_compare "$SWAPPED")"
assert_eq "a decoder reading salt and immutablesHash from each other's positions is caught in every program" \
  "$((2 * M13_EXPECTED_PROGRAMS))" "$s_disagreed"

finish
