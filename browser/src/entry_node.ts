// `aztec-avm-runtime/node` — DD-5's Node entry point. THE SUPERSET, AND ONLY BY CONVENIENCES.
//
// ===========================================================================================
// THE RULE, AND HOW THIS FILE IS BUILT TO MAKE IT CHECKABLE.
// ===========================================================================================
//
// DD-5: "Every feature must work in the browser; Node may add *conveniences* (fs, process args),
// never *capabilities*."
//
// "Convenience" and "capability" are easy words to argue about, so this file makes the distinction
// mechanical instead:
//
//   * It `export *`s the browser entry. Every name there is here, by construction rather than by
//     a list somebody has to keep in step.
//   * Everything it ADDS is declared in `NODE_CONVENIENCES` below, each with the browser call it
//     saves and nothing else. `verify_browser_entry_points_are_dd5_shaped` computes
//     (node exports) − (browser exports) FROM THE BUILT BUNDLES and requires the difference to
//     equal that list exactly — so an addition nobody declared fails, and a declaration for
//     something that is not there fails too.
//   * Each addition is a THIN WRAPPER over a browser function, in this file, visible in one
//     screen. `openAvmRuntimeFromFile` is `openAvmRuntime` with a `fetch` that reads a file;
//     `saveSnapshot` is `JSON.stringify(runtime.exportSnapshot())` and `writeFile`. There is no
//     third path into the runtime and no code here that the browser entry could not have run.
//
// The failure this prevents is the one upstream had: a Node path that grows a feature, a browser
// path that quietly cannot do it, and a browser story that is dead within a month. M28 is the gate
// that keeps checking; this file is what makes the gate cheap to write.

import { readFile, writeFile } from 'node:fs/promises';

import { openAvmRuntime, type OpenOptions, type OpenedRuntime } from './runtime.ts';
import type { AvmRuntime } from '../../orchestration/src/index.ts';

export * from './entry_browser.ts';

/**
 * The declared conveniences, and the browser call each one saves.
 *
 * Read by `verify_browser_entry_points_are_dd5_shaped`, which compares it against the DIFFERENCE
 * of the two built bundles' export sets. It is deliberately a value rather than a comment: a
 * comment cannot be compared with a bundle.
 */
export const NODE_CONVENIENCES: Readonly<Record<string, string>> = Object.freeze({
  openAvmRuntimeFromFile:
    'openAvmRuntime with a fetch that reads the module off disk. A page fetches it over HTTP.',
  readModuleFile: 'readFile, as a Response, so the browser loader is reached unchanged.',
  saveSnapshot: 'writeFile of runtime.exportSnapshot(). A page hands the same object to a download.',
  loadSnapshot: 'readFile into runtime.importSnapshot(). A page reads the same object from a file input.',
  NODE_CONVENIENCES: 'this declaration itself, so the check can read it out of the bundle.',
});

/** `readFile` dressed as a `fetch`, so the BROWSER loader — gate and all — is what runs. */
export async function readModuleFile(path: string): Promise<Response> {
  const bytes = await readFile(path);
  return new Response(new Uint8Array(bytes), { headers: { 'content-type': 'application/wasm' } });
}

/**
 * Open a runtime against a module on disk.
 *
 * A CONVENIENCE AND NOT A CAPABILITY, and the implementation is the evidence: it calls
 * `openAvmRuntime` — the browser's function — with a one-line `fetch`. There is no Node-only code
 * path into the runtime, which is what would make this a capability.
 */
export function openAvmRuntimeFromFile(
  path: string,
  options: Omit<OpenOptions, 'moduleUrl' | 'fetch'>,
): Promise<OpenedRuntime> {
  return openAvmRuntime({
    ...options,
    moduleUrl: path,
    fetch: (input: RequestInfo | URL) => readModuleFile(String(input)),
  } as OpenOptions);
}

/** M23's replay-log snapshot, written to a file. The object is the browser's; the file is Node's. */
export async function saveSnapshot(runtime: AvmRuntime, path: string): Promise<number> {
  const json = JSON.stringify(runtime.exportSnapshot(), (_k, v) =>
    typeof v === 'bigint' ? v.toString() : v,
  );
  await writeFile(path, json, 'utf8');
  return json.length;
}

/** The other direction. `importSnapshot`'s own refusals are unchanged and are what validate it. */
export async function loadSnapshot(
  runtime: AvmRuntime,
  path: string,
): Promise<ReturnType<AvmRuntime['importSnapshot']>> {
  return runtime.importSnapshot(JSON.parse(await readFile(path, 'utf8')) as never);
}
