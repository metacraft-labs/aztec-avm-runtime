#!/usr/bin/env bash
# M12: the stripped standalone reactor stays within its gzipped size budget, and CI fails on
# regression.
#
# THE BUDGET IN THE MILESTONE IS STALE AND IS RE-DERIVED HERE RATHER THAN INHERITED.
#
# The deliverable states "1,259,737 bytes raw and 272,661 gzipped with the observation hook compiled
# in". That figure predates this artefact: it was taken from the vm2-wasm spike's reactor, which had
# no msgpack host ABI, no resident-DB export surface and no `testing/` translation units in its link
# closure. Measured on the module this milestone actually produces, it is 1,565,772 raw and 350,104
# gzipped. The number is corrected in the write-up rather than quietly satisfied by a weaker check.
#
# WHY THE BUDGET IS THE NUMBER IT IS. A budget equal to the measurement fails on any change at all
# and therefore gets raised rather than read. A budget pulled out of the air is not a budget either.
# This one is chosen so that THE UNPRUNED CONTROL FAILS IT: the same objects linked with
# `--export-dynamic` and without `--gc-sections` are 1,917,463 / 418,849, above both limits. A budget
# the control passes is a budget that would not notice the link options going away.
#
# Each of the four things the deliverable asks for is measured separately, because they are four
# different claims:
#
#   -Oz             read off every one of the reactor's own compile commands, from the build's own
#                   compile database.
#   exports pruned  the difference between `avm.wasm` and `avm-unpruned.wasm`, which adds
#                   `--export-dynamic` and nothing else.
#   --gc-sections   the difference between `avm.wasm` and `avm-nogc.wasm`, which adds
#                   `-Wl,--no-gc-sections` and nothing else. It needs its OWN control because
#                   wasm-ld collects by default: omitting `--gc-sections` does not disable it, and
#                   an earlier version of this check credited the collector with what the export
#                   list did.
#   symbols stripped   the difference between `avm.wasm` and the linker's own unstripped output.

set -uo pipefail

TEST_NAME=verify_avm_wasm_size_budget
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
m12_measured
note "tree: $M12_TREE"

REACTOR="$(m12_wasm_bin avm.wasm)"
REACTOR_GZ="$(m12_wasm_bin avm.wasm.gz)"
UNPRUNED="$(m12_wasm_bin avm-unpruned.wasm)"
UNPRUNED_GZ="$(m12_wasm_bin avm-unpruned.wasm.gz)"
NOGC="$(m12_wasm_bin avm-nogc.wasm)"
NOGC_GZ="$(m12_wasm_bin avm-nogc.wasm.gz)"
DEBUGMOD="$(m12_wasm_bin avm-reactor-debug.wasm)"
m8_require_artifacts "$REACTOR" "$REACTOR_GZ" "$UNPRUNED" "$UNPRUNED_GZ" "$NOGC" "$NOGC_GZ" "$DEBUGMOD"

raw=$(stat -c %s "$REACTOR")
gz=$(stat -c %s "$REACTOR_GZ")
unpruned_raw=$(stat -c %s "$UNPRUNED")
unpruned_gz=$(stat -c %s "$UNPRUNED_GZ")
nogc_raw=$(stat -c %s "$NOGC")
nogc_gz=$(stat -c %s "$NOGC_GZ")
debug=$(stat -c %s "$DEBUGMOD")

# --- the budget -------------------------------------------------------------
assert_true "the stripped reactor is within the raw budget ($raw <= $M12_SIZE_BUDGET_RAW)" \
  test "$raw" -le "$M12_SIZE_BUDGET_RAW"
assert_true "and within the gzipped budget ($gz <= $M12_SIZE_BUDGET_GZ)" \
  test "$gz" -le "$M12_SIZE_BUDGET_GZ"
