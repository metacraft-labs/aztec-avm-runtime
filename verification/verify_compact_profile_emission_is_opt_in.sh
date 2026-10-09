#!/usr/bin/env bash
# verify_compact_profile_emission_is_opt_in
#
# CCP-6 verification: this runtime's writer CAN emit `ctfs-container.md` §1e's COMPACT container
# profile, it does so only when a caller explicitly asks, and the container it emits carries the
# same recording as the full one.
#
# ---------------------------------------------------------------------------
# THE GAP THIS CLOSES, MEASURED BEFORE IT WAS CLOSED.
#
# Both trace-format libraries carry the profile choice at `pins.json`'s anchors:
# `codetracer_trace_writer::compact_profile::select_profile` in the Rust tree and `selectProfile` in
# the Nim one, reached from `CtfsTraceWriter::with_compact_threshold` and from the C ABI's
# `trace_writer_set_compact_threshold`. Both are gated on a threshold that is initialised to ZERO.
# `compact_threshold` had ZERO occurrences anywhere under this repository's `ct-writer`: the glue
# never set it, so `select_profile` was never asked for compact and no container this runtime has
# ever written could be anything but the full profile. The producer-side gap was the whole of that.
#
# THE INEQUALITY RUNS THE WAY THAT LOOKS BACKWARDS, and §4 below measures it at the boundary rather
# than restating it. `select_profile` emits COMPACT when the finished container's members total
# FEWER than the threshold's raw bytes — the threshold is a CEILING, compact is for SMALL
# recordings, and `0` means NEVER because nothing is below zero. §4 derives the recording's raw
# member total from the compact container's OWN directory and drives the module twice more, at that
# total and at one byte above it: the first must be full and the second compact. A one-byte control
# is what makes the direction a measurement; prose about it would be the thing this campaign
# distrusts most.
#
# ---------------------------------------------------------------------------
# THE SAFETY PROPERTY IS THE POINT, AND IT IS A PROPERTY OF ANOTHER REPOSITORY'S PIN.
#
# A compact container is container VERSION 6 with its profile byte (offset 16) set to 1. This
# runtime's full containers are version 5. BlockTracer's deployed replay engine is pinned BY CONTENT
# in `client/hydrate/engine-pin.txt`, and an engine without CCP-5's compact loader refuses a
# version-6 container outright — no steps, no replay, on every published page. So the capability
# ships OFF, and §6 asserts that nothing in this tree asks for it: the only non-zero threshold
# passed anywhere is the one this check passes.
#
# §5 turns "a reader in the path cannot read it" into a measurement rather than a caution, with two
# real binaries at the SAME pinned revision:
#
#   * `ct-print`       — gated on `ctfsVersionError`, version 5 only. REFUSES the compact container
#                        by name. This is the shape of refusal the deployed engine produces, from a
#                        binary, and it is also the control that says a reader CAN refuse: a probe
#                        that read everything would make §5's success meaningless.
#   * `ct-split-probe` — `openNewTrace`, gated on `ctfsReadableVersionError`, versions 5 and 6.
#                        READS the compact container, and every fact it reports about the recording
#                        is identical to the full container's.
#
# That pair is also a correction to the brief this work came from, which held that `ct-print` at the
# pinned revision reads compact. It does not; the LIBRARY at that revision does, through the other
# gate, and `pins.json`'s own prose for the `trace_format_nim` anchor ("container v5 and v6") is a
# statement about the library and not about that binary.
#
# THE FACTS COMPARED ARE NOT ALL OF THE PROBE'S OUTPUT, AND THE EXCLUSIONS ARE NAMED. §1e stores the
# compact members RAW — every zstd frame inflated — so the probe's `PLEDGE_*` lines, which ask
# whether a member is a zstd frame with a pledged content size, legitimately differ, as does the
# count of chunk decompressions. Those are facts about STORAGE. Every fact about the RECORDING must
# agree, and §5 asserts both halves: the agreeing set is compared line for line, and the differing
# set is asserted to be exactly those five keys — so a sixth difference appearing fails here rather
# than being absorbed by a filter.
#
# Run: just verify-compact-profile-opt-in

TEST_NAME="verify_compact_profile_emission_is_opt_in"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (coreutils, from the dev shell)"

TAB_=$'\t'

CRATE_TOML="$M41_CRATE/Cargo.toml"
assert_file "the writer crate's manifest is where it is expected" "$CRATE_TOML"

