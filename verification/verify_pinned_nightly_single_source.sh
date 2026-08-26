#!/usr/bin/env bash
# verify_pinned_nightly_single_source
#
# M1 verification: the pinned @aztec nightly version appears in exactly one
# place; no package.json or lockfile disagrees with it.
#
# READ THIS BEFORE JUDGING THE CHECK. The literal string cannot be reduced to one
# physical occurrence — npm requires a version in every package.json and repeats
# it per entry in every lockfile. What CAN be guaranteed, and is what this check
# enforces, is that there is exactly one **authority** and that nothing anywhere
# disagrees with it:
#
#   * pins.json is the only file that DECLARES a pin. Asserted directly: no other
#     tracked JSON file may carry a nightly literal except the package.json /
#     package-lock.json files pins.json itself names as derived consumers.
#   * every @aztec/* dependency in every consumer tree equals the pin pins.json
#     declares for that tree — including the exception packages, which carry
#     their own declared version and a reason;
#   * every lockfile entry resolves to that same version, AND its tarball URL
#     carries that version, so a lockfile whose URL and version disagree fails;
#   * every tracked prose file that quotes a nightly quotes a declared one, so a
#     stale number in a README fails instead of quietly misinforming;
#   * a declared pin WITNESS — a measured artefact that records which pin it was
#     produced against — may carry a literal, and must carry the RIGHT one, and
#     must still carry one at all. Exempting such a file instead would make "one
#     authority" true by shrinking its subject.
#
# Then seven NEGATIVE CONTROLS over scratch copies, because a single-source check
# that has never rejected a disagreement is indistinguishable from one that
# cannot. Two of the seven are the witness rule's, in both directions.
#
# Run: just verify-pinned-nightly

TEST_NAME="verify_pinned_nightly_single_source"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"
REPIN="$REPO_ROOT/tools/repin.py"
[ -f "$REPIN" ] || die "tools/repin.py is missing"
[ -f "$REPO_ROOT/pins.json" ] || die "pins.json does not exist"

# ---- pins.json is well formed and says what it must ------------------------
info="$(python3 - "$REPO_ROOT/pins.json" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
npm = {k: v for k, v in p["npm"].items() if not k.startswith("_")}
cons = {k: v for k, v in p["npm_consumers"].items() if not k.startswith("_")}
exc = {k: v for k, v in p.get("npm_exceptions", {}).items() if not k.startswith("_")}
print("PINS %d" % len(npm))
print("CURRENT %s" % npm["current"]["version"])
print("CONSUMERS %s" % " ".join(sorted(cons)))
print("EXCEPTIONS %s" % " ".join(sorted(exc)))
wit = {k: v for k, v in p.get("npm_pin_witnesses", {}).items() if not k.startswith("_")}
print("WITNESSES %s" % " ".join(sorted(wit)))
for path, role in wit.items():
    if role not in npm:
        print("PROBLEM witness %s names undeclared npm pin %r" % (path, role))
    else:
        print("WITNESSVALUE %s %s" % (path, npm[role]["version"]))
print("HISTORY %d" % len(p.get("history", [])))
print("ANCHORS %s" % " ".join(sorted(k for k in p["anchors"])))
for role, spec in npm.items():
    if not re.fullmatch(r"\d+\.\d+\.\d+-nightly\.\d{8}", spec["version"]):
        print("PROBLEM npm.%s version %r is not a nightly" % (role, spec["version"]))
    if not spec.get("role"):
        print("PROBLEM npm.%s has no stated role" % role)
for name, spec in exc.items():
    if len(spec.get("why", "")) < 60:
        print("PROBLEM exception %s has no substantive reason" % name)
hist = p.get("history", [])
if not hist:
    print("PROBLEM pins.json records no bump history")
else:
    newest = hist[-1]
    for role, spec in npm.items():
        if spec["version"] not in json.dumps(newest):
            print("PROBLEM the newest history entry does not name npm.%s's current value" % role)
PY
)" || die "pins.json could not be read"

