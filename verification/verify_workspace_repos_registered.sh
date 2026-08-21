#!/usr/bin/env bash
# verify_workspace_repos_registered
#
# M0 verification: both repos appear in the workspace repo listing with the
# correct remote and revision, and a fresh workspace init checks them out.
#
# The second half is not asserted by inspection. The check first asserts that
# the resolver's OWN answer — the fetch URL and revision `repro workspace list
# --json` would hand to a fresh `repro workspace init` — equals the EXPECTED
# table below, and then performs a real clone from those coordinates into a
# scratch directory and materialises a known file out of it. A manifest entry
# that is syntactically perfect but names a branch nobody can fetch fails here,
# which is the whole point.
#
# The clone is `--depth 1 --filter=blob:none --no-checkout` plus a
# sparse-checkout of one path, so proving a 3 GB monorepo is checkoutable costs
# about a second and three megabytes rather than a full clone.
#
# This check requires NETWORK ACCESS. If the remotes are unreachable it FAILS;
# it does not skip.
#
# Run: just verify-workspace-registration

TEST_NAME="verify_workspace_repos_registered"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required to read repro's JSON"
command -v git >/dev/null 2>&1 || die "git is required"

# `repro` may be on PATH already (the workspace dev shell), or reachable
# through direnv at the workspace root. Anything else is a hard failure.
REPRO=""
if command -v repro >/dev/null 2>&1; then
  REPRO="repro"
elif command -v direnv >/dev/null 2>&1; then
  REPRO="direnv exec $WORKSPACE_ROOT repro"
else
  die "the 'repro' CLI is not available (not on PATH, and direnv is missing)"
fi

# The expectations. These are the assertion, not the input: they are written
# out here so a drifting manifest is caught rather than mirrored.
#   name | checkout path | remote alias | fetch url | revision | sentinel file
EXPECTED="aztec-avm-runtime|aztec-avm-runtime|metacraft-labs|https://github.com/metacraft-labs/aztec-avm-runtime|dev|flake.nix
aztec-packages|aztec-packages|metacraft-labs|https://github.com/metacraft-labs/aztec-packages|aztec-avm-runtime|barretenberg/cpp/CMakePresets.json"
EXPECTED_PROJECT="codetracer"

LIST_JSON="$($REPRO ws list --json --workspace-root="$WORKSPACE_ROOT" 2>/dev/null)" || die "'repro ws list --json' failed"
LIST_JSON="${LIST_JSON#*\{}"; LIST_JSON="{$LIST_JSON"
REPOS_JSON="$($REPRO ws repos list --json --workspace-root="$WORKSPACE_ROOT" 2>/dev/null)" || die "'repro ws repos list --json' failed"
REPOS_JSON="${REPOS_JSON#*\{}"; REPOS_JSON="{$REPOS_JSON"

