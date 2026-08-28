// m30_vfs_trees.mjs — the virtual filesystems M30's arms compile, in one place.
//
// Shared by `tools/run_vfs_arms.mjs` (which drives them in a page) and by the checks that
// read the report, so "the page compiled the tree the check is talking about" is a fact
// rather than a coincidence of two literals that happen to match.
//
// ==========================================================================================
// EVERY EXPECTED POSITION IS DERIVED FROM THE FIXTURE TEXT, NEVER TYPED.
// ==========================================================================================
//
// The subject under test computes a `(line, column)` from a byte span. A check that
// compared it against a number typed into the check would be comparing a measurement with
// a constant its author read off the same file — `CAMPAIGN-BRIEF.md`'s "a constant you have
// just typed into a check looks like a measurement to the person typing it". `lineOf()`
// below scans the fixture's own text for the token, so the expected side is a second,
// independent derivation of the same fact; and the `*Moved` trees exist so that a
// derivation which had silently stopped working would have to be wrong twice, in step.
//
// No file here is loaded from disk. A fixture on disk is a fifth thing that can drift from
// the tree the page holds, and the whole subject of this milestone is a filesystem that is
// not a filesystem.

/** 1-based line of the first line whose text contains `needle`. Throws if absent. */
export function lineOf(files, path, needle) {
  const source = files[path];
  if (source === undefined) {
    throw new Error(`lineOf: the tree has no ${path}`);
  }
  const lines = source.split('\n');
  const index = lines.findIndex((line) => line.includes(needle));
  if (index < 0) {
    throw new Error(`lineOf: ${path} has no line containing ${JSON.stringify(needle)}`);
  }
  return index + 1;
}

/** 1-based column of `needle` on its line. Throws if absent. */
export function columnOf(files, path, needle) {
  const source = files[path];
  if (source === undefined) {
    throw new Error(`columnOf: the tree has no ${path}`);
  }
  for (const line of source.split('\n')) {
    const at = line.indexOf(needle);
    if (at >= 0) {
      return at + 1;
    }
  }
  throw new Error(`columnOf: ${path} has no line containing ${JSON.stringify(needle)}`);
}

/** The value of `[package].entry` in a manifest. Throws if the key is absent. */
export function entryOf(files, path) {
  const source = files[path];
  if (source === undefined) {
    throw new Error(`entryOf: the tree has no ${path}`);
  }
  const match = source.match(/^\s*entry\s*=\s*"([^"]+)"\s*$/m);
  if (!match) {
    throw new Error(`entryOf: ${path} declares no [package].entry`);
  }
  return match[1];
}

/** The parameter NAMES of `fn main` in a Noir source. Throws if there is no `fn main`. */
export function mainParamsOf(files, path) {
  const source = files[path];
  if (source === undefined) {
    throw new Error(`mainParamsOf: the tree has no ${path}`);
  }
  const match = source.match(/fn\s+main\s*\(([^)]*)\)/);
  if (!match) {
    throw new Error(`mainParamsOf: ${path} has no fn main`);
  }
  return match[1]
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => p.split(':')[0].trim());
}

const UTIL_LIB = 'pub fn twice(x: Field) -> Field {\n    x + x\n}\n';

// The dependency's manifest. `type = "lib"`, so it may be depended upon.
const UTIL_MANIFEST = '[package]\nname = "util"\ntype = "lib"\n';

// A three-`.nr`-file tree WITH a local path dependency: the entry package contributes
// `main.nr` and `helper.nr`, the dependency contributes `lib.nr`.
const APP_MANIFEST_LOCAL = [
  '[package]',
  'name = "app"',
  'type = "bin"',
  '',
  '[dependencies]',
  'util = { path = "../util" }',
  '',
].join('\n');

const APP_MAIN = [
  'mod helper;',
  '',
  'fn main(x: Field, y: pub Field) {',
  '    assert(helper::plus_one(util::twice(x)) == y);',
  '}',
  '',
].join('\n');

const APP_HELPER = 'pub fn plus_one(x: Field) -> Field {\n    x + 1\n}\n';

// A manifest that DECLARES its crate root. `src/noir/package.ts:62-80` hard-codes `main.nr`
// and drops the field on the floor (`parseNoirPackageConfig` is a no-op cast), while native
// `nargo` honours it (`tooling/nargo_toml/src/lib.rs:193-202`) and refuses a missing one by
// name — so a manifest like this compiles a DIFFERENT file through the two paths, silently.
//
// The fixture is built so that honouring it and ignoring it give OBSERVABLY different
// artifacts rather than merely different strings: `src/main.nr` is still there and still
// takes two parameters, and the declared root takes one. The ABI is therefore the
// discriminator, and it is a reading of the artifact rather than of the plan.
const APP_MANIFEST_ENTRY = [
  '[package]',
  'name = "app"',
  'type = "bin"',
  'entry = "src/entry_point.nr"',
  '',
  '[dependencies]',
  'util = { path = "../util" }',
  '',
].join('\n');

