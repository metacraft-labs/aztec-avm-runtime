#!/usr/bin/env bash
# verify_npm_pack_no_optional_native
#
# M28 verification: "the PACKED package declares no optional native dependency and contains no
# prebuilt binary".
#
# ==============================================================================================
# A MANIFEST READ IS NOT A PACK, AND THAT IS THIS ENTRY'S WHOLE POINT.
# ==============================================================================================
#
# M19's `verify_differential_containment` asks a neighbouring question with `npm pack --dry-run
# --json`, which reports the file list npm WOULD include and produces nothing. That is the right
# instrument for M19's question and the wrong one for this deliverable, which says "the PACKED
# package". Two things only a real tarball can answer:
#
#   * npm REWRITES the manifest on pack — it normalises, it can inject fields, and a `prepack`
#     script can edit it outright. The manifest that ships is the one INSIDE `package/package.json`
#     in the archive, and this check reads it from there and compares it against the one on disk,
#     so a pack-time rewrite is visible instead of assumed away.
#   * A prebuilt binary is a FILE, and "no `.node` in the file list" is only as wide as the
#     extensions somebody enumerated. `CAMPAIGN-BRIEF.md`: "an absence claim is only as wide as the
#     spellings you enumerated". So the members are EXTRACTED and every one is required to decode
#     as UTF-8 — a prebuilt binary cannot, whatever it is called. The extension list is kept as
#     well, as the cheap arm, but the decode is the total one.
#
# ==============================================================================================
# THE CONTROL PACKS A PACKAGE THAT VIOLATES BOTH HALVES, THROUGH THE SAME FUNCTIONS.
# ==============================================================================================
#
# Both assertions here are absences over three packages that have never had a native dependency, so
# on their own they cannot fail. Section 4 builds a package that declares
# `optionalDependencies: {"@aztec/native": …}` and contains a file of non-UTF-8 bytes named
# `prebuilt.node`, packs it with `m28_pack` — the same function — and runs the same manifest and
# member instruments over it. Both must report the violation. A control that does not share the
# instrument is the defect M27's review measured in the builtin census.
#
# ==============================================================================================
# AND THE HONEST HALF: THE TRANSITIVE CLOSURE DOES DECLARE OPTIONAL NATIVE DEPENDENCIES.
# ==============================================================================================
#
# "The published package declares no optional native dependency" is TRUE of the package's own
# manifest and FALSE of its dependency closure: `msgpackr` optionally depends on
# `msgpackr-extract` (six prebuilt `.node` platforms) and `@crate-crypto/node-eth-kzg` on six more.
# Three of the 268 manifests in the closure declare `optionalDependencies` and all three are
# native-addon families. That is a real property of what an `npm install` of this package would
# pull, it is recorded as `DRIFT.md` D22, and section 5 measures it rather than letting the
# narrower true statement stand in for it — together with the consequence that matters, which is
# that none of the three is reached by the browser bundle.
#
# Run: just verify-npm-pack-no-native   (or: just ci-browser-gate)

TEST_NAME="verify_npm_pack_no_optional_native"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m28_gate.sh"

m28_summary_on_abnormal_exit

command -v npm >/dev/null 2>&1 || die "npm is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
require_work_dir "$M28_WORK" 1

# THE THREE PACKAGES THAT SHIP. Named here and asserted against the tree, so a fourth appearing
# without this list moving is a failure rather than an omission: `orchestration`, `node-host` and
# `ct-host` are the three `@aztec-avm-runtime/*` packages, and `diffsim`, `drift`, `probe-mt` and
# `spike` are the harness trees, which DO depend on @aztec/native and are not shipped.
SHIPPED="orchestration node-host ct-host"
HARNESS="diffsim drift probe-mt spike"

echo "== 1. the shipped packages are exactly the three, measured over the tree"

FOUND="$(cd "$REPO_ROOT" && git ls-files '*/package.json' | sed 's|/package.json$||' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the tracked package.json files are the three shipped plus the four harness trees" \
  "ct-host diffsim drift node-host orchestration probe-mt spike " "$FOUND"
for p in $SHIPPED; do
  assert_file "the shipped package $p has a manifest" "$REPO_ROOT/$p/package.json"
  assert_eq "…named under the runtime's own scope" "@aztec-avm-runtime/$p" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$REPO_ROOT/$p/package.json")"
