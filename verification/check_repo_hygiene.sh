#!/usr/bin/env bash
# just check-repo-hygiene
#
# M0 verification: each of the campaign's two repos has a flake, a lock, an
# .envrc, and no uncommitted generated files.
#
# The "no uncommitted generated files" half is checked from BOTH directions,
# because either direction alone passes vacuously:
#
#   1. Nothing git reports as changed or untracked may look like a build
#      artefact (the deny list below). This catches an artefact that escaped
#      .gitignore.
#   2. Every generated location that ACTUALLY EXISTS on disk must be ignored by
#      git. This is the direction that cannot be satisfied by simply not having
#      built anything: if the repo has never been built, the check says so and
#      fails, because a hygiene check over an empty tree proves nothing. At
#      least one real build artefact must be present and ignored.
#
# The lock asserted here is `flake.lock` — the file that actually pins these
# repos' dependencies. See the M0 notes in the milestone file for why neither
# repo carries a reprobuild `repro.lock`.
#
# Run: just check-repo-hygiene

TEST_NAME="just check-repo-hygiene"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required to read flake.lock"

# Paths that must never show up as changed or untracked in `git status`.
# Extended regex, matched against the workspace-relative path git reports.
GENERATED_RE='(^|/)(node_modules|\.direnv|__pycache__|dest|dist|target|build|build-wasm[^/]*|build-native[^/]*|\.cache|\.tsbuildinfo)(/|$)|\.(o|obj|a|wasm\.gz|tsbuildinfo)$|(^|/)result(-[^/]*)?$'

# Generated locations that are EXPECTED to exist after a normal working session
# and must therefore be ignored. Per repo, at least one of these must exist —
# otherwise the tree has never been built and direction (2) above is vacuous.
GENERATED_CANDIDATES_aztec_avm_runtime="diffsim/node_modules
spike/node_modules
drift/node_modules
probe-mt/node_modules
vm2wasm/src
vm2wasm/wasi-sdk-33
.direnv"
GENERATED_CANDIDATES_aztec_packages="barretenberg/cpp/build-wasm
barretenberg/cpp/build
node_modules
.direnv"

check_repo() { # <label> <root> <candidate-list>
  local label="$1" root="$2" candidates="$3"
  note "--- $label"

  [ -d "$root" ] || { fail "$label: no checkout at $root"; return; }
  assert_true "$label: is a git checkout" git -C "$root" rev-parse --git-dir

  # ---- a flake -------------------------------------------------------------
  assert_file "$label: has flake.nix" "$root/flake.nix"
  assert_file "$label: has nix/wasi-sdk.nix (nixpkgs has no wasi-sdk attribute)" \
    "$root/nix/wasi-sdk.nix"
  assert_true "$label: flake.nix is tracked" \
    git -C "$root" ls-files --error-unmatch flake.nix
  assert_true "$label: nix/wasi-sdk.nix is tracked" \
    git -C "$root" ls-files --error-unmatch nix/wasi-sdk.nix

  # ---- a lock --------------------------------------------------------------
  assert_file "$label: has flake.lock" "$root/flake.lock"
  assert_true "$label: flake.lock is tracked" \
    git -C "$root" ls-files --error-unmatch flake.lock
  if [ -f "$root/flake.lock" ]; then
    # Present-and-parseable is not enough: assert the lock actually PINS
    # nixpkgs to a concrete revision with an integrity hash. An unpinned lock
    # is not a lock.
    local pinned
    pinned="$(python3 - "$root/flake.lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
nodes = lock.get("nodes", {})
for name, node in nodes.items():
    if "nixpkgs" not in name:
        continue
    locked = node.get("locked", {})
    if locked.get("rev") and locked.get("narHash"):
        print("%s %s %s" % (name, locked["rev"], locked["narHash"]))
        break
PY
)"
    if [ -n "$pinned" ]; then
      pass "$label: flake.lock pins nixpkgs to a revision + narHash  [$pinned]"
    else
      fail "$label: flake.lock does not pin nixpkgs to a rev + narHash"
    fi
  fi

  # ---- an .envrc -----------------------------------------------------------
  # .envrc is asserted to be VERSIONED — either already in the index, or
  # present and not ignored, so the next commit picks it up. The failure this
  # guards against is a real one: an .envrc that exists on one developer's
  # machine and is quietly covered by .gitignore is not a shared dev shell.
  assert_file "$label: has .envrc" "$root/.envrc"
  if git -C "$root" ls-files --error-unmatch .envrc >/dev/null 2>&1; then
    pass "$label: .envrc is tracked"
  elif [ -f "$root/.envrc" ] && ! git -C "$root" check-ignore -q .envrc; then
    pass "$label: .envrc is present and not ignored (pending its first commit)"
  else
    fail "$label: .envrc is neither tracked nor committable (is it gitignored?)"
  fi
  if [ -f "$root/.envrc" ]; then
    assert_contains "$label: .envrc activates the repo's own flake" \
      "use flake" "$(cat "$root/.envrc")"
  fi

  # ---- no uncommitted generated files, direction 1 -------------------------
  local status offenders
  status="$(git -C "$root" status --porcelain --untracked-files=all)"
  offenders="$(printf '%s\n' "$status" | sed 's/^...//' | grep -E "$GENERATED_RE" || true)"
  if [ -z "$offenders" ]; then
    pass "$label: git reports no generated artefacts as changed or untracked"
  else
    fail "$label: generated artefacts are not ignored: $(printf '%s' "$offenders" | tr '\n' ' ')"
  fi

  # ---- no uncommitted generated files, direction 2 -------------------------
  local present=0 ignored=0 leaked=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -e "$root/$cand" ] || continue
    present=$((present + 1))
    if git -C "$root" check-ignore -q "$cand"; then
      ignored=$((ignored + 1))
    else
      leaked="$leaked $cand"
    fi
  done <<EOF
$candidates
EOF
  assert_ge "$label: at least one real build artefact is on disk to check" 1 "$present"
  assert_eq "$label: every generated artefact on disk is git-ignored" \
    "$present" "$ignored"
  if [ -n "$leaked" ]; then
    note "$label: not ignored:$leaked"
  fi
}

check_repo "aztec-avm-runtime" "$REPO_ROOT" "$GENERATED_CANDIDATES_aztec_avm_runtime"
check_repo "aztec-packages"    "$FORK_ROOT" "$GENERATED_CANDIDATES_aztec_packages"

finish
