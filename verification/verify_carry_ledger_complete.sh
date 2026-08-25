#!/usr/bin/env bash
# verify_carry_ledger_complete
#
# The ledger has one job: to be true. Two ways it can stop being true, and both
# are checked.
#
#   1. It disagrees with the data. CARRY-LEDGER.md is GENERATED from
#      carry/series.json, so the check is that regenerating it changes nothing —
#      byte for byte. A hand-edited ledger fails here, which is the point: this
#      project has already shipped a corrected document beside a stale one, twice.
#
#   2. An entry is incomplete. Every patch has a status from a CLOSED vocabulary;
#      a declined one carries both a reason and a maintenance consequence; a
#      stalled one carries a reason; anything with a verdict carries a URL, and
#      that URL appears in the entry's PR.md as well, which is what the
#      upstream-bugs convention requires.
#
# The completeness rules are also exercised NEGATIVELY, against synthetic ledger
# entries, so "every entry is complete" is a check that could have failed rather
# than a sentence about five entries that happen to be in one state today.
#
# TWO CORRECTIONS, both made after this check failed for reasons that said nothing
# about the ledger:
#
#   * It compared the committed file against a re-render that embedded
#     `date.today()`, so it passed on the day the ledger was regenerated and failed
#     on every day after. The identity is the substance and is kept; the calendar
#     was not part of it and is gone from the renderer (see
#     tools/render_carry_ledger.py). It is now asserted that it stays gone: the
#     render is repeated under an interpreter whose wall clock RAISES, and the
#     poison's own liveness is proved by a positive and a negative control before
#     the renderer is run under it. A check "the output does not contain today's
#     date" would pass for a renderer that stamped yesterday's; a renderer that
#     cannot read a clock at all cannot stamp any.
#
#   * It rendered OVER the tracked CARRY-LEDGER.md in order to compare it, and
#     mutated the tracked carry/series.json in order to probe the renderer's
#     sensitivity — so a failure between the two halves of either dance left the
#     working tree dirty. Nothing here writes inside the repository any more:
#     every render goes to a temporary directory, the sensitivity probe mutates a
#     COPY, and the check ends by asserting that the four files it reads are
#     byte-for-byte and git-status-for-git-status as it found them. That last
#     assertion compares the state to ITSELF at the start rather than to "clean",
#     because whether the tree was clean when the check started is not this
#     check's business and is not something it produced.

TEST_NAME="verify_carry_ledger_complete"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
LEDGER="$REPO_ROOT/CARRY-LEDGER.md"
SPECS="$WORKSPACE_ROOT/codetracer-specs"

assert_file "the carry set manifest exists" "$SERIES"
assert_file "the carry ledger exists" "$LEDGER"
[ -f "$SERIES" ] && [ -f "$LEDGER" ] || die "nothing to check"

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT

RENDER="$REPO_ROOT/tools/render_carry_ledger.py"

# The state this check must not disturb, recorded before it does anything. Compared
# against ITSELF at the end — see the header.
TRACKED_INPUTS="CARRY-LEDGER.md carry/series.json carry/exposure.json carry/rebase.json carry/overlap.json"
# shellcheck disable=SC2086
status_before="$(cd "$REPO_ROOT" && git status --porcelain -- $TRACKED_INPUTS 2>/dev/null)"
# shellcheck disable=SC2086
sums_before="$(cd "$REPO_ROOT" && sha256sum $TRACKED_INPUTS 2>/dev/null)"
before="$(sha256sum "$LEDGER" | awk '{print $1}')"

# --- 1. the ledger is what the data renders to ------------------------------

python3 "$RENDER" --output "$probe/rendered.md" >"$probe/render.out" 2>"$probe/render.err"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "the ledger renderer runs"
else
  fail "the ledger renderer exited $rc: $(head -3 "$probe/render.err" | tr '\n' ' ')"
fi
assert_file "the renderer produced a ledger" "$probe/rendered.md"
rendered="$(sha256sum "$probe/rendered.md" 2>/dev/null | awk '{print $1}')"
assert_eq "the committed ledger is byte-identical to what the data renders to" \
  "$before" "$rendered"

# --- 1a. the rendering is a function of the data and of nothing else --------
#
# The failure this replaces: `Generated <today>` in the output made the identity
# above true for one day and false thereafter. The controls come first, so a
# green result below cannot mean "the poison never fired".
cat >"$probe/sitecustomize.py" <<'PY'
import datetime as _dt, time as _time
_MSG = "consulted the wall clock"


class _NoDate(_dt.date):
    @classmethod
    def today(cls):
        raise RuntimeError(_MSG)


