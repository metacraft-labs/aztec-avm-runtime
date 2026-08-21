// Tier C support — do the six compiled Noir contract artifacts load, and do they expose every
// public function the app tests actually call?
//
// ADDED BY aztec-avm-runtime. Not upstream; upstream has no such check because upstream builds
// the artifacts and the tests in one repo, so a missing function is a compile error there. Here
// the artifacts arrive as a pinned npm dependency and the tests are vendored from a different
// commit, so a nightly that renames or drops a public function would show up as a confusing
// mid-test failure rather than as "the corpus no longer covers what it says it covers".
//
// THE LIST IS DERIVED, NOT DECLARED. The set of called functions is recovered by scanning every
// `*.ts` under `src/` for quoted identifiers and intersecting that with the artifact's own
// function names. That is deliberate: a hand-written list can be trimmed until the check passes,
// and a derived one cannot. `verification/test_contract_artifacts_load.sh` compares the derived
// set against the checked-in `fixtures/contracts/artifacts.json` in BOTH directions, so a
// function vanishing from an artifact and the corpus quietly ceasing to call one are both
// failures.
//
// Run:  cd diffsim && node check_contract_artifacts.mjs          # prints JSON on stdout
//
// Exit status is non-zero if any artifact fails to load or any called function is missing.

import fs from 'fs';
import path from 'path';

// The declared npm pin for this tree, read from the single authority. The artifact's own
// `aztecVersion` is compared against it here rather than being copied into the output, because
// `verify_pinned_nightly_single_source` forbids a nightly literal in any tracked JSON except
// `pins.json` and the consumer package files — and rightly so: a version string checked into a
// generated fixture is a second place for the pin to be wrong.
const PINS = JSON.parse(fs.readFileSync(path.resolve('..', 'pins.json'), 'utf8'));
const DECLARED_VERSION = PINS.npm[PINS.npm_consumers.diffsim].version;

// The six the M2 corpus names. `export` is the named export in the package subpath.
const ARTIFACTS = [
  { name: 'Token', module: '@aztec/noir-contracts.js/Token', export: 'TokenContractArtifact' },
  { name: 'AMM', module: '@aztec/noir-contracts.js/AMM', export: 'AMMContractArtifact' },
  { name: 'AvmTest', module: '@aztec/noir-test-contracts.js/AvmTest', export: 'AvmTestContractArtifact' },
  {
    name: 'AvmGadgetsTest',
    module: '@aztec/noir-test-contracts.js/AvmGadgetsTest',
    export: 'AvmGadgetsTestContractArtifact',
  },
  {
    name: 'StorageProofTest',
    module: '@aztec/noir-test-contracts.js/StorageProofTest',
    export: 'StorageProofTestContractArtifact',
  },
  {
    name: 'PublicFnsWithEmitRepro',
    module: '@aztec/noir-test-contracts.js/PublicFnsWithEmitRepro',
    export: 'PublicFnsWithEmitReproContractArtifact',
  },
];

/** Every quoted identifier appearing anywhere in the vendored TypeScript corpus. */
function quotedIdentifiers(root) {
  const found = new Set();
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(p);
      } else if (p.endsWith('.ts')) {
        const text = fs.readFileSync(p, 'utf8');
        for (const m of text.matchAll(/['"`]([a-zA-Z_][a-zA-Z0-9_]*)['"`]/g)) {
          found.add(m[1]);
        }
      }
    }
  };
  walk(root);
  return found;
}

const referenced = quotedIdentifiers('src');
const out = { note: 'Derived by diffsim/check_contract_artifacts.mjs. Do not hand-edit.', artifacts: {} };
let failures = 0;

for (const spec of ARTIFACTS) {
  let artifact;
  try {
    artifact = (await import(spec.module))[spec.export];
  } catch (err) {
    process.stderr.write(`FAIL ${spec.name}: cannot import ${spec.module}: ${err.message}\n`);
    failures++;
    continue;
  }
  if (!artifact) {
    process.stderr.write(`FAIL ${spec.name}: ${spec.module} has no export ${spec.export}\n`);
    failures++;
    continue;
  }

  const dispatch = artifact.functions.find(f => f.name === 'public_dispatch');
  // Every AVM contract is entered through a single `public_dispatch` entry point; the named
  // public functions are selector-dispatched inside it and live in `nonDispatchPublicFunctions`.
  // So "the artifact exposes the function" means two separate things and both are asserted:
  // the dispatcher carries real transpiled bytecode, and the named function is declared.
  if (!dispatch) {
    process.stderr.write(`FAIL ${spec.name}: no public_dispatch function\n`);
    failures++;
    continue;
  }
  if (dispatch.functionType !== 'public') {
    process.stderr.write(`FAIL ${spec.name}: public_dispatch has functionType ${dispatch.functionType}\n`);
    failures++;
  }
  if (!dispatch.bytecode || dispatch.bytecode.length === 0) {
    process.stderr.write(`FAIL ${spec.name}: public_dispatch has no bytecode\n`);
    failures++;
  }

  const publicNames = (artifact.nonDispatchPublicFunctions ?? []).map(f => f.name);
  const publicSet = new Set(publicNames);
  const called = [...publicSet].filter(n => referenced.has(n)).sort();

  // A contract whose public surface the corpus never touches is not Tier C coverage of anything.
  if (called.length === 0) {
    process.stderr.write(`FAIL ${spec.name}: the corpus calls none of its ${publicNames.length} public functions\n`);
    failures++;
  }

  // The artifact must come from the DECLARED pin, not from whatever happens to be installed.
  if (artifact.aztecVersion !== DECLARED_VERSION) {
    process.stderr.write(
      `FAIL ${spec.name}: aztecVersion ${artifact.aztecVersion} does not equal the declared pin for diffsim\n`,
    );
    failures++;
  }

  out.artifacts[spec.name] = {
    module: spec.module,
    export: spec.export,
    aztecVersionMatchesDeclaredPin: artifact.aztecVersion === DECLARED_VERSION,
    publicFunctionCount: publicNames.length,
    dispatchBytecodeBytes: dispatch.bytecode ? dispatch.bytecode.length : 0,
    calledPublicFunctions: called,
  };
}

if (failures > 0) {
  process.stderr.write(`check_contract_artifacts: ${failures} failure(s)\n`);
  process.exit(1);
}

process.stdout.write(JSON.stringify(out, null, 2) + '\n');