const APP_ENTRY_POINT = [
  'fn main(x: Field) -> pub Field {',
  '    util::twice(x)',
  '}',
  '',
].join('\n');

// The same manifest naming a file that is NOT in the tree.
const APP_MANIFEST_ENTRY_MISSING = APP_MANIFEST_ENTRY.replace(
  'src/entry_point.nr',
  'src/no_such_root.nr',
);

// Decoys. Every one of these is IN the virtual filesystem and none of them is in the
// program, which is what makes the resolver's `sources` a decision rather than a copy of
// its input. `scratch.nr` is the sharp one: a `.nr` file, in the package directory, outside
// `src/`.
const DECOYS = {
  'app/Prover.toml': 'x = "3"\ny = "7"\n',
  'app/README.md': '# app\n\nNot Noir.\n',
  'app/scratch.nr': 'pub fn scratch() -> Field {\n    9\n}\n',
  'app/target/app.json': '{"stale": true}\n',
};

function tree(extra) {
  return {
    'app/Nargo.toml': APP_MANIFEST_LOCAL,
    'app/src/main.nr': APP_MAIN,
    'app/src/helper.nr': APP_HELPER,
    'util/Nargo.toml': UTIL_MANIFEST,
    'util/src/lib.nr': UTIL_LIB,
    ...DECOYS,
    ...extra,
  };
}

function without(files, ...paths) {
  const out = { ...files };
  for (const path of paths) {
    delete out[path];
  }
  return out;
}

// A git dependency BESIDE a local one, so the refusal has to name the right one rather
// than the only one. `zzz_ecrecover` sorts after `util`, so it is not first in manifest
// order either.
const APP_MANIFEST_GIT = [
  '[package]',
  'name = "app"',
  'type = "bin"',
  '',
  '[dependencies]',
  'util = { path = "../util" }',
  'zzz_ecrecover = { git = "https://github.com/colinnielsen/ecrecover-noir", tag = "v0.8.0" }',
  '',
].join('\n');

// The same manifest with the git entry pushed down by four lines of comment. Nothing else
// differs, so a reported line that did not move by four is a line that was not measured.
const APP_MANIFEST_GIT_MOVED = [
  '[package]',
  'name = "app"',
  'type = "bin"',
  '',
  '# a comment',
  '# another comment',
  '# a third comment',
  '# a fourth comment',
  '[dependencies]',
  'util = { path = "../util" }',
  'zzz_ecrecover = { git = "https://github.com/colinnielsen/ecrecover-noir", tag = "v0.8.0" }',
  '',
].join('\n');

const APP_MANIFEST_GIT_NO_TAG = [
  '[package]',
  'name = "app"',
  'type = "bin"',
  '',
  '[dependencies]',
  'zzz_ecrecover = { git = "https://github.com/colinnielsen/ecrecover-noir" }',
  '',
].join('\n');

// `twice` returns a Field; declaring `u8` is a type error whose primary span is the
// return-type token on the FIRST line of the file, inside the DEPENDENCY.
const UTIL_LIB_TYPE_ERROR = 'pub fn twice(x: Field) -> u8 {\n    x + x\n}\n';

// The same error with six blank lines above it. The reported line must move by six.
const UTIL_LIB_TYPE_ERROR_MOVED =
  '\n\n\n\n\n\npub fn twice(x: Field) -> u8 {\n    x + x\n}\n';

// ------------------------------------------------------------------------------------
// The tracing tree — single crate, two source files, for the edit / recompile / retrace arm.
// ------------------------------------------------------------------------------------
const TRACE_MANIFEST = '[package]\nname = "app"\ntype = "bin"\n';
const TRACE_MAIN = [
  'mod util;',
  '',
  'fn main(x: Field) -> pub Field {',
  '    util::scale(x)',
  '}',
  '',
].join('\n');
const TRACE_UTIL_A = 'pub fn scale(x: Field) -> Field {\n    x * 2\n}\n';
// The edit. One character of arithmetic, in a file the plan says is part of the program.
const TRACE_UTIL_B = 'pub fn scale(x: Field) -> Field {\n    x * 3\n}\n';
// The decoy edit. A `.nr` file the plan says is NOT part of the program.
const TRACE_SCRATCH_A = 'pub fn unused() -> Field {\n    1\n}\n';
const TRACE_SCRATCH_B = 'pub fn unused() -> Field {\n    2\n}\n';
// The edit that does not compile, so the page has to survive a refusal and recover.
const TRACE_UTIL_BROKEN = 'pub fn scale(x: Field) -> u8 {\n    x * 2\n}\n';

