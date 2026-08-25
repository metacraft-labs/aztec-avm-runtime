#!/usr/bin/env bash
# lib_m21_form_b.sh — shared machinery for M21's Form B checks.
#
# WHERE PROBES LIVE, AND WHY NOT IN THE PACKAGE. `orchestration/` is a published package directory
# and the campaign's rule is that no scratch file goes in one — M20's review had to check that
# `orchestration/m20-dbg.mjs` and `m20-run.mjs` were gone, and M20's own staleness computation was
# wrong for a whole milestone BECAUSE two checks wrote probes into `orchestration/src` and made the
# shared arm run happen three times instead of once.
#
# So probes are written into a work directory under `~/.cache` (never `$TMPDIR`, which on this host
# is a quota-limited tmpfs where `df` reports gigabytes and `dd` fails at 356 MiB), and they import
# `orchestration/src/*.ts` BY ABSOLUTE PATH. Node resolves a bare `@aztec/…` specifier relative to
# the IMPORTING file, so the orchestration sources find their own `node_modules` and the probe needs
# none of its own — which also means a probe cannot accidentally resolve a different install of
# `@aztec/stdlib`. Five `node_modules` roots in this repository each carry one, and
# `serializeWithMessagePack` recognises an `Fr` by the class object of ITS OWN install, so "which
# install" is a correctness question and not a tidiness one.

M21_WORK="${M21_WORK:-$HOME/.cache/aztec-m21-form-b}"
export M21_WORK

M21_SRC="$REPO_ROOT/orchestration/src"
export M21_SRC

m21_prepare() {
  require_work_dir "$M21_WORK" 1
  mkdir -p "$M21_WORK/probes"
  # A probe may import a published package DIRECTLY — `@aztec/foundation/curves/bn254` for an `Fr`
  # — and Node resolves a bare specifier from the importing file's own directory upward, which for
  # a probe in the work directory finds nothing. The symlink points at the SAME install the
  # orchestration sources resolve to, which is the only correct one: five `node_modules` roots in
  # this repository each carry an `@aztec/stdlib`, and `serializeWithMessagePack` recognises an `Fr`
  # by the class object of its own install, so two installs in one process is a wrong answer rather
  # than a slow one.
  ln -sfn "$REPO_ROOT/orchestration/node_modules" "$M21_WORK/probes/node_modules"
  assert_dir "the orchestration sources are where this milestone expects them" "$M21_SRC"
  assert_file "…including M21's own producer" "$M21_SRC/form_b.ts"
  assert_file "…and the settled-read source" "$M21_SRC/settled_read_source.ts"
  assert_dir "…and the package's own node_modules, which the probes resolve through" \
    "$REPO_ROOT/orchestration/node_modules/@aztec/stdlib"
}

# m21_probe <name> <source-text> -> writes the probe, runs it, prints stdout; stderr to <name>.err
#
# The exit status is the probe's. Callers assert on it EXPLICITLY: "the output had the expected
# lines" is not the same claim as "the probe exited 0", and a run that dies after printing what a
# check greps for would satisfy the first and not the second.
m21_probe() { # <name> <source-text>
  local name="$1" src="$2"
  printf '%s' "$src" >"$M21_WORK/probes/$name.mjs"
  ( cd "$M21_WORK/probes" && node "$name.mjs" ) 2>"$M21_WORK/probes/$name.err"
}

m21_probe_err() { printf '%s\n' "$M21_WORK/probes/$1.err"; }

# The import prologue every probe shares. One place, so two probes cannot come to disagree about
# which module they are testing.
m21_imports() {
  cat <<EOF
import {
  ALLOWED_SURFACE,
  PRIVATE_SIMULATORS,
  ResidentSettledReadSource,
  SETTLED_READ_TREES,
  SettledReadSourceSurfaceExceeded,
  executeExternallySettledTx,
  externalTx,
  locallyExecutedTx,
  locallyOriginatedTx,
  originateLocalTx,
  publicOnlyPrivateExecution,
  strictSurface,
  summarisePrivateExecution,
  txFromTail,
} from '$M21_SRC/index.ts';
EOF
}

# A key/value line, the transcript vocabulary every driver in this repository uses. `m21_field`
# reads one back. The terminal sentinel is `formB.done`, and the checks REFUSE on its absence
# through lib.sh's one implementation rather than adding an eighth spelling.
m21_field() { # <file> <key>
  [ -f "$1" ] || die "m21_field: no such file: $1"
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1"
}
