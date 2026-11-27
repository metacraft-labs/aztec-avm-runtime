#!/usr/bin/env bash
# runquota_bridge.sh -- put a heavy build command under a RunQuota lease when one is available.
#
#   runquota_bridge.sh jobserver [FLAGS] -- CMD [ARG...]    CMD follows a GNU make jobserver (ninja, make)
#   runquota_bridge.sh run       [FLAGS] -- CMD [ARG...]    CMD takes a width flag (RUNQUOTA_RUN_WIDTH)
#   runquota_bridge.sh active VERB                          exit 0 if VERB would take a lease, else 1
#
# It `exec`s either `runquota VERB FLAGS -- CMD` or plain `CMD`, so the command's output and exit
# status are untouched and, where RunQuota is absent, the build runs exactly as it did before.
#
# WHY. Several checkouts, agent sessions and CI jobs on one machine each assumed every core was
# theirs (bare `ninja` is cores+2 jobs; `nproc` fed to `-j`), so together they oversubscribed it.
# Under a lease the command takes its slots from the host's shared budget, waits its turn, and runs
# at the granted width. RunQuota has no ninja adapter; ninja (>= 1.13) follows a make jobserver, so
# the bridge for ninja is `jobserver`. The idiom and its decisions are documented in
# reprobuild/docs/user-guide/runquota-in-justfiles.md; this file is that idiom for scripts.
#
# CONTROL. RQ unset     auto: bridge when the installed `runquota` has the verb
#          RQ=          (empty) off: run CMD directly
#          RQ="PREFIX"  any other value replaces `runquota VERB FLAGS --`, e.g.
#                       RQ="runquota jobserver --width 2 --" pins a width
#
# PROBE THE VERB, NOT THE BINARY. A `runquota` that predates a verb prints its usage and exits 0
# rather than rejecting the word, so a bridged build would "pass" without running anything. The
# probes below ask the verb something that only a build which has it answers; neither takes a lease:
#   jobserver  with no command prints `runquota jobserver: missing command`
#   run        `--adapter list` prints a table starting `adapters`
#
# ONE BRIDGE PER COMMAND CHAIN, at the command that does the work and not around a whole script:
# a lease is held for the command's life, and a `run` started inside a `jobserver` would queue behind
# the command that started it. Nest `jobserver` inside `run`, never the reverse.
#
# MEMORY. Pass `--mem SIZE` in FLAGS where a measured peak exists. A lease reserves memory as well
# as CPU (default 512 MiB per slot); the reservation is what other leases are admitted against and
# does not cap the process.
set -uo pipefail

_rq_verb_available() { # <verb>
  command -v runquota >/dev/null 2>&1 || return 1
  # Captured, not piped into `grep -q`: under pipefail grep's early exit would SIGPIPE the writer
  # and read as "verb absent".
  local out
  case "$1" in
    jobserver) out="$(runquota jobserver 2>&1 </dev/null)" || true
               case "$out" in *'runquota jobserver: missing command'*) return 0 ;; esac ;;
    run)       out="$(runquota run --adapter list 2>/dev/null </dev/null)" || true
               case "$out" in adapters*|*$'\nadapters'*) return 0 ;; esac ;;
  esac
  return 1
}

# 0 when VERB would take a lease under the current RQ setting.
_rq_active() { # <verb>
  if [ "${RQ+set}" = set ]; then
    [ -n "$RQ" ]
  else
    _rq_verb_available "$1"
  fi
}

if [ "${1:-}" = active ]; then
  [ $# -eq 2 ] || { echo "usage: runquota_bridge.sh active VERB" >&2; exit 2; }
  _rq_active "$2"
  exit $?
fi

verb="${1:-}"
case "$verb" in jobserver|run) shift ;; *)
  echo "usage: runquota_bridge.sh {jobserver|run} [FLAGS] -- CMD [ARG...]" >&2; exit 2 ;;
esac

flags=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
[ "${1:-}" = "--" ] || { echo "runquota_bridge.sh: missing '--' before the command" >&2; exit 2; }
shift
[ $# -gt 0 ] || { echo "runquota_bridge.sh: missing command" >&2; exit 2; }

if [ "${RQ+set}" = set ]; then
  if [ -n "$RQ" ]; then
    # shellcheck disable=SC2086  # the prefix is a command line on purpose
    exec $RQ "$@"
  fi
  exec "$@"
fi
if _rq_verb_available "$verb"; then
  exec runquota "$verb" ${flags[@]+"${flags[@]}"} -- "$@"
fi
exec "$@"
