#!/usr/bin/env bash
# verify_no_pipeline_predicates — M21
#
# ONE DEFECT CLASS, THREE WAYS IT HAS BITTEN, AND A RULE THAT MAKES IT IMPOSSIBLE.
#
# The shape is `printf … | grep -q …` — a shell string piped into an early-exiting reader whose
# exit status is then used as a predicate. Every instance is silent, and this campaign has now met
# all three of its failure modes:
#
#   1. THE PIPE BINDS TO THE ASSERTION HELPER.
#      `assert_true "…" printf '%s\n' "$x" | grep -qx 'y'` parses as
#      `{ assert_true "…" printf '%s\n' "$x" ; } | grep -qx 'y'`, so the helper runs `printf`
#      (which always succeeds), the assertion can only pass, its `ok` line goes INTO grep and is
#      never printed, and its `_ASSERTIONS` increment happens in a subshell and is lost.
#      TWO LIVE INSTANCES were found by this milestone, at
#      `verify_wasi_shim_reuse_decision_recorded.sh:159-160` — invisible in that check's own
#      transcript, between two neighbouring `ok` lines.
#
#   2. UNDER `pipefail` THE PIPELINE REPORTS THE WRITER'S SIGNAL, NOT THE READER'S VERDICT.
#      `grep -q` exits at its first match; `printf` is still writing, takes SIGPIPE, and the
#      pipeline's status becomes 141. The predicate then answers ABSENT whatever the string says.
#      It is SIZE-DEPENDENT, which is why it stayed latent for eight milestones:
#      `verify_upstream_world_state_reference_gate_green` detonated the moment M20 grew
#      `avm-wasm.yml` past the 64 KiB pipe buffer.
#
#   3. THE `bash -c` SPELLING HAS A DIFFERENT, LOUDER CEILING.
#      `bash -c "printf '%s' \"\$0\" | grep -q …" "$BIG"` does NOT inherit `pipefail` (measured
#      below), so it is immune to (2) — but the string is an ARGUMENT, so it dies E2BIG at
#      MAX_ARG_STRLEN. Measured, on this host, in one sweep:
#
#        bytes    parent shell (pipefail)      child `bash -c`
#        48,892   PRESENT   (correct)          PRESENT (correct)
#        98,892   ABSENT, status 141 (WRONG)   PRESENT (correct)
#        128,892  ABSENT, status 141 (WRONG)   PRESENT (correct)
#        133,892  ABSENT, status 141 (WRONG)   ABSENT, status 126 (E2BIG)
#
# THE RULE THIS CHECK ENFORCES: no `printf` may be the writer of a pipeline whose reader is
# `grep -q`, anywhere under `verification/` or `tools/`. It is scoped to `printf` deliberately and
# with a reason: where the writer is a real command (`git show … | grep -q`) the writer taking
# SIGPIPE is ordinary shell and there is no shell string that can grow past a buffer. Five such
# lines remain and are enumerated BY NAME below, so the exclusion cannot quietly widen — a file
# that stops having one fails, and a sixth line appearing fails too.
#
# The replacements are `lib.sh`'s five builtin predicates. This check exercises every one of them
# against a haystack larger than the pipe buffer AND larger than MAX_ARG_STRLEN, cross-checks each
# against the `grep` spelling it replaces on inputs where the two could disagree, and reproduces
# both (1) and (2) so the fix is measured against the defect rather than asserted over it.

set -uo pipefail
TEST_NAME="verify_no_pipeline_predicates"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

SCAN_DIRS="$REPO_ROOT/verification $REPO_ROOT/tools"
for d in $SCAN_DIRS; do assert_dir "the scanned directory is present" "$d"; done

# ---------------------------------------------------------------------------
# 1. THE SCANNER, AND A CONTROL THAT IT SEES ANYTHING AT ALL
#
# `printf` and `grep -q` may be separated by further stages — `verify_tier_e_authored_fixtures_justified` had one with a `tr`
# between them, and the first census this milestone ran used `printf[^|]*|[^|]*grep` and MISSED it
# for exactly that reason. The needle is therefore "a line containing `printf`, later a `|`, later
# a `grep` with a `q` in its flags", with no assumption about what is in between.
# ---------------------------------------------------------------------------
# The flag must come IMMEDIATELY after `grep`, or `[^|]*-[A-Za-z]*q` reads the `-eq` of a
# `[ "$(diff … | grep -c "^[<>]")" -eq 2 ]` as a quiet flag. Measured: that spelling put
# `verify_avm_wasm_module_split_patch_applies.sh:243` on the offender list, which is a needle
# matching more than it names — the campaign's fourteen-times defect, met again in this check.
PRED_RE='printf.*\|.*grep( +-[A-Za-z]*q| +--quiet)'
# `(^|[^|])` in front of the pipe, because `||` is not a pipeline. Without it this check put its
# own `if grep -qF … || grep -qF …` on the offender list — a needle matching more than it names, in
# the check whose entire subject is needles matching more than they name.
ANY_GREPQ_RE='(^|[^|])\| *grep +(-[A-Za-z]*q|--quiet)'

