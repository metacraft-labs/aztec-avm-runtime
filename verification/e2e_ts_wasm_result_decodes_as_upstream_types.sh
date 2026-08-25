#!/usr/bin/env bash
# e2e_ts_wasm_result_decodes_as_upstream_types — M18.
#
# THE MILESTONE'S OWN INSTRUCTION IS THAT THE TWO HALVES BE TESTED TOGETHER FROM THE FIRST COMMIT
# RATHER THAN INTEGRATED AT THE END. This is that check, and it is the smallest question whose
# answer nothing before it establishes:
#
#   Does the byte stream `avm.wasm` returns satisfy UPSTREAM'S OWN TypeScript types?
#
# Everything either half has been checked against so far is inside that half. M8 compared the
# wasm AVM against the native C++ AVM — C++ on both sides. M2's differential compared the
# TypeScript interpreter against the native NAPI AVM — TypeScript reading a NAPI addon's bytes,
# not a wasm module's. M17 drove `avm.wasm` from TypeScript with a decoder written for the
# purpose, dependency-free by design, which decodes a 32-byte `bin` as a `Uint8Array`. None of
# those is the composition this milestone rests on: upstream's `PublicTxResult`, built from
# upstream's `deserializeFromMessagePack`, over bytes produced by a wasm build of upstream's C++.
# If those do not compose, M18's orchestration cannot be assembled at all, and the failure would
# otherwise appear much later wearing a different name.
#
# THE MEASUREMENT IS A COMPARISON OF TWO DECODERS OVER ONE BYTE STREAM, and both sides are read
# off decoded objects. `orchestration/src/roundtrip_cli.ts` runs each corpus program once, keeps
# the raw result bytes, and decodes them twice — with node-host's `unpack` and with
# `@aztec/stdlib/avm`'s `deserializeFromMessagePack` — then constructs a `PublicTxResult` from
# the second. Nothing is printed as a constant: `decoders.agree` is computed from five fields
# read off both objects, and `publicTxResult.agreesWithRaw` is computed from the typed object
# against the plain one.
#
# THE CONTROLS, AND THE FIRST DRAFT OF THEM WAS WRONG ABOUT THE DATA.
#
# It expected `deserializeFromMessagePack` to hand back an `Fr` for a field element, because
# `serializeWithMessagePack` registers an msgpackr extension for that class, and it asserted
# `stdlib.txFee.isUint8Array == false`. Measured: it is TRUE, and the constructor is `Buffer`.
# The extension's READ side never fires — the C++ writer emits a plain, untagged `bin`, and
# msgpackr dispatches read extensions on a tag that is not in the data. Upstream states this
# itself in @aztec/native's `msgpack_channel.ts`: "this only works for writes. Unpacking from C++
# can't create Fr instances because the data is passed as raw, untagged, buffers."
#
# So the agreement on `bin`-valued fields is NOT independent evidence and is not asserted as
# though it were. What is asserted instead:
#
#   * The two decoders are demonstrably not one decoder: over the same 32 bytes, upstream's
#     returns a `Buffer` and node-host's a `Uint8Array`. That difference is not cosmetic and the
#     check proves it — `PublicTxResult.fromPlainObject` REFUSES node-host's decode of the same
#     bytes, because `BaseField`'s constructor takes a `Buffer` and rejects a plain
#     `Uint8Array`. So "upstream's decoder accepted the module's bytes" is a claim about
#     upstream's decoder and not about msgpack in general.
#   * `PublicTxResult.fromPlainObject` is a zod parse, and a parse that accepted anything would
#     accept the module's output for no reason. The same object with `revertCode` made a string
#     must be REJECTED, and so must the same object with `gasUsed` removed — two corruptions,
#     because a schema can be lax about a primitive's type and strict about a missing subtree.
#     That pair is what turns "it accepted the bytes" into evidence.
#
# Run: just verify-halves-compose

TEST_NAME="e2e_ts_wasm_result_decodes_as_upstream_types"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m18_orchestration.sh"

# M18 gets its own work directory and its own tree, the way M13 did over M12's and M14 did over
# M6's. `avm.wasm` is M12's artefact and M12's machinery builds it; pointing M17's and M12's work
# directories at M18's before sourcing is what keeps this milestone's build out of theirs.
M17_WORK="$M18_WORK"
M12_WORK="$M18_WORK"
export M17_WORK M12_WORK
# shellcheck source=lib_m17_node_host.sh
. "$VERIFY_DIR/lib_m17_node_host.sh"

m18_require_packages

require_work_dir "$M18_WORK" 12
m17_measured

WASM="$(m12_wasm_bin avm.wasm)"
INPUTS="$(m17_inputs)"
assert_file "the wasm AVM is where the measurement says" "$WASM"
assert_file "and so are M12's reactor inputs" "$INPUTS"

