#!/usr/bin/env bash
# verify_no_interpreter_source_change — `vm2/simulation/**` differs from
# upstream only by changes that are named, one at a time, and the throw/catch
# sites the AVM's revert path is built on are untouched.
#
# THE MILESTONE'S WORDING, AND WHY IT IS NARROWED HERE
#
# M6's verification entry says `vm2/simulation/**` differs from upstream "only
# by the M5 shift widening and the M9 observation hook". Two corrections, both
# from measurement:
#
#   * M9's hook is NOT in this build. The AVM_WASM stack is patches 1, 2, 3 and
#     5 of the series; patch 4, the observation hook, is not applied, and its
#     `simulation/interfaces/execution_observer.hpp` is asserted absent here.
#   * The AVM_WASM patch itself changes TWO files under `vm2/simulation/**`,
#     and M6's own deliverable requires it to: `gadgets/to_radix.cpp` and
#     `lib/indexed_memory_tree.hpp`, the narrowing corrections. A check written
#     to the letter of the entry would have to fail the build it is verifying.
#
# So what is asserted is the exact file set, each file attributed to the patch
# that changes it, each with its exact added/removed line counts, and — the
# statement the entry is really making — that not one added or removed line
# under `vm2/simulation/**` mentions `throw` or `catch`.
#
# THE CONTROL. Every predicate is also run against a worktree of the spike's own
# `spike.patch`, which DOES change the interpreter: it adds
# `execution_observer.hpp` and edits `standalone/hybrid_execution.cpp`. A check
# that reports "nothing changed" needs a tree where something did.

set -uo pipefail

TEST_NAME=verify_no_interpreter_source_change
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

m6_prepare_trees
m6_prepare_spike_tree

SIM=barretenberg/cpp/src/barretenberg/vm2/simulation