function traceTree(extra) {
  return {
    'app/Nargo.toml': TRACE_MANIFEST,
    'app/src/main.nr': TRACE_MAIN,
    'app/src/util.nr': TRACE_UTIL_A,
    'app/Prover.toml': 'x = "3"\n',
    'app/scratch.nr': TRACE_SCRATCH_A,
    ...extra,
  };
}

export const TRACE_INPUTS = 'x = "3"\n';
export const TRACE_RECORDING_ID = '01949fcc-7d92-7e9c-8000-0000000030a0';

export const TREES = {
  // 1. The subject of `test_vfs_multifile_compiles`.
  multifile: { packageDir: 'app', files: tree({}) },

  // 1a. Its dependency-sensitivity partner: the dependency's body changes, nothing else.
  //
  // THE EDIT HAS TO CHANGE WHAT THE FUNCTION COMPUTES, NOT ONLY WHAT IT SAYS. The first
  // version of this fixture read `x + x + x - x`, which is different SOURCE and the same
  // CIRCUIT: the SSA passes fold it back to `x + x` and the artifact came out
  // byte-identical. `test_vfs_multifile_compiles` §5 caught it on its first run — the
  // assertion is capable of failing, and this is the input that proved it.
  multifileDependencyEdited: {
    packageDir: 'app',
    files: tree({ 'util/src/lib.nr': 'pub fn twice(x: Field) -> Field {\n    x + x + x\n}\n' }),
  },

  // 1b. Its decoy partner: a `.nr` file is ADDED to the virtual filesystem, outside `src/`.
  //
  // IT IS AN ADDITION AND NOT AN EDIT, AND THE DIFFERENCE IS THE WHOLE POINT. An EDIT to a
  // file that is not part of the program cannot change the artifact whatever the resolver
  // does — an unreferenced file contributes no code — so the assertion that used to compare
  // the two artifacts was one that could not fail. An ADDITION can: a file that enters
  // `sources` enters the `FileManager`, which shifts every later `FileId`, and
  // `compile.rs:136-140` records that those ids are what the program `hash` is based on.
  // So the hash is the discriminating reading and the bytecode is not, which is why §6 of
  // `test_vfs_multifile_compiles` asserts both and says which is which.
  //
  // THE CALIBRATION IS AN ARM NOW RATHER THAN A SENTENCE. This comment used to quote a
  // measured pair — "the hash goes from 1206613220 to 4090147220" — that nothing re-derived,
  // and by the time M30's review re-took it the numbers were **1076565353 -> 848041253**: the
  // fixture had moved under the figure. `multifileDecoyAddedUnderSrc` below is the same
  // experiment as a compiled arm, so the pair is measured on every run and neither number
  // lives in prose.
  multifileDecoyAdded: {
    packageDir: 'app',
    files: tree({ 'app/aaa_decoy.nr': 'pub fn decoy() -> Field {\n    10\n}\n' }),
  },

  // 1b'. The CALIBRATION for 1b: the same file, one directory lower, INSIDE `src/`, where the
  // resolver's own rule puts it in the program. It must move the hash and leave the bytecode
  // alone — which is what makes "the hash is unchanged" in 1b a reading of the resolver's
  // decision rather than a reading of an instrument that cannot move.
  multifileDecoyAddedUnderSrc: {
    packageDir: 'app',
    files: tree({ 'app/src/aaa_decoy.nr': 'pub fn decoy() -> Field {\n    10\n}\n' }),
  },

  // 1f/1g. `[package].entry`, honoured and refused.
  declaredEntry: {
    packageDir: 'app',
    files: tree({
      'app/Nargo.toml': APP_MANIFEST_ENTRY,
      'app/src/entry_point.nr': APP_ENTRY_POINT,
    }),
  },
  declaredEntryMissing: {
    packageDir: 'app',
    files: tree({ 'app/Nargo.toml': APP_MANIFEST_ENTRY_MISSING }),
  },

  // 1c/1d. The controls: the tree with one file taken away, twice, differently.
  missingDependencyManifest: {
    packageDir: 'app',
    files: without(tree({}), 'util/Nargo.toml'),
  },
  missingDependencySource: {
    packageDir: 'app',
    files: without(tree({}), 'util/src/lib.nr'),
  },
  // 1e. A module the entry package's own `mod` statement names, taken away.
  missingLocalModule: {
    packageDir: 'app',
    files: without(tree({}), 'app/src/helper.nr'),
  },

  // 2. `test_vfs_compile_errors_carry_positions`.
  typeErrorInDependency: {
    packageDir: 'app',
    files: tree({ 'util/src/lib.nr': UTIL_LIB_TYPE_ERROR }),
  },
  typeErrorInDependencyMoved: {
    packageDir: 'app',
    files: tree({ 'util/src/lib.nr': UTIL_LIB_TYPE_ERROR_MOVED }),
  },

  // 3. `verify_git_dependency_refused_by_name`.
  gitDependency: { packageDir: 'app', files: tree({ 'app/Nargo.toml': APP_MANIFEST_GIT }) },
  gitDependencyMoved: {
    packageDir: 'app',
    files: tree({ 'app/Nargo.toml': APP_MANIFEST_GIT_MOVED }),
  },
  gitDependencyNoTag: {
    packageDir: 'app',
    files: tree({ 'app/Nargo.toml': APP_MANIFEST_GIT_NO_TAG }),
  },

  // 4. `e2e_vfs_edit_recompile_retrace`.
  traceA: { packageDir: 'app', files: traceTree({}) },
  traceB: { packageDir: 'app', files: traceTree({ 'app/src/util.nr': TRACE_UTIL_B }) },
  // The same addition-not-edit rule as `multifileDecoyAdded` above.
  traceDecoyAdded: { packageDir: 'app', files: traceTree({ 'app/aaa_decoy.nr': TRACE_SCRATCH_B }) },
  traceBroken: { packageDir: 'app', files: traceTree({ 'app/src/util.nr': TRACE_UTIL_BROKEN }) },
};

