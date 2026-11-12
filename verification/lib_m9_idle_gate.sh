#!/usr/bin/env bash
# The M9 idle-machine gate: refuse to take a timed measurement while THIS JOB is being starved of CPU.
#
# Not to be executed directly: sourced AFTER lib.sh (it uses `note`, `TEST_NAME`) by
# lib_m9_observer.sh and by test_m9_idle_gate_measures_own_contention.sh.
#
# WHAT THE GATE IS FOR. The timing checks claim a difference between two binaries is smaller than
# the noise they ran in. That claim is only meaningful if the noise they measured is the noise the
# binaries actually ran in. A competing multi-core build is not noise the design can absorb: the
# between-session spread it characterises is sd 1.42pp, and a barretenberg build alongside it
# exceeds that comfortably and asymmetrically (whichever arm overlaps the busiest minutes takes the
# penalty and the rotation cannot cancel a load that is not periodic). It happened: M11's re-run
# had `just verify-m10` building while `verify-m9` timed, and `test_observer_disabled_is_free`
# reported a failure that was an artefact of the box rather than of the patch.
#
# So this is a PRECONDITION and not an assertion: nothing after it can be meaningfully evaluated and
# a wrong answer is worse than no answer. It gets its OWN exit code because a precondition exit that
# collides with a check's semantic vocabulary is a defect (WORK_DIR_PRECONDITION_EXIT exists because
# run_avm_differential.sh spends 1 on DIVERGENCE):
#
#   0  measured
#   1  an assertion failed
#   3  the machine was too busy to measure on (this)
#   4  it measured, the answer is inside the budget, and the interval around it is still too wide to
#      call that a claim at the session cap (M9_PRECISION_PRECONDITION_EXIT, added by M15)
#
# WHY /proc/loadavg IS THE WRONG SIGNAL ON A SHARED RUNNER. Until 2026-11-12 the gate compared the
# 1-minute load average with max(nproc/4, 2.0). /proc/loadavg is not namespaced: in a container it
# is the HOST's, and in a VM on a shared hypervisor the guest's average says nothing about the cores
# the hypervisor hands the guest. On the GARM runners it read 42.24 and 68.18 on 2 cores and 4.51
# and 7.29 on 6, the gate waited its full 420 s and refused every time, and the reactor job
# `verify-m12` was red on dev however the code under test changed (issue
# codetracer-pm/issues/2026-11-12-aztec-m12-step-stream-batching-idle-gate-reads-the-host-load-
# average-on-a-shared-runner.md). A load average also counts tasks in uninterruptible I/O sleep, is
# an average over a minute that lags a finished build, and is a count of runnable tasks, not a
# statement that anyone WAITED. The question the gate asks is "would a single-threaded timed
# process queue behind somebody else's work", so it measures that: the time runnable tasks spent
# waiting for a CPU, as this job sees it.
#
# (EPOCHREALTIME's radix follows the locale, '.' or ',' (de_DE); the spin strips either.)
#
# THE SIGNALS, in order, all in one unit: percent of the last ~10 s a task waited for a CPU.
#
#  1. psi-cgroup  `some avg10` of the process's OWN cgroup `cpu.pressure`, from /proc/self/cgroup
#                 -> /sys/fs/cgroup/<path>/cpu.pressure. This is Linux's pressure-stall information,
#                 a per-cgroup account of exactly the stall the gate cares about, and it is the
#                 contention the job experiences: a neighbour's load that does not delay this
#                 cgroup does not count, and CPU-quota throttling of this cgroup does.
#                 https://docs.kernel.org/accounting/psi.html (the "some" line, and the
#                 per-cgroup `cpu.pressure` files)
#                 https://docs.kernel.org/admin-guide/cgroup-v2.html#pressure-stall-information
#                 `some` and not `full`: for CPU, `full` is undefined at system level and `some`
#                 ("at least one task was stalled") is the queueing a timed single thread suffers.
#  2. spin        When the own-cgroup file is absent (CONFIG_PSI off, `psi=0`, cgroup v1, or a
#                 container that hides its cgroup): the gate spins for about one second and reads the
#                 spinning shell's own scheduler accounting, /proc/<pid>/schedstat
#                 (https://docs.kernel.org/scheduler/sched-stats.html): field 2 is nanoseconds this
#                 task spent runnable on a runqueue. The signal is that delta over the wall time of
#                 the spin, i.e. the share of a CPU-bound task's life spent queueing. The same
#                 quantity as PSI measured on one task for one second, so it uses the same threshold.
#                 A spin that compared wall time with a "known" duration was rejected: it needs a
#                 per-machine baseline, and a constant throttle slows every sample equally. If
#                 schedstat is missing too the gate DIES (exit 1); it never passes unmeasured.
#
# SYSTEM-WIDE PSI (/proc/pressure/cpu) IS DELIBERATELY NOT A FALLBACK. It is not namespaced: inside a
# container it is the HOST's reading, i.e. /proc/loadavg's mistake again. Measured on the shared
# workstation nixos-ci-bare-004 (2026-11-12): system PSI read 17% from neighbours while this job's own
# cgroup stayed at or below 2.2%. The spin sees only what this process suffers, so it is the better
# stand-in when the cgroup file is missing.
#
# LIMIT, STATED: none of these see a hypervisor stealing time from the whole guest while the guest
# believes it is running. That is invisible from inside the guest by any of the three, and no
# in-guest gate can promise otherwise.
#
# TWO KINDS OF REFUSAL, because they fail differently. Competing build processes are found by NAME
# and are exact and immediate (and are only visible when they share our PID namespace, which is the
# only case in which they could be ours to worry about); the pressure reading is the lagging,
# continuous one. Either refuses.
#
# KNOBS
#   M9_IDLE_WAIT      seconds to keep polling before refusing (default 420)
#   M9_IDLE_MAX_PSI   refuse above this percent (default 5.0): in 10 s, tasks of this job waited
#                     for a CPU more than half a second. The timed simulations run for seconds
#                     each, so half a second of queueing per ten is already a visible fraction of
#                     one session; an idle runner reads 0.0 to 0.3.
#   M9_IDLE_MAX_LOAD  RETIRED with the load-average signal. It is no longer a threshold, so setting
#                     it prints a warning naming M9_IDLE_MAX_PSI and is otherwise ignored; a
#                     knob that silently stopped doing anything would be a bypass nobody saw.
#   M9_LOAD_PRECONDITION_EXIT   exit code of the refusal (default 3)
#   M9_IDLE_BUILD_NAMES  space-separated process names that count as a competing build (default
#                     below). A test seam as much as a knob: a test on a box that is itself building
#                     must be able to say "no competitors" to exercise the pressure half alone.
#
# TEST SEAM (documented in test_m9_idle_gate_measures_own_contention.sh):
#   M9_IDLE_PSI_FILE  read the PSI `some avg10` from this file instead of discovering one. The file
#                     is parsed by the real parser, so a test writes the kernel's real format. A
#                     path that does not exist means "no PSI here" and selects the spin fallback.
#
# It WAITS before it refuses, and that is not a softening. The pressure this gate sees when it
# starts is usually its OWN: it has just built two drivers with the whole machine and avg10 is still
# carrying that build. A precondition that refuses there can never pass, which is how a check gets
# an --i-mean-it flag bolted on and then gets run with it. So it polls for a bounded window and
# refuses only if the job is STILL being starved at the end of it; the failure mode it exists for,
# somebody's build running for the next half hour, outlasts the window and is still caught.
M9_LOAD_PRECONDITION_EXIT="${M9_LOAD_PRECONDITION_EXIT:-3}"
M9_IDLE_WAIT="${M9_IDLE_WAIT:-420}"
M9_IDLE_MAX_PSI="${M9_IDLE_MAX_PSI:-5.0}"

