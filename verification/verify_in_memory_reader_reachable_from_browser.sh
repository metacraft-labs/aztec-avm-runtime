#!/usr/bin/env bash
# verify_in_memory_reader_reachable_from_browser
#
# M41 verification: on the freestanding target, the trace reader's PATH-TAKING constructor is
# absent and its BYTE-TAKING one is present — so a browser, which has bytes and no path, can open a
# container.
#
# ---------------------------------------------------------------------------
# WHY THIS IS ONE OF THE TWO FACTS THAT DECIDED PATH B, AND WHY IT IS ABOUT THE READER
# ---------------------------------------------------------------------------
#
# The user's ruling was taken on the browser's actual workload: *"The browser code reads .ct
# containers all the time and emits them rarely."* Path A's reader has ONE constructor on every
# target, `CtfsReader::open(&Path)`, while its WRITE side has `create_in_memory`. A browser has
# bytes and no path, so the read half of Path A cannot be reached at all from a page — which is a
# capability question rather than a speed one, and it is the half of the workload that dominates.
#
# WHAT THE `ct-writer` MODULE ITSELF DOES NOT DO, SAID PLAINLY. This runtime's module is
# WRITE-ONLY: its thirty-eight entry points are a writer ABI and none of them opens a container.
# So the browser's read path is not this module. It is the trace-format repository's own
# `wasm/standalone/trace_reader_only_standalone.nim` — the reader surface with no writer linked —
# and that module is the third arm below.
#
# THREE ARMS, AND THE THIRD IS THE ONE THAT ANSWERS THE QUESTION:
#
#   host C ABI            the path-taking constructor IS emitted           (the control)
#   freestanding C ABI    it is NOT                                        (the gate works)
#   freestanding READER   the byte-taking constructor IS emitted, and so   (the capability)
#                         are the byte-taking entry points a page calls
#
# The middle arm alone would be a check about an absence. It was written that way first, and the
# byte-taking constructor turned out to be absent from BOTH C-ABI arms — Nim dead-strips it,
# because the only thing that reached it was the constructor the gate removes. A check that had
# asserted its presence there would have been asserting something false about the wrong module;
# one that had asserted only the absence would have passed while proving nothing about reading.
#
# THE CONTROLS. "A symbol is absent" is equally true of a search over an empty directory, of a
# compile that failed, and of a grep with a typo in it. So: the host arm must FIND the symbol the
# freestanding arm must not; every arm must emit C at all; a symbol that must be present in every
# arm is asserted in every arm; and a fabricated symbol must be found in none.
#
# Run: just verify-in-memory-reader

TEST_NAME="verify_in_memory_reader_reachable_from_browser"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v nim >/dev/null 2>&1 || die "nim is required (it comes from the workspace dev shell)"

# The source the Path B module is built from, materialised by `ct-writer/build.rs` at the pinned
# writer anchor. Requiring the module first is what materialises it — a check that compiled a tree
# it had materialised itself would be measuring a tree nothing else uses.
m41_require_path_b
NIM_SRC="$M41_CRATE/build-wasm-deps/ctf-nim"
assert_dir "the pinned Nim source is materialised by the Path B build" "$NIM_SRC"
FFI="$NIM_SRC/src/codetracer_trace_writer_ffi.nim"
assert_file "and it carries the C ABI" "$FFI"

# ---------------------------------------------------------------------------
# 1. The gate exists in the source, and it gates the constructor by name.
# ---------------------------------------------------------------------------
READER="$NIM_SRC/src/codetracer_trace_writer/new_trace_reader.nim"
assert_file "the reader is where the gate is declared" "$READER"
assert_true "the reader declares a filesystem gate rather than assuming one" \
  grep -qE 'const ctHasFilesystem\* = defined\(posix\) or defined\(windows\)' "$READER"
assert_true "and the byte-taking constructor is OUTSIDE it, so no target can lack it" \
  python3 -c "
import sys
text = open('$READER', encoding='utf-8').read()
at = text.index('proc openNewTraceFromBytes*')
# The constructor is ungated when no 'when ctHasFilesystem:' block encloses it. The enclosing test
# is INDENTATION: a gated proc sits inside the block and is indented; this one is at column zero.
sys.exit(0 if text[at - 1] == '\n' else 1)
"
assert_true "while the path-taking one is inside the gate" \
  python3 -c "
import re, sys
text = open('$READER', encoding='utf-8').read()
m = re.search(r'^when ctHasFilesystem:\n(?:.*\n)*?  proc openNewTrace\*', text, re.M)
sys.exit(0 if m else 1)
"

# ---------------------------------------------------------------------------
# 2. The C ABI, compiled BOTH ways, and the difference measured in the emitted C.
# ---------------------------------------------------------------------------
WORK="$M41_WORK/reader-surface"
rm -rf "$WORK"
mkdir -p "$WORK"