# ---------------------------------------------------------------------------
# The exact file set, and each file's attribution.
# ---------------------------------------------------------------------------
CHANGED="$(m6_sim_diff "$M6_TREE_AVM" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "vm2/simulation/** differs from $M6_BASE_REV in exactly three files" \
  "$M6_EXPECTED_SIM_DIFF" "$CHANGED"

assert_eq "lib/contract_crypto.cpp is patch 3's (M5's) widening, and only that patch touches it" \
  "1 0" "$(printf '%s %s' \
      "$(m6_patch_files "$M6_PATCH_3" | grep -c "$SIM/lib/contract_crypto.cpp")" \
      "$(m6_patch_files "$M6_PATCH_4" | grep -c "$SIM/lib/contract_crypto.cpp")")"
assert_eq "gadgets/to_radix.cpp is patch 4's (M6's) narrowing, and only that patch touches it" \
  "0 1" "$(printf '%s %s' \
      "$(m6_patch_files "$M6_PATCH_3" | grep -c "$SIM/gadgets/to_radix.cpp")" \
      "$(m6_patch_files "$M6_PATCH_4" | grep -c "$SIM/gadgets/to_radix.cpp")")"
assert_eq "lib/indexed_memory_tree.hpp likewise" \
  "0 1" "$(printf '%s %s' \
      "$(m6_patch_files "$M6_PATCH_3" | grep -c "$SIM/lib/indexed_memory_tree.hpp")" \
      "$(m6_patch_files "$M6_PATCH_4" | grep -c "$SIM/lib/indexed_memory_tree.hpp")")"
assert_eq "patches 1 and 2 touch nothing under vm2/simulation at all" \
  "0" "$(( $(m6_patch_files "$M6_PATCH_1" | grep -c "$SIM/") + \
           $(m6_patch_files "$M6_PATCH_2" | grep -c "$SIM/") ))"

# The size of each change, as git counts it. A file named in the expected set
# could still have grown by two hundred lines.
NUMSTAT="$(git -C "$M6_TREE_AVM" diff --numstat "$M6_BASE_REV..HEAD" -- "$SIM/" \
           | awk '{printf "%s+%s/-%s ", $3, $1, $2}' | sed 's/ $//')"
assert_eq "and the three changes are exactly this big" \
  "$SIM/gadgets/to_radix.cpp+1/-1 $SIM/lib/contract_crypto.cpp+3/-1 $SIM/lib/indexed_memory_tree.hpp+15/-13" \
  "$NUMSTAT"

# M5's change, by identity rather than by count.
M5_DIFF="$(git -C "$M6_TREE_AVM" diff "$M6_BASE_REV..HEAD" -- "$SIM/lib/contract_crypto.cpp" \
           | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')"
assert_contains "the removed line is the truncating shift" \
  "-    return FF(uint256_t(DOM_SEP__PUBLIC_BYTECODE) + uint256_t(bytecode_size << 32));" "$M5_DIFF"
assert_contains "the added line widens first" \
  "+    return FF(uint256_t(DOM_SEP__PUBLIC_BYTECODE) + (uint256_t(bytecode_size) << 32));" "$M5_DIFF"

# M6's to_radix change, likewise.
TR_DIFF="$(git -C "$M6_TREE_AVM" diff "$M6_BASE_REV..HEAD" -- "$SIM/gadgets/to_radix.cpp" \
           | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')"
assert_contains "to_radix's addend is cast to the iterator's difference_type" \
  "static_cast<std::vector<uint8_t>::difference_type>(num_limbs)" "$TR_DIFF"

# ---------------------------------------------------------------------------
# M9's hook is not in this build, and is asserted absent rather than assumed.
# ---------------------------------------------------------------------------
assert_false "simulation/interfaces/execution_observer.hpp does not exist in the AVM_WASM tree" \
  test -e "$M6_TREE_AVM/$SIM/interfaces/execution_observer.hpp"
assert_eq "and standalone/hybrid_execution.cpp is byte-identical to upstream's" \
  "$(git -C "$M6_TREE_AVM" rev-parse "$M6_BASE_REV:$SIM/standalone/hybrid_execution.cpp")" \
  "$(git -C "$M6_TREE_AVM" rev-parse "HEAD:$SIM/standalone/hybrid_execution.cpp")"

# ---------------------------------------------------------------------------
# THE STATEMENT THE ENTRY IS REALLY MAKING: the revert path is untouched.
# ---------------------------------------------------------------------------
assert_eq "not one added or removed line under vm2/simulation mentions throw or catch" \
  "0" "$(m6_sim_diff_throw_catch_lines "$M6_TREE_AVM")"

# The census, with its definition stated. "~40 files and 327 throw/catch sites"
# is a number whose value depends entirely on what is counted; under the nearest
# reproducible definition — non-test, non-bench `.cpp` under vm2/simulation/ —
# it is 40 files and 326 sites at this base commit, and it must be the same on
# both sides.
census_cpp() { # <tree> -> "<files-with-a-site> <sites>"
  local d="$1/$SIM" f s
  f=$(find "$d" -name '*.cpp' | grep -v '\.test\.\|\.bench\.' \
      | xargs grep -lE '\b(throw|catch)\b' 2>/dev/null | wc -l)
  s=$(find "$d" -name '*.cpp' | grep -v '\.test\.\|\.bench\.' \
      | xargs grep -ohE '\b(throw|catch)\b' 2>/dev/null | wc -l)
  printf '%s %s\n' "$f" "$s"
}
CENSUS_BASE="$(census_cpp "$M6_TREE_BASE")"
CENSUS_AVM="$(census_cpp "$M6_TREE_AVM")"
assert_eq "upstream's own census: 40 files carrying 326 throw/catch sites" "40 326" "$CENSUS_BASE"
assert_eq "the AVM_WASM tree's is identical" "$CENSUS_BASE" "$CENSUS_AVM"

# The wider census too, so a change hiding in a header is not missed.
assert_eq "and the whole-directory census (.cpp and .hpp) is identical as well" \
  "$(m6_sim_census "$M6_TREE_BASE")" "$(m6_sim_census "$M6_TREE_AVM")"
note "vm2/simulation census (files, throw, catch): $(m6_sim_census "$M6_TREE_AVM")"

# ---------------------------------------------------------------------------
# THE CONTROL. The spike's change set, measured the same way, must be caught.
# ---------------------------------------------------------------------------
SPIKE_CHANGED="$(m6_sim_diff "$M6_TREE_SPIKE" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the spike's tree changes three files under vm2/simulation, and they are not these" \
  "$SIM/interfaces/execution_observer.hpp $SIM/lib/contract_crypto.cpp $SIM/standalone/hybrid_execution.cpp" \
  "$SPIKE_CHANGED"
assert_eq "the expected set and the spike's set have exactly one file in common" \
  "1" "$(comm -12 <(printf '%s\n' $M6_EXPECTED_SIM_DIFF | sort) \
                  <(printf '%s\n' $SPIKE_CHANGED | sort) | grep -c .)"
assert_true "so this measurement distinguishes the two trees" \
  test "$CHANGED" != "$SPIKE_CHANGED"
assert_true "the spike adds the observation hook header the AVM_WASM tree does not have" \
  test -e "$M6_TREE_SPIKE/$SIM/interfaces/execution_observer.hpp"
# Worth recording rather than glossing: even the spike, which DID change the
# interpreter, changed no throw/catch line. Its hook is a call inserted in the
# fast execution loop, not a change to the revert path. So the spike is a
# control for the FILE SET but not for the throw/catch measurement, and that one
# needs its own.
assert_eq "the spike changes the interpreter but still touches no throw/catch line" \
  "0" "$(m6_sim_diff_throw_catch_lines "$M6_TREE_SPIKE")"

# ---------------------------------------------------------------------------
# THE MUTATION CONTROL for the throw/catch measurement. A count of zero is what
# a measurement that looks at nothing also reports, so one throw site is edited
# in a scratch tree and the count is required to move — by exactly the number of
# lines edited, not merely to be non-zero.
# ---------------------------------------------------------------------------
m6_reset_tree simmut
SIMMUT=$(m6_prepare_tree simmut "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4")
# The substitution swallows `die`, so an unpreparable tree arrives here as the
# empty string and every `git -C ""` below runs in the CALLER's repository —
# where the throw/catch count is 0 and the assertion passes having measured
# nothing. Guard the assignment, exactly as m6_prepare_trees does.
m6_tree_or_die SIMMUT
assert_eq "the mutation tree starts clean, reporting zero touched throw/catch lines" \
  "0" "$(m6_sim_diff_throw_catch_lines "$SIMMUT" "$M6_BASE_REV")"
MUT_FILE="$SIMMUT/$SIM/gadgets/addressing.cpp"
assert_file "the file the mutation edits exists" "$MUT_FILE"
assert_not_contains "and it is not one of the three the patches already change" \
  "$SIM/gadgets/addressing.cpp" "$M6_EXPECTED_SIM_DIFF"
python3 - "$MUT_FILE" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    if re.match(r"^\s*throw ", l):
        lines[i] = l.replace("throw ", "throw /* mutated */ ", 1)
        break
else:
    raise SystemExit("no throw line found")
open(p, "w").write("\n".join(lines))
PY
assert_eq "editing exactly one throw line was possible" "0" "$?"
assert_eq "the measurement then reports exactly two touched lines (the - and the +)" \
  "2" "$(m6_sim_diff_throw_catch_lines "$SIMMUT" "$M6_BASE_REV")"
assert_eq "and the file set grows by exactly that one file" \
  "4" "$(m6_sim_diff "$SIMMUT" "$M6_BASE_REV" | grep -c .)"
note "mutation control edited $(basename "$MUT_FILE")"
m6_reset_tree simmut
assert_eq "the mutation tree is clean again" \
  "0" "$(m6_sim_diff_throw_catch_lines "$SIMMUT" "$M6_BASE_REV")"

finish