done
# The harness trees are named too, because "these three are what ships" is the premise everything
# below rests on and it has to be falsifiable: each of the four declares at least one of the
# packages DD-9 forbids the shipped ones from reaching.
#
# NOT "each declares @aztec/native", which is what the first version of this assertion said and
# which went red on its own first run: `probe-mt` declares `@aztec/world-state` and NOT
# `@aztec/native`. Three of the four do; the property that actually separates the harness trees
# from the shipped ones is the DD-9 SET, and the names each one declares are printed rather than
# collapsed into a count.
for p in $HARNESS; do
  declared="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
FORBIDDEN = ("@aztec/native", "@aztec/world-state", "@aztec/telemetry-client")
out = set()
for f in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
    for name in (d.get(f) or {}):
        if name in FORBIDDEN:
            out.add(name)
print(" ".join(sorted(out)))' "$REPO_ROOT/$p/package.json")"
  assert_ge "the harness tree $p declares a DD-9 package, which is why it is not shipped [$declared]" 1 \
    "$(printf '%s\n' "$declared" | tr ' ' '\n' | grep -c . || true)"
done

echo "== 2. each shipped package is PACKED, and the tarball is opened"

# Reused between sections so the manifest arm and the member arm run over the same archive.
declare -A TGZ=()
for p in $SHIPPED; do
  t="$(m28_pack "$REPO_ROOT/$p")" \
    || die "npm pack of $p could not be completed; see the message above and $M28_WORK/bounded.log.
             Refusing here rather than asserting over an archive that was never produced:
             m28_pack returns non-zero for the reason its own header gives."
  TGZ[$p]="$t"
  assert_file "npm pack produced a tarball for $p" "$t"
  members="$(m28_pack_members "$t")"
  n="$(printf '%s\n' "$members" | grep -c . || true)"
  assert_ge "…with files in it, so the absences below are absences from something" 5 "$n"
  assert_ge "…and it holds the sources, not just a manifest" 3 \
    "$(printf '%s\n' "$members" | grep -c '^package/src/' || true)"
  note "$p: $(basename "$t"), $n members, $(stat -c %s "$t") bytes"
done

echo "== 3. the manifest INSIDE the tarball declares no optional native dependency"

for p in $SHIPPED; do
  packed="$(m28_pack_manifest "${TGZ[$p]}")"
  # A NON-EMPTY READ FIRST. `tar -xzO` of a member that is not there prints nothing and every
  # comparison below would then be between two absences.
  assert_ge "the packed manifest for $p was read out of the archive" 2 \
    "$(printf '%s\n' "$packed" | grep -c . || true)"
  assert_eq "the PACKED manifest for $p declares no optionalDependencies" "0" \
    "$(printf '%s' "$packed" | python3 -c '
import json, sys
print(len(json.load(sys.stdin).get("optionalDependencies") or {}))')"
  # And no native package under any other dependency field either — an optional dependency is the
  # usual way a native addon arrives, not the only way.
  assert_eq "…and no dependency field of $p names a native package" "" \
    "$(printf '%s' "$packed" | python3 -c '
import json, sys
d = json.load(sys.stdin)
NATIVE = ("@aztec/native", "@aztec/world-state", "@aztec/bb.js", "msgpackr-extract",
          "node-gyp-build", "node-gyp-build-optional-packages", "bindings", "prebuild-install",
          "@crate-crypto/node-eth-kzg")
out = []
for f in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
    for name in sorted(d.get(f) or {}):
        if name in NATIVE:
            out.append(f + ":" + name)
print(" ".join(out))')"
  # THE PACK DID NOT REWRITE WHAT MATTERS. npm normalises on pack and a `prepack` script could
  # rewrite outright; comparing the archived manifest with the on-disk one in the fields this
  # check judges is what makes reading it out of the archive worth doing.
  assert_eq "the packed manifest's dependency fields for $p equal the on-disk manifest's" \
    "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps({f: d.get(f) for f in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")}, sort_keys=True))' "$REPO_ROOT/$p/package.json")" \
    "$(printf '%s' "$packed" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({f: d.get(f) for f in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies")}, sort_keys=True))')"
done

echo "== 4. the tarball contains no prebuilt binary — by extension AND by decoding every member"