# THIS FILE IS EXCLUDED FROM THE SCAN, and that is asserted rather than assumed: section 4 below
# runs the very spelling this check forbids, deliberately, to cross-check each builtin against the
# `grep` it replaces, and section 3 reproduces the defect. An exclusion that is not measured is how
# a rule quietly stops applying, so the count of instances IN THIS FILE is pinned exactly too.
SELF="$REPO_ROOT/verification/verify_no_pipeline_predicates.sh"

scan() { # <regex> -> path:line:text for every matching line that is not a comment, self excluded
  grep -rnE "$1" $SCAN_DIRS --include='*.sh' --include='*.py' --include='*.mjs' \
       --exclude-dir='.m21-scan-probe' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+: *#' | grep -vF "$SELF:" || true
}

HITS="$(scan "$PRED_RE")"
N_HITS=0
[ -z "$HITS" ] || N_HITS="$(printf '%s\n' "$HITS" | grep -c . || true)"
[ -z "$HITS" ] || printf '%s\n' "$HITS" | sed 's/^/  --   OFFENDER /'
assert_eq "no printf-into-grep-q predicate survives anywhere under verification/ or tools/" \
  "0" "$N_HITS"

# The scanner is a thing under test too. A planted offender in a probe file MUST be reported, or
# the zero above is the zero of a scanner that matches nothing.
PROBE_DIR="$REPO_ROOT/verification/.m21-scan-probe"
rm -rf "$PROBE_DIR"; mkdir -p "$PROBE_DIR"
trap 'rm -rf "$PROBE_DIR"' EXIT
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'if printf "%s" "$x" | grep -q NEEDLE; then :; fi'
  printf '%s\n' 'if printf "%s" "$x" | tr "\\n" " " | grep -q NEEDLE; then :; fi'
  printf '%s\n' '# if printf "%s" "$x" | grep -q COMMENTED; then :; fi'
  printf '%s\n' 'if str_has_sub "$x" NEEDLE; then :; fi'
  printf '%s\n' 'git show HEAD:f | grep -q NEEDLE'
} >"$PROBE_DIR/planted.sh"
PROBE_HITS="$(grep -nE "$PRED_RE" "$PROBE_DIR/planted.sh" | grep -vE '^[0-9]+: *#' || true)"
assert_eq "the scanner reports a planted direct offender AND one with a stage in between" "2" \
  "$(printf '%s\n' "$PROBE_HITS" | grep -c . || true)"
assert_contains "…the direct one" 'grep -q NEEDLE; then' "$PROBE_HITS"
assert_contains "…and the one with a tr between the writer and the reader" '| tr ' "$PROBE_HITS"
assert_not_contains "…and a COMMENTED offender is not counted" 'COMMENTED' "$PROBE_HITS"
assert_not_contains "…and the builtin replacement is not counted" 'str_has_sub' "$PROBE_HITS"
assert_not_contains "…nor is a pipeline whose WRITER is a real command" 'git show' "$PROBE_HITS"

# ---------------------------------------------------------------------------
# 2. THE EXCLUSION IS ENUMERATED BY NAME AND CANNOT WIDEN
#
# Five `| grep -q` lines remain in the tree, in three files. Every one has a real command as its
# writer — `git worktree list`, a `git show` wrapper, and a `grep|sed|sort` helper — so there is no
# shell string to outgrow a buffer, and none of the three enclosing shells sets `pipefail` on the
# pipeline in question. They are listed here rather than described, and BOTH directions are
# asserted: a listed file that stops having one fails (the list has gone stale), and a line that
# appears and is not listed fails (the exclusion has widened).
# ---------------------------------------------------------------------------
ALLOWED_WRITERS="$(cat <<'EOF'
verify_provenance_complete.sh:git
verify_tier_e_authored_fixtures_justified.sh:at
m14/verify.sh:passes
EOF
)"
REMAINING="$(scan "$ANY_GREPQ_RE")"
N_REMAINING=0
[ -z "$REMAINING" ] || N_REMAINING="$(printf '%s\n' "$REMAINING" | grep -c . || true)"
note "$N_REMAINING surviving '| grep -q' line(s), all with a command as the writer"
assert_eq "the surviving set is exactly the five enumerated lines" "5" "$N_REMAINING"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  f="${row%%:*}"; w="${row##*:}"
  assert_true "…$f still has at least one, written by '$w'" \
    str_has_sub "$REMAINING" "$f"