note "raw margin: $((M12_SIZE_BUDGET_RAW - raw)) bytes ($(( (M12_SIZE_BUDGET_RAW - raw) * 100 / M12_SIZE_BUDGET_RAW ))%)"
note "gz margin:  $((M12_SIZE_BUDGET_GZ - gz)) bytes ($(( (M12_SIZE_BUDGET_GZ - gz) * 100 / M12_SIZE_BUDGET_GZ ))%)"

# The measurement is reported and its drift from what the write-up records is bounded, but it is
# NOT asserted as an identity: -Oz output moves with a toolchain bump and pinning it would make this
# check fail on a correct build. Ten per cent either way is a drift worth looking at.
drift_raw=$(( (raw - M12_MEASURED_RAW) * 100 / M12_MEASURED_RAW ))
drift_gz=$(( (gz - M12_MEASURED_GZ) * 100 / M12_MEASURED_GZ ))
assert_true "raw size is within 10% of the recorded measurement (drift ${drift_raw}%)" \
  test "${drift_raw#-}" -le 10
assert_true "gzipped size is within 10% of the recorded measurement (drift ${drift_gz}%)" \
  test "${drift_gz#-}" -le 10

# --- THE DISCRIMINATOR: the budget rejects BOTH controls --------------------
assert_true "the --export-dynamic control EXCEEDS the raw budget ($unpruned_raw > $M12_SIZE_BUDGET_RAW)" \
  test "$unpruned_raw" -gt "$M12_SIZE_BUDGET_RAW"
assert_true "and EXCEEDS the gzipped budget ($unpruned_gz > $M12_SIZE_BUDGET_GZ)" \
  test "$unpruned_gz" -gt "$M12_SIZE_BUDGET_GZ"
note "the pruned export list saves $((unpruned_raw - raw)) bytes raw and $((unpruned_gz - gz)) gzipped"

# THE SECOND CONTROL, and the reason it is a separate one. wasm-ld collects by DEFAULT, so the
# control above does not turn the collector off — it adds `--export-dynamic`, which makes every
# default-visibility symbol a GC root. `avm-nogc.wasm` is the same objects and the same explicit
# export list with `-Wl,--no-gc-sections`, and it is what `--gc-sections` is actually worth.
assert_true "the no-gc control EXCEEDS the raw budget ($nogc_raw > $M12_SIZE_BUDGET_RAW)" \
  test "$nogc_raw" -gt "$M12_SIZE_BUDGET_RAW"
assert_true "and EXCEEDS the gzipped budget ($nogc_gz > $M12_SIZE_BUDGET_GZ)" \
  test "$nogc_gz" -gt "$M12_SIZE_BUDGET_GZ"
assert_true "and the collector is worth MORE than the export list ($((nogc_raw - raw)) > $((unpruned_raw - raw)) bytes raw)" \
  test "$((nogc_raw - raw))" -gt "$((unpruned_raw - raw))"
note "--gc-sections alone saves $((nogc_raw - raw)) bytes raw and $((nogc_gz - gz)) gzipped"

# --- stripping, measured separately -----------------------------------------
assert_true "stripping is not a no-op: the linker's output is far larger ($debug > $raw)" \
  test "$debug" -gt "$((raw * 2))"
note "stripping saves $((debug - raw)) bytes"
# The stripped module still works — a strip that removed something load-bearing would show up as a
# module that no longer links, and this is the cheapest place to notice.
assert_eq "the stripped module still declares its full export set" "$M12_EXPORT_COUNT" \
  "$(m12_wasm_module_exports "$REACTOR" | grep -c .)"

