#!/usr/bin/env bash
# lib_l0_node_client.sh — shared machinery for L0's three checks.
#
# L0 is the first milestone of the LIVE-CHAIN REPLAY campaign
# (codetracer-specs/Planned-Work/Aztec-Live-Chain-Replay.milestones.org), which is a separate
# campaign from Aztec-AVM-Runtime and shares this repository, this brief and these conventions.
#
# WHERE PROBES LIVE, AND WHY NOT IN THE PACKAGE. `replay/` is a package directory and the
# campaign's rule is that no scratch file goes in one: M20's own staleness computation was wrong
# for a whole milestone because two checks wrote probes into `orchestration/src`. So probes are
# written into `~/.cache/aztec-l0-node-client` — never `$TMPDIR`, which on the campaign's Linux
# host is a quota-limited tmpfs where `df` reports gigabytes and a write fails at 356 MiB — and
# they import `replay/src/*.ts` BY ABSOLUTE PATH.
#
# NODE RESOLVES A BARE `@aztec/…` SPECIFIER FROM THE IMPORTING FILE UPWARD, so the replay sources
# find `replay/node_modules` by themselves, and the probe gets a symlink to the SAME install. Six
# `node_modules` roots in this repository carry an `@aztec/stdlib` and they are not
# interchangeable: `orchestration/` is on `npm.deletion_era` and `replay/` is on `npm.current`, and
# a class identity comparison across two installs is a wrong answer rather than a slow one. One
# symlink, one install.
#
# `_l0_fake_node.mjs` IS COPIED INTO THE WORK DIRECTORY RATHER THAN IMPORTED FROM `verification/`,
# and that is not cosmetic: a module under `verification/` resolves its own bare specifiers from
# `verification/` upward, finds no `node_modules`, and dies `ERR_MODULE_NOT_FOUND` — measured, on
# this lib's first run. Copying it beside the symlink puts it on the same resolution root as the
# probe. It is re-copied on EVERY run, because a stale copy is state you did not produce.

L0_WORK="${L0_WORK:-$HOME/.cache/aztec-l0-node-client}"
export L0_WORK

L0_SRC="$REPO_ROOT/replay/src"
export L0_SRC

l0_prepare() {
  require_work_dir "$L0_WORK" 1
  mkdir -p "$L0_WORK/probes"
  ln -sfn "$REPO_ROOT/replay/node_modules" "$L0_WORK/probes/node_modules"
  cp "$VERIFY_DIR/_l0_fake_node.mjs" "$L0_WORK/probes/l0_fake_node.mjs"

  assert_dir "the replay sources are where L0 expects them" "$L0_SRC"
  assert_file "…including the enumeration" "$L0_SRC/node_surface.ts"
  assert_file "…the client" "$L0_SRC/node_client.ts"
  assert_file "…the guard" "$L0_SRC/strict_surface.ts"
  assert_file "…the pinned protocol version" "$L0_SRC/pinned_protocol_version.ts"
  assert_file "…and the shared membership-witness seam L2 and M35 both answer" \
    "$L0_SRC/membership_witness_source.ts"
  assert_dir "…and the package's own node_modules, on npm.current, which the probes resolve through" \
    "$REPO_ROOT/replay/node_modules/@aztec/stdlib"
  assert_file "the fake node was copied onto the probe's resolution root" \
    "$L0_WORK/probes/l0_fake_node.mjs"
}

# l0_probe <name> <source-text> -> writes the probe, runs it, prints stdout; stderr to <name>.err
#
# The exit status is the probe's. Callers assert on it EXPLICITLY: "the output had the expected
# lines" is not the same claim as "the probe exited 0", and a run that dies after printing what a
# check greps for would satisfy the first and not the second.
#
# EVERY RUN IS BOUNDED. A check that hangs never reddens — the campaign has met a `node` invocation
# with no timeout that sat at zero bytes of output and would have blocked the whole sweep behind
# it. Exceeding the bound is a named failure below, not a hang.
l0_probe() { # <name> <source-text>
  local name="$1" src="$2"
  printf '%s' "$src" >"$L0_WORK/probes/$name.mjs"
  ( cd "$L0_WORK/probes" && timeout "${L0_PROBE_TIMEOUT:-180}" node "$name.mjs" ) \
    2>"$L0_WORK/probes/$name.err"
}