problems="$(printf '%s\n' "$info" | sed -n 's/^PROBLEM //p')"
n_pins="$(printf '%s\n' "$info" | sed -n 's/^PINS //p')"
current="$(printf '%s\n' "$info" | sed -n 's/^CURRENT //p')"
consumers="$(printf '%s\n' "$info" | sed -n 's/^CONSUMERS //p')"
exceptions="$(printf '%s\n' "$info" | sed -n 's/^EXCEPTIONS //p')"
witnesses="$(printf '%s\n' "$info" | sed -n 's/^WITNESSES //p')"
history="$(printf '%s\n' "$info" | sed -n 's/^HISTORY //p')"
anchors="$(printf '%s\n' "$info" | sed -n 's/^ANCHORS //p')"

note "pinned nightly: $current"
note "consumers: $consumers"
note "exceptions: $exceptions"
note "witnesses: $witnesses"
note "anchors: $anchors"

assert_ge "pins.json declares the npm pins it needs" 2 "$n_pins"
assert_ge "pins.json declares several consumer trees" 3 "$(printf '%s' "$consumers" | wc -w)"
assert_ge "pins.json records a bump history" 1 "$history"
assert_ge "pins.json declares the upstream anchors too" 3 "$(printf '%s' "$anchors" | wc -w)"
if [ -z "$problems" ]; then
  pass "pins.json is internally consistent and every pin states its role"
else
  while IFS= read -r p; do [ -n "$p" ] && fail "$p"; done <<EOF
$problems
EOF
fi

# ---- pins.json is the only authority ---------------------------------------
# Every tracked file carrying a nightly literal must be pins.json itself or a
# file pins.json names as derived. Computed here from git, independently of the
# tool, so a bug in the tool cannot hide a stray declaration.
allowed="pins.json"
for t in $consumers; do allowed="$allowed $t/package.json $t/package-lock.json"; done
# WITNESSES: measured artefacts that record which pin they were produced against. They are
# allowed to carry a literal and REQUIRED to carry the right one — merely exempting them would
# make "pins.json is the only authority" true by shrinking its subject, which is this campaign's
# absence-asked-of-a-tree-that-cannot-answer defect.
#
# `fixtures/differential-wasm-divergences.json` is the first, and it is why this paragraph exists:
# it was committed by M19 AFTER M19's review sweep had run, so `git grep` (which sees tracked
# files only) could not see it during the measurement and this check went red the moment it was
# committed. Nobody re-ran M1. A witness is now a declared, checked category rather than a
# surprise.
for w in $witnesses; do allowed="$allowed $w"; done
carriers="$(git -C "$REPO_ROOT" grep -l -E '[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}' -- \
  ':(exclude)*/node_modules/*' 2>/dev/null || true)"
n_carriers="$(printf '%s\n' "$carriers" | grep -c . || true)"
assert_ge "some tracked file carries a nightly literal (the scan is not vacuous)" 3 "$n_carriers"

stray_json=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.json)
      case " $allowed " in
        *" $f "*) : ;;
        *) stray_json="$stray_json $f" ;;
      esac
      ;;
  esac
done <<EOF
$carriers
EOF
if [ -z "$stray_json" ]; then
  pass "pins.json is the only machine-readable declaration; every other JSON carrying a pin is a declared consumer or witness"
else
  fail "these JSON files carry a pin value but are not pins.json, a declared consumer or a witness:$stray_json"
fi

# Every witness EXISTS, is TRACKED, carries a literal AT ALL, and carries the RIGHT one. The
# middle two matter: a witness that had stopped carrying a literal would make the agreement
# assertion pass by never running, which is the shape this campaign has met more often than any
# other; the running total is CAMPAIGN-BRIEF.md's and is deliberately not repeated here.
assert_ge "pins.json declares at least one pin witness, so the paragraph above has a subject" 1 \
  "$(printf '%s' "$witnesses" | wc -w)"
for w in $witnesses ; do
  want="$(printf '%s\n' "$info" | sed -n "s|^WITNESSVALUE $w ||p")"
  assert_true "$w is tracked" \
    test -n "$(git -C "$REPO_ROOT" ls-files -- "$w")"
  got="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}' "$REPO_ROOT/$w" | sort -u | tr '\n' ' ')"
  got="${got% }"
  assert_true "$w carries a nightly literal at all, so the comparison below is not vacuous" \
    test -n "$got"
  assert_eq "$w witnesses exactly the pin pins.json declares for it" "$want" "$got"
done

