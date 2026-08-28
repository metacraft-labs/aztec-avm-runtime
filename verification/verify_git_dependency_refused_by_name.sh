#!/usr/bin/env bash
# verify_git_dependency_refused_by_name
#
# M30's fourth entry: a `git` dependency is refused NAMING ITSELF AND THE MANIFEST LINE.
# Control: a local `path` dependency resolves.
#
# ===========================================================================================
# WHY THIS IS A DELIVERABLE AT ALL.
# ===========================================================================================
#
# Nothing in this fork refuses a git dependency. Measured, with the needles named, before any
# of it was written:
#
#   - `compiler/wasm/src/noir/noir-wasm-compiler.ts:71-79` wires
#     `GithubCodeArchiveDependencyResolver(fileManager, fetch)`. A GitHub dependency is
#     answered by DOWNLOADING A ZIP over the network — `github-dependency-resolver.ts:39-45`
#     — and unpacking it into the file manager.
#   - Any other git host falls through every resolver and lands on
#     `dependency-manager.ts:122-124`'s `throw new Error('Dependency not resolved')`, which
#     names nothing: not the dependency, not the manifest, not the reason.
#   - Native `nargo` shells out: `nargo_toml/src/git.rs:51-62` runs
#     `git clone --depth 1 --branch <tag>` into `$HOME/nargo`, and discards the status
#     (`:61-64`), so a failed clone still returns `Ok`.
#
# THE NEEDLE CENSUS, RE-TAKEN, BECAUSE THE PUBLISHED ONE DID NOT REPRODUCE. This header said
# `grep -rn 'refus|not supported|only github'` over `compiler/wasm/src`,
# `tooling/nargo_toml/src` and `tooling/tracer_wasm/src` finds "exactly two hits, and both are
# about the GitHub resolver declining a NON-github URL so the next resolver can try". Measured
# by M30's review, over exactly those trees and excluding M30's own `vfs.rs` and
# `compile_vfs.rs`, there is **ONE**:
#
#     compiler/wasm/src/noir/dependencies/github-dependency-resolver.ts:50:
#         throw new Error('Only github dependencies are supported');
#
# and it is not a decline-and-continue: `resolveDependency:35-37` has ALREADY `return null`ed
# for any non-github host, and the guard beside the throw compares a `URL` object with `null`,
# which is always true — so it is unreachable, and it names no dependency either way. The
# decline-and-continue is the `return null`, which these needles do not match at all.
# `tooling/tracer_wasm/src` (which exists only in the `wasm/webpage` worktree) has zero.
#
# And the census has already gone stale inside its own repository: run today WITHOUT excluding
# M30's own work it is about forty hits, because `vfs.rs` and `compile_vfs.rs` live in
# `compiler/wasm/src` and are full of the word. A census whose haystack now contains the thing
# whose absence it was counting is `CAMPAIGN-BRIEF.md`'s "ask what the haystack is".
#
# So the stable statement is: **one pre-existing hit, unreachable, naming nothing.** §7's three
# re-derived facts, each with a paired negative control, are what hold this deliverable up.
#
# So "a virtual filesystem cannot fetch" had three possible answers and none of them was a
# refusal: fetch it anyway, clone it anyway, or throw a sentence with no nouns in it. M30's
# is the fourth: a named error carrying the dependency, the manifest, the line, the URL and
# the tag.
#
# ===========================================================================================
# THE LINE IS A MEASUREMENT AND THE CHECK PROVES IT TWICE.
# ===========================================================================================
#
# The module derives the line from `toml::Spanned`'s byte offset. The expectation is derived
# separately, in `tools/m30_vfs_trees.mjs`, by scanning the manifest's own text. And the same
# manifest is compiled again with four comment lines inserted above `[dependencies]`: the
# reported line must move by exactly four. A number that had silently become a constant would
# have to be the right constant twice.
#
# ===========================================================================================
# THE REFUSAL NAMES THE RIGHT DEPENDENCY, WHICH IS NOT THE SAME AS NAMING ONE.
# ===========================================================================================
#
# The fixture's manifest carries TWO dependencies: `util`, which is local and resolvable, and
# `zzz_ecrecover`, which is the git one. `zzz_ecrecover` sorts last, so it is not first in
# manifest order either. A refusal that named whichever dependency it happened to be looking
# at, or the only one there was, would pass a one-dependency fixture and fail this one.
#
# ===========================================================================================
# AND THE REFUSAL IS NOT A FETCH THAT FAILED.
# ===========================================================================================
#
# The strongest available form of "no network was touched" is that there was no network to
# touch: the refusal happens inside a wasm module that DECLARES twenty-eight imports and
# reaches none of them, in a page whose only requests are the two `.wasm` files and its own
# HTML. §6 reads both.
#
# Run: just verify-m30-git-refusal