l0_probe_err() { printf '%s\n' "$L0_WORK/probes/$1.err"; }

# l0_run_probe <name> <source-text> <outfile>
#
# The whole ritual, in one place, because three checks were about to write it three times: run,
# assert the exit status, DIE with the probe's own stderr if it is non-zero, and refuse an
# incomplete transcript through lib.sh's one implementation rather than adding another spelling.
#
# THE ORDER IS LOAD-BEARING: exit status first, completeness second. A probe that throws part way
# leaves a partial transcript indistinguishable from the V8/WASI truncation, and asking the
# completeness question first makes the refusal tell the reader about a flake when what happened
# was an exception with a stack trace sitting in stderr. M21 measured that on its own first run.
l0_run_probe() { # <name> <source-text> <outfile>
  local name="$1" src="$2" out="$3" rc
  l0_probe "$name" "$src" >"$out"
  rc=$?
  assert_eq "the $name probe exited 0" "0" "$rc"
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      die "the $name probe exceeded its ${L0_PROBE_TIMEOUT:-180}s bound and was killed. That is a
     named failure and not a hang; a check that hangs never reddens. Its stderr so far:
$(head -12 "$(l0_probe_err "$name")")"
    fi
    die "the $name probe exited $rc. Its stderr, which is where the reason is:
$(head -20 "$(l0_probe_err "$name")")"
  fi
  require_complete_transcript "$out" l0.done "the $name probe's"
  assert_eq "…and the $name transcript is complete rather than truncated" "complete" \
    "$(transcript_completeness "$out" l0.done)"
}

# A key/value line, the transcript vocabulary every driver in this repository uses. The terminal
# sentinel is `l0.done`.
l0_field() { # <file> <key>
  [ -f "$1" ] || die "l0_field: no such file: $1"
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1"
}