# ---------------------------------------------------------------------------
# 1. WHICH WRITER THE RUNTIME SHIPS, because the lever is a different one on each path.
#
# The manifest's default feature decides it, and the module's own `ct_writer_kind()` confirms it.
# Asserting only the manifest would be asserting a declaration; asserting only the kind would not
# say which build the figure belongs to.
# ---------------------------------------------------------------------------
DEFAULT_FEATURE="$(sed -n 's/^default *= *\[\"\([a-z-]*\)\"\].*/\1/p' "$CRATE_TOML" | head -1)"
assert_eq "ct-writer's default feature is path-b, so the shipped module is the NIM writer and the lever is its C ABI's trace_writer_set_compact_threshold" \
  "path-b" "$DEFAULT_FEATURE"

m41_require_path_b
m41_drive "$M41_PATH_B" compact-absent
m41_drive "$M41_PATH_B" compact-zero 0
assert_eq "and the module built from it reports ct_writer_kind() = 2, DD-7's Path B" \
  "2" "$(m41_report compact-absent writerKind)"

ABSENT="$M41_WORK/compact-absent/container.ct"
ZERO="$M41_WORK/compact-zero/container.ct"

# ---------------------------------------------------------------------------
# 2. THE DEFAULT IS UNCHANGED, AND "unchanged" IS A BYTE COMPARISON.
#
# Two drives: one that passes no threshold at all — which is every caller written before CCP-6 —
# and one that passes an explicit `0`. The export is CALLED on both, because the driver calls it on
# every run; what differs is whether the caller named a value. The containers must be identical,
# which is what makes the export's presence free.
# ---------------------------------------------------------------------------
assert_eq "the drive that passes NO threshold reports 0, the writer's own default" \
  "0" "$(m41_report compact-absent compactThreshold)"
assert_eq "the drive that passes an explicit 0 reports 0 as well" \
  "0" "$(m41_report compact-zero compactThreshold)"
assert_true "and the two containers are byte-identical, so naming the default costs nothing" \
  cmp -s "$ABSENT" "$ZERO"
assert_eq "the default container is container VERSION 5" "5" "$(m41_report compact-absent containerVersion)"
assert_eq "…and carries no profile byte, because only version 6 has one" \
  "" "$(m41_report compact-absent containerProfile)"
m41_say "default container: $(wc -c <"$ABSENT") bytes, sha256 $(sha256sum "$ABSENT" | cut -c1-16)…"

# ---------------------------------------------------------------------------
# 3. THE OPT-IN EMITS A COMPACT CONTAINER, read out of the container's own header bytes.
# ---------------------------------------------------------------------------
HIGH=67108864
m41_drive "$M41_PATH_B" compact-high "$HIGH"
COMPACT="$M41_WORK/compact-high/container.ct"
assert_eq "with a 64 MiB ceiling the container is VERSION 6" "6" "$(m41_report compact-high containerVersion)"
assert_eq "…and its profile byte says 1, Profile::Compact" "1" "$(m41_report compact-high containerProfile)"
# The magic, read from the file rather than from the report, so §3 does not rest on one reader.
assert_eq "the first five bytes are still the CTFS magic C0 DE 72 AC E2" "c0de72ace2" \
  "$(head -c 5 "$COMPACT" | od -An -tx1 | tr -d ' \n')"
assert_eq "and byte 5 — the version — is 6 on disk, not merely in the report" "06" \
  "$(dd if="$COMPACT" bs=1 skip=5 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
assert_eq "and byte 16 — the profile — is 01 on disk" "01" \
  "$(dd if="$COMPACT" bs=1 skip=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
# THE CONTROL FOR §3: the same three reads over the DEFAULT container must NOT say compact. A header
# check that could not tell the two apart would pass over either.
assert_eq "THE CONTROL: byte 5 of the DEFAULT container is 05, so the read discriminates" "05" \
  "$(dd if="$ABSENT" bs=1 skip=5 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
assert_false "and the two containers are NOT byte-identical, so §2's comparison can fail" \
  cmp -s "$ABSENT" "$COMPACT"
FULL_BYTES="$(wc -c <"$ABSENT")"
COMPACT_BYTES="$(wc -c <"$COMPACT")"
m41_say "full profile $FULL_BYTES bytes, compact profile $COMPACT_BYTES bytes, same recording"
# A SIZE REDUCTION IS REPORTED AND IS NOT THE CLAIM. §5 is the claim. This assertion exists only so
# that a compact container that somehow came out larger than the full one would be noticed.
assert_true "the compact container is smaller than the full one" test "$COMPACT_BYTES" -lt "$FULL_BYTES"

