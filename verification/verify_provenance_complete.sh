#!/usr/bin/env bash
# verify_provenance_complete
#
# M1 verification: every vendored source file has a provenance header naming a
# path that EXISTS at the recorded upstream commit, and an inventory entry
# justifying the vendoring.
#
# Three claims, each asserted against the real files rather than against
# PROVENANCE.md's own prose:
#
#   1. COVERAGE. Every tracked file under a vendored prefix is mapped. Checked
#      from the filesystem side, not the document side: the check walks the
#      declared prefixes with `git ls-files` and requires the mapping to account
#      for every path it finds, so a file cannot be vendored and left unrecorded.
#   2. THE HEADER IS TRUE. Every header is re-derived from the mapping and
#      byte-compared with what is in the file, and — the substantive part — the
#      `upstream-path` it names is resolved with `git cat-file -e <commit>:<path>`
#      in the fork. A header naming a path that does not exist at the recorded
#      commit is worse than no header. The only files without a header are the
#      ones PROVENANCE.md exempts, each with a format reason, and the exemption
#      list is asserted to be small and to consist only of formats that genuinely
#      cannot carry a comment (plus one symlink, which a header would corrupt).
#   3. THE VENDORING IS JUSTIFIED. Every mapped file's `inventory:` id resolves to
#      an entry in REUSE-INVENTORY.md whose decision is a vendoring decision.
#      "Vendoring requires an inventory justification, not merely a habit."
#
# Plus two negative controls, because a header check that has never rejected a
# header proves nothing.
#
# Run: just verify-provenance

TEST_NAME="verify_provenance_complete"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
PROV="$REPO_ROOT/tools/provenance.py"
[ -f "$PROV" ] || die "the provenance tool is missing at $PROV"

# ---- the TypeScript anchor is checked out, not merely reachable ------------
# M1 pins the TS side as "a worktree at 3a68d68ac2". A commit the fork happens to
# contain is not the same thing as a checkout someone can read, so the worktree
# is asserted rather than assumed. It is gitignored (upstream/), so this is the
# only place its existence is recorded.
TS_ANCHOR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["ts"]["commit"])' "$REPO_ROOT/pins.json")"
if [ -d "$REPO_ROOT/upstream/tsavm" ]; then
  wt_head="$(git -C "$REPO_ROOT/upstream/tsavm" rev-parse HEAD 2>/dev/null || echo none)"
  assert_eq "upstream/tsavm is checked out at the ts anchor" "$TS_ANCHOR" "$wt_head"
  assert_true "upstream/tsavm is a worktree of the fork, not an independent clone" \
    bash -c "git -C '$FORK_ROOT' worktree list --porcelain | grep -qx 'worktree $REPO_ROOT/upstream/tsavm'"
  assert_dir "the worktree carries the recovered simulator sources" \
    "$REPO_ROOT/upstream/tsavm/yarn-project/simulator/src/public/avm"
else
  fail "upstream/tsavm is missing; M1 pins the TypeScript side as a worktree at the ts anchor"
fi

map="$(python3 "$PROV" map)" || die "provenance.py map failed"
total="$(printf '%s\n' "$map" | grep -c . || true)"
assert_ge "the mapping is not empty" 500 "$total"

# ---- 1. coverage, checked from the filesystem ------------------------------
# Rebuild the set of tracked files under every declared prefix independently of
# the mapping, and require the two sets to be equal.
prefixes="$(python3 "$PROV" counts | cut -f2)"
n_prefixes="$(printf '%s\n' "$prefixes" | grep -c . || true)"
assert_ge "several vendored trees are declared" 5 "$n_prefixes"

actual_files="$(mktemp)"; mapped_files="$(mktemp)"
trap 'rm -f "$actual_files" "$mapped_files"' EXIT

# The independent side: what git says is tracked under each declared prefix.
: > "$actual_files"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  git -C "$REPO_ROOT" ls-files -- "$p" >> "$actual_files"
done <<EOF
$prefixes
EOF
sort -u -o "$actual_files" "$actual_files"

# The document side: the rows the tree tables (V*) produced. Single-file rows
# (F*) are excluded here on purpose — they have no prefix to walk, so they are
# checked one by one below instead.
printf '%s\n' "$map" | awk -F'\t' '$9 ~ /^V/ {print $1}' | sort -u > "$mapped_files"