/** Positions the checks expect, derived from the fixture text rather than typed. */
export function derivedExpectations() {
  return {
    gitDependencyLine: lineOf(TREES.gitDependency.files, 'app/Nargo.toml', 'zzz_ecrecover'),
    gitDependencyMovedLine: lineOf(
      TREES.gitDependencyMoved.files,
      'app/Nargo.toml',
      'zzz_ecrecover',
    ),
    gitDependencyNoTagLine: lineOf(
      TREES.gitDependencyNoTag.files,
      'app/Nargo.toml',
      'zzz_ecrecover',
    ),
    // The column of the dependency's VALUE — the `{` the TOML span starts at, not the key.
    gitDependencyColumn: columnOf(TREES.gitDependency.files, 'app/Nargo.toml', '{ git ='),
    typeErrorLine: lineOf(TREES.typeErrorInDependency.files, 'util/src/lib.nr', '-> u8'),
    typeErrorMovedLine: lineOf(
      TREES.typeErrorInDependencyMoved.files,
      'util/src/lib.nr',
      '-> u8',
    ),
    typeErrorColumn: columnOf(TREES.typeErrorInDependency.files, 'util/src/lib.nr', 'u8'),
    // What the plan must say the program is made of. Derived by the same rule the resolver
    // applies — every `.nr` under each package's `src/` — but written out here, so the two
    // do not share a derivation.
    multifileSources: ['app/src/helper.nr', 'app/src/main.nr', 'util/src/lib.nr'],
    multifileEntryPoint: 'app/src/main.nr',
    // `[package].entry`'s value, read OUT OF THE MANIFEST TEXT rather than typed here, so the
    // expected side is a second derivation of the fixture and not a copy of the answer.
    declaredEntryPoint: `app/${entryOf(TREES.declaredEntry.files, 'app/Nargo.toml')}`,
    declaredEntryMissingPoint: `app/${entryOf(TREES.declaredEntryMissing.files, 'app/Nargo.toml')}`,
    // What `main.nr` — the root the DEFAULT rule would have chosen — takes, and what the
    // declared root takes. Two ABIs, so honouring the field is visible in the ARTIFACT and
    // not only in the plan; both read out of the fixture's own `fn main` signatures.
    defaultRootAbi: mainParamsOf(TREES.declaredEntry.files, 'app/src/main.nr'),
    declaredRootAbi: mainParamsOf(TREES.declaredEntry.files, 'app/src/entry_point.nr'),
    traceSources: ['app/src/main.nr', 'app/src/util.nr'],
    traceEntryPoint: 'app/src/main.nr',
    // Files that are in the virtual filesystem and must NOT be in any program.
    decoys: ['app/Prover.toml', 'app/README.md', 'app/scratch.nr', 'app/target/app.json'],
  };
}