class _NoDatetime(_dt.datetime):
    @classmethod
    def now(cls, tz=None):
        raise RuntimeError(_MSG)

    @classmethod
    def today(cls):
        raise RuntimeError(_MSG)

    @classmethod
    def utcnow(cls):
        raise RuntimeError(_MSG)


def _no(*a, **k):
    raise RuntimeError(_MSG)


_dt.date = _NoDate
_dt.datetime = _NoDatetime
_time.time = _no
_time.localtime = _no
_time.gmtime = _no
PY
if PYTHONPATH="$probe" python3 -c \
     'import json, argparse, pathlib; print("ok")' >/dev/null 2>&1; then
  pass "the clock-poisoned interpreter still runs a program that does not read a clock"
else
  fail "the clock-poisoned interpreter is broken — the control below would prove nothing"
fi
if PYTHONPATH="$probe" python3 -c \
     'from datetime import date; date.today()' >/dev/null 2>"$probe/poison.err"; then
  fail "the clock poison did not fire on date.today() — the control below proves nothing"
else
  pass "the clock poison fires on date.today()"
fi
PYTHONPATH="$probe" python3 "$RENDER" --output "$probe/noclock.md" \
  >"$probe/noclock.out" 2>"$probe/noclock.err"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "the renderer runs with no wall clock available to it"
else
  fail "the renderer read the wall clock — the ledger would again be a function of the calendar: $(tail -2 "$probe/noclock.err" | tr '\n' ' ')"
fi
assert_eq "the clockless rendering is byte-identical to the ordinary one" \
  "$rendered" "$(sha256sum "$probe/noclock.md" 2>/dev/null | awk '{print $1}')"

