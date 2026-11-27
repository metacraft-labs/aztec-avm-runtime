#!/usr/bin/env bash
# test_runquota_bridge
#
# RQE-M6b: every heavy ninja call in this repo's verification scripts takes a RunQuota lease and runs
# at the granted width, instead of assuming every core is its own. A call site that lost its bridge
# still PASSES (the build just runs wider), so the only thing that can notice is a test of the bound
# itself. This is that test.
#
# WHAT IS REAL. A private `runquotad` (3 CPU slots, socket in a scratch directory,
# RUNQUOTA_SOCKET + RUNQUOTA_ENDPOINT_SCOPE=private, so no other daemon is touched); the REAL helper
# verification/runquota_bridge.sh; REAL `ninja` (>= 1.13, the first with a jobserver client; taken
# from PATH, else from `nix build nixpkgs#ninja`); and the REAL call sites of the repo's build
# functions -- m3_build (lib_merkle_lmdb.sh), m6_build (lib_avm_wasm.sh), m5_native_build
# (lib_bytecode_shift.sh) and the inner script wasm_host/_preset_build_inner.sh -- run at the same
# time, so the budget is shared between four sessions.
#
# WHAT IS STUBBED, AND WHY (a heavy build is forbidden on a shared host; the unit under test is which
# commands reach the bridge, not what a compiler does):
#   * `nix` is a shim that drops `develop --command` and runs the rest. The real one would enter the
#     fork's dev shell and download a toolchain. Everything inside the shell script -- including the
#     line that carries the bridge -- is the repo's own text, executed unmodified.
#   * `cmake` (used only by the inner preset script's configure step) is a shim that exits 0.
#   * The build graphs are tiny build.ninja files whose edges run `sleep 0.2537`. It does not fork, so one process is one job and /proc sampling by
#     exact command line (`sleep` with that odd duration, which nothing else on a host runs) counts
#     concurrent jobs exactly. Peak concurrency is read from /proc every 5 ms, never from a
#     log.
# Call sites that need a real barretenberg tree to execute at all (m14/verify.sh, the compiler-cache
# check, the dev-shell fork check, the vm2 prebuild) are covered by a static assertion that their
# ninja line goes through the bridge; that is weaker than running them and is said so here.
#
# WHAT IT ASSERTS
#   1. no ninja invocation in the verification tree is un-bridged (static, over the real files);
#   2. peak concurrent jobs across four simultaneous sessions is <= the budget AND > 1;
#   3. a failing edge's exit status survives the bridge;
#   4. the helper's probes: a `runquota` that lacks the verb is not used, RQ= turns the bridge off
#      (and the peak then exceeds the budget -- the control that the bound is the bridge's doing),
#      RQ="prefix" replaces the prefix, no `runquota` on PATH runs the command unchanged;
#   5. NEGATIVE CONTROL (--mutate): the bridge is deleted from a copy of the real files and the same
#      measurement must then exceed the budget. Prints "MUTATION KILLED" when it does.
#
# Usage: test_runquota_bridge.sh [--mutate]
TEST_NAME=test_runquota_bridge
. "$(dirname "$0")/lib.sh"
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && MUTATE=1

BUDGET=3          # CPU slots of the private daemon
SESSIONS=4        # simultaneous build sessions
EDGES=8           # independent 0.25 s jobs per session

command -v runquota >/dev/null && command -v runquotad >/dev/null || die "runquota and runquotad are required on PATH"
command -v python3 >/dev/null || die "python3 is required (the /proc sampler)"

# ninja >= 1.13 is required for jobserver client support.
ninja_ok() { command -v ninja >/dev/null 2>&1 && [ "$(printf '1.13\n%s\n' "$(ninja --version)" | sort -V | head -1)" = "1.13" ]; }
if ! ninja_ok; then
  NINJA_OUT="$(nix build --no-link --print-out-paths 'nixpkgs#ninja' 2>/dev/null | tail -1)"
  [ -x "$NINJA_OUT/bin/ninja" ] && export PATH="$NINJA_OUT/bin:$PATH"
fi
ninja_ok || die "no ninja >= 1.13 on PATH and 'nix build nixpkgs#ninja' did not provide one"

# A Unix socket path is limited to ~100 bytes: keep the scratch directory under a short parent.
S="$(mktemp -d "/tmp/rqb.XXXXXX")" || die "mktemp failed"
DAEMON_PID=""
cleanup() {
  [ -n "${RQB_KEEP:-}" ] && { echo "kept $S" >&2; return; }
  if [ -n "$DAEMON_PID" ] && ps -o args= -p "$DAEMON_PID" 2>/dev/null | grep -q -- "--socket $S/rq.sock"; then
    kill "$DAEMON_PID" 2>/dev/null
  fi
  rm -rf "$S"
}
trap cleanup EXIT