compile_arm() { # <label> <entry> <extra nim flags...>
  local label="$1" entry="$2"; shift 2
  m41_bounded 1800 "the $label compile" \
    nim c --compileOnly --mm:arc -d:useMalloc --threads:off --noMain \
      -d:noSignalHandler -d:release --opt:size --hints:off \
      --nimMainPrefix:codetracerTraceWriter \
      "-p:$NIM_SRC/src" "--nimcache:$WORK/$label" \
      "-o:$WORK/$label.out" "$@" "$entry"
}

# The reader module is a DIFFERENT entry point in the same materialised tree, so the third arm
# reuses `compile_arm` with a different final source rather than a second compiler invocation
# written out again.
READER_ENTRY="$NIM_SRC/wasm/standalone/trace_reader_only_standalone.nim"
assert_file "the pinned tree carries a reader-only standalone module" "$READER_ENTRY"

compile_arm freestanding "$FFI" --os:any --cpu:wasm32 -d:ctHostClock -d:ctLeanRecord \
  || die "the freestanding compile of the C ABI failed:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"
compile_arm host "$FFI" \
  || die "the host compile of the C ABI failed:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"
compile_arm reader "$READER_ENTRY" --os:any --cpu:wasm32 -d:ctHostClock -d:ctLeanRecord \
  || die "the freestanding compile of the reader-only module failed:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"

for arm in freestanding host reader; do
  N="$(find "$WORK/$arm" -name '*.c' | grep -c . || true)"
  assert_ge "the $arm compile emitted C, so an absence below is not an empty directory" 1 "$N"
  m41_say "$arm: $N C files"
done

# THE MATCH IS A PREFIX AT A WORD BOUNDARY, NOT A WHOLE WORD, and that is not laxity.
# Nim mangles a non-`exportc` proc: `openNewTraceFromBytes` becomes
# `openNewTraceFromBytes__pbqrgenpre95...`, so a trailing `\b` never matches — the next character
# is an underscore, which is a word character. A whole-word search reported the constructor absent
# from BOTH arms, which would have read as "the browser cannot open a container either way".
symbol_in() { # <arm> <symbol>
  grep -rl "\b$2" "$WORK/$1" --include='*.c' 2>/dev/null | grep -c . || true
}

# The writer's own entry point, in both C-ABI arms. Without this every absence below is satisfied
# by a compile that emitted nothing useful. The reader arm links no writer, by design, so it is not
# asked for these — and section 3 gives it its own must-be-present symbols for the same reason.
for arm in freestanding host; do
  assert_ge "the $arm compile has the writer's in-memory constructor" 1 \
    "$(symbol_in "$arm" trace_writer_begin_in_memory)"
  assert_ge "the $arm compile has the recording-id setter the browser needs" 1 \
    "$(symbol_in "$arm" trace_writer_set_recording_id)"
done

# THE MEASUREMENT, and its control, in that order.
HOST_OPEN="$(symbol_in host ct_reader_open)"
FREE_OPEN="$(symbol_in freestanding ct_reader_open)"
assert_ge "THE CONTROL: the host compile DOES define the path-taking constructor" 1 "$HOST_OPEN"
assert_eq "and the freestanding compile does NOT" "0" "$FREE_OPEN"
m41_say "ct_reader_open: $HOST_OPEN file(s) on the host, $FREE_OPEN freestanding"

# ---------------------------------------------------------------------------
# 3. THE CAPABILITY: a freestanding module that CAN open a container held as bytes.
# ---------------------------------------------------------------------------
assert_ge "the freestanding reader module emits the byte-taking constructor" 1 \
  "$(symbol_in reader openNewTraceFromBytes)"
assert_eq "and does NOT emit the path-taking one, so it needs no filesystem" "0" \
  "$(symbol_in reader ct_reader_open)"
# The entry points a page actually calls: hand the module bytes, then open them. Named
# individually rather than counted, so a module that grew one and lost another still fails.
for e in ct_input_alloc ct_input_len ct_open_input ct_step_count ct_step_position; do
  assert_ge "the reader module exposes $e to a host with no filesystem" 1 "$(symbol_in reader "$e")"
done

# The C-ABI arms do NOT emit the byte-taking constructor, and that is recorded rather than
# glossed: nothing on that ABI reaches it, so Nim strips it. The browser's reader is the module
# above, not this runtime's writer module.
m41_say "openNewTraceFromBytes: $(symbol_in reader openNewTraceFromBytes) file(s) in the reader module, $(symbol_in freestanding openNewTraceFromBytes) in the freestanding C ABI, $(symbol_in host openNewTraceFromBytes) on the host"
assert_eq "the write-only C ABI does not carry a reader constructor it cannot reach" "0" \
  "$(symbol_in freestanding openNewTraceFromBytes)"

# And the same search for a symbol that exists in NONE of the three must find nothing, so the
# counter is shown to be able to answer zero for a reason other than the gate.
for arm in freestanding host reader; do
  assert_eq "a fabricated symbol is found in no $arm file" "0" \
    "$(symbol_in "$arm" ct_reader_open_from_a_constructor_that_does_not_exist)"
done

finish