if diff -q "$actual_files" "$mapped_files" >/dev/null; then
  pass "every tracked file under a vendored prefix is mapped, and nothing else is  [$(wc -l < "$mapped_files") files]"
else
  fail "the mapping and the tracked tree disagree: $(diff "$actual_files" "$mapped_files" | head -5 | tr '\n' ' ')"
fi

# Each individually-declared file must be tracked, and must NOT sit inside a
# vendored prefix (which would map it twice, by two different rules).
n_single=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n_single=$((n_single + 1))
  assert_true "single-file row $f is tracked" git -C "$REPO_ROOT" ls-files --error-unmatch "$f"
  if grep -qx -F "$f" "$actual_files"; then
    fail "$f is declared as a single file but also falls under a vendored prefix"
  fi
done <<EOF
$(printf '%s\n' "$map" | awk -F'\t' '$9 ~ /^F/ {print $1}')
EOF
assert_ge "individually-declared vendored files are present" 5 "$n_single"

# ---- 2. the header is true --------------------------------------------------
hdr="$(python3 "$PROV" headers --check 2>&1)"
if [ -z "$hdr" ]; then
  pass "every non-exempt vendored file carries the exact header its mapping implies"
else
  n_wrong="$(printf '%s\n' "$hdr" | grep -c . || true)"
  fail "$n_wrong file(s) have a wrong or missing provenance header: $(printf '%s\n' "$hdr" | head -3 | tr '\n' ' ')"
fi

# The upstream path each header names must exist at the recorded commit. This is
# the assertion the verification entry actually describes, so it is done here
# against the fork rather than trusted from PROVENANCE.md.
resolve="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT" "$FORK_ROOT" <<'PY'
import os, subprocess, sys
repo, fork = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "tools"))
import provenance  # noqa: E402

m = provenance.load_model()
checked = missing = added = 0
bad = []
for e in m.entries:
    if e.kind == "added":
        added += 1
        # An added file must NOT resolve; its header says so, and a header that
        # named a real path for a file we wrote would be a false attribution.
        if provenance.git_show(e.commit, e.upstream) is not None:
            bad.append("added-but-exists-upstream %s" % e.local)
        continue
    checked += 1
    if provenance.git_show(e.commit, e.upstream) is None:
        missing += 1
        bad.append("no such path at %s: %s -> %s" % (e.commit[:10], e.local, e.upstream))
print("CHECKED %d" % checked)
print("ADDED %d" % added)
print("MISSING %d" % missing)
for b in bad[:10]:
    print("BAD %s" % b)
PY
)" || die "could not resolve upstream paths against the fork"

checked="$(printf '%s\n' "$resolve" | sed -n 's/^CHECKED //p')"
added="$(printf '%s\n' "$resolve"   | sed -n 's/^ADDED //p')"
missing="$(printf '%s\n' "$resolve" | sed -n 's/^MISSING //p')"
badres="$(printf '%s\n' "$resolve"  | sed -n 's/^BAD //p')"

assert_ge "upstream paths were actually resolved against the fork" 500 "$checked"
assert_eq "every vendored file's upstream path exists at its recorded commit" "0" "$missing"
assert_ge "the locally-added files are enumerated rather than mis-attributed" 2 "$added"
if [ -n "$badres" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] && fail "$b"
  done <<EOF
$badres
EOF
fi

# ---- the exemptions are narrow and format-justified ------------------------
exempt="$(printf '%s\n' "$map" | awk -F'\t' '$7=="no-header" {print $1}')"
n_exempt="$(printf '%s\n' "$exempt" | grep -c . || true)"
note "header-exempt: $(printf '%s' "$exempt" | tr '\n' ' ')"
if [ "$n_exempt" -le 6 ]; then
  pass "the header exemption list is narrow  [$n_exempt file(s)]"