# The instrument, defined once so section 5's control runs the same code.
pack_binaries() { # <tarball> -> one "<why> <member>" line per binary member
  local t="$1" dir="$M28_WORK/extract"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xzf "$t" -C "$dir"
  python3 - "$dir" <<'PY'
import os, sys
BINARY_EXT = (".node", ".so", ".dylib", ".dll", ".a", ".lib", ".exe", ".wasm", ".bin")
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(dirnames)
    for fn in sorted(filenames):
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root)
        if fn.endswith(BINARY_EXT):
            print("extension %s" % rel)
            continue
        # THE TOTAL ARM. A prebuilt binary is not text, whatever it is named — this is the half
        # that does not depend on having enumerated the right suffixes.
        with open(full, "rb") as handle:
            blob = handle.read()
        try:
            blob.decode("utf-8")
        except UnicodeDecodeError:
            print("not-utf8 %s" % rel)
PY
}

# NON-VACUITY PER PACKAGE, NOT ONCE AFTER THE LOOP, and the difference is a measured one.
# `pack_binaries` empties `$M28_WORK/extract` and re-fills it per tarball, so a single check after
# the loop only ever judges the LAST package's extraction. Measured by M28's review, driving the
# `die`-in-`$(…)` above: with nothing packed at all, `tar -xzf ""` left the directory empty and all
# THREE of these assertions reported `ok []` — an absence over a directory that was empty by
# construction, which is this campaign's most-repeated defect, reported green about the entry's own
# deliverable. The non-emptiness now stands beside each absence rather than after all three.
for p in $SHIPPED; do
  bins="$(pack_binaries "${TGZ[$p]}")"
  assert_ge "the extraction of $p produced files, so the absence below is not over an empty directory" 5 \
    "$(find "$M28_WORK/extract" -type f 2>/dev/null | grep -c . || true)"
  assert_eq "the packed $p contains no prebuilt binary, by extension or by decoding" "" "$bins"
done

echo "== 5. THE CONTROL — a package that violates both halves, through the same two instruments"

CTRL="$M28_WORK/control-package"
rm -rf "$CTRL"; mkdir -p "$CTRL"
cat >"$CTRL/package.json" <<'JSON'
{
  "name": "@aztec-avm-runtime/m28-pack-control",
  "version": "0.0.0",
  "private": true,
  "description": "NOT SHIPPED. Built and packed by verify_npm_pack_no_optional_native as the negative control for its two instruments: it declares an optional native dependency and carries a file that cannot decode as UTF-8. It lives under $M28_WORK and is deleted at the end of the check.",
  "optionalDependencies": { "@aztec/native": "5.0.0-nightly.20260626" }
}
JSON
printf 'export const x = 1;\n' >"$CTRL/index.js"
# Real non-UTF-8 bytes, not a name: the decode arm must be the thing that catches this file, and a
# file called `prebuilt.node` that happened to be text would only exercise the extension arm.
printf '\177ELF\002\001\001\000\377\376\375\374' >"$CTRL/prebuilt.node"
printf '\377\376\000\001binary-but-innocently-named\000\377' >"$CTRL/data.dat"

CTRL_TGZ="$(m28_pack "$CTRL")" \
  || die "the control package could not be packed; the negative control below would otherwise be
           asserted over nothing, which is the failure mode it exists to rule out."
assert_file "the control package packs" "$CTRL_TGZ"
CTRL_MANIFEST="$(m28_pack_manifest "$CTRL_TGZ")"
assert_eq "the SAME manifest instrument reports the control's optional native dependency" "1" \
  "$(printf '%s' "$CTRL_MANIFEST" | python3 -c '
import json, sys
print(len(json.load(sys.stdin).get("optionalDependencies") or {}))')"
CTRL_BINS="$(pack_binaries "$CTRL_TGZ")"
assert_ge "the SAME member instrument reports the control's binary members" 2 \
  "$(printf '%s\n' "$CTRL_BINS" | grep -c . || true)"
assert_true "…catching prebuilt.node by its extension" \
  str_has_line "$CTRL_BINS" "extension package/prebuilt.node"
assert_true "…and data.dat, which no extension list would have named, by failing to decode" \
  str_has_line "$CTRL_BINS" "not-utf8 package/data.dat"
# And the control's TEXT file is not reported, so the instrument discriminates rather than
# reporting everything it is shown.
assert_eq "…while the control's ordinary source file is not reported" "0" \
  "$(printf '%s\n' "$CTRL_BINS" | grep -c 'index\.js' || true)"
rm -rf "$CTRL"

echo "== 6. the DECLARED CLOSURE does contain optional native dependencies, and that is DRIFT.md D22"

CLOSURE="$(python3 - "$REPO_ROOT/orchestration" <<'PY'
import json, os, sys
root = sys.argv[1]
nm = os.path.join(root, "node_modules")