done <<EOF
$ALLOWED_WRITERS
EOF
NOT_PRINTF=1
while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in (*printf*) NOT_PRINTF=0 ;; esac
done <<EOF
$REMAINING
EOF
assert_eq "…and not one of them has printf as its writer" "1" "$NOT_PRINTF"

# The self-exclusion, pinned in both directions.
SELF_HITS="$(grep -nE "$PRED_RE" "$SELF" | grep -vE '^[0-9]+: *#' | grep -c . || true)"
assert_eq "this check itself runs the forbidden spelling, deliberately and a known number of times" \
  "10" "$SELF_HITS"
assert_ge "…so its exclusion from the scan is load-bearing rather than cosmetic" 1 "$SELF_HITS"

# ---------------------------------------------------------------------------
# 3. THE DEFECT REPRODUCED, so the rule is measured rather than believed
# ---------------------------------------------------------------------------
BIG=""
for i in $(seq 1 4000); do BIG="${BIG}filler-line-${i}-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"$'\n'; done
BIG="${BIG}THE-NEEDLE"
assert_ge "the reproduction haystack is past the 64 KiB pipe buffer" 65536 "${#BIG}"
assert_ge "…and past MAX_ARG_STRLEN, so the bash -c spelling would die too" 131072 "${#BIG}"

# (2): the match is on the FIRST line, so grep exits immediately and printf takes SIGPIPE.
if printf '%s\n' "$BIG" | grep -qx 'filler-line-1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; then
  OLD_VERDICT="present"; OLD_STATUS=0
else
  OLD_STATUS=$?; OLD_VERDICT="absent"
fi
assert_eq "the old shape answers ABSENT on a haystack whose FIRST line matches" "absent" "$OLD_VERDICT"
assert_eq "…because the pipeline reports printf's SIGPIPE and not grep's verdict" "141" "$OLD_STATUS"
assert_true "…while the builtin predicate answers correctly on the same string" \
  str_has_line "$BIG" 'filler-line-1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
# And the same predicate must still be able to say NO, or "correct" above is just "always true".
assert_false "…and still says no to a line that is not there" \
  str_has_line "$BIG" 'filler-line-0-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

# (3): the child shell does not inherit pipefail — which is why the `bash -c` spelling was never
# exposed to (2), and why this check does not rewrite the five lines that use it.
CHILD_PIPEFAIL="$(bash -c 'case $(set -o) in *"pipefail       	on"*) echo on ;; *) echo off ;; esac')"
assert_eq "a child bash -c does not inherit pipefail" "off" "$CHILD_PIPEFAIL"

# (1): the counter defect, reproduced against THIS repository's own helpers rather than described.
COUNTER_PROBE="$PROBE_DIR/counter.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "TEST_NAME=counter_probe"
  printf '%s\n' ". \"$REPO_ROOT/verification/lib.sh\""
  printf '%s\n' 'H=$'"'"'bb.js\nsqlite3mc-wasm'"'"''
  printf '%s\n' "assert_true 'a needle that CANNOT match' printf '%s\\n' \"\$H\" | grep -qx 'no-such-package'"
  printf '%s\n' 'finish'
} >"$COUNTER_PROBE"
COUNTER_OUT="$(bash "$COUNTER_PROBE" 2>&1)"; COUNTER_RC=$?
assert_eq "an assert_true whose pipe binds to the HELPER reports zero assertions" "1" "$COUNTER_RC"
assert_contains "…and finish() is what catches it, by refusing a run with no assertions" \
  "no assertions ran" "$COUNTER_OUT"
assert_not_contains "…the assertion's own line never reaches the transcript" "a needle that CANNOT match" "$COUNTER_OUT"
# The control: the same assertion written the new way DOES appear, and DOES fail.
FIXED_PROBE="$PROBE_DIR/fixed.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "TEST_NAME=fixed_probe"
  printf '%s\n' ". \"$REPO_ROOT/verification/lib.sh\""
  printf '%s\n' 'H=$'"'"'bb.js\nsqlite3mc-wasm'"'"''
  printf '%s\n' "assert_true 'a needle that CANNOT match' str_has_line \"\$H\" 'no-such-package'"
  printf '%s\n' "assert_true 'a needle that CAN match' str_has_line \"\$H\" 'bb.js'"
  printf '%s\n' 'finish'
} >"$FIXED_PROBE"
FIXED_OUT="$(bash "$FIXED_PROBE" 2>&1)"
assert_contains "the builtin spelling PRINTS the assertion that cannot match" "a needle that CANNOT match" "$FIXED_OUT"
assert_contains "…as a FAIL" "FAIL a needle that CANNOT match" "$FIXED_OUT"
assert_contains "…and counts both of them" "2 assertion(s), 1 failure(s)" "$FIXED_OUT"