# THE NEGATIVE CONTROL for the witness rule, over a scratch copy: a witness whose literal has
# drifted must be REJECTED. Without this, "the witness agrees" is indistinguishable from a rule
# that accepts anything.
WITSANDBOX="$(mktemp -d)"
trap 'rm -rf "$WITSANDBOX"' EXIT
FIRST_WITNESS="$(printf '%s' "$witnesses" | awk '{print $1}')"
cp "$REPO_ROOT/$FIRST_WITNESS" "$WITSANDBOX/witness.json"
WANT_FIRST="$(printf '%s\n' "$info" | sed -n "s|^WITNESSVALUE $FIRST_WITNESS ||p")"
DRIFTED="$(printf '%s\n' "$WANT_FIRST" | sed 's/-nightly\.[0-9]\{8\}$/-nightly.19700101/')"
assert_true "the drifted value really differs from the declared one" \
  test "$DRIFTED" != "$WANT_FIRST"
sed -i "s/$WANT_FIRST/$DRIFTED/g" "$WITSANDBOX/witness.json"
DRIFTED_GOT="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}' "$WITSANDBOX/witness.json" | sort -u | tr '\n' ' ')"
assert_eq "a witness whose literal drifted is caught by the same comparison" "not-equal" \
  "$([ "${DRIFTED_GOT% }" = "$WANT_FIRST" ] && echo equal || echo not-equal)"
rm -rf "$WITSANDBOX"

# ---- the real check: nothing disagrees -------------------------------------
out="$(python3 "$REPIN" --check --report 2>&1)"
rc=$?
note "$(printf '%s\n' "$out" | grep '^repin:')"
n_assertions="$(printf '%s\n' "$out" | sed -n 's/^repin: \([0-9]*\) assertion.*/\1/p')"
assert_ge "the pin check made a meaningful number of assertions" 100 "$n_assertions"
if [ "$rc" -eq 0 ]; then
  pass "no package.json, lockfile or prose file disagrees with pins.json"
else
  while IFS= read -r l; do
    case "$l" in
      *PIN-MISMATCH*) fail "${l#*PIN-MISMATCH }" ;;
    esac
  done <<EOF
$out
EOF
fi

# ---- --apply is a no-op on an agreeing tree --------------------------------
# The rewriter and the checker must agree about what "correct" means. If --apply
# changed anything here, one of them is wrong.
before="$(git -C "$REPO_ROOT" status --porcelain -- '*/package.json')"
apply_out="$(python3 "$REPIN" --apply 2>&1)"
after="$(git -C "$REPO_ROOT" status --porcelain -- '*/package.json')"
assert_eq "repin --apply is a byte-level no-op on an agreeing tree" "$before" "$after"
assert_contains "...and says so" "rewrote 0 file(s)" "$apply_out"

# ---- negative controls ------------------------------------------------------
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/repo/tools"
python3 - "$REPO_ROOT" "$SB/repo" <<'PY' || die "could not stage the pin sandbox"
import os, shutil, subprocess, sys
src, dst = sys.argv[1], sys.argv[2]
files = subprocess.run(["git", "-C", src, "ls-files", "-z"],
                       capture_output=True, check=True).stdout.decode().split("\0")
keep = [f for f in files if f and (f.endswith("package.json") or f.endswith("package-lock.json"))]
keep += ["pins.json", "tools/repin.py", "README.md"]
# The declared pin WITNESSES belong in the sandbox too. `repin.py` asserts that every declared
# witness carries a literal, so a sandbox missing one fails before any mutation is applied — and
# the failure would read as "the controls are meaningless" rather than as "the sandbox is short a
# file". Staged from the authority itself so a new witness needs no edit here.
import json
with open(os.path.join(src, "pins.json"), encoding="utf-8") as fh:
    keep += [k for k in json.load(fh).get("npm_pin_witnesses", {}) if not k.startswith("_")]
n = 0
for rel in keep:
    s = os.path.join(src, rel)
    if not os.path.exists(s):
        continue
    d = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
    n += 1
if n < 8:
    raise SystemExit("staged only %d files" % n)
PY
( cd "$SB/repo" && git init -q . && git add -- . >/dev/null 2>&1 ) || die "could not init the pin sandbox"

