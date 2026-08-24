// The Node APIs this package uses, declared here rather than depended on.
//
// WHY NOT `@types/node`. Everything else in this repo's dev shells comes from the pinned nix
// toolchain; `@types/node` would come from npm, would be the only npm dependency the node host
// has, and would put a network fetch between a clean checkout and `tsc`. What is actually used is
// three modules and two globals, so they are declared.
//
// WHAT HOLDS THE SUBSET HONEST, stated as what actually runs rather than as a check name: this
// file is in `tsconfig.json`'s `include`, and `verify_node_v8_accepts_module` type-checks the
// WHOLE package with it (`tsc -p tsconfig.json`, section 2) under `strict`, `skipLibCheck: false`
// and `erasableSyntaxOnly`. So a source that imports a Node module this file does not declare
// fails to compile, and a declaration here that does not match how the sources use it fails too.
// The converse — a declaration this package no longer uses — is NOT asserted by anything and is
// dead weight rather than a correctness risk.
//
// `WebAssembly`, `TextDecoder`, `TextEncoder` and `console` come from TypeScript's own bundled
// `lib.dom.d.ts` / `lib.es2022.d.ts` and are deliberately NOT restated here.

declare module 'node:wasi' {
  /** Node's own WASI preview1 implementation. It supplies all eleven of avm.wasm's WASI imports. */
  export interface WASIOptions {
    version: 'preview1';
    args?: readonly string[];
    env?: Readonly<Record<string, string | undefined>>;
    preopens?: Readonly<Record<string, string>>;
    returnOnExit?: boolean;
  }
  export class WASI {
    constructor(options: WASIOptions);
    /** The import object. Its only member this package reads is `wasi_snapshot_preview1`. */
    getImportObject(): { wasi_snapshot_preview1: Record<string, (...args: number[]) => number> };
    /** Runs `_initialize` on a reactor. Throws if the module has a `_start` instead. */
    initialize(instance: WebAssembly.Instance): void;
    /** Runs `_start` on a command. Not used by this package; declared so misuse is a type error. */
    start(instance: WebAssembly.Instance): number;
  }
}

declare module 'node:fs/promises' {
  export function readFile(path: string): Promise<Uint8Array<ArrayBuffer>>;
  export function readFile(path: string, encoding: 'utf8'): Promise<string>;
}

declare module 'node:process' {
  interface WriteStream {
    write(chunk: string, callback?: () => void): boolean;
  }
  interface HrTime {
    bigint(): bigint;
  }
  interface Process {
    argv: string[];
    /** e.g. `v24.19.0`. Read by the engine probe so a finding names the engine it is about. */
    version: string;
    versions: Record<string, string | undefined>;
    env: Record<string, string | undefined>;
    exitCode: number | undefined;
    stdout: WriteStream;
    stderr: WriteStream;
    hrtime: HrTime;
    exit(code?: number): never;
  }
  const process: Process;
  export default process;
}