# The import prologue every probe shares, so two probes cannot come to disagree about which module
# they are testing.
l0_imports() {
  cat <<EOF
import { startFakeNode, unusedPort } from './l0_fake_node.mjs';
import {
  ALLOWED_SURFACE,
  ANCHOR_ONLY_METHODS,
  AZTEC_NODE_METHOD_COUNT,
  COMPONENTS_VERSION_FIELDS,
  MEMBERSHIP_WITNESS_QUERIES,
  NodeUnreachable,
  PACKAGE_ONLY_METHODS,
  PINNED_NETWORK,
  PINNED_PROTOCOL_VERSION,
  ProtocolVersionMismatch,
  REFUSAL_GROUPS,
  REFUSED_METHODS,
  REPLAY_CLIENT_OWN_MEMBERS,
  REPLAY_NODE_SURFACE,
  ReplayNodeSurfaceExceeded,
  SettledTransactionNotFound,
  createReplayNodeClient,
  createUnguardedNodeClientForControls,
  strictSurface,
} from '$L0_SRC/index.ts';

const line = (k, v) => console.log(\`\${k} \${v}\`);
EOF
}

# ---------------------------------------------------------------------------
# THE ANCHOR SIDE.
#
# Every enumeration in L0 is re-derived from upstream AT THE PINNED ANCHOR on every run rather than
# read back out of `replay/src`. That is the whole point of the deliverable: a one-off grep answers
# today's question, a check that re-derives answers next month's, and the milestone that skipped
# this step in the sibling campaign paid four milestones of deferral for it.
#
# The fork is a WORKSPACE-ROOT SIBLING (`$FORK_ROOT`, the M0 layout decision) and only its OBJECT
# STORE is used — `git show <anchor>:<path>` — so a bare or partial clone is enough and no working
# tree has to be checked out at the anchor.
# ---------------------------------------------------------------------------

l0_cpp_anchor() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
    "$REPO_ROOT/pins.json"
}

l0_at_anchor() { # <path> -> that file's contents at anchors.cpp
  ( cd "$FORK_ROOT" && git show "$(l0_cpp_anchor):$1" ) 2>/dev/null
}

# l0_anchor_node_members <source-text> -> "COUNT n", then one "MEMBER <name>" per line, then
# "RESIDUE <n>" and one "UNPLACED <line>" per line the scanner could not classify.
#
# THE SCANNER PRINTS ITS RESIDUE RATHER THAN COUNTING ITS MATCHES. M22's vendored-diff classifier
# is why: a character class that is too narrow becomes a silent undercount, and a scanner that
# reports what it cannot place turns the same defect into a red line. The residue here is asserted
# to be exactly the multi-line-signature continuations, so "the residue is empty" cannot be
# achieved by a class that swallowed everything.
l0_anchor_node_members() { # <source-text>
  python3 - "$1" <<'PY'
import re, sys

src = sys.argv[1].split('\n')
try:
    start = next(i for i, l in enumerate(src) if l.startswith('export interface AztecNode'))
except StopIteration:
    print('COUNT 0'); print('RESIDUE 0'); raise SystemExit(0)
end = next(i for i in range(start + 1, len(src)) if src[i] == '}')

members, residue = [], []
for line in src[start + 1:end]:
    if not line.strip():
        continue
    if not re.match(r'^  \S', line):        # depth-2 only: nested object literals are not members
        continue
    s = line[2:]
    if s.startswith('*') or s.startswith('/*') or s.startswith('//') or s.startswith('}'):
        continue
    # A member is `name(`, `name<`, `name?:` or `name:`. The `<` arm is here because a character
    # class without it found three of five in M23 — `warpL2TimeAtLeastTo` has a digit and the
    # generics have angle brackets, and both were the whole point of the section that missed them.
    m = re.match(r'^([A-Za-z_$][A-Za-z0-9_$]*)\s*[<(?:]', s)
    if m:
        members.append(m.group(1))
    else:
        residue.append(line)

print('COUNT %d' % len(set(members)))
for name in sorted(set(members)):
    print('MEMBER %s' % name)
print('RESIDUE %d' % len(residue))
for line in residue:
    print('UNPLACED %s' % line.strip())
PY
}

# l0_anchor_schema_keys <source-text> -> "COUNT n" and "MEMBER <name>" lines for
# `AztecNodeApiSchema`, the SECOND independent derivation of the same set.
#
# `ApiSchemaFor<AztecNode>` makes the compiler require one key per method, so the two sets are the
# same BY CONSTRUCTION — which is exactly why taking both is worth doing: a scanner error in either
# shows up as a disagreement rather than as a plausible number. When the derivation IS the number,
# run the derivation twice, differently, before believing it.
l0_anchor_schema_keys() { # <source-text>
  python3 - "$1" <<'PY'
import re, sys

src = sys.argv[1].split('\n')
try:
    start = next(i for i, l in enumerate(src) if l.startswith('export const AztecNodeApiSchema'))
except StopIteration:
    print('COUNT 0'); print('RESIDUE 0'); raise SystemExit(0)
end = next(i for i in range(start + 1, len(src)) if src[i] == '};')

keys, residue = [], []
for line in src[start + 1:end]:
    if not line.strip():
        continue
    if not re.match(r'^  \S', line):
        continue
    s = line[2:]
    if s.startswith('*') or s.startswith('/*') or s.startswith('//'):
        continue
    m = re.match(r'^([A-Za-z_$][A-Za-z0-9_$]*)\s*:', s)
    if m:
        keys.append(m.group(1))
    else:
        residue.append(line)

print('COUNT %d' % len(set(keys)))
for name in sorted(set(keys)):
    print('MEMBER %s' % name)
print('RESIDUE %d' % len(residue))
for line in residue:
    print('UNPLACED %s' % line.strip())
PY
}

l0_members_of() { # <scanner-output> -> the sorted names, one per line
  printf '%s\n' "$1" | sed -n 's/^MEMBER //p'
}

L0_NODE_IFACE_PATH='yarn-project/stdlib/src/interfaces/aztec-node.ts'
export L0_NODE_IFACE_PATH