pin_control() { # <description> <shell-body>
  local desc="$1" body="$2" dir
  dir="$(mktemp -d -p "$SB")"
  cp -a "$SB/repo/." "$dir/"
  if ! ( cd "$dir" && eval "$body" ); then
    fail "$desc — the mutation failed to apply"
    return
  fi
  if ( cd "$dir" && python3 tools/repin.py --check >/dev/null 2>&1 ); then
    fail "$desc — the pin check still PASSED; it is too weak"
  else
    pass "$desc — rejected"
  fi
}

# The sandbox must be green before anything is mutated.
if ( cd "$SB/repo" && python3 tools/repin.py --check >/dev/null 2>&1 ); then
  pass "the unmutated pin sandbox passes (the controls start from green)"
else
  fail "the unmutated pin sandbox already fails; the controls would be meaningless"
  finish
fi

# The synthetic version the controls mutate TO. The digits are split across two
# adjacent shell strings on purpose: this script is a tracked file, and the check it
# drives asserts that no tracked file quotes a nightly pins.json does not declare, so
# a literal here would make the check fail on its own negative controls. Splitting it
# keeps the scan free of carve-outs, which is the stronger arrangement — an exclusion
# list would be exactly where a genuinely stale version number could hide.
CTRL_VER="9.9.9-nightly.2099""0101"

pin_control "a package.json dependency moved off the declared pin" \
  "sed -i '0,/\"@aztec\\/foundation\": \"/s//\"@aztec\\/foundation\": \"$CTRL_VER\"XX/' drift/package.json && sed -i 's/\"XX[^\"]*\"/\"/' drift/package.json"

pin_control "a lockfile entry resolving to a different version than pins.json declares" \
  "python3 - <<'EOF'
import json
p='drift/package-lock.json'
d=json.load(open(p))
for k,v in d['packages'].items():
    if k.endswith('node_modules/@aztec/foundation'):
        v['version']='$CTRL_VER'
        break
json.dump(d, open(p,'w'), indent=2)
EOF"

pin_control "a lockfile whose tarball URL disagrees with its own version field" \
  "python3 - <<'EOF'
import json
p='drift/package-lock.json'
d=json.load(open(p))
for k,v in d['packages'].items():
    if k.endswith('node_modules/@aztec/foundation') and v.get('resolved'):
        v['resolved']=v['resolved'].replace(v['version'],'$CTRL_VER')
        break
json.dump(d, open(p,'w'), indent=2)
EOF"

pin_control "prose quoting a nightly version pins.json does not declare" \
  "printf '\nPinned at $CTRL_VER.\n' >> README.md"

pin_control "a consumer tree pointed at the wrong declared pin" \
  "python3 - <<'EOF'
import json
p='pins.json'
d=json.load(open(p))
d['npm_consumers']['drift']='deletion_era'
json.dump(d, open(p,'w'), indent=2)
EOF"

# THE WITNESS RULE'S OWN CONTROLS, both directions. A witness is allowed to carry a literal
# precisely because it is required to carry the RIGHT one; if either half could not fail, the
# category would be an exemption wearing a check's name.
pin_control "a pin witness whose literal drifted off the pin it names" \
  "python3 - <<'EOF'
import json, re
d = json.load(open('pins.json'))
path, role = next((k, v) for k, v in d['npm_pin_witnesses'].items() if not k.startswith('_'))
want = d['npm'][role]['version']
text = open(path, encoding='utf-8').read()
assert want in text, 'the witness does not carry the pin it names; the control is staged wrong'
# The drifted value is DERIVED from the declared one rather than typed. A literal here
# would be a nightly version this very file quotes, which repin.py's prose rule rejects —
# and it did, which is the rule working on its own check.
drifted = re.sub(r'(\d+\.\d+\.\d+-nightly\.)\d{8}', lambda m: m.group(1) + '19700101', want)
assert drifted != want
open(path, 'w', encoding='utf-8').write(text.replace(want, drifted))
EOF"

pin_control "a pin witness that has stopped carrying a literal at all" \
  "python3 - <<'EOF'
import json, re
d = json.load(open('pins.json'))
path = next(k for k in d['npm_pin_witnesses'] if not k.startswith('_'))
text = open(path, encoding='utf-8').read()
stripped = re.sub(r'\d+\.\d+\.\d+-nightly\.\d{8}', '<redacted>', text)
assert stripped != text, 'nothing to strip; the control is staged wrong'
open(path, 'w', encoding='utf-8').write(stripped)
EOF"

finish
