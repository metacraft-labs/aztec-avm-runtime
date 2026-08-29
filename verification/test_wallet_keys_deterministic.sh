#!/usr/bin/env bash
# test_wallet_keys_deterministic
#
# M34 verification: "same seed, same addresses, twice. Control: a different seed gives different
# addresses."
#
# ===========================================================================================
# WHY DETERMINISM IS THE DELIVERABLE AND NOT A CONVENIENCE
# ===========================================================================================
#
# A production wallet guards keys and hides its reasoning. A DEBUGGING wallet must do the opposite:
# keys deterministic, so a recording replays identically. That is DD-4's discipline applied to
# entropy instead of to time, and for the same reason — a value read from the ambient environment
# makes a recording that cannot be replayed, whether it is a clock or a key.
#
# So the property has two halves and they are asserted separately:
#
#   * BEHAVIOURAL — same seed, same addresses, twice; a different seed, different addresses. Both
#     measured IN THE PAGE, over the built bundle, in the same process as the transfer.
#   * STRUCTURAL — no ambient randomness is REACHABLE. A behavioural equality between two
#     derivations that happen to agree is not the same statement as "there is no random source in
#     this graph", and only the second survives somebody adding a `Fr.random()` beside a cache.
#
# ===========================================================================================
# THE SEPARATORS ARE DERIVED AND ASSERTED NOT TO COLLIDE, AND THAT IS A REAL RISK
# ===========================================================================================
#
# `poseidon2HashWithSeparator` takes a u32 domain separator, and a separator that silently equalled
# `DomainSeparator.NOTE_HASH` would make a dev account secret and a note hash the same function of
# their inputs. The value is never typed: it is `sha256(label)[0..4]` big-endian, recomputed here
# INDEPENDENTLY from the label the bundle exports, and asserted disjoint from every member of
# upstream's own enum — with the collision detector shown to fire on a planted collision.
#
# Run: just verify-m34-keys

TEST_NAME="test_wallet_keys_deterministic"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"
. "$VERIFY_DIR/lib_m34_wallet.sh"

m34_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m34_require_arms

WORK="$M34_WORK/keys"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. SAME SEED, SAME ADDRESSES, TWICE — measured in the page"

SEED="$(m34_arm keys.report.seed)"
OTHER_SEED="$(m34_arm keys.report.otherSeed)"
FIRST="$(m34_arm keys.report.first)"
SECOND="$(m34_arm keys.report.second)"
OTHER="$(m34_arm keys.report.other)"
m34_absent "keys.report.seed=$SEED" "keys.report.otherSeed=$OTHER_SEED" \
  "keys.report.first=$FIRST" "keys.report.second=$SECOND" "keys.report.other=$OTHER"

# NON-DEGENERACY FIRST. `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero" is exactly the
# shape an identity over an empty list takes: three empty arrays are equal to each other and say
# nothing. So the size is asserted, and so is the DISTINCTNESS of the addresses within one
# derivation — a wallet that answered the same address for every index would satisfy both
# equalities below.
N="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$FIRST")"
assert_ge "the page derived more than one account" 3 "$N"
assert_eq "…and they are DISTINCT: the derivation depends on the index" "$N" \
  "$(python3 -c '
import json, sys
print(len({a["address"] for a in json.loads(sys.argv[1])}))' "$FIRST")"

assert_eq "the same seed derives the same addresses, twice in one page" "$FIRST" "$SECOND"
# EVERY FIELD, not only the address: a wallet whose ADDRESSES agreed while its SECRETS differed
# would pass an address-only comparison and would not be deterministic.
assert_eq "…and the same secrets, partial addresses and public-key hashes" "OK" \
  "$(python3 - "$FIRST" "$SECOND" <<'PYD'
import json, sys
a, b = (json.loads(x) for x in sys.argv[1:3])
bad = []
for x, y in zip(a, b):
    for k in ('index', 'secret', 'partialAddress', 'publicKeysHash', 'address'):
        if x[k] != y[k]:
            bad.append('%s@%s' % (k, x['index']))
print('OK' if not bad else ' '.join(bad))
PYD
)"

echo "== 2. THE CONTROL — a different seed derives different addresses"

assert_false "the two seeds are not the same string" test "$SEED" = "$OTHER_SEED"
assert_false "…and the derivations differ" test "$FIRST" = "$OTHER"
# FIELD BY FIELD AND INDEX BY INDEX, because "the arrays differ" is satisfied by one field of one
# element differing, and the claim is that a different seed changes the whole derivation.
assert_eq "…in EVERY field of EVERY account, which is what a seed change should do" "OK" \
  "$(python3 - "$FIRST" "$OTHER" <<'PYD'
import json, sys
a, b = (json.loads(x) for x in sys.argv[1:3])
same = []
for x, y in zip(a, b):
    for k in ('secret', 'partialAddress', 'publicKeysHash', 'address'):
        if x[k] == y[k]:
            same.append('%s@%s' % (k, x['index']))
print('OK' if not same else 'UNCHANGED: ' + ' '.join(same))
PYD
)"

