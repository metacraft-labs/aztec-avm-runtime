#!/usr/bin/env bash
# m30-mutations.sh — break M30's subject, one way at a time, and record WHICH assertions
# notice.
#
#   scratchpad/campaign/m30-mutations.sh [arm …]     (default: all)
#
# ===========================================================================================
# WHY "THE CHECK FAILED" IS NOT THE RESULT.
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`: *"when a mutation reddens, read WHICH assertions went red. 'The check
# failed' and 'the check saw what I broke' are different statements, and only the second is
# coverage."* Every arm below therefore records the failing assertion TEXT, not just a count,
# and each arm's comment says which assertion it was written for.
#
# Two of the arms are the states that are worse than red, and that this campaign has met
# repeatedly:
#
#   M10 HANG  a subprocess that never returns. A trap fires on exit; a process that never
#             exits has no exit, so a BOUND is the only thing that can report it.
#   M11 DIE   a check that exits before `finish` prints no summary and reads as a SMALLER
#             milestone rather than a red one — the state that took `verify-m9` from 807 to
#             524 with nothing reported. `m30_summary_on_abnormal_exit` is what must turn it
#             into a counted failure, and this is where that is exercised rather than
#             described.
#
# ===========================================================================================
# EVERY MUTATION IS APPLIED THROUGH A QUOTED HEREDOC.
# ===========================================================================================
#
# An unquoted heredoc expands backticks, and half the strings below contain them (the error
# messages quote identifiers as `name`). A first draft of this script used one, which would
# have run the mutation text as commands. Every patch here is `<<'PY'`.
#
# ===========================================================================================
# THE RESTORE IS CHECKED, AND THE CHECKER HAS ITS OWN CONTROL.
# ===========================================================================================
#
# Every mutated file is compared against a pre-mutation copy by sha256 after restoration —
# against a copy THIS SCRIPT took, not against `git status`, because a path that is not
# tracked yet prints nothing whatever the probe did and two checks once "proved" a restore
# that way. The comparison is then shown to be capable of failing, on a scratch copy
# corrupted by one character.
#
# THIS SCRIPT AND A VERIFICATION SWEEP ARE TWO WRITERS. Run it to completion, restore, verify
# the restore, and only then sweep.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKSPACE="$(cd "$REPO/.." && pwd)"
NOIR="$WORKSPACE/noir"

BACKUP="$HOME/.cache/aztec-m30-mutations/backup"
RESULTS="$HOME/.cache/aztec-m30-mutations/results"
mkdir -p "$BACKUP" "$RESULTS"

VFS_RS="$NOIR/compiler/wasm/src/vfs.rs"
COMPILE_VFS_RS="$NOIR/compiler/wasm/src/compile_vfs.rs"
BUILDER_RS="$NOIR/compiler/noirc_evaluator/src/ssa/builder.rs"
PAGE_MJS="$REPO/verification/m30/page/vfs_page.mjs"
TREES_MJS="$REPO/tools/m30_vfs_trees.mjs"
ARM_REPORT="${M30_WORK:-$HOME/.cache/aztec-m30-vfs}/vfs.json"

FILES=("$VFS_RS" "$COMPILE_VFS_RS" "$BUILDER_RS" "$PAGE_MJS" "$TREES_MJS")

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'm30-mutations: %s\n' "$*" >&2; exit 1; }

backup_all() {
  for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "no $f to back up"
    cp -p "$f" "$BACKUP/$(basename "$f")"
  done
  sha256sum "${FILES[@]}" >"$BACKUP/sha256.before"
}

# THE RESTORE MUST NOT PRESERVE THE TIMESTAMP, AND THIS COST A MEASUREMENT TO FIND.
#
# `cp -p` puts the ORIGINAL mtime back, and cargo's fingerprint is mtime-based. So after the
# M9 arm restored `noirc_evaluator/src/ssa/builder.rs`, the restored file was OLDER than the
# rlib the mutated one had produced, cargo declined to recompile it, and the next build
# emitted a module still carrying the mutation — with a build script that reported success
# and a content stamp that said the sources were current. The four checks then failed for a
# reason that had nothing to do with the tree on disk. That is `CAMPAIGN-BRIEF.md`'s "a
# mutated artefact outlived its restored source" exactly, and `build_ct_writer_wasm.sh`
# records the same mechanism in the other direction (`git archive`'s `-m`).
#
# The content is what is restored; the timestamp is deliberately NOW.
restore_all() {
  for f in "${FILES[@]}"; do
    cp "$BACKUP/$(basename "$f")" "$f"
    touch "$f"
  done
}

verify_restored() {
  if sha256sum -c --quiet "$BACKUP/sha256.before" 2>/dev/null; then
    printf 'restore: every file is byte-identical to its pre-mutation copy\n'
  else
    sha256sum -c "$BACKUP/sha256.before" 2>&1 | grep -v ': OK$' >&2
    die "RESTORE FAILED — the tree is not what it was. Compare against $BACKUP"
  fi
}

verify_restore_control() {
  local scratch="$RESULTS/restore-control"
  rm -rf "$scratch"; mkdir -p "$scratch"
  cp "$VFS_RS" "$scratch/vfs.rs"
  ( cd "$scratch" && sha256sum vfs.rs >sha256.before )
  printf '// one character\n' >>"$scratch/vfs.rs"
  if ( cd "$scratch" && sha256sum -c --quiet sha256.before >/dev/null 2>&1 ); then
    die "the restore checker reported a one-character corruption as identical; it cannot fail"
  fi
  printf 'restore-control: a one-character corruption IS reported\n'
}

run_checks() { # <label> <check …>
  local label="$1"; shift
  local out="$RESULTS/$label.log"
  : >"$out"
  for c in "$@"; do
    printf '### %s\n' "$c" >>"$out"
    ( cd "$REPO" && direnv exec . bash -c "verification/$c.sh" ) >>"$out" 2>&1
    printf '### rc=%d\n' "$?" >>"$out"
  done
  printf -- '--- %s\n' "$label"
  grep -E '^  FAIL|assertion\(s\)|^### rc=|cannot run:' "$out" | sed 's/^/    /'
}

ARMS=("$@")
[ "${#ARMS[@]}" -gt 0 ] || ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11)

backup_all
verify_restore_control

for arm in "${ARMS[@]}"; do
export M30_ARMS_REFRESH=1
case "$arm" in

# -------------------------------------------------------------------------------------
M1) say "M1 — THE GIT REFUSAL BECOMES A SILENT SKIP"
# The deliverable's own words are "refused by name, NEVER SILENTLY SKIPPED". This is the
# skip: the git arm continues instead of returning an error, so the tree resolves with the
# git dependency simply absent — a plausible value in place of a throw.
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = """            if let Some(git) = &dep.git {
                return Err(VfsError::GitDependency {
                    manifest: manifest_path.clone(),
                    at,
                    dependency: dep_name.clone(),
                    git: git.clone(),
                    tag: dep.tag.clone(),
                });
            }"""
new = """            if dep.git.is_some() {
                continue;
            }"""
assert old in s, "M1 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M1 verify_git_dependency_refused_by_name
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M2) say "M2 — THE REFUSAL LOSES THE DEPENDENCY'S NAME"
# It still refuses, still at the right stage, still with the right kind, still positioned.
# Only the noun is gone. That is the difference between "a git dependency was refused" and
# "THIS git dependency was refused", which is what the deliverable says.
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = 'write!(f, "the dependency `{dependency}` is a GIT dependency (git = \\"{git}\\"")?;'
new = 'let _ = dependency;\n                write!(f, "a dependency is a GIT dependency (git = \\"{git}\\"")?;'
assert old in s, "M2 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M2 verify_git_dependency_refused_by_name
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M3) say "M3 — THE MANIFEST LINE BECOMES A CONSTANT"
# Every dependency position reports line 1, column 1. The dependency is still named, the kind
# is still right, and the refusal still refuses. Only the measurement is gone — the shape this
# campaign calls "a constant that looks like a measurement to the person typing it".
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "            let at = Some(position_in(manifest_text, spanned.span().start));"
new = "            let _ = spanned.span();\n            let at = Some(ManifestPosition { line: 1, column: 1 });"
assert old in s, "M3 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M3 verify_git_dependency_refused_by_name
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M4) say "M4 — THE RESOLVER SWALLOWS THE WHOLE VIRTUAL FILESYSTEM"
# `sources` becomes every `.nr` in the tree rather than every `.nr` under each package's
# `src/`. The three-file tree still compiles and the artifact is still real; what is gone is
# the DECISION. §6 of `test_vfs_multifile_compiles` and §7 of the e2e are written for this.
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = """        let mut sources: Vec<String> = keyed
            .keys()
            .filter(|p| p.starts_with(&src_prefix_slash))"""
new = """        let mut sources: Vec<String> = keyed
            .keys()
            .filter(|_p| { let _ = &src_prefix_slash; true })"""
assert old in s, "M4 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M4 test_vfs_multifile_compiles e2e_vfs_edit_recompile_retrace
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M5) say "M5 — [package].entry IS IGNORED, THE WAY THE SHIPPED TYPESCRIPT IGNORES IT"
# The silent-wrong-answer one: a manifest naming a custom entry compiles a different file and
# says nothing. NO BROWSER FIXTURE USES `entry`, so the arms cannot see this and the expected
# result is that only the native suite goes red. That is the point of running it — it says
# which half of `test_vfs_multifile_compiles` is load-bearing for this property.
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "        let declared_entry = package.and_then(|p| p.entry.clone());"
new = "        let declared_entry: Option<String> = { let _ = package.and_then(|p| p.entry.clone()); None };"
assert old in s, "M5 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M5 test_vfs_multifile_compiles
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M6) say "M6 — DIAGNOSTICS LOSE THEIR POSITION"
# The file is still right, the message is still right, the byte offsets are still there. Only
# the line and column collapse to 0 — which is exactly what `noir-wasm-compiler.ts`'s
# `#resolveFile` catch produces for a file it cannot read.
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = """                line: at.as_ref().map_or(0, |l| l.line_number),
                column: at.as_ref().map_or(0, |l| l.column_number),"""