# --- the verification tree under test: the real one, or a mutated copy ---------------------------
VSRC="$VERIFY_DIR"
if [ "$MUTATE" = 1 ]; then
  mkdir -p "$S/mut" && cp -r "$VERIFY_DIR" "$S/mut/verification" && cp "$REPO_ROOT/pins.json" "$S/mut/pins.json" || die "cannot copy the verification tree"
  # Delete the bridge from every real call site (the helper's own file is left alone).
  python3 -I - "$S/mut/verification" <<'PY'
import pathlib, re, sys
pat = re.compile(r'\\?"\\?\$RQ_BRIDGE\\?" jobserver -- |"\$\{RQ_BRIDGE:-[^}]*\}" jobserver -- ')
n = 0
for f in pathlib.Path(sys.argv[1]).rglob('*.sh'):
    if f.name in ('runquota_bridge.sh', 'test_runquota_bridge.sh'):
        continue
    t = f.read_text()
    u, k = pat.subn('', t)
    if k:
        f.write_text(u); n += k
print('mutation removed %d bridge prefixes' % n)
PY
  VSRC="$S/mut/verification"
fi

# --- private daemon ----------------------------------------------------------------------------
export RUNQUOTA_SOCKET="$S/rq.sock" RUNQUOTA_ENDPOINT_SCOPE=private
runquotad --socket "$S/rq.sock" --cpu-milli $((BUDGET * 1000)) --memory-bytes 17179869184 \
  --no-write-stats --estimate-db "$S/est.db" --observation-db "$S/obs.db" --log-file "$S/rqd.log" \
  >"$S/rqd.out" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 100); do runquota status >/dev/null 2>&1 && break; sleep 0.1; done
runquota status >/dev/null 2>&1 || die "the private runquotad did not answer: $(cat "$S/rqd.log" "$S/rqd.out" 2>/dev/null | tail -3)"

# --- stubs and fixtures --------------------------------------------------------------------------
mkdir -p "$S/bin"
cat >"$S/bin/nix" <<'EOF'
#!/usr/bin/env bash
# test shim: `nix develop --command CMD...` runs CMD in the current environment.
[ "${1:-}" = develop ] && shift
[ "${1:-}" = --command ] && shift
exec "$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$S/bin/cmake"
chmod +x "$S/bin/nix" "$S/bin/cmake"
export PATH="$S/bin:$PATH"

write_graph() { # <dir> <failing-edge:0|1>
  mkdir -p "$1"
  { echo "rule job"; echo "  command = sleep 0.2537"
    echo "rule bad"; echo "  command = false"
    local i; for i in $(seq "$EDGES"); do echo "build o$i: job"; done
    [ "$2" = 1 ] && echo "build bad1: bad"
    echo "build all: phony $(for i in $(seq "$EDGES"); do printf 'o%s ' "$i"; done)$([ "$2" = 1 ] && echo bad1)"
    echo "default all"; } >"$1/build.ninja"
}
FORK_ROOT="$S/fork"; mkdir -p "$FORK_ROOT"
for n in 1 2 3 4; do mkdir -p "$S/t$n/barretenberg/cpp"; done
write_graph "$S/t1/barretenberg/cpp/build-native" 0       # m3_build
mkdir -p "$S/t1/barretenberg/cpp/src/barretenberg/nodejs_module/node_modules"
write_graph "$S/t2/barretenberg/cpp/build-m6" 0           # m6_build
write_graph "$S/t3/barretenberg/cpp/build" 0              # m5_native_build
write_graph "$S/t4/barretenberg/cpp/build-wasm" 0         # _preset_build_inner.sh (preset "wasm")

# The real build functions, from the tree under test.
[ "$VSRC" = "$VERIFY_DIR" ] || . "$VSRC/lib.sh"
. "$VSRC/lib_avm_wasm.sh"; . "$VSRC/lib_bytecode_shift.sh"; . "$VSRC/lib_merkle_lmdb.sh"
FORK_ROOT="$S/fork"   # lib.sh pointed it at the real sibling checkout
export RQ_BRIDGE="$VSRC/runquota_bridge.sh"

# --- the sampler: peak number of concurrent jobs (exact command-line match) ----------------------
cat >"$S/sample.py" <<'EOF'
import os, sys, time
stop, out = sys.argv[1], sys.argv[2]
peak = 0
while not os.path.exists(stop):
    n = 0
    for p in os.listdir('/proc'):
        if p.isdigit():
            try:
                with open('/proc/%s/cmdline' % p, 'rb') as f:
                    if f.read() == b'sleep\x000.2537\x00':
                        n += 1
            except OSError:
                pass
    peak = max(peak, n)
    time.sleep(0.005)
open(out, 'w').write(str(peak))
EOF