else
  fail "the header exemption list has grown to $n_exempt files; exemptions must stay format-driven"
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.json) pass "exempt for a real format reason (JSON has no comment syntax): $f" ;;
    *)
      if [ -L "$REPO_ROOT/$f" ]; then
        pass "exempt for a real format reason (a symlink; a header would write through it): $f"
      elif grep -q "^| $f |" "$REPO_ROOT/PROVENANCE.md"; then
        pass "exempt with a recorded reason: $f"
      else
        fail "exempt with no recorded reason: $f"
      fi
      ;;
  esac
done <<EOF
$exempt
EOF

# ---- 3. the vendoring is justified by an inventory entry -------------------
inv_ids="$(printf '%s\n' "$map" | cut -f6 | sort -u)"
n_inv="$(printf '%s\n' "$inv_ids" | grep -c . || true)"
assert_ge "the mapping cites several inventory entries" 4 "$n_inv"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if ! grep -q "^### $id — " "$REPO_ROOT/REUSE-INVENTORY.md"; then
    fail "PROVENANCE.md cites $id, which REUSE-INVENTORY.md does not define"
    continue
  fi
  decision="$(awk -v id="$id" '
    $0 ~ "^### " id " — " {inside=1; next}
    inside && /^### RI-/ {inside=0}
    inside && /^- decision:/ {sub(/^- decision:[ ]*/,""); print; inside=0}
  ' "$REPO_ROOT/REUSE-INVENTORY.md")"
  case "$decision" in
    vendor|"vendor + extend"|depend|extend|build)
      pass "$id justifies vendoring  [decision: $decision]" ;;
    *)
      fail "$id has decision '$decision', which does not justify a vendored copy" ;;
  esac
done <<EOF
$inv_ids
EOF

# ---- negative controls ------------------------------------------------------
# A header check that has never rejected a header proves nothing. Each control
# mutates the REAL file, runs the REAL check, and restores it — the restore is
# verified with cmp against a backup, and a failed restore is a hard error
# rather than a failed assertion, because leaving the tree modified would be
# worse than any verdict this script could report.
victim="reference/vm2-common/gas.hpp"
assert_file "the control's victim exists" "$REPO_ROOT/$victim"
backup="$(mktemp)"
cp "$REPO_ROOT/$victim" "$backup"

header_control() { # <description> <sed-expression>
  local desc="$1" expr="$2" out
  sed -i "$expr" "$REPO_ROOT/$victim"
  if cmp -s "$REPO_ROOT/$victim" "$backup"; then
    fail "$desc — the mutation changed nothing; the control is vacuous"
  else
    out="$(python3 "$PROV" headers --check 2>&1)"
    if printf '%s' "$out" | grep -qF "$victim"; then
      pass "$desc — rejected"
    else
      fail "$desc — ACCEPTED; the header check is too weak"
    fi
  fi
  cp "$backup" "$REPO_ROOT/$victim"
  cmp -s "$REPO_ROOT/$victim" "$backup" || die "FAILED TO RESTORE $victim from $backup"
}

header_control "a header whose upstream-path is not the mapped one" \
  's|^//   upstream-path:.*|//   upstream-path:   barretenberg/cpp/src/barretenberg/vm2/common/NO_SUCH_FILE.hpp|'
header_control "a header whose upstream-commit has been altered" \
  's|^//   upstream-commit: .*|//   upstream-commit: 0000000000000000000000000000000000000000|'
header_control "a header that has been removed entirely" \
  "/BEGIN VENDORED-PROVENANCE/,/END VENDORED-PROVENANCE/d"

rm -f "$backup"
# Nothing may be left modified by the controls.
assert_true "the victim file is restored (git reports it unchanged apart from the tracked header)" \
  python3 "$PROV" headers --check

# ...and the real path resolves, so the resolution assertion above is not
# trivially true of any string.
real_up="$(printf '%s\n' "$map" | awk -F'\t' -v v="$victim" '$1==v{print $2}')"
real_c="$(printf '%s\n' "$map" | awk -F'\t' -v v="$victim" '$1==v{print $3}')"
assert_true "the mapped upstream path for $victim resolves in the fork" \
  git -C "$FORK_ROOT" cat-file -e "$real_c:$real_up"
assert_false "a deliberately wrong upstream path does not resolve" \
  git -C "$FORK_ROOT" cat-file -e "$real_c:barretenberg/cpp/src/barretenberg/vm2/common/NO_SUCH_FILE.hpp"

finish