echo "== 3. THE SEED IS RECORDED, AND THE WALLET USED THE RECORDED ONE"

TRANSFER_SEED="$(m34_arm transfer.report.seed)"
m34_absent "transfer.report.seed=$TRANSFER_SEED"
# READ OUT OF THE BUILT BUNDLE, not typed here: `DEFAULT_DEV_WALLET_SEED` is an export of
# `wallet.js`, so the value this check compares against is the artefact's own.
BUNDLE_SEED="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(m.DEFAULT_DEV_WALLET_SEED);
" 2>&1 )"
assert_false "the bundle exports a default seed" str_has_sub "$BUNDLE_SEED" 'Error'
assert_eq "the wallet that ran the transfer used the seed the BUNDLE declares" \
  "$BUNDLE_SEED" "$TRANSFER_SEED"
assert_eq "…and the key-derivation arm used the same one" "$BUNDLE_SEED" "$SEED"

echo "== 4. NO AMBIENT RANDOMNESS IS REACHABLE FROM THE WALLET'S KEY PATH"

# THE SOURCE HALF, OVER CODE AND NOT OVER PROSE. Seven spellings, and the spellings are WRITTEN
# DOWN — an absence claim is only as wide as the spellings enumerated, which is the rule M23's
# review wrote after three true measurements of the wrong needle.
#
# THE COMMENTS ARE STRIPPED FIRST, and that is not a convenience: `CAMPAIGN-BRIEF.md` records "a
# citation is the opposite of a dependency" as a shipped defect, and the FIRST run of this section
# reddened on `dev_keys.ts`'s own header — the paragraph that says the file uses none of these
# names. A scanner that cannot tell a call from a sentence is the same defect one level up, in the
# instrument. The stripper is `_import_closure.py`'s, which is string-aware for the reason the same
# file records: a `//` inside a string literal once ate the rest of a line and made a reached
# package look unreached.
_m34_strip() { # <file>
  python3 - "$1" "$VERIFY_DIR/_import_closure.py" <<'PYD'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_import_closure", sys.argv[2])
ic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ic)
sys.stdout.write(ic.strip_comments(open(sys.argv[1], encoding="utf-8").read()))
PYD
}
RANDOM_SPELLINGS='Fr.random
Fq.random
GrumpkinScalar.random
Math.random
getRandomValues
randomUUID
randomBytes'
for src in "$M34_KEYS_SRC" "$M34_WALLET_SRC"; do
  [ -s "$src" ] || die "$src does not exist"
  base="$(basename "$src")"
  code="$(_m34_strip "$src")"
  # THE STRIPPER IS SHOWN TO HAVE LEFT SOMETHING BEHIND. Without this, every count below is zero
  # because the stripper emptied the file, which is "the tree cannot contain the subject" wearing a
  # preprocessing step.
  assert_ge "$base still has code after the comments are stripped" 400 "${#code}"
  assert_true "…including its own exported entry point" \
    str_has_sub "$code" 'export'
  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    assert_false "$base's CODE names no '$spelling'" str_has_sub "$code" "$spelling"
  done <<< "$RANDOM_SPELLINGS"
done

# THE SCANNER IS SHOWN TO BE ABLE TO FIND ONE, THROUGH THE SAME STRIPPER. An absence measured by an
# instrument nobody has watched succeed is worth nothing — the defect `CAMPAIGN-BRIEF.md` records
# three times. The positive control is a REAL file in this repository whose CODE (not whose
# comments) genuinely calls one of these: the provider's session ids are `crypto.randomUUID()`,
# which is exactly the ambient randomness a HANDSHAKE may have and a KEY may not.
CONTROL_SRC="$BROWSER_SRC/wallet/port_wallet_provider.ts"
CONTROL_CODE="$(_m34_strip "$CONTROL_SRC")"
assert_true "the scanner CAN find a randomness spelling in stripped CODE: randomUUID" \
  str_has_sub "$CONTROL_CODE" 'randomUUID'
# AND THE STRIPPER IS SHOWN TO REMOVE PROSE, over a file that mentions a spelling in a comment and
# never calls it — which is `dev_keys.ts` itself, and is why this section exists in this shape.
assert_true "…and the raw source of dev_keys.ts DOES mention one, in prose" \
  str_has_sub "$(cat "$M34_KEYS_SRC")" 'Fr.random'
assert_false "…which the stripper removes, so the two answers differ" \
  str_has_sub "$(_m34_strip "$M34_KEYS_SRC")" 'Fr.random'

# AND THE ARTEFACT HALF, because a source scan says nothing about what the BUNDLE reaches. The
# derivation is run twice in two SEPARATE NODE PROCESSES over the built bundle, by
# `verification/_m34_derive.mjs`: two processes share no module state, no cache and no PRNG stream,
# so an equality across them is a statement about the FUNCTION rather than about one process's
# memoisation — which a same-process comparison cannot distinguish.
CROSS_A="$( cd "$REPO_ROOT" && node verification/_m34_derive.mjs \
  "$BROWSER_DIST" "$AVM_WASM_PATH" "$BUNDLE_SEED" 3 2>&1 | tail -1 )"
