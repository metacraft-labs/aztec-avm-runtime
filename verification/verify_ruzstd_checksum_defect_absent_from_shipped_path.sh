#!/usr/bin/env bash
# verify_ruzstd_checksum_defect_absent_from_shipped_path
#
# M41 verification: the Path B module contains NO `ruzstd`, so the decoder that accepts a frame
# corrupted under a content checksum is not in it.
#
# ---------------------------------------------------------------------------
# WHAT THE DEFECT IS, AND WHY IT DECIDED A MILESTONE
# ---------------------------------------------------------------------------
#
# Handed a zstd frame whose payload has been corrupted under a content checksum, C libzstd refuses.
# `ruzstd` returns 4,194,304 bytes of wrong data with no error — native and wasm32 alike. It is not
# a parsing gap: it READS the checksum, it COMPUTES the checksum, and it compares them nowhere
# outside its own test suite. That is this campaign's silent-wrong-answer shape, on the compressor
# `ct-writer/Cargo.lock` resolves for Path A today.
#
# THIS CHECK DOES NOT RE-DERIVE THE DEFECT, and says so rather than implying it did. The measurement
# lives in `tracing-formats-benchmarks/results/wasm_writer/REPORT.md` §12–§14 and is not repeated
# here: reproducing it would mean building a corrupted-frame corpus and a `ruzstd` harness inside
# this repository, which is a second copy of somebody else's evidence. What is measured HERE is the
# narrower fact this repository owns and can regress: **is that decoder in the module this runtime
# would ship?**
#
# ---------------------------------------------------------------------------
# THE CONTROL IS PATH A, AND IT IS THE STRONGEST ONE AVAILABLE
# ---------------------------------------------------------------------------
#
# "The Path B module contains no `ruzstd`" is satisfied by a search that can find nothing. So the
# SAME search is run against the Path A module, which does contain it, and must find it. The two
# arms differ in one thing — which writer was selected — and the search is identical.
#
# The dependency graph is checked in the same two directions: `path-b` resolves neither
# `codetracer_ctfs` nor `ruzstd` as a *linked* dependency, because the Path A crates are optional
# and gated on `path-a`; the default build resolves both.
#
# Run: just verify-ruzstd-defect-absent

TEST_NAME="verify_ruzstd_checksum_defect_absent_from_shipped_path"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"

m41_require_path_a
m41_require_path_b

# ---------------------------------------------------------------------------
# 1. The binaries.
# ---------------------------------------------------------------------------
count_needle() { # <module> <needle>
  python3 -c "
import sys
data = open(sys.argv[1], 'rb').read()
print(data.count(sys.argv[2].encode()))
" "$1" "$2"
}

A_RUZSTD="$(count_needle "$M41_PATH_A" ruzstd)"
B_RUZSTD="$(count_needle "$M41_PATH_B" ruzstd)"
m41_say "the string 'ruzstd' appears $A_RUZSTD times in the Path A module and $B_RUZSTD in Path B"

assert_ge "THE CONTROL: the search DOES find ruzstd in the Path A module" 1 "$A_RUZSTD"
assert_eq "and finds it ZERO times in the Path B module" "0" "$B_RUZSTD"

# The needle is shown to be a needle rather than a word that never occurs anywhere: a string both
# modules DO contain must be found in both, or "zero" above could be a property of the reader.
A_ZSTD="$(count_needle "$M41_PATH_A" zstd)"
B_ZSTD="$(count_needle "$M41_PATH_B" zstd)"
assert_ge "the reader finds 'zstd' in the Path A module" 1 "$A_ZSTD"
assert_ge "and finds 'zstd' in the Path B module too, so the reader can read it" 1 "$B_ZSTD"
m41_say "'zstd' appears $A_ZSTD times in Path A and $B_ZSTD in Path B — both compress; only one does it in Rust"

# A fabricated needle must be found in NEITHER, so the counter is not simply answering yes.
for arm in "$M41_PATH_A" "$M41_PATH_B"; do
  N="$(count_needle "$arm" ruzstd_that_is_not_a_crate)"
  assert_eq "a fabricated needle is found zero times in $(basename "$(dirname "$(dirname "$arm")")")" "0" "$N"
done

# ---------------------------------------------------------------------------
# 2. The dependency graph, which is where the module's contents come from.
# ---------------------------------------------------------------------------
LOCK="$M41_CRATE/Cargo.lock"
assert_file "ct-writer has a lock file" "$LOCK"
assert_true "and it resolves ruzstd, which is what Path A links" \
  grep -q 'name = "ruzstd"' "$LOCK"

MANIFEST="$M41_CRATE/Cargo.toml"
assert_true "the Path A crates are OPTIONAL, so a path-b build does not link them" \
  grep -qE 'codetracer_trace_writer = \{ path = .*optional = true' "$MANIFEST"
assert_true "and they are gated on the path-a feature by name" \
  grep -qE '^path-a = \["dep:codetracer_trace_types", "dep:codetracer_trace_writer"\]' "$MANIFEST"
assert_true "while path-b names no crate at all" grep -qE '^path-b = \[\]' "$MANIFEST"

# ---------------------------------------------------------------------------
# 3. And the Nim tree the Path B module IS has no ruzstd anywhere in it either.
#
# The binary search above could in principle be satisfied by a compressor that was inlined without
# leaving its crate name behind. The source tree cannot be.
# ---------------------------------------------------------------------------
NIM_SRC="$M41_CRATE/build-wasm-deps/ctf-nim"
assert_dir "the Nim writer source the Path B module was built from is materialised" "$NIM_SRC"
NIM_HITS="$(grep -ril 'ruzstd' "$NIM_SRC" 2>/dev/null | grep -c . || true)"
assert_eq "and no file in it mentions ruzstd" "0" "$NIM_HITS"
# The same grep DOES find the compressor the Nim writer actually uses, so the search is a search.
ZSTD_HITS="$(grep -ril 'zstd' "$NIM_SRC" 2>/dev/null | grep -c . || true)"
assert_ge "while the same grep finds zstd, which is what it binds" 1 "$ZSTD_HITS"
m41_say "the materialised Nim tree: $NIM_HITS files mention ruzstd, $ZSTD_HITS mention zstd"

finish