# ---------------------------------------------------------------------------
# 4. THE INEQUALITY DIRECTION, AT THE BOUNDARY, derived from the artefact.
#
# `raw_member_bytes` is the sum of the compact directory's lengths, and the compact container states
# it: `Size = 28 + 24*N + sum(length)` (§1d). So the recording's raw total is read out of the
# container rather than typed here, and the two drives below sit one byte either side of it.
# `raw < threshold` is STRICT, so the threshold EQUAL to the total must give the FULL profile.
# ---------------------------------------------------------------------------
read -r MEMBERS RAW_TOTAL DIR_SIZE <<<"$(python3 - "$COMPACT" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
n = struct.unpack_from("<I", d, 24)[0]
total = sum(struct.unpack_from("<QQQ", d, 28 + 24 * i)[2] for i in range(n))
print(n, total, 28 + 24 * n + total)
PY
)" || die "the compact directory could not be read"
assert_eq "the compact directory's own arithmetic closes: 28 + 24*N + sum(length) IS the file size" \
  "$COMPACT_BYTES" "$DIR_SIZE"
m41_say "compact directory: $MEMBERS members, $RAW_TOTAL raw member bytes"
assert_true "and there are members to total, so the boundary below is not a boundary at zero" \
  test "$MEMBERS" -gt 0

m41_drive "$M41_PATH_B" compact-at "$RAW_TOTAL"
m41_drive "$M41_PATH_B" compact-above "$((RAW_TOTAL + 1))"
assert_eq "a threshold EQUAL to the $RAW_TOTAL raw member bytes gives the FULL profile: the inequality is strict" \
  "5" "$(m41_report compact-at containerVersion)"
assert_eq "…and ONE BYTE above it gives version 6" "6" "$(m41_report compact-above containerVersion)"
assert_eq "…profile 1" "1" "$(m41_report compact-above containerProfile)"
assert_true "the at-the-boundary container is byte-identical to the default one, so the full arm really is the full arm" \
  cmp -s "$ABSENT" "$M41_WORK/compact-at/container.ct"
assert_true "and the one-above container is byte-identical to the 64 MiB one: any ceiling above the total gives the SAME compact container" \
  cmp -s "$COMPACT" "$M41_WORK/compact-above/container.ct"

# ---------------------------------------------------------------------------
# 5. A REAL READER OPENS IT, AND THE TWO PROFILES AGREE ON THE RECORDING.
# ---------------------------------------------------------------------------
m41_require_readers
assert_file "the split-stream reference reader was built" "$M41_PROBE_NEW"
assert_file "and ct-print, whose gate is the version-5-only one" "$M41_PRINT_NEW"

PROBE_FULL="$(m41_probe "$M41_PROBE_NEW" "$ABSENT")"
PROBE_COMPACT="$(m41_probe "$M41_PROBE_NEW" "$COMPACT")"
assert_true "the reference reader OPENS the compact container" \
  str_has_line "$PROBE_COMPACT" "OPEN${TAB_}ok"
assert_true "…and finishes" str_has_line "$PROBE_COMPACT" "DONE${TAB_}ok"
assert_true "and it opens the full one too, so the reader is not simply permissive about one shape" \
  str_has_line "$PROBE_FULL" "OPEN${TAB_}ok"

# THE STORAGE FACTS ARE EXPECTED TO DIFFER AND ARE NAMED. §1e inflates every zstd frame and stores
# the members as they are, so a member of a compact container is NOT a zstd frame. Anything else
# differing is a finding.
# `$TAB_` AND NOT `\\t`: `grep -E` has no `\\t` escape, so a pattern spelled that way matches a
# literal backslash-t, filters nothing, and the equality below then compares the storage lines it
# was supposed to exclude. It did exactly that on the first run.
STORAGE_KEYS="^(PLEDGE_[A-Za-z0-9_.]+|EXEC_CHUNK_DECOMPRESSIONS)$TAB_"
DIFFERING="$(diff <(printf '%s\n' "$PROBE_FULL") <(printf '%s\n' "$PROBE_COMPACT") \
  | sed -n 's/^[<>] //p' | cut -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "exactly five keys differ between the two profiles, and all five are about STORAGE" \
  "EXEC_CHUNK_DECOMPRESSIONS PLEDGE_calls.dat PLEDGE_events.dat PLEDGE_steps.dat PLEDGE_values.dat" \
  "$DIFFERING"
FACTS_FULL="$(printf '%s\n' "$PROBE_FULL" | grep -Ev "$STORAGE_KEYS")"
FACTS_COMPACT="$(printf '%s\n' "$PROBE_COMPACT" | grep -Ev "$STORAGE_KEYS")"
# THE CONTROL FOR THE COMPARISON BELOW: the set it compares is not empty and contains the facts that
# matter. A filter that had removed everything would make the equality vacuous, and this campaign has
# shipped exactly that shape of assertion before.
assert_ge "the compared set is not a residue: at least twenty fact lines survive the filter" 20 \
  "$(printf '%s\n' "$FACTS_COMPACT" | grep -c . || true)"