# measure_peak <label> : run the four real call sites at once, print the peak concurrent jobs.
measure_peak() {
  local label="$1" rc_total=0 pids=() sp
  rm -f "$S/stop" "$S/peak.$label"
  python3 -I "$S/sample.py" "$S/stop" "$S/peak.$label" & sp=$!
  m3_build "$S/t1" all & pids+=($!)
  m6_build "$S/t2" build-m6 all & pids+=($!)
  m5_native_build "$S/t3" all & pids+=($!)
  ( "$VSRC/wasm_host/_preset_build_inner.sh" "$S/t4" wasm all >"$S/t4.log" 2>&1 ) & pids+=($!)
  local p; for p in "${pids[@]}"; do wait "$p" || rc_total=$((rc_total + 1)); done
  : >"$S/stop"; wait "$sp"
  echo "$rc_total" >"$S/rc.$label"
  cat "$S/peak.$label"
}

if [ "$MUTATE" = 1 ]; then
  peak="$(measure_peak mutated)"
  echo "mutated (bridge deleted from the real call sites): peak concurrent jobs = $peak, budget = $BUDGET"
  if [ "$peak" -gt "$BUDGET" ]; then echo "MUTATION KILLED"; exit 0; fi
  echo "MUTATION SURVIVED: the measurement does not depend on the bridge"; exit 1
fi

# =================================================================================================
echo "== 1. no ninja invocation in the verification tree is un-bridged (static) =="
# An executable line that runs ninja must carry the bridge, or be a read-only query (`-t`).
unbridged="$(cd "$VERIFY_DIR" && grep -rnE '(^|[^[:alnum:]_./-])ninja( |$)' --include='*.sh' . \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
  | grep -vE 'jobserver -- ninja|ninja -t |ninja --version|assert_|note |pass |fail |echo |emit |command -v|printf|corpus_invocations|for tool in |^./runquota_bridge.sh|^./test_runquota_bridge.sh' || true)"
assert_eq "no executable ninja line lacks the bridge" "" "$unbridged"
n_sites="$(cd "$VERIFY_DIR" && grep -rE 'jobserver -- ninja' --include='*.sh' . | grep -vc 'test_runquota_bridge.sh')"
assert_eq "the bridge is present at all nine known sites (m3, m5, m6, vm2 prebuild, m14, cache x2, fork shell, preset inner)" 9 "$n_sites"

echo "== 2. four sessions, one budget =="
peak="$(measure_peak bridged)"
assert_eq "all four real call sites exited 0" 0 "$(cat "$S/rc.bridged")"
assert_ge "the bridge let more than one job run (not met by running nothing)" 2 "$peak"
if [ "$peak" -le "$BUDGET" ]; then pass "peak concurrent jobs $peak <= budget $BUDGET"; else fail "peak concurrent jobs $peak exceeds budget $BUDGET"; fi
note "measured peak $peak of budget $BUDGET across $SESSIONS sessions x $EDGES edges"

echo "== 3. the escape hatch and its control =="
peak_off="$(RQ= measure_peak off)"
assert_ge "RQ= turns the bridge off: the same sessions then exceed the budget" $((BUDGET + 1)) "$peak_off"

echo "== 4. exit status and probes =="
write_graph "$S/t2/barretenberg/cpp/build-bad" 1
m6_build "$S/t2" build-bad all; rc=$?
assert_true "a failing edge's status survives the bridge (m6_build returns non-zero)" test "$rc" -ne 0
assert_contains "and ninja's own status is recorded in the log" "### ninja_rc=1" "$(cat "$S/t2/m6-build-bad-build.log")"

# A runquota that predates the verb prints usage and exits 0 -- it must not be used.
mkdir -p "$S/old"; printf '#!/usr/bin/env bash\necho "usage: runquota ..."; exit 0\n' >"$S/old/runquota"; chmod +x "$S/old/runquota"
out="$(PATH="$S/old:$PATH" "$RQ_BRIDGE" jobserver -- echo ran)"
assert_eq "a runquota without the jobserver verb is not used; the command still runs" "ran" "$out"
assert_false "and the helper reports it inactive" env PATH="$S/old:$PATH" "$RQ_BRIDGE" active jobserver
assert_true "the real runquota is reported active" "$RQ_BRIDGE" active jobserver
out="$(RQ='env BRIDGED=yes' "$RQ_BRIDGE" jobserver -- sh -c 'echo ${BRIDGED:-no}')"
assert_eq "RQ=<prefix> replaces the prefix" yes "$out"
noprefix="$(PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v env)")" "$RQ_BRIDGE" jobserver -- echo plain 2>&1)"
assert_eq "with no runquota on PATH the command runs unchanged" plain "$noprefix"
"$RQ_BRIDGE" jobserver -- false; assert_eq "the command's exit status passes through the helper" 1 "$?"

finish