OUT="$M18_WORK/roundtrip.out"
ERR="$M18_WORK/roundtrip.err"
( cd "$ORCH_DIR" && node src/roundtrip_cli.ts "$WASM" "$INPUTS" ) >"$OUT" 2>"$ERR"
rc=$?

# stdout and stderr are kept APART. D11: the AVM logs at VERBOSE on fd 2 under wasm,
# unconditionally, and a merged comparison mismatched 1,308 of 1,308 lines when M8 tried it.
note "driver exit $rc, $(grep -c . "$OUT" || true) line(s) of stdout, $(grep -c . "$ERR" || true) of stderr"
assert_eq "the driver exited 0" "0" "$rc"
assert_contains "and reached its own sentinel, so the output is not a truncation" \
  "roundtrip.done 1" "$(cat "$OUT")"

val() { # <key> -> the value the driver printed for it
  awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$OUT"
}

N_PROGRAMS="$(val roundtrip.programs.count)"
assert_eq "all seven corpus programs ran" "7" "$N_PROGRAMS"

# The headline: nothing disagreed and nothing failed to decode. Asserted as counts read out of
# the artefact, and then per program, so a failure names the program rather than the total.
assert_eq "no field disagrees between the two decoders" "0" "$(val roundtrip.mismatches)"
assert_eq "and nothing failed to decode" "0" "$(val roundtrip.decodeFailures)"

PROGRAMS="$(awk '$1 ~ /^roundtrip\.[a-z0-9]+\.status$/ { split($1, a, "."); print a[2] }' "$OUT")"
N_SEEN="$(printf '%s\n' "$PROGRAMS" | grep -c . || true)"
assert_eq "the per-program lines cover every program the driver counted" "$N_PROGRAMS" "$N_SEEN"

for p in $PROGRAMS; do
  assert_eq "$p: the module answered status 0, so a revert is a result and not an error" \
    "0" "$(val "roundtrip.$p.status")"
  BYTES="$(val "roundtrip.$p.resultBytes")"
  assert_ge "$p: the module returned a result buffer" 1 "$BYTES"
  assert_eq "$p: @aztec/stdlib decoded it" "ok" "$(val "roundtrip.$p.stdlib.decode")"
  assert_eq "$p: and PublicTxResult accepted the decoded object" "ok" \
    "$(val "roundtrip.$p.publicTxResult")"
  assert_eq "$p: the two decoders agree on revert code, both gas dimensions, the fee and the nullifier count" \
    "true" "$(val "roundtrip.$p.decoders.agree")"
  assert_eq "$p: and the typed result agrees with the plain one it was built from" \
    "true" "$(val "roundtrip.$p.publicTxResult.agreesWithRaw")"

  # CONTROL ONE: the two decoders are not one decoder. Same 32 bytes, different constructors.
  assert_eq "$p: upstream's decoder returns a Buffer for the fee" \
    "Buffer" "$(val "roundtrip.$p.stdlib.txFee.ctor")"
  assert_eq "$p: node-host's returns a plain Uint8Array for the same bytes" \
    "Uint8Array" "$(val "roundtrip.$p.nodeHost.txFee.ctor")"

  # CONTROL TWO: the zod parse that accepted the module's output is not a rubber stamp.
  assert_eq "$p: PublicTxResult REJECTS the same object with revertCode made a string" \
    "true" "$(val "roundtrip.$p.publicTxResult.rejectsWrongType")"
  assert_eq "$p: and REJECTS it with gasUsed removed" \
    "true" "$(val "roundtrip.$p.publicTxResult.rejectsMissingField")"

  # CONTROL THREE, and it is the strongest — found by MUTATING the driver rather than by
  # reasoning about it. The two decoders are not interchangeable for this type: node-host's
  # decode of the same bytes is REFUSED, because `BaseField`'s constructor accepts a `Buffer`
  # and rejects a plain `Uint8Array`. That is what makes "upstream's decoder accepted the
  # module's bytes" a statement about upstream's decoder rather than about msgpack.
  assert_eq "$p: PublicTxResult REFUSES node-host's decode of the same bytes" \
    "true" "$(val "roundtrip.$p.publicTxResult.rejectsNodeHostDecode")"
  assert_eq "$p: and the refusal names the field-element constructor as the cause" \
    "BaseField-ctor" "$(val "roundtrip.$p.publicTxResult.nodeHostRejection")"

  # The two decoders' own outputs, printed side by side, so the transcript carries the values
  # rather than only the verdict.
  note "$p: revertCode $(val "roundtrip.$p.nodeHost.revertCode") gas $(val "roundtrip.$p.nodeHost.totalGas") fee $(val "roundtrip.$p.nodeHost.txFee") nullifiers $(val "roundtrip.$p.nodeHost.nullifiers.count")"
done

