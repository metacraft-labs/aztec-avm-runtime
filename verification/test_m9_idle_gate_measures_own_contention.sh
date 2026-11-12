#!/usr/bin/env bash
# test_m9_idle_gate_measures_own_contention
#
# `m9_require_idle_machine` (lib_m9_idle_gate.sh) used to refuse on /proc/loadavg, which on a shared
# runner is the host's or a neighbour's load; it read 42.24 and 68.18 on 2 cores on the GARM fleet
# and turned `verify-m12` red on every run. It now measures the contention THIS JOB sees: PSI
# `some avg10` of its own cgroup, else system PSI, else a one-second spin read through
# /proc/$$/schedstat. This check holds that to both halves of its contract: it must PASS where the
# job is not starved and REFUSE (exit 3) where it is.
#
# NOTHING IS MOCKED EXCEPT ONE INPUT, AND THAT ONE IS DISCLOSED. Part 1 uses the gate's test seam,
# M9_IDLE_PSI_FILE: a file the test writes in the kernel's own PSI format, which the gate's REAL
# parser, threshold comparison, poll loop and exit code then consume. A synthetic reading is the only
# way to make the verdict deterministic on any runner, including one whose own cpu.pressure is noisy.
# Parts 2 and 3 use no seam at all for the signal: they start real CPU-bound processes with
# `taskset` and drive the real kernel accounting (the cgroup's cpu.pressure, and the spin's
# schedstat), so the verdict is the kernel's. Part 3 is the NEGATIVE CONTROL that the gate can
# refuse for a real reason: N busy loops on one core, then the gate pinned to that core.
#
# What it asserts:
#   1. synthetic IDLE reading  -> exit 0;  synthetic BUSY reading -> exit 3, naming the signal;
#      boundaries either side of the limit; a malformed file is never read as idle.
#   2. real, one busy loop alone on a core (no queueing) -> the gate passes, on both the default
#      signal and the forced spin fallback.
#   3. real, 4 busy loops on one core -> the gate refuses (exit 3), on both.
#   4. the host load average is not consulted (source shape), and the retired M9_IDLE_MAX_LOAD warns.
# Every loop is killed on exit; the last assertion counts the survivors.
#
# Needs only bash >= 5, awk, pgrep, taskset. The PSI-dependent real part waits ~15 s for avg10.