jq_field() { # <json> <repo-name> <field>
  printf '%s' "$1" | python3 -c '
import json, sys
doc = json.loads(sys.stdin.read())
name, field = sys.argv[1], sys.argv[2]
key = "name" if doc["repos"] and "name" in doc["repos"][0] else "repo"
for r in doc["repos"]:
    if r.get(key) == name:
        print(r.get(field, ""))
        break
' "$2" "$3"
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

CLONE_PROOFS=0

while IFS='|' read -r name path remote url revision sentinel; do
  [ -n "$name" ] || continue
  note "--- $name"

  # ---- the resolved workspace listing ------------------------------------
  assert_eq  "$name: checkout path"        "$path"     "$(jq_field "$LIST_JSON" "$name" path)"
  assert_eq  "$name: remote alias"         "$remote"   "$(jq_field "$LIST_JSON" "$name" remote)"
  assert_eq  "$name: resolved fetch URL"   "$url"      "$(jq_field "$LIST_JSON" "$name" fetchUrl)"
  assert_eq  "$name: resolved revision"    "$revision" "$(jq_field "$LIST_JSON" "$name" revision)"
  assert_eq  "$name: vcs"                  "git"       "$(jq_field "$LIST_JSON" "$name" vcs)"
  # The definition-axis listing must agree, and must show the repo enabled for
  # this workspace (i.e. an enabled project declares it).
  assert_eq  "$name: enabled in this workspace" "True" \
    "$(jq_field "$REPOS_JSON" "$name" enabled)"

  # ---- the manifest fragment is COMMITTED, not just written --------------
  FRAG="repos/$name.toml"
  assert_true "$name: $FRAG is tracked in the manifests repo" \
    git -C "$WORKSPACE_ROOT" ls-files --error-unmatch "$FRAG"
  assert_true "$name: $FRAG has no uncommitted changes" \
    git -C "$WORKSPACE_ROOT" diff --quiet HEAD -- "$FRAG"
  COMMITTED_FRAG="$(git -C "$WORKSPACE_ROOT" show "HEAD:$FRAG" 2>/dev/null)"
  assert_contains "$name: the committed fragment declares path = \"$path\"" \
    "path = \"$path\"" "$COMMITTED_FRAG"
  assert_contains "$name: the committed fragment declares remote = \"$remote\"" \
    "remote = \"$remote\"" "$COMMITTED_FRAG"
  # aztec-packages is PINNED to its fork branch; aztec-avm-runtime deliberately
  # omits the key so it INHERITS the codetracer project's default_revision.
  if [ "$name" = "aztec-packages" ]; then
    assert_contains "$name: the fragment pins revision = \"$revision\"" \
      "revision = \"$revision\"" "$COMMITTED_FRAG"
  else
    assert_not_contains "$name: the fragment omits revision (inherits the project default)" \
      "revision = " "$COMMITTED_FRAG"
  fi

  # ---- the include edge into the codetracer project ----------------------
  PROJECT_FILE="projects/$EXPECTED_PROJECT.toml"
  COMMITTED_PROJECT="$(git -C "$WORKSPACE_ROOT" show "HEAD:$PROJECT_FILE" 2>/dev/null)"
  assert_contains "$name: included by the $EXPECTED_PROJECT project (committed)" \
    "\"$FRAG\"" "$COMMITTED_PROJECT"
  assert_true "$name: $PROJECT_FILE has no uncommitted changes" \
    git -C "$WORKSPACE_ROOT" diff --quiet HEAD -- "$PROJECT_FILE"

  # ---- the local checkout matches the declaration ------------------------
  LOCAL="$WORKSPACE_ROOT/$path"
  assert_dir "$name: checked out at the declared path" "$LOCAL"
  if [ -d "$LOCAL/.git" ]; then
    LOCAL_ORIGIN="$(git -C "$LOCAL" remote get-url origin 2>/dev/null)"
    LOCAL_ORIGIN="${LOCAL_ORIGIN%.git}"
    assert_eq "$name: the local checkout's origin is the declared remote" \
      "$url" "$LOCAL_ORIGIN"
  else
    fail "$name: $LOCAL is not a git checkout"
  fi

  # ---- a fresh init really can check it out ------------------------------
  DEST="$SCRATCH/$name"
  if git clone --quiet --depth 1 --filter=blob:none --no-checkout \
       --branch "$revision" "$url" "$DEST" 2>"$SCRATCH/$name.clone.err"; then
    pass "$name: a fresh clone of $revision from the resolved URL succeeds"
    HEAD_SHA="$(git -C "$DEST" rev-parse HEAD 2>/dev/null)"
    assert_true "$name: the cloned HEAD is a commit object" \
      git -C "$DEST" cat-file -e "$HEAD_SHA^{commit}"
    if git -C "$DEST" sparse-checkout set --no-cone "/$sentinel" >/dev/null 2>&1 &&
       git -C "$DEST" checkout --quiet >/dev/null 2>&1; then
      assert_file "$name: a working tree materialises from the clone" "$DEST/$sentinel"
      CLONE_PROOFS=$((CLONE_PROOFS + 1))
    else
      fail "$name: could not materialise $sentinel from the fresh clone"
    fi
    # The fresh clone and the workspace checkout must be on the same history,
    # or "registered" and "what is on disk" are two different repos.
    if [ -d "$LOCAL/.git" ]; then
      assert_true "$name: the workspace checkout shares history with the fresh clone" \
        git -C "$LOCAL" cat-file -e "$HEAD_SHA^{commit}"
    fi
  else
    fail "$name: fresh clone of $revision from $url failed: $(tail -3 "$SCRATCH/$name.clone.err")"
  fi
done <<EOF
$EXPECTED
EOF

assert_eq "both repos were proved checkoutable from their resolved coordinates" \
  "2" "$CLONE_PROOFS"

finish
