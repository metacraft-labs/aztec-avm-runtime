#!/usr/bin/env bash
# verify_path_table_fixed_at_first_mention
#
# A path's line-length table is decided at its first mention, and the host is told -- at
# `internPath`, by name -- when a later registration offers a different one.
#
# WHY. Both writers at the 2026-10 trace-format revision decide a column-aware path's table at its
# first mention and REFUSE a later, different one (`internal-files.md`, "paths.dat Layout A"); a
# refusal is recorded and fails the close. Two things on this side hid that rule:
#
#   1. `ct_intern_path` answered a repeat registration from its own path list, so the writer never
#      saw it. A second, different table for an interned path -- two different files under one
#      name, which a transaction whose contracts were compiled against different library versions
#      can produce -- returned the first file's id with no error, and every step of the second file
#      was then addressed in the first file's table. Measured before the fix: id 0, no error, a
#      container that closed. Silent.
#   2. It ignored the writer's answer when it did pass a registration on. Interning the session's
#      own source path with a table, on a column-aware recording, is refused by the writer (that
#      path was first mentioned by `start` at open, with none), and the module returned an id and
#      let the CLOSE fail long after, for a reason the host could no longer place.
#
# The module now keeps each path's table and refuses a different one itself, and returns the
# writer's refusal from the call that caused it. `ct-host/src/writer.ts` registers a path only
# through `internPath`, which crosses at once (it is not batched behind pending steps), and a
# path id reaches a step or a frame only after `internPath` returned it -- so the host registers
# no table late of its own accord, and this check is where that is measured rather than read.
#
# MEASURED BOTH WAYS. With the module's comparison removed (a repeat registration answered from the
# path list whatever its table, which is what the module did before), this check reads 41
# assertions and 12 failures: the four refusal assertions of each of the three module/mode
# arms, each finding id 0 and no message.
#
# NOTHING HERE IS A MOCK. Both modules are the real ones `lib_m41_writer.sh` builds and the host is
# the real `ct-host`, imported from its source. The `same` and `empty` cases are the controls: a
# module that refused every repeat registration would pass every refusal assertion, and these say
# it does not. The line-only `source` case is the writer's own control: the rule is a column-aware
# one, and a line-only recording that interns its source path with a table is accepted.
#
# Run: just verify-m41

TEST_NAME="verify_path_table_fixed_at_first_mention"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"

TAB=$'\t'
PROBE="$REPO_ROOT/verification/_path_table_probe.mjs"
[ -f "$PROBE" ] || die "the probe $PROBE is missing"

m41_require_path_a
m41_require_path_b

OUT="$M41_WORK/path-table-probe.out"
m41_bounded "$M41_DRIVE_TIMEOUT" "the path-table probe" \
  node --experimental-strip-types "$PROBE" "$M41_HOST/src/index.ts" "$M41_PATH_A" "$M41_PATH_B" \
  || die "the path-table probe failed; its output is in $M41_LAST_LOG:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"
cp "$M41_LAST_LOG" "$OUT"
grep -q '^PROBEDONE$' "$OUT" || die "the path-table probe did not finish; see $OUT"
P="$(cat "$OUT")"

# row <kind> <module> <case> [<step>] — the remaining fields of the one matching line.
row() {
  if [ "$#" -eq 4 ]; then
    printf '%s\n' "$P" | awk -F"$TAB" -v k="$1" -v m="$2" -v c="$3" -v s="$4" \
      '$1==k && $2==m && $3==c && $4==s { $1=$2=$3=$4=""; sub(/^\t+/, ""); print; exit }' OFS="$TAB"
  else
    printf '%s\n' "$P" | awk -F"$TAB" -v k="$1" -v m="$2" -v c="$3" \
      '$1==k && $2==m && $3==c { $1=$2=$3=""; sub(/^\t+/, ""); print; exit }' OFS="$TAB"
  fi
}
field() { printf '%s\n' "$1" | cut -d"$TAB" -f"$2"; }

for spec in "path-a-module lines" "path-b-module lines" "path-b-module cols"; do
  set -- $spec
  m="$1"; t="$2"
  echo "== $m, $t"
  # THE CONTROLS. The same table again, and no table, are the same path.
  assert_eq "$m/$t: a path interns" "0" "$(field "$(row INTERN "$m" "same-$t" first)" 1)"
  assert_eq "$m/$t: and the SAME table again returns its id" "0" "$(field "$(row INTERN "$m" "same-$t" again)" 1)"
  assert_eq "$m/$t: and the recording closes" "ok" "$(field "$(row CLOSE "$m" "same-$t")" 1)"
  assert_eq "$m/$t: NO table again also returns its id" "0" "$(field "$(row INTERN "$m" "empty-$t" again)" 1)"
  assert_eq "$m/$t: and that recording closes too" "ok" "$(field "$(row CLOSE "$m" "empty-$t")" 1)"
  # THE SUBJECT. A different table for an interned path.
  D="$(row INTERN "$m" "different-$t" again)"
  assert_eq "$m/$t: a DIFFERENT table for an interned path is refused at internPath" "REFUSED" "$(field "$D" 1)"
  assert_eq "$m/$t: as a writer refusal (CT_ERR_WRITER)" "-2" "$(field "$D" 2)"
  assert_contains "$m/$t: and the refusal names the path" "/aztec/b.nr" "$(field "$D" 3)"
  assert_contains "$m/$t: and says why" "decided at its first mention" "$(field "$D" 3)"
  # The refusal touched nothing: the module never passed it on, so the recording goes on and closes.
  assert_eq "$m/$t: the session goes on after it: the next step is accepted" "ok" \
    "$(field "$(printf '%s\n' "$P" | awk -F"$TAB" -v m="$m" -v c="different-$t" '$1=="STEP" && $2==m && $3==c' | sed -n 2p | cut -d"$TAB" -f4-)" 1)"
  assert_eq "$m/$t: and the recording closes, with the path as first interned" "ok" \
    "$(field "$(row CLOSE "$m" "different-$t")" 1)"
done

echo "== the session's own source path"
# LINE-ONLY: accepted by both writers. The table rule is a column-aware one.
assert_eq "path-a/lines: interning the source path with a table is accepted" "0" \
  "$(field "$(row INTERN path-a-module source-lines first)" 1)"
assert_eq "path-b/lines: and on Path B" "0" "$(field "$(row INTERN path-b-module source-lines first)" 1)"
assert_eq "path-b/lines: and the recording closes" "ok" "$(field "$(row CLOSE path-b-module source-lines)" 1)"
# COLUMN-AWARE: `start` gave the source path the conventional table at open; a later, different one
# is the WRITER's refusal, and it now arrives at the call rather than at the close.
S="$(row INTERN path-b-module source-cols first)"
assert_eq "path-b/cols: interning the source path with a table is refused AT internPath" "REFUSED" "$(field "$S" 1)"
assert_eq "path-b/cols: as a writer refusal" "-2" "$(field "$S" 2)"
assert_contains "path-b/cols: in the writer's own words, naming the path" "/aztec/tx.nr" "$(field "$S" 3)"
assert_contains "path-b/cols: and naming the conventional table start gave it" "100000-line table" "$(field "$S" 3)"
# The writer recorded the refusal, so the recording fails at its close; that is the writer's rule
# and is asserted so a writer that started ignoring it would be noticed here.
assert_eq "path-b/cols: and the writer still fails that recording at its close" "REFUSED" \
  "$(field "$(row CLOSE path-b-module source-cols)" 1)"

finish