# --- -Oz, read off the build's own compile commands -------------------------
db="$(m6_compile_db "$M12_TREE" "$M12_WASM_BUILD")"
assert_file "the wasm build has a compile database" "$db"
OWN_TUS="$(m6_own_tu_count "$M12_TREE" "$M12_WASM_BUILD")"
OZ_TUS="$(m6_flag_tu_count "$M12_TREE" "$M12_WASM_BUILD" -Oz own)"
assert_ge "the build compiles barretenberg's own sources" 100 "$OWN_TUS"
assert_eq "and EVERY one of them carries -Oz" "$OWN_TUS" "$OZ_TUS"
# The reactor's own translation units specifically, so the flag is not merely true on average.
# FOUR entries: `avm_reactor.cpp` is compiled three times — once for the shipped module and once for
# each of the two controls, which is what makes the controls comparisons of link options rather than
# of different builds — plus `avm_msgpack_coverage.cpp`.
assert_eq "the reactor's own translation units are in the database, avm_reactor.cpp three times" 4 \
  "$(m6_module_tu_count "$M12_TREE" "$M12_WASM_BUILD" '/vm2/reactor/')"
assert_eq "-O2 appears on none of barretenberg's own wasm translation units" 0 \
  "$(m6_flag_tu_count "$M12_TREE" "$M12_WASM_BUILD" -O2 own)"

# --- the gzip is the build's, and it reproduces ------------------------------
# `gzip -9 -n` is what the build runs; re-running it must give the same bytes, otherwise the number
# in the budget is a property of whichever gzip the checking script happened to find.
repro="$M12_WORK/avm.wasm.regz"
m6_in_devshell 'gzip -9 -n -c "$1" > "$2"' "$REACTOR" "$repro" >/dev/null 2>&1
assert_file "the gzip reproduces" "$repro"
assert_eq "and byte for byte" "$(sha256sum <"$REACTOR_GZ" | awk '{print $1}')" \
  "$(sha256sum <"$repro" | awk '{print $1}')"

# --- the comparison the milestone commits to --------------------------------
# Against the proving stack, measured FROM THIS TREE with THIS toolchain rather than quoted.
BB_GZ_FILE="$(m12_wasm_bin barretenberg.wasm.gz)"
assert_file "barretenberg.wasm.gz was built in the same tree" "$BB_GZ_FILE"
bb_gz=$(stat -c %s "$BB_GZ_FILE")
assert_ge "the proving stack is at least 8x larger gzipped" 8 "$((bb_gz / gz))"
note "avm.wasm.gz $gz bytes against barretenberg.wasm.gz $bb_gz — $((bb_gz * 10 / gz))/10 times smaller"
# The milestone quotes barretenberg-THREADS.wasm at 2.93 MiB gzipped. That preset is not configured
# in this tree, so what is measured here is the single-threaded `barretenberg.wasm` from the
# `wasm-avm` preset. Saying which artefact the ratio is against is the whole point of quoting it.
note "the milestone's 2.93 MiB figure is barretenberg-threads.wasm, a preset this tree does not configure"

# --- the write-up carries the same numbers ----------------------------------
assert_file "the reactor write-up exists" "$M12_WRITEUP"
# Read with thousands separators removed: the write-up spells 1,565,772 and the build reports
# 1565772, and a check that could not see through that would be a check about punctuation.
writeup="$(tr -d ',' <"$M12_WRITEUP" 2>/dev/null)"
# `$bb_gz` is deliberately NOT in this list, and its absence is a finding rather than a
# convenience. MEASURED: `barretenberg.wasm` is not byte-reproducible across build directories —
# two builds of the same tree with the same toolchain give the same SIZE (18,017,075) and 64
# differing bytes, which gzip turns into 4,046,715 against 4,046,721. `avm.wasm` IS byte-identical
# across those same two builds, so this is a property of the comparison artefact and not of the
# module under test. Requiring the write-up to carry that figure verbatim made this check fail on a
# correct build from a clean work directory, which is exactly the failure mode the drift bounds
# above exist to avoid. It is asserted with a tolerance below instead, and the write-up records it
# as a measurement from one tree rather than as an identity.
for n in "$raw" "$gz" "$unpruned_raw" "$unpruned_gz" "$nogc_raw" "$nogc_gz" \
         "$M12_SIZE_BUDGET_RAW" "$M12_SIZE_BUDGET_GZ"; do
  assert_contains "the write-up carries the measured figure $n" "$n" "$writeup"
