#!/usr/bin/env bash
# lib_m28_gate.sh — shared machinery for the M28 (browser CI gate) checks.
#
# Not to be executed directly: sourced after lib.sh, lib_m23_chain.sh and lib_m27_browser.sh.
#
# ==============================================================================================
# WHAT M28 IS, AND WHY ITS MACHINERY IS DELIBERATELY THIN.
# ==============================================================================================
#
# M27 proved the product works in a browser ONCE. M28 makes it STAY true. Every entry is a gate
# rather than a feature, so the value is entirely in what it PREVENTS — which makes a weak
# assertion here more dangerous than anywhere else in this campaign, because a gate that cannot
# fail is worse than no gate: it retires the question.
#
# So this library owns almost nothing. The bundle, the browser arms, the module and the chromium
# pin are all M27's (`m27_require_bundle`, `m27_require_arms`, `m27_arm`, `m27_meta`) and are
# REUSED rather than re-implemented, for the reason `CAMPAIGN-BRIEF.md` gives about a second gate
# in `browser/`: two implementations of one question eventually disagree, and the disagreement
# surfaces as "it works in Node". What is here is the three things M27 does not have: the scan of
# a BUILT bundle as an artefact, the `npm pack` of a package as a TARBALL, and the composition of
# the gate itself.

M28_WORK="${M28_WORK:-$HOME/.cache/aztec-m28-gate}"
export M28_WORK

M28_DOC="$REPO_ROOT/BROWSER-GATE.md"
M28_SCANNER="$VERIFY_DIR/_m28_bundle_scan.py"
M28_BUILD_CONFIG="$BROWSER_DIST/.build-config.json"
export M28_DOC M28_SCANNER M28_BUILD_CONFIG