TEST_NAME="verify_git_dependency_refused_by_name"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m30_vfs.sh"

m30_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m30_require_arms

echo "== 1. the fields every comparison reads are present"

# THE TWO FIELDS THAT EXIST IN BOTH OUTCOMES ARE ASSERTED FIRST, BEFORE THE NON-EMPTINESS
# GUARD. `ok` and `stage` are present whether the tree resolved or was refused, so they can
# say WHAT happened; every other field below exists only in the refusal, so their absence has
# to be a `die`. Ordered this way round because of what the mutation harness measured: with
# the refusal turned into a silent `continue` — the deliverable's own "never silently
# skipped" — the guard fired first and the check reported one assertion and two failures,
# which is correct and says nothing about the subject. It now reports the subject too.
assert_eq "the tree with a git dependency does not resolve" "false" \
  "$(m30_arm arms.compile.gitDependency.ok)"
assert_eq "…and it fails at the RESOLVE stage, before any compilation" "resolve" \
  "$(m30_arm arms.compile.gitDependency.stage)"

KIND="$(m30_arm arms.compile.gitDependency.kind)"
MSG="$(m30_arm arms.compile.gitDependency.message)"
LINE="$(m30_arm arms.compile.gitDependency.line)"
COLUMN="$(m30_arm arms.compile.gitDependency.column)"
MANIFEST="$(m30_arm arms.compile.gitDependency.manifest)"
WANT_LINE="$(m30_arm arms.modules.expectations.gitDependencyLine)"
WANT_MOVED="$(m30_arm arms.modules.expectations.gitDependencyMovedLine)"
WANT_COLUMN="$(m30_arm arms.modules.expectations.gitDependencyColumn)"
MOVED_LINE="$(m30_arm arms.compile.gitDependencyMoved.line)"

ABSENT="$(m30_absent "kind=$KIND" "message=$MSG" "line=$LINE" "column=$COLUMN" \
                     "manifest=$MANIFEST" "wantLine=$WANT_LINE" "wantMovedLine=$WANT_MOVED" \
                     "wantColumn=$WANT_COLUMN" "movedLine=$MOVED_LINE")"
assert_eq "every field the comparisons below read is present" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report is missing $ABSENT; every comparison would be between two
             absences. A failure, not a smaller check."

echo "== 2. it is refused, and the refusal is a throw rather than a plausible value"

assert_eq "…with a kind a host can branch on without reading prose" "git-dependency-refused" "$KIND"
assert_eq "…and NO plan: the tree is not partially resolved and handed over" "false" \
  "$(m30_arm arms.compile.gitDependency.planPresent)"
# The control for that assertion: the same field is `true` for a tree that DOES resolve, so
# `planPresent` is a reading of the answer and not a constant.
assert_eq "…while the tree that resolves does carry one" "true" \
  "$(m30_arm arms.compile.multifile.planPresent)"
assert_eq "…and no artifact" "false" "$(m30_arm arms.compile.gitDependency.artifact.present)"
assert_eq "…and no diagnostics, because nothing was compiled" "[]" \
  "$(m30_arm arms.compile.gitDependency.diagnostics)"
# The refusal's wall time is REPORTED and not asserted. It is 0 or 1 ms on this host — the
# resolver returns before the compiler is entered — but a millisecond counter on a loaded box
# is a measurement of the box, and this campaign has a standing rule that a timing assertion
# must assert its own preconditions. The structural facts above (`stage`, no plan, no
# artifact) are what say nothing was fetched, and §6b is what says nothing COULD be.
note "the refusal took $(m30_arm arms.compile.gitDependency.ms) ms against $(m30_arm arms.compile.multifile.ms) ms for the compile it replaces"

echo "== 3. BY NAME: the dependency, the manifest, the line, the url and the tag"