done
bb_drift=$(( (bb_gz - M12_MEASURED_BARRETENBERG_GZ) * 10000 / M12_MEASURED_BARRETENBERG_GZ ))
assert_true "the proving stack's gzipped size is within ${M12_BARRETENBERG_GZ_TOLERANCE_PCT}% of the recorded $M12_MEASURED_BARRETENBERG_GZ (drift ${bb_drift}/100 %)" \
  test "${bb_drift#-}" -le "$((M12_BARRETENBERG_GZ_TOLERANCE_PCT * 100))"
assert_contains "and the write-up names the artefact the ratio is against" "barretenberg.wasm.gz" "$writeup"
assert_contains "and states that figure is not byte-reproducible rather than pinning it" \
  "not byte-reproducible" "$writeup"
# And it does NOT still carry the superseded ones.
assert_not_contains "and no longer states the superseded raw figure as this artefact's size" \
  "is 1259737 bytes raw" "$writeup"

# --- two modules, deliberately -----------------------------------------------
# The recorded decision NOT to add vm2_sim to BARRETENBERG_TARGET_OBJECTS. Sharing the existing
# barretenberg wasm would give one module instead of two and would couple public execution to a
# download a public-only page currently avoids entirely — measured here as the ratio above. The
# decision is asserted against the list itself, in the fork at the anchor AND after M12's overlay,
# so it cannot be reversed silently.
SRC_CMAKE="$M12_WORK/src_cmakelists.txt"
m8_upstream_file barretenberg/cpp/src/CMakeLists.txt "$SRC_CMAKE"
assert_ge "upstream's src/CMakeLists.txt declares BARRETENBERG_TARGET_OBJECTS" 1 \
  "$(grep -c 'set(BARRETENBERG_TARGET_OBJECTS' "$SRC_CMAKE")"
upstream_list="$(awk '/^set\(BARRETENBERG_TARGET_OBJECTS/,/^\)/' "$SRC_CMAKE")"
assert_ge "and the list is non-empty, so the absence below is not vacuous" 10 \
  "$(printf '%s\n' "$upstream_list" | grep -c 'TARGET_OBJECTS:')"
assert_eq "vm2_sim is NOT in it at the anchor" 0 \
  "$(printf '%s\n' "$upstream_list" | grep -c 'vm2_sim')"
tree_list="$(awk '/^set\(BARRETENBERG_TARGET_OBJECTS/,/^\)/' "$M12_TREE/barretenberg/cpp/src/CMakeLists.txt")"
assert_eq "and M12's overlay does not add it" 0 "$(printf '%s\n' "$tree_list" | grep -c 'vm2_sim')"
assert_eq "M12's overlay does not touch src/CMakeLists.txt at all" 0 \
  "$(m6_patch_files "$M12_PATCH_9" | grep -cx 'barretenberg/cpp/src/CMakeLists.txt')"
assert_contains "and the decision is recorded with its cost" "BARRETENBERG_TARGET_OBJECTS" "$writeup"
assert_contains "naming the download a public-only page would take on" "barretenberg.wasm" "$writeup"

# --- enforced in CI ---------------------------------------------------------
# Stated precisely rather than generously: the workflow entry exists and names this check. Whether
# it has ever RUN is a separate question and the write-up answers it; a check that read "the job is
# defined" and reported "the budget is enforced" would be the overstatement this campaign has met.
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the AVM_WASM workflow exists" "$WF"
wf="$(cat "$WF" 2>/dev/null)"
assert_contains "and it has a job for the reactor" "avm-reactor" "$wf"
assert_contains "which runs the whole M12 set" "just verify-m12" "$wf"
assert_contains "with M12_WORK pointed somewhere that can hold the builds" "M12_WORK:" "$wf"
assert_contains "and the M12 overlay patch asserted present before the build" \
  "verification/m12/0001-test-vm2-AVM_REACTOR" "$wf"

finish