# The result really is upstream's shape and not a bag that happens to decode: the top-level key
# set is asserted, once, against the fields REACTOR-ABI.md names for `TxSimulationResult`.
KEYS="$(val "roundtrip.add.stdlib.topLevelKeys")"
note "top-level keys: $KEYS"
for k in callStackMetadata executionSteps gasUsed hints logs publicInputs publicTxEffect revertCode stats; do
  assert_eq "the decoded result carries a top-level $k" "1" \
    "$(printf '%s\n' "$KEYS" | tr ',' '\n' | grep -cx "$k" || true)"
done

# A REVERT REACHES UPSTREAM'S TYPE AS A REVERT. A partition of all seven rather than an existence
# claim — the distinction M17 spent a whole check on at the boundary, carried one layer further.
N_REVERTED=0
N_OK=0
for p in $PROGRAMS; do
  case "$(val "roundtrip.$p.publicTxResult.revertCode.isOK")" in
    true)  N_OK=$((N_OK + 1)) ;;
    false) N_REVERTED=$((N_REVERTED + 1)) ;;
    *)     fail "$p: PublicTxResult did not answer whether it reverted" ;;
  esac
done
# TWO of the seven revert, not one — `revert` by construction and `burn` by exhausting its gas
# limit at 1,000,000/1,000,000, which is a revert the corpus's name does not advertise and which
# the first draft of this partition got wrong.
assert_eq "two corpus programs revert, and upstream's type says so" "2" "$N_REVERTED"
assert_eq "and the other five do not" "5" "$N_OK"
assert_eq "the deliberate one is 'revert'" "false" "$(val "roundtrip.revert.publicTxResult.revertCode.isOK")"
assert_eq "the gas-exhausted one is 'burn'" "false" "$(val "roundtrip.burn.publicTxResult.revertCode.isOK")"
assert_eq "and 'add' is not" "true" "$(val "roundtrip.add.publicTxResult.revertCode.isOK")"
assert_eq "burn's revert is gas exhaustion, and the numbers say so rather than the name" \
  "1000000/1000000" "$(val "roundtrip.burn.nodeHost.totalGas")"

# The instance pool did what M17 established, through a different caller. One module compiled,
# instances reused, nothing retired — a retirement here would mean a trap, which would be a
# finding rather than a detail.
assert_eq "one instance was created for the whole run" "1" "$(val roundtrip.pool.created)"
assert_eq "and none was retired, so nothing trapped" "0" "$(val roundtrip.pool.retired)"
assert_ge "the rest were reused" 6 "$(val roundtrip.pool.reused)"

# ---------------------------------------------------------------------------
# The check set is wired into CI, stated precisely — and what that does NOT mean.
# ---------------------------------------------------------------------------
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the AVM_WASM workflow exists" "$WF"
WF_TXT="$(cat "$WF")"
assert_contains "…and it has a job for the orchestration" "  orchestration:" "$WF_TXT"
assert_contains "…which runs the whole M18 set" "just verify-m18" "$WF_TXT"
assert_contains "…in its own work directory, not M12's or M17's" "M18_WORK: " "$WF_TXT"
assert_contains "…after installing the orchestration's own packages"   "Install the orchestration's own packages" "$WF_TXT"
assert_contains "…and the ones the reuse enumeration reads, which are a different tree"   "Install the published @aztec packages the reuse enumeration reads" "$WF_TXT"
assert_contains "…and asserts M18's own inputs before running anything"   "missing M18 input" "$WF_TXT"
assert_contains "…and unshallows the fork, because three checks read the TypeScript anchor"   "3a68d68ac2^{commit}" "$WF_TXT"

# Structure, not text: a job named in a comment is not a job.
YAML_JOBS=""
if command -v yq >/dev/null 2>&1; then
  YAML_JOBS="$(yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
elif command -v nix >/dev/null 2>&1; then
  YAML_JOBS="$(nix shell nixpkgs#yq-go --command yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
fi
if [ -n "$YAML_JOBS" ]; then
  assert_contains "the workflow parses as YAML and declares the M18 job as a job"     "orchestration" "$YAML_JOBS"
  assert_contains "…alongside M17's, which it must not have displaced" "node-host" "$YAML_JOBS"
  assert_contains "…and M12's, which builds the same tree in a different directory"     "avm-reactor" "$YAML_JOBS"
  assert_not_contains "…and it does not declare a job M18 never added"     "orchestration-browser" "$YAML_JOBS"
else
  fail "no YAML parser was available, so the workflow's structure could not be asserted"
fi

# AND WHAT IT DOES NOT MEAN. Neither this job nor any other in this workflow has ever run: they
# all abort at `Generate CI token` on "Input required and not supplied: app-id", which M11
# recorded as undiagnosed and which the `vars.` spelling did not fix. The job existing means it
# is wired and names the checks.
assert_contains "the job says plainly that it has never run" "this job has never run" "$WF_TXT"

finish