# The Justfile recipe that IS the gate. Named once, here, so the checks that assert the CI job and
# the recipe agree are comparing against one spelling rather than three.
M28_GATE_RECIPE="ci-browser-gate"
M28_WORKFLOW="$REPO_ROOT/.github/workflows/avm-wasm.yml"
M28_GATE_JOB="browser-gate"
export M28_GATE_RECIPE M28_WORKFLOW M28_GATE_JOB

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, for M21's review's reason: a check that dies before `finish` prints no summary
# and reads as a SMALLER milestone rather than a red one, which once took M1 from 151 to 141 with
# nothing reported as failing. M22 said a third milestone wanting it is when it moves into
# `lib.sh`; M23, M24 and M27 each declined for M22's own reason — changing the abnormal-exit
# behaviour of a hundred and fifty checks does not belong in a commit about a chain loop, a writer
# or a bundle — and M28 declines for the same reason and records the cost: THIS IS THE FIFTH COPY.
# M9's four checks still do not have it, which is the retrospective case
# `CAMPAIGN-BRIEF.md` names, and the move remains this campaign's outstanding item rather than
# something a gate milestone should do on its way out.
# ---------------------------------------------------------------------------
# DELEGATED TO `lib.sh` ON 2026-08-31. These eight lines were copied into FOURTEEN
# milestone libraries, m22..m37. M22 wrote them and said the third milestone wanting
# them is when they move into `lib.sh`; M24 declined for M22's own reason and recorded
# it as owed. The fifteenth caller turned out to be M9 — not a new milestone but the
# campaign's oldest open item — so the move is made and these are wrappers. The public
# names are unchanged, so no check needed editing, and the behaviour is identical: one
# implementation instead of fourteen, verified by the sweep.
m28_finish() { finish; }
m28_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# A bounded subprocess whose overrun is a NAMED failure rather than a hang. `CAMPAIGN-BRIEF.md`
# names three states a check can be in — green, red and HUNG — and says the third is the worst,
# because it reports nothing at all and blocks the sweep behind it. `npm pack` reaches the network
# in some configurations and a browser is the most hang-prone thing in this repository.
m28_bounded() { # <seconds> <what> <command...>
  local secs="$1" what="$2"; shift 2
  mkdir -p "$M28_WORK"
  timeout -s KILL "$secs" "$@" >"$M28_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
    die "$what did not finish within ${secs}s and was killed.
             That is the HANG state CAMPAIGN-BRIEF.md names, reported as a failure rather than as
             silence. Output: $M28_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# THE SCAN OF A BUILT BUNDLE.
#
# One instrument, run over the subject AND over its control, which is the correction M27's review
# had to make to the builtin census: its control was a hand-written literal beside the loop rather
# than a second run of the same scanner, so typing the loop's needle list left both green.
#
# `m28_scan <tag> <dist-dir> <metafile[,metafile...]> [<exclude-subdir>]`
# prints the scanner's report and caches it under $M28_WORK/scan-<tag>.tsv.
# ---------------------------------------------------------------------------
#
# IT RETURNS NON-ZERO RATHER THAN CALLING `die`, AND THAT IS NOT A STYLE CHOICE. Every caller uses
# it as `X="$(m28_scan …)"`, and `CAMPAIGN-BRIEF.md` lists "a `die` in `$(…)`" among the ways a
# check dies before its summary: `die`'s `exit` leaves the SUBSHELL, the assignment gets an empty
# string, and the check carries on asserting over nothing. Measured by M28's own arms S and S2 — the
# first draft did `die` here, and a scanner that died mid-report produced *23 red assertions* over
# an empty report instead of one refusal naming the truncation. It reddened, so it was not the
# silent shape; it was the misattributing one, which is what `m9_completeness` exists to prevent one
# milestone over. Callers write `|| die "…"`, which runs in the check's own shell.
m28_scan() {
  local tag="$1" dist="$2" metas="$3" exclude="${4:-}"
  mkdir -p "$M28_WORK"
  local out="$M28_WORK/scan-$tag.tsv"
  local -a args=("$M28_SCANNER" "$REPO_ROOT" "$dist" "$metas" --shims "$M28_BUILD_CONFIG")
  [ -n "$exclude" ] && args+=(--exclude "$exclude")
  if ! python3 "${args[@]}" >"$out" 2>"$M28_WORK/scan-$tag.err"; then
    printf 'the bundle scan FAILED for %s. See %s\n' "$tag" "$M28_WORK/scan-$tag.err" >&2
    return 1
  fi
  # THE SENTINEL. A scanner that died half way through prints a PREFIX of its report, and every
  # assertion below it is an ABSENCE — so a truncated report reads as a clean bundle. That is the
  # campaign's "a check that dies reads as a smaller milestone" one level down, inside an
  # instrument, and it is closed the way `transcript_completeness` closes it: with a terminal
  # sentinel the caller requires.
  if ! str_has_line "$(cat "$out")" "$(printf 'scan.done\t1')"; then
    printf 'the bundle scan for %s did not reach its sentinel — the report is TRUNCATED and every absence read from it would be meaningless. See %s\n' \
      "$tag" "$out" >&2
    return 1
  fi
  cat "$out"
}

# One key out of a scan report. Prints every matching line's remainder, or nothing.
m28_rows() { # <report> <KEY>
  local report="$1" key="$2" line
  local -a lines=()
  local IFS=$'\n'
  set -f
  lines=($report)
  set +f
  for line in "${lines[@]}"; do
    case "$line" in
      ("$key"$'\t'*) printf '%s\n' "${line#"$key"$'\t'}" ;;
    esac
  done
}

# A single-valued key. Prints MISSING rather than empty, so a typo'd key FAILS instead of
# comparing two absences — the sentinel M27's review found defends a comparison with a LITERAL and
# defends nothing when both sides come from this helper, so callers compare against literals.
m28_value() { # <report> <KEY>
  local v
  v="$(m28_rows "$1" "$2" | head -1)"
  [ -n "$v" ] && printf '%s\n' "$v" || printf 'MISSING\n'
}

# ---------------------------------------------------------------------------
# THE PACK. A TARBALL, NOT A MANIFEST READ.
#
# M19's `verify_differential_containment` uses `npm pack --dry-run --json`, which reports the file
# LIST npm would include without producing anything. That is the right instrument for the question
# it asks. M28's deliverable is narrower and says so: "the PACKED package declares no optional
# native dependency and contains no prebuilt binary" — so this produces a real `.tgz`, reads the
# member list out of the archive with `tar`, and extracts the `package.json` THE TARBALL CONTAINS
# rather than the one on disk. Those can differ: npm rewrites the manifest on pack.
# ---------------------------------------------------------------------------
M28_PACK_TIMEOUT="${M28_PACK_TIMEOUT:-180}"
#
# IT RETURNS NON-ZERO RATHER THAN CALLING `die`, FOR THE SAME REASON `m28_scan` DOES — AND THE FACT
# THAT THIS HAD TO BE SAID TWICE, IN ONE FILE, IS THE POINT.
#
# M28 met "a `die` in `$(…)`" in `m28_scan`, fixed it there, wrote the paragraph sixty lines above
# explaining exactly why the shape is dangerous — and left the identical shape here, in the same
# file, with BOTH call sites spelled `t="$(m28_pack …)"`. `CAMPAIGN-BRIEF.md` says it in as many
# words: "when you fix an instance of a form, grep for the form in the file you are fixing before
# you leave it."
#
# Measured by M28's review, driving it with `M28_PACK_TIMEOUT=0.01` so the bound cannot be met:
# `verify_npm_pack_no_optional_native` reported **52 assertions, 26 failures** — the misattributing
# cascade — and, worse, THREE of its green lines were lies. `pack_binaries ""` runs `tar -xzf ""`,
# which fails and leaves `$M28_WORK/extract` empty, so "the packed <p> contains no prebuilt binary,
# by extension or by decoding" passed `ok []` for all three shipped packages over a directory
# nothing had been extracted into. That is this entry's own deliverable, reported green, three
# times, having packed nothing. The per-package non-emptiness assertion in
# `verify_npm_pack_no_optional_native` §4 is the other half of this fix.
m28_pack() { # <package-dir> -> prints the tarball path; non-zero on failure, callers write `|| die`
  local dir="$1" name dest
  name="$(basename "$dir")"
  dest="$M28_WORK/pack/$name"
  rm -rf "$dest"; mkdir -p "$dest"
  # `--pack-destination` keeps the tarball OUT of the repository: `npm pack` writes to the current
  # directory by default, and a stray `.tgz` in the working tree is exactly what
  # `just check-repo-hygiene` refuses. `--ignore-scripts` because a lifecycle script is a way for a
  # pack to do something other than pack.
  #
  # `m28_bounded` still calls `die` on an overrun, and that is correct at ITS other two call sites,
  # which are not inside a command substitution. Reached from here it exits this function's
  # subshell non-zero, which the caller's `|| die` then turns into a refusal in the check's own
  # shell — so the bound is still a named failure rather than a hang either way.
  if ! m28_bounded "$M28_PACK_TIMEOUT" "npm pack of $name" \
       npm pack --ignore-scripts --pack-destination "$dest" --silent "$dir"; then
    printf 'npm pack failed for %s; see %s\n' "$dir" "$M28_WORK/bounded.log" >&2
    return 1
  fi
  local tgz
  tgz="$(find "$dest" -maxdepth 1 -name '*.tgz' -print -quit)"
  if [ -z "$tgz" ] || [ ! -s "$tgz" ]; then
    printf 'npm pack of %s produced no tarball in %s — a pack that produced nothing would make every absence below vacuous.\n' \
      "$dir" "$dest" >&2
    return 1
  fi
  printf '%s\n' "$tgz"
}

m28_pack_members() { # <tarball> -> one member path per line
  tar -tzf "$1"
}

m28_pack_manifest() { # <tarball> -> the package.json INSIDE the tarball, on stdout
  tar -xzOf "$1" package/package.json
}