assert_true "the message names the dependency" str_has_sub "$MSG" '`zzz_ecrecover`'
assert_false "…and NOT the local dependency beside it in the same manifest" \
  str_has_sub "$MSG" '`util`'
assert_true "…it names the manifest and a position in it" str_has_sub "$MSG" "app/Nargo.toml:"
assert_true "…it names the git URL" \
  str_has_sub "$MSG" "https://github.com/colinnielsen/ecrecover-noir"
assert_true "…it names the tag" str_has_sub "$MSG" 'tag = "v0.8.0"'
assert_true "…it says why a virtual filesystem cannot have it" \
  str_has_sub "$MSG" "cannot fetch it"
assert_true "…and what to do instead" str_has_sub "$MSG" "depend on it by \`path\`"
assert_eq "the manifest field is the manifest, on its own" "app/Nargo.toml" "$MANIFEST"

echo "== 4. THE LINE IS MEASURED: two derivations agree, and it moves when the entry moves"

assert_eq "the reported line is the line the git dependency sits on" "$WANT_LINE" "$LINE"
assert_eq "the reported column is where its value starts" "$WANT_COLUMN" "$COLUMN"
assert_true "…and the message carries the same position it reports as fields" \
  str_has_sub "$MSG" "app/Nargo.toml:$LINE:$COLUMN:"

assert_eq "the same dependency four lines further down reports four lines further down" \
  "$WANT_MOVED" "$MOVED_LINE"
assert_eq "…which is four" "4" "$((MOVED_LINE - LINE))"
assert_eq "…and the column is unchanged, because it did not move sideways" "$COLUMN" \
  "$(m30_arm arms.compile.gitDependencyMoved.column)"
assert_eq "…and it is still refused by name" "git-dependency-refused" \
  "$(m30_arm arms.compile.gitDependencyMoved.kind)"

echo "== 5. A GIT DEPENDENCY THAT IS NOT WELL FORMED IS STILL REFUSED BY NAME"

# `nargo_toml`'s `DependencyConfig` is `#[serde(untagged)]` over `Github{git,tag,..}` and
# `Path{path}`, so `{ git = "…" }` with no `tag` matches NEITHER arm and comes back as a TOML
# type error about the whole `[dependencies]` table. Reading every key separately is what
# lets the refusal name the dependency rather than the table it is in.
assert_eq "a git dependency with no tag is refused" "git-dependency-refused" \
  "$(m30_arm arms.compile.gitDependencyNoTag.kind)"
NOTAG_MSG="$(m30_arm arms.compile.gitDependencyNoTag.message)"
assert_true "…naming itself" str_has_sub "$NOTAG_MSG" '`zzz_ecrecover`'
assert_true "…and its URL" str_has_sub "$NOTAG_MSG" "ecrecover-noir"
assert_false "…without inventing a tag it was not given" str_has_sub "$NOTAG_MSG" "tag ="
assert_eq "…at the line it is on" "$(m30_arm arms.modules.expectations.gitDependencyNoTagLine)" \
  "$(m30_arm arms.compile.gitDependencyNoTag.line)"

echo "== 6. THE CONTROL: a local path dependency resolves, in the same module, same run"

# Without this, "the git dependency was refused" is equally consistent with a resolver that
# refuses every dependency, with one that refuses every tree, and with a module that did not
# run. The control is the SAME manifest with the git entry removed — which is the fixture
# `test_vfs_multifile_compiles` compiles — so what differs between them is one line.
assert_eq "the same tree with only the local dependency resolves" "true" \
  "$(m30_arm arms.compile.multifile.ok)"
assert_eq "…finding two packages" "2" \
  "$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' \
      "$(m30_arm arms.compile.multifile.plan.packages)")"
assert_eq "…and it compiles to an artifact" "true" \
  "$(m30_arm arms.compile.multifile.artifact.present)"
assert_eq "…and the refused tree's own local dependency is the SAME one" \
  "$(m30_arm arms.compile.multifile.plan.packages.1.manifest)" "util/Nargo.toml"

echo "== 6b. AND THERE WAS NO NETWORK TO REACH: the refusal is not a fetch that failed"