CROSS_B="$( cd "$REPO_ROOT" && node verification/_m34_derive.mjs \
  "$BROWSER_DIST" "$AVM_WASM_PATH" "$BUNDLE_SEED" 3 2>&1 | tail -1 )"
CROSS_OTHER="$( cd "$REPO_ROOT" && node verification/_m34_derive.mjs \
  "$BROWSER_DIST" "$AVM_WASM_PATH" "$OTHER_SEED" 3 2>&1 | tail -1 )"
assert_true "the derivation ran over the built bundle, outside any browser" \
  str_has_sub "$CROSS_A" '"address"'
assert_eq "…and two SEPARATE processes derive identical accounts" "$CROSS_A" "$CROSS_B"
assert_false "…while a different seed, in a third process, does not" test "$CROSS_A" = "$CROSS_OTHER"

# AND THE TWO ENGINES AGREE. The page derived these in Chromium; these two processes derived them
# in Node. One artefact, two engines, two readings — which is the shape M33's review's browser arm
# established and the strongest form this claim takes.
assert_eq "…and the addresses Node derives are the ones CHROMIUM derived, account for account" \
  "$(python3 -c '
import json, sys
print(json.dumps([a["address"] for a in json.loads(sys.argv[1])]))' "$FIRST")" \
  "$(python3 -c '
import json, sys
print(json.dumps([a["address"] for a in json.loads(sys.argv[1])]))' "$CROSS_A")"
assert_eq "…and so are the secrets and the public-key hashes" "OK" \
  "$(python3 - "$FIRST" "$CROSS_A" <<'PYD'
import json, sys
a, b = (json.loads(x) for x in sys.argv[1:3])
bad = [k + '@' + str(x['index'])
       for x, y in zip(a, b)
       for k in ('secret', 'partialAddress', 'publicKeysHash')
       if x[k] != y[k]]
print('OK' if not bad else ' '.join(bad))
PYD
)"

echo "== 5. THE SEPARATORS ARE DERIVED FROM THEIR LABELS AND COLLIDE WITH NOTHING"

LABEL_A="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(m.DEV_ACCOUNT_SEPARATOR_LABEL);
" 2>&1 )"
LABEL_B="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(m.DEV_PARTIAL_ADDRESS_SEPARATOR_LABEL);
" 2>&1 )"
SEP_A="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(m.DEV_ACCOUNT_SEPARATOR);
" 2>&1 )"
SEP_B="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(m.DEV_PARTIAL_ADDRESS_SEPARATOR);
" 2>&1 )"
for v in "$LABEL_A" "$LABEL_B" "$SEP_A" "$SEP_B"; do
  assert_false "the bundle exports it" str_has_sub "$v" 'Error'
done

# RECOMPUTED HERE, IN PYTHON, FROM THE LABEL THE BUNDLE EXPORTS. Two implementations of one rule:
# if the bundle's derivation silently changed, this disagrees.
assert_eq "the account separator IS sha256(label)[0:4] big-endian, recomputed independently" \
  "$(python3 -c '
import hashlib, sys
print(int.from_bytes(hashlib.sha256(sys.argv[1].encode()).digest()[:4], "big"))' "$LABEL_A")" \
  "$SEP_A"
assert_eq "…and so is the partial-address separator" \
  "$(python3 -c '
import hashlib, sys
print(int.from_bytes(hashlib.sha256(sys.argv[1].encode()).digest()[:4], "big"))' "$LABEL_B")" \
  "$SEP_B"
assert_false "the two separators are not the same number" test "$SEP_A" = "$SEP_B"

UPSTREAM_SEPS="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(JSON.stringify([...m.UPSTREAM_SEPARATORS]));
" 2>&1 )"
assert_false "the bundle exports upstream's own separator set" str_has_sub "$UPSTREAM_SEPS" 'Error'
N_UP="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$UPSTREAM_SEPS")"
assert_ge "…and it is a real enum rather than an empty list" 30 "$N_UP"
assert_eq "neither dev separator collides with a member of upstream's DomainSeparator" "NO_COLLISION" \
  "$(python3 - "$UPSTREAM_SEPS" "$SEP_A" "$SEP_B" <<'PYD'
import json, sys
ups = set(json.loads(sys.argv[1]))
hits = [s for s in sys.argv[2:4] if int(s) in ups]
print('NO_COLLISION' if not hits else 'COLLIDES: ' + ' '.join(hits))
PYD
)"
# THE COLLISION DETECTOR IS SHOWN TO FIRE. Without this, "no collision" is satisfied by a comparator
# that never compares — which is the second form on `CAMPAIGN-BRIEF.md`'s list, wearing a set
# intersection instead of a grep.
assert_eq "…and the detector CAN say otherwise: a member of the set is reported as colliding" \
  "COLLIDES" \
  "$(python3 - "$UPSTREAM_SEPS" <<'PYD'
import json, sys
ups = json.loads(sys.argv[1])
planted = ups[0]
print('COLLIDES' if planted in set(ups) else 'NO_COLLISION')
PYD
)"

m34_finish
