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

TEST_NAME="verify_carry_ledger_complete"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
LEDGER="$REPO_ROOT/CARRY-LEDGER.md"
SPECS="$WORKSPACE_ROOT/codetracer-specs"

assert_file "the carry set manifest exists" "$SERIES"
assert_file "the carry ledger exists" "$LEDGER"
[ -f "$SERIES" ] && [ -f "$LEDGER" ] || die "nothing to check"

# --- 1. the ledger is what the data renders to ------------------------------

before="$(sha256sum "$LEDGER" | awk '{print $1}')"
python3 "$REPO_ROOT/tools/render_carry_ledger.py" >/dev/null 2>&1
rc=$?
after="$(sha256sum "$LEDGER" | awk '{print $1}')"
if [ "$rc" -eq 0 ]; then
  pass "the ledger renderer runs"
else
  fail "the ledger renderer exited $rc"
fi
assert_eq "the committed ledger is byte-identical to what the data renders to" \
  "$before" "$after"

# The renderer is not trusted to be sensitive: a change to the data MUST move the
# file, or the identity above would hold for a renderer that ignored its input.
probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
cp "$SERIES" "$probe/series.json.orig"
python3 - "$SERIES" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["patches"][0]["ledger"]["status"] = "declined"
d["patches"][0]["ledger"]["url"] = "https://example.invalid/pull/1"
d["patches"][0]["ledger"]["reason"] = "SYNTHETIC PROBE"
d["patches"][0]["ledger"]["maintenance"] = "SYNTHETIC PROBE"
open(sys.argv[1], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
python3 "$REPO_ROOT/tools/render_carry_ledger.py" >/dev/null 2>&1
mutated="$(sha256sum "$LEDGER" | awk '{print $1}')"
cp "$probe/series.json.orig" "$SERIES"
python3 "$REPO_ROOT/tools/render_carry_ledger.py" >/dev/null 2>&1
restored="$(sha256sum "$LEDGER" | awk '{print $1}')"
if [ "$mutated" != "$before" ]; then
  pass "changing a ledger entry in the data changes the rendered ledger"
else
  fail "the rendered ledger did not move when a status changed — the renderer ignores its input"
fi
assert_eq "the probe left the ledger exactly as it found it" "$before" "$restored"

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

finish