def manifest(name):
    p = os.path.join(nm, name, "package.json")
    return json.load(open(p)) if os.path.exists(p) else None


seen, optional, unresolved = set(), [], []
stack = list(json.load(open(os.path.join(root, "package.json"))).get("dependencies", {}))
while stack:
    n = stack.pop()
    if n in seen:
        continue
    seen.add(n)
    d = manifest(n)
    if d is None:
        unresolved.append(n)
        continue
    od = d.get("optionalDependencies") or {}
    if od:
        optional.append(n)
    stack.extend(d.get("dependencies") or {})
    stack.extend(od)
print("CLOSURE %d" % len(seen))
print("UNRESOLVED %d" % len(unresolved))
for n in sorted(optional):
    print("OPTIONAL %s" % n)
PY
)"
CLOSURE_N="$(printf '%s\n' "$CLOSURE" | sed -n 's/^CLOSURE //p')"
OPTIONAL_PKGS="$(printf '%s\n' "$CLOSURE" | sed -n 's/^OPTIONAL //p' | LC_ALL=C sort | tr '\n' ' ')"
note "the shipped package's declared closure is $CLOSURE_N packages; those declaring optionalDependencies: $OPTIONAL_PKGS"
assert_ge "the closure walk reached a real dependency tree" 200 "$CLOSURE_N"
assert_eq "exactly three manifests in that closure declare optionalDependencies, and all three are native-addon families" \
  "@crate-crypto/node-eth-kzg msgpackr msgpackr-extract " "$OPTIONAL_PKGS"
# THE CONSEQUENCE THAT MATTERS. Declared in the closure is not the same as reached by the bundle,
# and the browser bundle reaches none of the three. Re-derived from the metafile here rather than
# taken from the sibling check, so this assertion stands on its own.
for pkg in msgpackr-extract @crate-crypto/node-eth-kzg; do
  assert_eq "…and the browser bundle does not reach $pkg" "0" \
    "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
needle = "node_modules/" + sys.argv[2] + "/"
print(len([k for k in m["inputs"] if needle in k]))' "$BROWSER_DIST/meta.json" "$pkg")"
done
assert_ge "…while it does reach msgpackr itself, so those zeroes are not an empty graph" 1 \
  "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(len([k for k in m["inputs"] if "node_modules/msgpackr/" in k]))' "$BROWSER_DIST/meta.json")"
assert_true "DRIFT.md records the closure's optional native dependencies as D22" \
  grep -q '^## D22 — ' "$REPO_ROOT/DRIFT.md"

echo "== 7. packing left nothing in the working tree"

# `npm pack` writes to the current directory unless told otherwise, and a stray `.tgz` is what
# `just check-repo-hygiene` refuses. `--pack-destination` is in `m28_pack`; this is the check that
# it is honoured, asked of the tree rather than of the flag.
#
# ASKED OF GIT RATHER THAN OF `find`, and the first version of this assertion is why. `find
# "$REPO_ROOT" -name '*.tgz'` reports four helm charts vendored under `upstream/tsavm/spartan/`,
# which have nothing to do with npm and are gitignored — so the check went red on its own first run
# for a reason with nothing to do with its subject. `*.tgz` is NOT in `.gitignore`, so a tarball
# `npm pack` dropped in the tree appears as an untracked path and a tarball that is deliberately
# vendored under an ignored directory does not. That is precisely the distinction wanted.
stray_tarballs() {
  ( cd "$REPO_ROOT" && git status --porcelain --untracked-files=all 2>/dev/null ) \
    | awk '{ print $NF }' | grep '\.tgz$' || true
}
assert_eq "packing left no tarball in the working tree" "" "$(stray_tarballs)"
# THE CONTROL, ON THE SAME INSTRUMENT: a tarball really placed in the tree IS reported, so the
# empty answer above is a measurement and not a predicate that cannot match.
cp "${TGZ[ct-host]}" "$REPO_ROOT/.m28-pack-control.tgz"
assert_ge "…and the same instrument does report one when there is one" 1 \
  "$(stray_tarballs | grep -c '\.m28-pack-control\.tgz' || true)"
rm -f "$REPO_ROOT/.m28-pack-control.tgz"
assert_eq "…and the control tarball is removed again" "" "$(stray_tarballs)"
assert_prefix "every tarball this check made is under the work directory" "$M28_WORK/" \
  "${TGZ[orchestration]}"

m28_finish