# ---------------------------------------------------------------------------
# 4. EACH HELPER AGREES WITH THE grep SPELLING IT REPLACES
#
# On inputs chosen from this campaign's own needle defects: `honk` inside `chonk`, a digit in
# `avm2`, a `.` that must not act as a wildcard, and a `^…$` that must anchor to a LINE and not to
# the whole string.
# ---------------------------------------------------------------------------
HAY=$'class MemoryContractDB {\navm2 and avm\nxaybz here\nsrs\nchonk\nbb.js'
agree_word() { # <needle>
  local n="$1" g s
  if printf '%s\n' "$HAY" | grep -qw -- "$n"; then g=yes; else g=no; fi
  if str_has_word "$HAY" "$n"; then s=yes; else s=no; fi
  assert_eq "str_has_word agrees with grep -qw on [$n]" "$g" "$s"
}
for n in 'a.b' 'srs' 'honk' 'chonk' 'MemoryContractDB' 'MemoryContract' 'avm2' 'avm' 'bb.js'; do
  agree_word "$n"
done
agree_line() { # <needle>
  local n="$1" g s
  if printf '%s\n' "$HAY" | grep -qxF -- "$n"; then g=yes; else g=no; fi
  if str_has_line "$HAY" "$n"; then s=yes; else s=no; fi
  assert_eq "str_has_line agrees with grep -qxF on [$n]" "$g" "$s"
}
for n in 'srs' 'chonk' 'chon' 'bb.js' 'bb?js' 'avm2 and avm'; do agree_line "$n"; done
agree_sub() { # <needle>
  local n="$1" g s
  if printf '%s\n' "$HAY" | grep -qF -- "$n"; then g=yes; else g=no; fi
  if str_has_sub "$HAY" "$n"; then s=yes; else s=no; fi
  assert_eq "str_has_sub agrees with grep -qF on [$n]" "$g" "$s"
}
for n in 'honk' 'MemoryContract' 'b.j' 'b?j'; do agree_sub "$n"; done
agree_line_re() { # <ere>
  local r="$1" g s
  if printf '%s\n' "$HAY" | grep -qE -- "$r"; then g=yes; else g=no; fi
  if str_has_line_re "$HAY" "$r"; then s=yes; else s=no; fi
  assert_eq "str_has_line_re agrees with grep -qE on [$r]" "$g" "$s"
}
for r in '^srs$' '^rs$' '^avm2 and avm$' 'avm[0-9]' '^bb\.js$' '^bb.js$' '^class .* \{$'; do
  agree_line_re "$r"
done

# THE ONE PLACE THE TWO SPELLINGS ARE NOT INTERCHANGEABLE, asserted rather than left to a comment:
# bash's `=~` has no REG_NEWLINE, so `^`/`$` anchor to the ends of the WHOLE string. Translating a
# `grep -qE '^srs$'` into `str_has_re` therefore silently stops matching, which is a green check
# that has stopped checking.
assert_true  "str_has_line_re anchors ^…\$ to a LINE, as grep -E does" str_has_line_re "$HAY" '^srs$'
assert_false "…while str_has_re anchors them to the whole STRING, which is why they are two names" \
  str_has_re "$HAY" '^srs$'
assert_true  "…and str_has_re is the right one for an unanchored pattern" str_has_re "$HAY" 'avm[0-9]'

# The escaper is the part of str_has_word that could silently widen a match.
assert_eq "the ERE escaper escapes every metacharacter, not just the ones a bracket expression sees" \
  'a\.b\+c\(d\)\[e\]\{f\}\|g\^h\$i\*j\?k\\l' "$(_str_escape_ere 'a.b+c(d)[e]{f}|g^h$i*j?k\l')"

# ---------------------------------------------------------------------------
# 5. lib.sh DECLARES ALL FIVE, and they are what the tree calls
# ---------------------------------------------------------------------------
LIB="$(cat "$REPO_ROOT/verification/lib.sh")"
for fn in str_has_line str_has_sub str_has_word str_has_re str_has_line_re; do
  assert_true "lib.sh declares $fn" str_has_line_re "$LIB" "^${fn}\(\) \{"
  N_CALLS="$(grep -rhoE "\b${fn}\b" $SCAN_DIRS --include='*.sh' | grep -c . || true)"
  assert_ge "…and something calls it" 2 "$N_CALLS"
done

rm -rf "$PROBE_DIR"; trap - EXIT
finish
