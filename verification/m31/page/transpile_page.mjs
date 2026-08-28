// The M31 page's own code. It fetches ONE `.wasm` file and one JSON artifact per fixture, and
// talks to the module through the bare C ABI M30's `wasm_host.mjs` already knows how to drive.
//
// ==========================================================================================
// WHAT THIS FILE DELIBERATELY DOES NOT DO.
// ==========================================================================================
//
// It does not parse the artifact, does not touch `bytecode`, and does not know what a Brillig
// opcode is. Everything it hands back is either the module's own output bytes or a digest of
// them. That is what makes "the browser transpiled it" a measurement: if this file could
// produce an AVM artifact, the claim would be about this file.
//
// It also never supplies a wasm import. `instantiateBare` satisfies every declared import with
// a function that RECORDS the call and then throws, so `reachedImports()` coming back empty is
// evidence rather than a description of a build flag — and `declaredImports` being non-empty is
// what stops the empty list being vacuous.

import { instantiateBare, sha256Hex } from './wasm_host.mjs';

const statusEl = document.getElementById('status');
const outEl = document.getElementById('out');

function say(text) {
  statusEl.textContent = text;
}

/** Base64 for a byte array, without pulling in a library. */
function toBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

/**
 * The transpiler's bare ABI: an artifact's JSON in, the transpiled artifact's JSON out.
 *
 * `avmt_ok` is read from the exports directly rather than through `callWithString`'s
 * `resultIsError` hook, because the two have opposite polarity — `avmt_ok()` is 1 on SUCCESS —
 * and passing it as an is-error predicate would report every success as a failure. Stated
 * because it is the kind of inversion that reads correct at the call site.
 */
function transpiler(host) {
  return {
    host,
    run(artifactJson) {
      const result = host.callWithString('avmt_transpile', artifactJson, {
        alloc: 'avmt_alloc',
        free: 'avmt_free',
        resultLen: 'avmt_result_len',
      });
      const ok = host.exports.avmt_ok();
      return { ok, bytes: result.bytes, text: result.text() };
    },
  };
}

let host;
let fixtures = [];

try {
  say('fetching the transpiler module…');
  const moduleBytes = new Uint8Array(
    await (await fetch('./assets/avm_transpiler_wasm.wasm')).arrayBuffer(),
  );
  const moduleSha = await sha256Hex(moduleBytes);

  say('instantiating…');
  const instantiations0 = globalThis.__avmtInstantiations ?? 0;
  host = await instantiateBare(moduleBytes, 'avm_transpiler_wasm');
  globalThis.__avmtInstantiations = instantiations0 + 1;

  fixtures = await (await fetch('./assets/fixtures.json')).json();

  // The host module's digest, taken IN THE PAGE over the bytes the page received. Added by M31's
  // review: the check used to compare the repository's copy against a digest the RUNNER took of
  // the copy it had just made itself, which is equal by construction — two readings of one file
  // with a `cp` between them, which is the shape M30's review found green over a mismatch. This
  // one crosses HTTP, the same way `inputSha256` does for the fixtures.
  const hostBytes = new Uint8Array(await (await fetch('./wasm_host.mjs')).arrayBuffer());

  const t = transpiler(host);

  globalThis.avmtDemo = {
    modules: {
      bytes: moduleBytes.length,
      sha256: moduleSha,
      hostBytes: hostBytes.length,
      hostSha256: await sha256Hex(hostBytes),
      declaredImports: host.declaredImports,
      declaredImportCount: host.declaredImports.length,
    },

    /** The imports the module actually CALLED. Read AFTER the arms, never before. */
    reachedImports: () => host.reachedImports.slice(),

    instantiations: () => globalThis.__avmtInstantiations,

    /**
     * Transpile every fixture, in ONE page load with ONE instantiation.
     *
     * The artifact text is fetched and hashed HERE, so a check comparing the browser's input
     * digest against the one on disk is comparing two independently produced values rather
     * than two readings the same process took of one file — the shape M30's review found
     * green over a mismatch.
     */
    async transpileArms() {
      const out = {};
      for (const name of fixtures) {
        const artifactText = await (await fetch(`./assets/artifacts/${name}.json`)).text();
        const inputBytes = new TextEncoder().encode(artifactText);
        const t0 = performance.now();
        const r = t.run(artifactText);
        const t1 = performance.now();
        out[name] = {
          ok: r.ok,
          inputBytes: inputBytes.length,
          inputSha256: await sha256Hex(inputBytes),
          outputBytes: r.bytes.length,
          outputSha256: await sha256Hex(r.bytes),
          ms: t1 - t0,
          // The whole output, so a check can read the ARTEFACT rather than the producer's
          // report about it. These are kilobytes, not megabytes.
          outputBase64: toBase64(r.bytes),
          head: r.ok === 1 ? r.text.slice(0, 80) : r.text.slice(0, 200),
        };
      }
      return out;
    },

    /**
     * The refusal path, exercised rather than described: bytes that are not a contract
     * artifact must come back `ok === 0` with the transpiler's own message, and must NOT come
     * back as a plausible artifact.
     */
    async refusalArms() {
      const arms = {};
      const cases = {
        notJson: 'this is not json at all',
        jsonButNotAContract: '{"hello":"world"}',
        alreadyTranspiled: JSON.stringify({ transpiled: true, name: 'X', functions: [] }),
        empty: '',
      };
      for (const [name, text] of Object.entries(cases)) {
        const r = t.run(text);
        arms[name] = { ok: r.ok, message: r.text.slice(0, 200), bytes: r.bytes.length };
      }
      return arms;
    },
  };

  say(`ready — ${fixtures.length} fixtures, module ${moduleBytes.length} bytes`);
  outEl.textContent = `module sha256 ${moduleSha}\ndeclared imports ${host.declaredImports.length}\n`;
  globalThis.avmtDemoReady = true;
} catch (err) {
  globalThis.avmtDemoError = String(err && err.stack ? err.stack : err);
  say(`failed: ${err}`);
}