# _m9_psi_some_avg10 <file> : print the `some avg10=` value of a PSI file, fail if unreadable or
# malformed. Format: `some avg10=0.04 avg60=0.27 avg300=0.16 total=50353923`.
_m9_psi_some_avg10() {
  local v
  [ -r "$1" ] || return 1
  v="$(awk '$1=="some"{for(i=2;i<=NF;i++) if($i ~ /^avg10=/){sub(/^avg10=/,"",$i); print $i; exit}}' "$1" 2>/dev/null)" || return 1
  case "$v" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  printf '%s\n' "$v"
}

# _m9_own_cgroup_pressure_file : print the cgroup-v2 cpu.pressure path of this process, or fail.
_m9_own_cgroup_pressure_file() {
  local rel f
  rel="$(awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup 2>/dev/null)"
  [ -n "$rel" ] || return 1   # cgroup v1 (no `0::` line) or unreadable
  f="/sys/fs/cgroup${rel%/}/cpu.pressure"
  [ -r "$f" ] || return 1
  printf '%s\n' "$f"
}

# _m9_spin_contention_pct : the share of a ~1 s CPU-bound spin this shell spent queueing, from its own
# schedstat. Fails if the kernel does not provide it.
_m9_spin_contention_pct() {
  # $BASHPID, not $$: this runs inside `$(...)`, where $$ is still the PARENT shell, which sleeps
  # while we spin, so reading its schedstat reports 0% contention however starved the spinner is.
  local f="/proc/$BASHPID/schedstat" spins=0 w1 d0 d1 t0 t1 _x
  [ -r "$f" ] || return 1
  read -r _x d0 _x < "$f" || return 1
  t0="${EPOCHREALTIME//[.,]/}"
  t1="$t0"
  while [ $((t1 - t0)) -lt 1000000 ]; do   # microseconds; bash >= 5 for EPOCHREALTIME
    spins=$((spins + 1))   # the work being timed; its count is irrelevant, only that it burns CPU
    t1="${EPOCHREALTIME//[.,]/}"
  done
  read -r _x d1 _x < "$f" || return 1
  w1=$((t1 - t0))
  [ "$w1" -gt 0 ] || return 1
  # run_delay is ns, the wall time is us.
  awk -v d="$((d1 - d0))" -v w="$w1" 'BEGIN{printf "%.2f\n", 100.0 * (d / 1000.0) / w}'
}

