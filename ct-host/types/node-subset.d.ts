// The Node APIs this package uses, declared here rather than depended on.
//
// node-host's rule and node-host's reason: everything else in this repo's dev shells comes from
// the pinned nix toolchain, and `@types/node` would put a network fetch between a clean checkout
// and `tsc`. What this package actually uses is two modules, so two modules are declared.
//
// THE SUBSET IS HELD HONEST BY THE SAME MECHANISM: this file is in `tsconfig.json`'s `include`
// and `verify_ct_writer_wasm_zero_imports` type-checks the WHOLE package with it under `strict`,
// `skipLibCheck: false` and `erasableSyntaxOnly`. A source importing a Node module this file does
// not declare fails to compile.
//
// `WebAssembly`, `DataView`, `TextEncoder`, `TextDecoder` and `console` come from TypeScript's own
// bundled libs and are deliberately NOT restated — this package is browser-reachable and must not
// acquire a Node-shaped declaration for anything a browser also has.

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