# THE ARTEFACT, NOT THE SOURCE. A `wasm32-unknown-unknown` module can only open a file or a
# socket through an IMPORT — the target has no syscalls of its own. So the module's declared
# import list is a complete account of what it could possibly do to the outside world, and it
# is a property of the bytes rather than of a sentence in a file. An earlier draft of this
# section grepped `vfs.rs` for `fetch` and `std::fs` instead; both matched THE PROSE THAT SAYS
# THE MODULE DOES NOT DO THOSE THINGS, which is the "a citation counted as a call" family
# exactly, and both were removed rather than made cleverer.
assert_eq "every import the module declares is wasm-bindgen's, and none is WASI or env" \
  '["__wbindgen_externref_xform__","__wbindgen_placeholder__"]' \
  "$(m30_arm arms.modules.modules.compiler.declaredImportModules)"
assert_ge "…and it declares enough of them for 'reached none' to mean something" 20 \
  "$(m30_arm arms.modules.modules.compiler.declaredImports)"
assert_eq "and it reached none of them" "[]" "$(m30_arm arms.modules.reached.compiler)"

# The page's own request log, which is the second instrument on the same question.
REQUESTS="$(m30_arm arms.modules.requests)"
assert_false "the page made no request to github" str_has_sub "$REQUESTS" "github"
assert_false "…and none to any codeload archive host" str_has_sub "$REQUESTS" "codeload"
assert_ge "…out of a request log that is not empty" 3 "$(m30_arm arms.modules.requestCount)"
assert_true "…which carries the compiler module it did fetch, so the log is being read" \
  str_has_sub "$REQUESTS" "/assets/noir_wasm.wasm"

echo "== 7. the refusal is in the resolver, and the three alternatives are still where the header says"

VFS_RS="$M30_VFS_SRC/vfs.rs"
assert_file "the resolver's source is where this check says it is" "$VFS_RS"
VFS_SRC_TEXT="$(cat "$VFS_RS" 2>/dev/null)"
assert_true "the resolver has a named error variant for a git dependency" \
  str_has_sub "$VFS_SRC_TEXT" "GitDependency {"
assert_true "…and RETURNS it rather than falling through to another resolver" \
  str_has_sub "$VFS_SRC_TEXT" "return Err(VfsError::GitDependency {"

# THE HEADER OF THIS FILE MAKES THREE CLAIMS ABOUT WHAT ELSE EXISTS. They are the reason this
# deliverable is a deliverable, and a claim about another file's behaviour rots the moment
# that file changes — `CAMPAIGN-BRIEF.md`'s "prose drifts from measurement". So each is
# re-derived here. If one of these goes red, the enumeration in the header is stale and the
# right response is to re-read those files, not to relax the assertion.
TS_COMPILER="$M30_NOIR_ROOT/compiler/wasm/src/noir/noir-wasm-compiler.ts"
TS_MANAGER="$M30_NOIR_ROOT/compiler/wasm/src/noir/dependencies/dependency-manager.ts"
TS_GITHUB="$M30_NOIR_ROOT/compiler/wasm/src/noir/dependencies/github-dependency-resolver.ts"
for f in "$TS_COMPILER" "$TS_MANAGER" "$TS_GITHUB"; do
  assert_file "the shipped TypeScript resolver chain is where the header says: $(basename "$f")" "$f"
done
assert_true "the shipped chain still answers a git dependency with a live fetch" \
  str_has_sub "$(cat "$TS_COMPILER" 2>/dev/null)" "GithubCodeArchiveDependencyResolver(fileManager, fetch)"
assert_true "…by downloading a zip archive" \
  str_has_sub "$(cat "$TS_GITHUB" 2>/dev/null)" "fetchZipFromGithub"
assert_true "…and any other git host still gets an error that names nothing" \
  str_has_sub "$(cat "$TS_MANAGER" 2>/dev/null)" "throw new Error('Dependency not resolved')"
# The control for those three greps: the SAME haystacks must not contain the refusal this
# milestone added. Without it, three needles that had silently stopped matching would look
# the same as three that matched, and a file that both fetched and refused would satisfy them.
for f in "$TS_COMPILER" "$TS_MANAGER" "$TS_GITHUB"; do
  assert_false "…and $(basename "$f") carries no git-dependency refusal of its own" \
    str_has_sub "$(cat "$f" 2>/dev/null)" "git-dependency-refused"
done

m30_finish