# _m9_read_contention : set M9_IDLE_SIGNAL_NAME and M9_IDLE_SIGNAL_VALUE (percent), or return 1.
_m9_read_contention() {
  local f v
  M9_IDLE_SIGNAL_NAME="" M9_IDLE_SIGNAL_VALUE=""
  if [ -n "${M9_IDLE_PSI_FILE+x}" ]; then
    if v="$(_m9_psi_some_avg10 "$M9_IDLE_PSI_FILE")"; then
      M9_IDLE_SIGNAL_NAME="psi-override"; M9_IDLE_SIGNAL_VALUE="$v"; return 0
    fi
  else
    if f="$(_m9_own_cgroup_pressure_file)" && v="$(_m9_psi_some_avg10 "$f")"; then
      M9_IDLE_SIGNAL_NAME="psi-cgroup"; M9_IDLE_SIGNAL_VALUE="$v"; return 0
    fi
  fi
  if v="$(_m9_spin_contention_pct)"; then
    M9_IDLE_SIGNAL_NAME="spin"; M9_IDLE_SIGNAL_VALUE="$v"; return 0
  fi
  return 1
}

m9_require_idle_machine() {
  local cores busy self_tree pid waited=0 reason="" name p
  cores="$(nproc 2>/dev/null || echo 1)"
  if [ -n "${M9_IDLE_MAX_LOAD:-}" ]; then
    printf '%s: warning: M9_IDLE_MAX_LOAD is retired and ignored (the gate no longer reads the load average); use M9_IDLE_MAX_PSI, a percent.\n' \
      "$TEST_NAME" >&2
  fi

  # Our own ancestry is excluded by PID: `just`, this shell and the harness are not competitors, and
  # matching them by name would make this refuse to run every time.
  self_tree=" "
  pid=$$
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    self_tree="$self_tree$pid "
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
  done

  while : ; do
    busy=""
    # `ccache` is in this list from M14 on, and it is not decoration. With the compiler cache wired
    # into both dev shells, a competing build that is HITTING spawns no compiler at all (every
    # process in it is named `ccache`), so a detector naming only compilers would have gone blind to
    # exactly the kind of build the cache makes cheap enough to run beside a measurement.
    for name in ${M9_IDLE_BUILD_NAMES:-ninja cmake ccache cc1plus cc1 clang clang++ ld.lld lld rustc cargo make gcc g++}; do
      for p in $(pgrep -x "$name" 2>/dev/null); do
        case "$self_tree" in *" $p "*) continue ;; esac
        busy="$busy $name($p)"
      done
    done

    reason=""
    [ -n "$busy" ] && reason="another build is running:$busy"
    if ! _m9_read_contention; then
      # No PSI and no schedstat: unmeasurable, and unmeasured must not read as idle.
      die "cannot measure CPU contention: no cpu.pressure (PSI) and no /proc/<pid>/schedstat on this kernel"
    fi
    if [ -z "$reason" ] && awk -v l="$M9_IDLE_SIGNAL_VALUE" -v m="$M9_IDLE_MAX_PSI" 'BEGIN{exit !(l>m)}'; then
      reason="CPU pressure ($M9_IDLE_SIGNAL_NAME) is ${M9_IDLE_SIGNAL_VALUE}% of the sampled window spent waiting for a CPU, above the limit of ${M9_IDLE_MAX_PSI}%"
    fi
    [ -z "$reason" ] && break

    if [ "$waited" -ge "$M9_IDLE_WAIT" ]; then
      printf '%s: cannot run: %s\n' "$TEST_NAME" "$reason" >&2
      printf '%s: still busy after %ss. A timing measurement taken while this job is starved of CPU is\n' \
        "$TEST_NAME" "$waited" >&2
      printf '%s: not measuring what it claims, so this refuses rather than reporting a number.\n' \
        "$TEST_NAME" >&2
      printf '%s: run it on an idle machine. M9_IDLE_WAIT and M9_IDLE_MAX_PSI override, and if\n' \
        "$TEST_NAME" >&2
      printf '%s: you use them, the interval this check reports is not the one it documents.\n' \
        "$TEST_NAME" >&2
      exit "$M9_LOAD_PRECONDITION_EXIT"
    fi
    [ "$waited" -eq 0 ] && note "waiting for the machine to go idle before timing: $reason"
    sleep 15
    waited=$((waited + 15))
  done

  note "machine is idle enough to time on: CPU pressure ($M9_IDLE_SIGNAL_NAME) ${M9_IDLE_SIGNAL_VALUE}%, limit ${M9_IDLE_MAX_PSI}%, $cores core(s), no competing builds, waited ${waited}s"
}