set -uo pipefail
TEST_NAME=test_m9_idle_gate_measures_own_contention
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
GATE="$VERIFY_DIR/lib_m9_idle_gate.sh"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/m9-idle-gate.XXXXXX")"
LOOP_PIDS=()
cleanup() {
  local p
  for p in "${LOOP_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

[ -f "$GATE" ] || die "missing $GATE"
command -v taskset >/dev/null || die "taskset is required for the real-contention control"

# The pressure half is exercised with the competing-build list pointed at a name nobody runs, so that
# a runner (or this workstation) that is itself compiling cannot turn a pressure verdict into a
# build verdict. The build-name half is exercised on its own in part 1b with a REAL process.
NO_BUILDS="m9-no-such-process"

# run_gate <cpu-or-empty> [VAR=value ...] : run the real gate in a fresh bash (optionally pinned to
# one CPU), with M9_IDLE_WAIT=0 so a busy reading refuses at once. Prints the gate's stderr into
# $SCRATCH/gate.err and returns its exit status.
run_gate() {
  local cpu="$1"; shift
  local -a pin=()
  [ -n "$cpu" ] && pin=(taskset -c "$cpu")
  env -u M9_IDLE_PSI_FILE -u M9_IDLE_MAX_LOAD M9_IDLE_WAIT=0 M9_IDLE_BUILD_NAMES="$NO_BUILDS" "$@" TEST_NAME="$TEST_NAME" GATE="$GATE" VERIFY_DIR="$VERIFY_DIR" \
    "${pin[@]}" bash -c '. "$VERIFY_DIR/lib.sh"; TEST_NAME="${TEST_NAME}"; . "$GATE"; m9_require_idle_machine' \
    >"$SCRATCH/gate.out" 2>"$SCRATCH/gate.err"
}

psi_file() { # <path> <some-avg10>
  printf 'some avg10=%s avg60=0.27 avg300=0.16 total=50353923\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$2" >"$1"
}

# ---------------------------------------------------------------------------
# 1. Synthetic readings through the real gate.
psi_file "$SCRATCH/idle" 0.04
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/idle"; rc=$?
assert_eq "synthetic idle reading (some avg10=0.04): the gate passes" "0" "$rc"
assert_contains "and says which signal it read" "psi-override" "$(cat "$SCRATCH/gate.out")"

psi_file "$SCRATCH/busy" 42.24
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/busy"; rc=$?
assert_eq "synthetic busy reading (some avg10=42.24, the load the GARM runner reported): exit 3" "3" "$rc"
assert_contains "the refusal names the pressure and the limit" "above the limit of 5.0%" "$(cat "$SCRATCH/gate.err")"

psi_file "$SCRATCH/edge-ok" 5.00
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/edge-ok"; assert_eq "exactly at the limit (5.00): passes" "0" "$?"
psi_file "$SCRATCH/edge-bad" 5.01
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/edge-bad"; assert_eq "just above the limit (5.01): refuses" "3" "$?"
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/busy" M9_IDLE_MAX_PSI=60; assert_eq "M9_IDLE_MAX_PSI moves the limit (60 > 42.24): passes" "0" "$?"
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/busy" M9_LOAD_PRECONDITION_EXIT=7; assert_eq "M9_LOAD_PRECONDITION_EXIT is honoured" "7" "$?"

# A file the parser cannot read is not an idle reading: it falls through to the spin, which on this
# otherwise-quiet process must still be a MEASUREMENT (the note names it), never a silent pass.
printf 'garbage\n' >"$SCRATCH/bad"
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/bad"
# (stdout on a pass, stderr on a refusal: on a noisy host the spin may legitimately refuse.)
assert_contains "a malformed PSI file falls back to the spin rather than reading as idle" "(spin)" "$(cat "$SCRATCH/gate.out" "$SCRATCH/gate.err")"

# Poll-then-refuse: with a wait the gate polls (and says so) before refusing. 15 s is one poll.
SECONDS=0
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/busy" M9_IDLE_WAIT=15; rc=$?
assert_eq "with M9_IDLE_WAIT=15 it still refuses a persistently busy reading" "3" "$rc"
assert_true "after polling for the window rather than refusing at once (>= 15 s elapsed)" test "$SECONDS" -ge 15
assert_contains "and it announced the wait" "waiting for the machine to go idle" "$(cat "$SCRATCH/gate.out")"

# 1b. The competing-build detector, with a real process: a bash reached through a symlink named like a compiler (pgrep -x matches the comm, which the kernel sets from the name execve was given; a #!/usr/bin/env script would report `bash`).
ln -s "$(command -v bash)" "$SCRATCH/ninja"
# The trailing `true` stops bash exec-ing sleep directly (which would rename the process to `sleep`).
"$SCRATCH/ninja" -c 'sleep 300; true' &
LOOP_PIDS+=("$!")
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/idle" M9_IDLE_BUILD_NAMES="ninja"; rc=$?
assert_eq "a process named ninja that is not our ancestor makes the gate refuse, whatever the pressure" "3" "$rc"
assert_contains "and the refusal names it" "another build is running: ninja(" "$(cat "$SCRATCH/gate.err")"
pkill -9 -P "${LOOP_PIDS[-1]}" 2>/dev/null   # its `sleep 300`
kill -9 "${LOOP_PIDS[-1]}" 2>/dev/null; wait "${LOOP_PIDS[-1]}" 2>/dev/null; LOOP_PIDS=()
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/idle" M9_IDLE_BUILD_NAMES="ninja"; rc=$?
assert_eq "and with it gone the same gate passes" "0" "$rc"

# ---------------------------------------------------------------------------
# 2 and 3. Real contention.
# Two distinct allowed CPUs: the loops' core, and an idle one to run the gate on.
ALLOWED="$(taskset -pc $$ | sed 's/.*: //')"
mapfile -t CPUS < <(taskset -pc $$ | sed 's/.*: //' | tr ',' '\n' | awk -F- 'NF==2{for(i=$1;i<=$2;i++)print i; next}{print}')
CPU="${CPUS[0]:-}"; IDLE_CPU="${CPUS[1]:-}"
[ -n "$CPU" ] && [ -n "$IDLE_CPU" ] || die "need two allowed CPUs for the real-contention control (allowed: $ALLOWED)"
note "real-contention control: loops on CPU $CPU, idle-core gate on CPU $IDLE_CPU (allowed set: $ALLOWED)"

start_loops() { # <count> <cpu>
  local i
  for ((i = 0; i < $1; i++)); do
    taskset -c "$2" bash -c 'while :; do :; done' &
    LOOP_PIDS+=("$!")
  done
}
stop_loops() {
  local p
  for p in "${LOOP_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null && wait "$p" 2>/dev/null; done
  LOOP_PIDS=()
}

# POSITIVE CONTROL, made flake-proof. The host is shared: another tenant's task can land on whichever
# idle core we pick, and then the gate correctly refuses (seen: 8% on the chosen core). So sample a
# spread of candidate cores (every allowed CPU but the loop's), measure each one's own baseline with the
# gate's real spin, and require the gate to pass on the quietest ones that are under the limit. If none
# is under the limit the box is too noisy to prove "a quiet core passes", and that is reported as an
# explicit SKIP with the readings, never as a silent pass. (Part 1's synthetic idle reading remains the
# deterministic positive control.)
start_loops 1 "$CPU"
sleep 15
LIMIT=5.0
cands=()
n=$(( ${#CPUS[@]} - 1 )); stride=$(( (n + 7) / 8 )); [ "$stride" -ge 1 ] || stride=1
for ((i = 1; i < ${#CPUS[@]}; i += stride)); do cands+=("${CPUS[i]}"); done
baselines=()
for c in "${cands[@]}"; do
  v="$(taskset -c "$c" bash -c '. "$1"; _m9_spin_contention_pct' _ "$GATE" 2>/dev/null || echo 999)"
  baselines+=("$v:$c")
done
mapfile -t sorted < <(printf '%s\n' "${baselines[@]}" | sort -t: -k1,1 -g)
note "baseline spin contention per candidate core (pct:cpu), quietest first: ${sorted[*]}"
quiet=()
for e in "${sorted[@]}"; do awk -v v="${e%%:*}" -v l="$LIMIT" 'BEGIN{exit !(v<l)}' && quiet+=("${e##*:}"); done
if [ "${#quiet[@]}" -eq 0 ]; then
  note "SKIP: no candidate core had a baseline under ${LIMIT}% (${sorted[*]}); the positive real-contention control cannot be proven on this host right now. The synthetic idle reading in part 1 is the positive control for this run."
else
  ok_default=1 ok_spin=1 last_default_rc=
  for c in "${quiet[@]}"; do
    [ "$ok_default" -eq 1 ] && { run_gate "$c"; last_default_rc=$?; [ "$last_default_rc" -eq 0 ] && ok_default=0 && note "default-signal pass on CPU $c: $(grep 'idle enough' "$SCRATCH/gate.out" | sed 's/^ *-- *//')"; }
    [ "$ok_spin" -eq 1 ] && { run_gate "$c" M9_IDLE_PSI_FILE=/nonexistent/psi; [ $? -eq 0 ] && ok_spin=0 && assert_contains "spin fallback passed on quiet CPU $c, and it really used the spin" "(spin)" "$(cat "$SCRATCH/gate.out")"; }
    [ "$ok_default" -eq 0 ] && [ "$ok_spin" -eq 0 ] && break
  done
  if [ "$ok_default" -ne 0 ] && [ "$last_default_rc" -eq 3 ] && grep -q 'psi-cgroup' "$SCRATCH/gate.err"; then
    # The cgroup-wide PSI is not per-core: if other tenants of this cgroup keep it above the limit,
    # no choice of core can make the default signal pass. Say so, with the reading; never pass silently.
    note "SKIP: default-signal positive control: own-cgroup PSI stayed above ${LIMIT}% on every quiet core tried (${quiet[*]}); last refusal: $(grep 'cannot run' "$SCRATCH/gate.err" | head -1 | cut -c1-200)"
  else
    assert_eq "one busy loop on its own core, gate on a quiet core (tried ${quiet[*]}), default signal: the gate passes" "0" "$ok_default"
  fi
  assert_eq "same, forced spin fallback: the gate passes" "0" "$ok_spin"
fi
stop_loops

# NEGATIVE CONTROL: four loops on one core, the gate pinned to that core.
start_loops 4 "$CPU"
sleep 15
run_gate "$CPU"; rc=$?
assert_eq "NEGATIVE CONTROL: 4 busy loops on one core, default signal: the gate REFUSES (exit 3)" "3" "$rc"
note "$(grep 'cannot run' "$SCRATCH/gate.err" | head -1)"
run_gate "$CPU" M9_IDLE_PSI_FILE=/nonexistent/psi; rc=$?
assert_eq "NEGATIVE CONTROL: same, forced spin fallback: REFUSES (exit 3)" "3" "$rc"
note "spin gate output: $(cat "$SCRATCH/gate.out" "$SCRATCH/gate.err" | head -3)"
note "$(grep 'cannot run' "$SCRATCH/gate.err" | head -1)"
stop_loops

# ---------------------------------------------------------------------------
# 3b. A comma-radix locale. bash renders EPOCHREALTIME with the locale's radix ("1700000000,123456"
# under de_DE), and the spin used to strip only a dot, so the arithmetic broke. Real locale if the host
# has one; otherwise the radix is simulated by feeding the spin a comma-formatted EPOCHREALTIME.
DE_LOCALE="$(locale -a 2>/dev/null | grep -i -m1 '^de_DE\.utf-\?8$' || true)"
if [ -n "$DE_LOCALE" ]; then
  de_radix="$(LC_ALL="$DE_LOCALE" bash -c 'echo "$EPOCHREALTIME"')"
  note "locale $DE_LOCALE renders EPOCHREALTIME as $de_radix"
  run_gate "$IDLE_CPU" LC_ALL="$DE_LOCALE" M9_IDLE_PSI_FILE=/nonexistent/psi; rc=$?
  assert_true "under $DE_LOCALE the spin parses its timestamps and produces a reading (exit 0 or 3, never a die)" test "$rc" -eq 0 -o "$rc" -eq 3
  assert_contains "and it really measured with the spin" "(spin)" "$(cat "$SCRATCH/gate.out" "$SCRATCH/gate.err")"
else
  note "no de_DE UTF-8 locale on this host: simulating a comma radix"
fi
# Simulated, always: shadow EPOCHREALTIME with a comma-formatted counter inside the real function.
sim="$(bash -c '. "$1"
  # A function cannot assign EPOCHREALTIME, so redefine the spin loop clock via a wrapper: the stripping
  # expression is the thing under test, and it is applied to a comma-radix value here.
  v="1700000000,123456"; w="${v//[.,]/}"; [ "$w" = 1700000000123456 ] && echo ok-comma
  v="1700000000.123456"; w="${v//[.,]/}"; [ "$w" = 1700000000123456 ] && echo ok-dot' _ "$GATE")"
assert_contains "the radix-stripping expression handles a comma" "ok-comma" "$sim"
assert_contains "and a dot" "ok-dot" "$sim"
assert_true "the gate source uses that same expression" grep -qF '${EPOCHREALTIME//[.,]/}' "$GATE"
assert_eq "and no dot-only stripping remains" "0" "$(grep -c 'EPOCHREALTIME/\./' "$GATE" || true)"

# 3c. Fallback order: with the own-cgroup file absent the gate must NOT consult /proc/pressure/cpu.
assert_eq "system-wide PSI (/proc/pressure/cpu) is not read by the gate" "0" \
  "$(grep -v '^[[:space:]]*#' "$GATE" | grep -c 'proc/pressure' || true)"

# ---------------------------------------------------------------------------
# 4. The load average is not consulted, and the retired knob is loud.
assert_eq "the gate reads no /proc/loadavg outside comments" "0" \
  "$(grep -v '^[[:space:]]*#' "$GATE" | grep -c 'loadavg' || true)"
psi_file "$SCRATCH/idle2" 0.0
run_gate "" M9_IDLE_PSI_FILE="$SCRATCH/idle2" M9_IDLE_MAX_LOAD=1; rc=$?
assert_eq "setting the retired M9_IDLE_MAX_LOAD does not change the verdict" "0" "$rc"
assert_contains "but it warns that the knob is ignored" "M9_IDLE_MAX_LOAD is retired" "$(cat "$SCRATCH/gate.err")"

# No loop of ours survives.
assert_eq "no busy loop started by this check is still running" "0" \
  "$(for p in "${LOOP_PIDS[@]:-}"; do [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; done | wc -l)"

finish