assert_true "…and it contains the step count" str_has_line "$FACTS_COMPACT" "STEP_COUNT${TAB_}8"
assert_true "…the path count" str_has_line "$FACTS_COMPACT" "PATH_COUNT${TAB_}2"
assert_true "…the value count" str_has_line "$FACTS_COMPACT" "VALUE_COUNT${TAB_}8"
assert_true "…the call count" str_has_line "$FACTS_COMPACT" "CALL_COUNT${TAB_}2"
assert_eq "EVERY FACT THE READER REPORTS ABOUT THE RECORDING IS IDENTICAL ACROSS THE TWO PROFILES" \
  "$FACTS_FULL" "$FACTS_COMPACT"

# THE DEPLOYED-READER SHAPE, FROM A BINARY. `ct-print` at the same pinned revision reads version 5
# only, so it refuses the compact container exactly as an engine without CCP-5's loader does — and
# reads the full one, which is what makes the refusal a fact about the VERSION rather than about the
# binary being broken.
PRINT_COMPACT="$(m41_probe "$M41_PRINT_NEW" "$COMPACT")"
PRINT_FULL="$(m41_probe "$M41_PRINT_NEW" "$ABSENT")"
assert_true "ct-print, the version-5-only gate, REFUSES the compact container and names the version" \
  str_has_sub "$PRINT_COMPACT" "CTFS container version 6 is not supported"
assert_true "…and it READS the full one, so the refusal is about the version and not about the reader" \
  str_has_sub "$PRINT_FULL" "program: aztec-avm-runtime"
assert_false "…and nothing of the recording comes back from the refused one" \
  str_has_sub "$PRINT_COMPACT" "program: aztec-avm-runtime"

# ---------------------------------------------------------------------------
# 6. NOTHING IN THIS TREE ASKS FOR IT. The capability is OFF, and that is asserted over the tree's
#    own text rather than claimed in a comment.
#
#    Searched over the git index AND the working tree (`--untracked`), because a caller added in an
#    unstaged file is still a caller, and a tracked-file scan is blind to a file that has just been
#    written.
# ---------------------------------------------------------------------------
# A COMMENT THAT MENTIONS THE ARGUMENT IS NOT A CALLER. `lib_m41_writer.sh`'s own usage line is
# `# m41_drive <module> <label> [compact-threshold]`, which the pattern matches and which passes no
# threshold to anything; the second filter drops any hit whose line begins with `#`.
drive_callers() { # [extra git-grep args...]
  git -C "$REPO_ROOT" grep -nE --untracked 'm41_drive +[^ ]+ +[^ ]+ +[^ ]' -- verification "$@" \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true
}
assert_eq "no check but this one passes m41_drive a threshold at all" "" \
  "$(drive_callers ":!verification/verify_compact_profile_emission_is_opt_in.sh")"
# THE CONTROL: the search is a search. Unfiltered, it must find THIS check's own calls.
assert_ge "THE CONTROL: unfiltered, the same search finds this check's own threshold drives" 4 \
  "$(drive_callers | grep -c . || true)"
assert_eq "and no tool or check runs the driver with a non-zero third argument" "" \
  "$(git -C "$REPO_ROOT" grep -nE --untracked 'ct_writer_drive\.mjs[^|&;]* [1-9][0-9]*' \
     -- verification tools || true)"
assert_true "THE CONTROL: the export IS called by the driver, with the default, so §2 drove it" \
  bash -c "git -C '$REPO_ROOT' grep -q 'x.ct_writer_set_compact_threshold(compactThreshold)' -- verification/ct_writer_drive_core.mjs"
# THE FABRICATED NAME IS ASSEMBLED, NOT WRITTEN. Spelled out, it would be in this file and the
# search would find it here — which is how a negative control becomes a failing assertion about
# itself. It happened on the first run.
FAKE_EXPORT="ct_writer_set_compact_threshold""_default_on"
assert_false "…and a fabricated spelling is not found anywhere, so the searches above discriminate" \
  git -C "$REPO_ROOT" grep -q --untracked "$FAKE_EXPORT"

# ---------------------------------------------------------------------------
# 7. THE ENGINE COUPLING IS STATED WHERE THE LEVER IS, and names the file that governs it.
# ---------------------------------------------------------------------------
for f in ct-writer/src/lib.rs ct-writer/src/backend.rs ct-host/src/abi.ts; do
  assert_true "$f names client/hydrate/engine-pin.txt, where the engine coupling is governed" \
    bash -c "grep -q 'client/hydrate/engine-pin.txt' '$REPO_ROOT/$f'"
done
assert_false "THE CONTROL: a fabricated pin path is in none of them, so the grep above is a grep" \
  grep -rq 'client/hydrate/engine-pin-v2.txt' "$REPO_ROOT/ct-writer/src" "$REPO_ROOT/ct-host/src"

finish
