#!/usr/bin/env bash
# Shared implementation behind the five per-PR submission scripts.
#
# Nothing in this repository files anything upstream. These scripts exist so
# that a human can file each prepared contribution with ONE command, from
# material that is generated rather than retyped: the title and body come out of
# the contribution's own `PR.md`, and the head branch comes out of
# `carry/series.json`. There is no second copy of either to go stale.
#
# What a run does, in order, and every step can fail the script:
#
#   1. Preconditions. `gh` present and authenticated; `PR.md` and the patch
#      present; the head branch published on our fork and pointing at the commit
#      the generator produces from the patch file. A branch that has drifted from
#      its patch is refused rather than filed.
#   2. The tracker search the contribution's `PR.md` requires, RUN, against
#      upstream's own issues and pull requests. Results are printed and written to
#      a transcript. If the search cannot run, the script FAILS and prints the
#      exact queries to run by hand — it does not proceed with an empty claim to
#      have searched.
#   3. Idempotency. If a pull request already exists for this head branch, the
#      script prints its URL, records it, and exits 0 without opening a second.
#   4. `gh pr create`, then the URL recorded back into `carry/series.json` and
#      into the contribution's `PR.md` `Status:` line.
#
# `--dry-run` performs 1 and 2, writes the exact title and body it would send,
# prints the exact `gh pr create` invocation, and creates nothing. That is how to
# inspect a submission before making it.

set -uo pipefail

SUBMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBMIT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
FORK_ROOT="$WORKSPACE_ROOT/aztec-packages"
SPECS_ROOT="$WORKSPACE_ROOT/codetracer-specs"
SERIES_JSON="$REPO_ROOT/carry/series.json"

UPSTREAM_REPO="AztecProtocol/aztec-packages"
FORK_OWNER="metacraft-labs"