new = """                line: { let _ = at.as_ref(); 0 },
                column: 0,"""
assert old in s, "M6 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M6 test_vfs_compile_errors_carry_positions
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M7) say "M7 — LIBRARY SOURCES ARE RE-KEYED, THE WAY package.ts RE-KEYS THEM"
# `src/noir/package.ts:112-114` rewrites every library source to `<alias>/<suffix>`. Under
# that scheme a diagnostic inside a dependency names a path the caller's virtual filesystem
# does not contain. This turns M30's registration scheme back into the shipped one for the
# dependency's crate root; the assertion it must trip is "that path is a file the caller put
# in the virtual filesystem".
python3 - "$VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old_fm = """    let parsed_files = parse_all(&file_manager);"""
new_fm = """    for package in plan.packages.iter().skip(1) {
        if let Some(source) = keyed.get(&package.entry_point) {
            let aliased = format!("{}/lib.nr", package.alias);
            file_manager.add_file_with_source(Path::new(&aliased), (*source).clone());
        }
    }
    let parsed_files = parse_all(&file_manager);"""
assert old_fm in s, "M7 file-manager anchor not found"
s = s.replace(old_fm, new_fm, 1)

old_dep = """        let id = prepare_dependency(&mut context, Path::new(&package.entry_point));"""
new_dep = """        let aliased = format!("{}/lib.nr", package.alias);
        let id = prepare_dependency(&mut context, Path::new(&aliased));"""
assert old_dep in s, "M7 prepare_dependency anchor not found"
s = s.replace(old_dep, new_dep, 1)
open(p, 'w', encoding='utf-8').write(s)
PY
run_checks M7 test_vfs_compile_errors_carry_positions
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M8) say "M8 — THE TRACER IS HANDED THE WHOLE TREE INSTEAD OF THE PLAN"
# The join, broken on the page side rather than in the resolver. Everything the resolver
# decides is still right; the tracer simply ignores it. §4 and §7 of the e2e are what stand
# between that and a green milestone.
python3 - "$PAGE_MJS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = """    const files = {};
    for (const path of compiled.plan.sources) {
      files[path] = tree.files[path];
    }"""
new = """    const files = {};
    for (const path of Object.keys(tree.files)) {
      if (path.endsWith('.nr')) files[path] = tree.files[path];
    }"""
assert old in s, "M8 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M8 e2e_vfs_edit_recompile_retrace
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M9) say "M9 — THE SSA PASS TIMER READS A CLOCK AGAIN"
# M30 made `noirc_evaluator::ssa::builder::time` read the clock only when it prints it. Put
# the unconditional read back and the module reaches `js_sys::Date::new_0` — a wasm-bindgen JS
# import — inside `run_passes`, before a single instruction is generated. The page supplies no
# imports, so the compile TRAPS. The expected result is not a set of failing assertions but a
# NAMED failure from the arms run, which is the honest report: without this one-line change
# the module cannot compile a Noir program at all under a host that supplies nothing.
python3 - "$BUILDER_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = """    if !print_timings {
        return f();
    }

    let start_time = chrono::Utc::now().time();
    let result = f();
    let end_time = chrono::Utc::now().time();
    println_to_stdout!("{name}: {} ms", (end_time - start_time).num_milliseconds());

    result"""
new = """    let start_time = chrono::Utc::now().time();
    let result = f();
    if print_timings {
        let end_time = chrono::Utc::now().time();
        println_to_stdout!("{name}: {} ms", (end_time - start_time).num_milliseconds());
    }
    result"""
assert old in s, "M9 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
run_checks M9 test_vfs_multifile_compiles
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M10) say "M10 — THE HANG"
# `nv_compile_vfs` spins forever inside the module, which blocks the RENDERER: `Runtime.evaluate`
# never answers, the arms run never returns, and the only thing that can report it is the
# bound. `M30_ARMS_TIMEOUT` is lowered for this arm so the demonstration takes three minutes
# rather than half an hour.
python3 - "$COMPILE_VFS_RS" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old = "pub fn run_request_json(request_json: &str) -> String {"
new = """pub fn run_request_json(request_json: &str) -> String {
    // M10: the hang.
    let mut spin: u64 = 0;
    loop {
        spin = spin.wrapping_add(1);
        std::hint::black_box(spin);
    }
    #[allow(unreachable_code)]"""
assert old in s, "M10 anchor not found"
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
M30_ARMS_TIMEOUT=180 run_checks M10 test_vfs_multifile_compiles
restore_all; verify_restored
;;

# -------------------------------------------------------------------------------------
M11) say "M11 — DIE BEFORE THE SUMMARY"
# The arm report is replaced by one whose fields are all absent. `m30_absent` names them and
# the `die` behind it fires, which historically prints NO SUMMARY LINE at all.
# `m30_summary_on_abnormal_exit` is what must turn that into a counted failure.
[ -s "$ARM_REPORT" ] || die "no arm report at $ARM_REPORT; run the checks once first"
cp -p "$ARM_REPORT" "$BACKUP/vfs.json.before"
python3 - "$ARM_REPORT" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['arms'] = {'modules': {}, 'compile': {}, 'trace': {}}
json.dump(d, open(p, 'w', encoding='utf-8'))
PY
# The staleness predicate must leave the hollowed report alone, or the harness would helpfully
# re-measure and the mutation would never be seen. `touch` makes it newer than every input,
# and `M30_ARMS_REFRESH` is unset for this arm only.
#
# AND THE MODULE MUST ALREADY BE CURRENT BEFORE THE REPORT IS HOLLOWED, WHICH IS A FINDING AND
# NOT A PRECAUTION. `m30_require_modules` runs BEFORE the staleness predicate, and every
# preceding arm leaves `build_noir_vfs_wasm.sh`'s content stamp naming ITS mutated sources — so
# the first check of this arm rebuilds the module, the fresh module is newer than the report
# this arm just touched, `m30_require_arms` re-measures, and the hollow report is replaced
# before one assertion reads it. Measured by M30's review: run as `M10 M11`, this arm printed
# `67 assertion(s), 0 failure(s)` and `44 assertion(s), 0 failure(s)`, rc 0, with nothing
# saying the mutation had been undone; run alone it prints the 1/2 it is written for. A
# mutation that goes GREEN and is reported as the arm's RESULT is worse than one that reddens
# for the wrong reason, because it reads as coverage that is absent.
#
# Two things close it. The build is brought current FIRST, so nothing rebuilds inside the
# checks; and the hollowing is asserted to have SURVIVED the run, so if it is ever re-measured
# again this arm fails loudly instead of reporting a green milestone.
"$REPO/verification/build_noir_vfs_wasm.sh" >/dev/null 2>&1 || die "M11: could not bring the module current before hollowing the report"
touch "$ARM_REPORT"
( unset M30_ARMS_REFRESH; run_checks M11 test_vfs_multifile_compiles e2e_vfs_edit_recompile_retrace )
if python3 - "$ARM_REPORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
raise SystemExit(0 if d.get('arms', {}).get('compile') else 1)
PY
then
  cp -p "$BACKUP/vfs.json.before" "$ARM_REPORT"
  die "M11 DID NOT EXERCISE ITS MUTATION: the arm report was re-measured during the run, so the
     checks above read a FULL report and their result says nothing about the die-before-summary
     path. Bring the module current (verification/build_noir_vfs_wasm.sh) and run this arm alone."
fi
printf 'M11: the hollowed report survived the run, so the checks above read it\n'
cp -p "$BACKUP/vfs.json.before" "$ARM_REPORT"
restore_all; verify_restored
;;

*) die "unknown arm $arm" ;;
esac
done

say "ALL ARMS DONE — restoring and verifying once more"
restore_all
verify_restored
printf '\nresults are under %s\n' "$RESULTS"