# --- 1b. the renderer is sensitive to its input -----------------------------
#
# A change to the data MUST move the output, or the identity in 1 would hold for a
# renderer that ignored its input. The probe mutates a COPY: the tracked manifest
# is never written.
cp "$SERIES" "$probe/series.mutated.json"
python3 - "$probe/series.mutated.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["patches"][0]["ledger"]["status"] = "declined"
d["patches"][0]["ledger"]["url"] = "https://example.invalid/pull/1"
d["patches"][0]["ledger"]["reason"] = "SYNTHETIC PROBE"
d["patches"][0]["ledger"]["maintenance"] = "SYNTHETIC PROBE"
open(sys.argv[1], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
python3 "$RENDER" --series "$probe/series.mutated.json" --output "$probe/mutated.md" \
  >"$probe/mutate.out" 2>"$probe/mutate.err"
mutated="$(sha256sum "$probe/mutated.md" 2>/dev/null | awk '{print $1}')"
if [ -n "$mutated" ] && [ "$mutated" != "$rendered" ]; then
  pass "changing a ledger entry in the data changes the rendered ledger"
else
  fail "the rendered ledger did not move when a status changed — the renderer ignores its input"
fi
# ... and it moves at the entry that changed, not merely somewhere.
if grep -Fq "SYNTHETIC PROBE" "$probe/mutated.md" 2>/dev/null; then
  pass "the moved ledger carries the mutated entry's reason, so the movement is the data's"
else
  fail "the rendered ledger moved without carrying the changed field"
fi
# Rendering from an unmodified copy reproduces the committed file, which is the
# same identity as 1 stated against a path outside the repository — so "we compared
# it to a file we had just written over" is not available as an explanation.
cp "$SERIES" "$probe/series.pristine.json"
python3 "$RENDER" --series "$probe/series.pristine.json" --output "$probe/pristine.md" \
  >/dev/null 2>"$probe/pristine.err"
assert_eq "rendering from an untouched copy of the manifest reproduces the committed ledger" \
  "$before" "$(sha256sum "$probe/pristine.md" 2>/dev/null | awk '{print $1}')"

# --- 2. every entry is complete ---------------------------------------------

python3 - "$SERIES" "$SPECS" <<'PY'
import json, os, re, sys
series, specs = sys.argv[1], sys.argv[2]
STATUSES = {"prepared", "submitted", "accepted", "declined", "stalled"}
d = json.load(open(series))
bad = []
for p in d["patches"]:
    led = p["ledger"]
    st = led["status"]
    if st not in STATUSES:
        bad.append("%s: status %r is outside the closed vocabulary" % (p["id"], st))
        continue
    if st == "prepared":
        if led["url"]:
            bad.append("%s: prepared but carries a URL" % p["id"])
    else:
        if not led["url"]:
            bad.append("%s: status %s with no upstream URL" % (p["id"], st))
    if st == "declined" and not (led["reason"] and led["maintenance"]):
        bad.append("%s: declined without a reason and a maintenance consequence" % p["id"])
    if st == "stalled" and not led["reason"]:
        bad.append("%s: stalled without a reason" % p["id"])
    script = os.path.join(os.path.dirname(series), "..", led["submission_script"])
    if not os.path.isfile(script):
        bad.append("%s: submission script missing: %s" % (p["id"], led["submission_script"]))
    elif not os.access(script, os.X_OK):
        bad.append("%s: submission script is not executable" % p["id"])
    # The convention requires the URL in the entry's PR.md too.
    md = os.path.join(specs, "upstream-bugs", p["entry"], "PR.md")
    text = open(md).read() if os.path.isfile(md) else ""
    m = re.search(r"^\*\*Status:\*\*(.*)$", text, re.MULTILINE)
    if not m:
        bad.append("%s: %s has no **Status:** line" % (p["id"], md))
    elif led["url"] and led["url"] not in m.group(1):
        bad.append("%s: PR.md's Status line does not carry the URL %s" % (p["id"], led["url"]))
    elif not led["url"] and "not filed" not in m.group(1):
        bad.append("%s: PR.md's Status line does not say it is unfiled: %r"
                   % (p["id"], m.group(1).strip()))
sys.exit("\n".join(bad) if bad else 0)
PY
if [ "$?" -eq 0 ]; then
  pass "every ledger entry is complete for its status, and agrees with its PR.md"
else
  fail "at least one ledger entry is incomplete (see above)"
fi

# The completeness rules, exercised negatively. Four synthetic entries, each
# breaking exactly one rule, each of which MUST be rejected.
rejected=0
for probe_case in \
  'declined-no-reason' 'submitted-no-url' 'prepared-with-url' 'bogus-status'; do
  python3 - "$SERIES" "$probe/probe.json" "$probe_case" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
led = d["patches"][0]["ledger"]
case = sys.argv[3]
if case == "declined-no-reason":
    led.update(status="declined", url="https://example.invalid/1", reason=None, maintenance=None)
elif case == "submitted-no-url":
    led.update(status="submitted", url=None)
elif case == "prepared-with-url":
    led.update(status="prepared", url="https://example.invalid/1")
elif case == "bogus-status":
    led.update(status="in-review")
open(sys.argv[2], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
  # stderr suppressed: these four probes are SUPPOSED to be rejected, and the
  # rejection message is the expected outcome rather than a problem to report.
  if python3 - "$probe/probe.json" 2>/dev/null <<'PY'
import json, sys
STATUSES = {"prepared", "submitted", "accepted", "declined", "stalled"}
d = json.load(open(sys.argv[1]))
bad = []
for p in d["patches"]:
    led = p["ledger"]; st = led["status"]
    if st not in STATUSES:
        bad.append("%s: bad status" % p["id"]); continue
    if st == "prepared" and led["url"]:
        bad.append("%s: prepared with URL" % p["id"])
    if st != "prepared" and not led["url"]:
        bad.append("%s: no URL" % p["id"])
    if st == "declined" and not (led["reason"] and led["maintenance"]):
        bad.append("%s: declined incomplete" % p["id"])
    if st == "stalled" and not led["reason"]:
        bad.append("%s: stalled incomplete" % p["id"])
sys.exit("\n".join(bad) if bad else 0)
PY
  then
    fail "the completeness rules ACCEPTED a broken entry: $probe_case"
  else
    rejected=$((rejected + 1))
  fi
done
assert_eq "all four synthetic broken ledger entries are rejected" "4" "$rejected"

# The ledger names every patch by title, so a renderer that dropped one cannot pass.
n_titles=0
while IFS= read -r title; do
  if grep -Fq "$title" "$LEDGER"; then
    n_titles=$((n_titles + 1))
  else
    fail "the ledger does not mention the patch titled: $title"
  fi
done < <(python3 -c 'import json,sys
print("\n".join(p["title"] for p in json.load(open(sys.argv[1]))["patches"]))' "$SERIES")
assert_eq "the ledger names all five patches by title" "5" "$n_titles"

# --- 4. this check wrote nothing inside the repository ----------------------
#
# The earlier version rendered over CARRY-LEDGER.md and mutated carry/series.json,
# and left the first of those modified every time it ran. Compared to how the check
# FOUND the tree, not to "clean": whether the tree was clean is not this check's
# claim and not something it produced.
# shellcheck disable=SC2086
status_after="$(cd "$REPO_ROOT" && git status --porcelain -- $TRACKED_INPUTS 2>/dev/null)"
# shellcheck disable=SC2086
sums_after="$(cd "$REPO_ROOT" && sha256sum $TRACKED_INPUTS 2>/dev/null)"
assert_eq "the check left the ledger and the carry manifests byte-for-byte as it found them" \
  "$sums_before" "$sums_after"
assert_eq "the check changed no tracked file's git status" \
  "$status_before" "$status_after"

finish