die() { printf '%s: %s\n' "${PATCH_ID:-submit}" "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
hr()  { printf -- '---------------------------------------------------------------\n'; }

series_field() { # <patch-id> <jq-ish path via python>
  python3 - "$SERIES_JSON" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
pid, path = sys.argv[2], sys.argv[3]
entry = next((p for p in doc["patches"] if p["id"] == pid), None)
if entry is None:
    sys.exit("no such patch id: %s" % pid)
cur = entry
for key in path.split("."):
    cur = cur[key]
if isinstance(cur, list):
    print("\n".join(str(x) for x in cur))
elif cur is None:
    print("")
else:
    print(cur)
PY
}

# ---------------------------------------------------------------------------
# Title and body, derived from PR.md
# ---------------------------------------------------------------------------

pr_title() { # <pr-md>
  local t
  t="$(awk '/^Suggested PR title:/{want=1; next} want && /^> `/{sub(/^> `/,""); sub(/`[[:space:]]*$/,""); print; exit}' "$1")"
  [ -n "$t" ] || die "could not read the suggested PR title out of $1"
  printf '%s\n' "$t"
}

# The body is everything from PR.md's first `##` heading onward. The lines above
# it are our own bookkeeping — which patch file, which base commit, whether it has
# been filed — and are not for an upstream reader.
pr_body() { # <pr-md> <out-file> [<stack-note-file>]
  local md="$1" out="$2" stack="${3:-}"
  : > "$out"
  if [ -n "$stack" ] && [ -f "$stack" ]; then
    cat "$stack" >> "$out"
    printf '\n' >> "$out"
  fi
  awk '/^## /{f=1} f' "$md" >> "$out"
  local n
  n=$(grep -c '' "$out")
  [ "$n" -ge 40 ] || die "body derived from $md is only $n lines; that is not the whole document"
  {
    printf '\n---\n\n'
    printf 'Generated against `%s`.\n\n' "$BASE_SHORT"
    printf 'The `verify.sh` referred to above is not part of the patch and is not in this\n'
    printf 'repository; it needs two checkouts and a toolchain, so it is kept with the\n'
    printf 'write-up rather than added here. Happy to paste it, or its transcript, into a\n'
    printf 'comment on request.\n'
  } >> "$out"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh is not on PATH; install the GitHub CLI"
  command -v git >/dev/null 2>&1 || die "git is not on PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
}

require_branch_matches_patch() { # <branch> <patch-file>
  local branch="$1"
  [ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"

  local remote_sha
  remote_sha="$(git -C "$FORK_ROOT" ls-remote --heads origin "$branch" | awk '{print $1}')"
  [ -n "$remote_sha" ] || die "branch '$branch' is not published on our fork; run:
    just make-fork-branches-push"

  # The branch must be exactly what the generator produces from the patch file,
  # so that what gets filed is the reviewed patch and not a hand-edited branch.
  # `--print-sha` rebuilds it without moving any ref, so this check cannot repair
  # the thing it is checking.
  local rebuilt
  rebuilt="$(python3 "$REPO_ROOT/tools/make_fork_branches.py" \
               --fork "$FORK_ROOT" --specs "$SPECS_ROOT" --print-sha "$PATCH_ID")" \
    || die "could not rebuild '$branch' from its patch file to compare against what is published"
  [ -n "$rebuilt" ] || \
    die "rebuilding '$branch' from its patch file produced no commit id"
  if [ "$rebuilt" != "$remote_sha" ]; then
    die "published '$branch' is $remote_sha but rebuilding it from the patch gives $rebuilt;
    the branch and the patch have drifted. Fix before filing."
  fi
  HEAD_SHA="$remote_sha"
  say "ok   $branch is published at $remote_sha and rebuilds byte for byte from the patch"
}

# ---------------------------------------------------------------------------
# The tracker search. It runs, or the script stops.
# ---------------------------------------------------------------------------

# GitHub's search API allows 30 requests per minute. Six queries per patch, two
# requests each, is twelve — so one script is fine and five in a row are not, and
# the failure is an HTTP 403 that looks exactly like a broken search. Pace against
# the real quota and retry the rate-limited case rather than reporting "the
# tracker search failed" for something that is not a failure at all.
gh_search_paced() { # <issues|prs> <query> <out-file> <err-file>
  local kind="$1" query="$2" out="$3" err="$4" attempt
  for attempt in 1 2 3; do
    local remaining reset now
    remaining="$(gh api rate_limit --jq .resources.search.remaining 2>/dev/null)"
    reset="$(gh api rate_limit --jq .resources.search.reset 2>/dev/null)"
    now="$(date +%s)"
    if [ -n "$remaining" ] && [ "$remaining" -lt 2 ] 2>/dev/null; then
      local wait=$(( ${reset:-0} - now + 2 ))
      [ "$wait" -gt 0 ] || wait=5
      [ "$wait" -gt 90 ] && wait=90
      say "  (search quota exhausted; waiting ${wait}s for the window to reset)"
      sleep "$wait"
    fi
    if gh search "$kind" --repo "$UPSTREAM_REPO" --limit 20 \
         --json number,title,state,url -- "$query" > "$out" 2>"$err"; then
      return 0
    fi
    if grep -q "rate limit" "$err" 2>/dev/null; then
      say "  (rate limited on attempt $attempt; retrying)"
      sleep 20
      continue
    fi
    return 1
  done
  return 1
}

run_tracker_search() { # <out-file>
  local out="$1" q rc=0 any=0 n=0
  local dir; dir="$(dirname "$out")"
  rm -f "$dir"/search-*.json
  say "Searching $UPSTREAM_REPO for prior art. Every query below is run; a query"
  say "that cannot run stops the submission."
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    any=1
    n=$((n + 1))
    hr
    say "query: $q"
    local iss="$dir/search-$n-issues.json" prs="$dir/search-$n-prs.json"
    if ! gh_search_paced issues "$q" "$iss" "$iss.err"; then
      rc=1
      say "  issues         SEARCH FAILED: $(head -c 200 "$iss.err")"
    fi
    if ! gh_search_paced prs "$q" "$prs" "$prs.err"; then
      rc=1
      say "  pull requests  SEARCH FAILED: $(head -c 200 "$prs.err")"
    fi
    [ "$rc" -eq 0 ] && python3 - "$q" "$iss" "$prs" <<'PY'
import json, sys
query, files = sys.argv[1], (("issues", sys.argv[2]), ("pull requests", sys.argv[3]))
for label, path in files:
    try:
        rows = json.load(open(path))
    except Exception as exc:
        print("  %-14s UNPARSEABLE (%s)" % (label, exc))
        continue
    if not rows:
        print("  %-14s no hits" % label)
    for r in rows:
        print("  %-14s #%-6s %-8s %s" % (label, r["number"], r["state"], r["title"][:88]))
PY
  done < <(series_field "$PATCH_ID" tracker_queries)

  # One transcript, assembled from the raw results rather than from what was
  # printed, so the recorded evidence is the search output and not a rendering
  # of it.
  python3 - "$out" "$dir" "$UPSTREAM_REPO" "$PATCH_ID" <<'PY'
import glob, json, os, sys, datetime
out, dirname, repo, pid = sys.argv[1:5]
doc = {"patch": pid, "repo": repo,
       "searched_at": datetime.date.today().isoformat(), "queries": []}
n = 1
while True:
    iss = os.path.join(dirname, "search-%d-issues.json" % n)
    prs = os.path.join(dirname, "search-%d-prs.json" % n)
    if not os.path.exists(iss) and not os.path.exists(prs):
        break
    row = {"n": n}
    for key, path in (("issues", iss), ("prs", prs)):
        try:
            row[key] = json.load(open(path))
        except Exception as exc:
            row[key] = {"error": str(exc)}
    doc["queries"].append(row)
    n += 1
json.dump(doc, open(out, "w"), indent=2)
PY
  python3 - "$out" "$SERIES_JSON" "$PATCH_ID" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
series = json.load(open(sys.argv[2]))
entry = next(p for p in series["patches"] if p["id"] == sys.argv[3])
for row, q in zip(doc["queries"], entry["tracker_queries"]):
    row["query"] = q
json.dump(doc, open(sys.argv[1], "w"), indent=2)
PY
  [ "$any" -eq 1 ] || die "no tracker queries recorded for $PATCH_ID in $SERIES_JSON"
  hr
  if [ "$rc" -ne 0 ]; then
    say "The tracker search did NOT complete. Nothing has been filed."
    say ""
    say "Run these by hand and read the results before filing:"
    while IFS= read -r q; do
      [ -n "$q" ] || continue
      say "  https://github.com/$UPSTREAM_REPO/issues?q=$(python3 -c \
        'import sys,urllib.parse;print(urllib.parse.quote_plus(sys.argv[1]))' "$q")"
    done < <(series_field "$PATCH_ID" tracker_queries)
    die "tracker search failed; see above"
  fi
  say "ok   tracker search completed; transcript: $out"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

submit_main() { # <patch-id> [args...]
  PATCH_ID="$1"; shift
  local dry_run=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry_run=1 ;;
      -h|--help)
        say "usage: $(basename "$0") [--dry-run]"
        say ""
        say "Files the prepared contribution '$PATCH_ID' as a pull request against"
        say "$UPSTREAM_REPO. With --dry-run, prints exactly what it would send and"
        say "creates nothing."
        return 0 ;;
      *) die "unknown argument: $a" ;;
    esac
  done

  require_tools
  [ -f "$SERIES_JSON" ] || die "missing $SERIES_JSON"

  BASE_SHORT="$(python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1]))["base"]["short"])' "$SERIES_JSON")"
  local upstream_branch
  upstream_branch="$(python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1]))["fork"]["upstream_branch"])' "$SERIES_JSON")"

  local entry branch title_expected
  entry="$(series_field "$PATCH_ID" entry)"
  branch="$(series_field "$PATCH_ID" branch)"
  title_expected="$(series_field "$PATCH_ID" title)"

  local dir="$SPECS_ROOT/upstream-bugs/$entry"
  local md="$dir/PR.md"
  [ -f "$md" ] || die "missing $md"
  local patch_file="$dir/$(series_field "$PATCH_ID" patch)"
  [ -f "$patch_file" ] || die "missing $patch_file"

  local title
  title="$(pr_title "$md")"
  # The lesson this project keeps re-learning: two documents drifting apart.
  # The title in PR.md, the title in series.json and the head commit's subject
  # are three copies of one string and all three are compared.
  [ "$title" = "$title_expected" ] || die \
    "PR.md title and series.json title disagree:
      PR.md:        $title
      series.json:  $title_expected"

  require_branch_matches_patch "$branch" "$patch_file"

  local head_subject
  head_subject="$(git -C "$FORK_ROOT" log -1 --format=%s "$HEAD_SHA" 2>/dev/null)"
  [ "$head_subject" = "$title" ] || die \
    "the head commit's subject and the PR title disagree:
      commit:  $head_subject
      PR.md:   $title"
  say "ok   PR.md title, series.json title and the head commit's subject all agree"

  local work="${SUBMIT_WORK:-$REPO_ROOT/.submit}/$PATCH_ID"
  mkdir -p "$work"
  local body="$work/body.md" search="$work/tracker-search.json"

  local stack_note=""
  if [ -n "${STACK_NOTE:-}" ]; then
    stack_note="$work/stack.md"
    printf '%s\n' "$STACK_NOTE" > "$stack_note"
  fi
  pr_body "$md" "$body" "$stack_note"
  say "ok   body derived from PR.md: $body ($(grep -c '' "$body") lines)"

  run_tracker_search "$search"

  local existing
  existing="$(gh pr list --repo "$UPSTREAM_REPO" --state all \
              --head "$branch" --json url,number,state --limit 5 2>/dev/null)"
  local existing_url
  existing_url="$(python3 -c '
import json,sys
try: rows=json.loads(sys.argv[1] or "[]")
except Exception: rows=[]
print(rows[0]["url"] if rows else "")' "$existing")"
  if [ -n "$existing_url" ]; then
    say ""
    say "A pull request already exists for head '$branch': $existing_url"
    say "Nothing filed. Recording the URL and exiting."
    "$REPO_ROOT/tools/record_submission.py" --id "$PATCH_ID" --url "$existing_url" \
      --status submitted || die "failed to record the existing URL"
    return 0
  fi

  hr
  say "repo:  $UPSTREAM_REPO"
  say "base:  $upstream_branch"
  say "head:  $FORK_OWNER:$branch"
  say "title: $title"
  say "body:  $body"
  hr

  if [ "$dry_run" -eq 1 ]; then
    say "DRY RUN — nothing was filed. The command this would run:"
    say ""
    say "  gh pr create --repo $UPSTREAM_REPO \\"
    say "    --base $upstream_branch \\"
    say "    --head $FORK_OWNER:$branch \\"
    say "    --title \"$title\" \\"
    say "    --body-file $body"
    say ""
    say "Read $body and $search first; then re-run without --dry-run."
    return 0
  fi

  local url
  url="$(gh pr create --repo "$UPSTREAM_REPO" \
          --base "$upstream_branch" \
          --head "$FORK_OWNER:$branch" \
          --title "$title" \
          --body-file "$body")" || die "gh pr create failed; nothing recorded"
  [ -n "$url" ] || die "gh pr create returned no URL"
  say ""
  say "filed: $url"

  "$REPO_ROOT/tools/record_submission.py" --id "$PATCH_ID" --url "$url" --status submitted \
    || die "the PR was filed at $url but recording it failed; record it by hand"
  say "recorded in carry/series.json and in $md"
  say ""
  say "Commit the two updated files:"
  say "  git -C $REPO_ROOT add carry/series.json CARRY-LEDGER.md"
  say "  git -C $SPECS_ROOT add upstream-bugs/$entry/PR.md upstream-bugs/SERIES.md"
  return 0
}
