# vm2wasm — the C++ AVM on WebAssembly

Evidence base for the claim that Aztec's real C++ AVM (`vm2_sim`) compiles to
`wasm32-wasip1`, executes correctly there, and produces results **byte-identical to
native x86-64** under both wasmtime and V8.

Narrative and full numbers: `../scratchpad/campaign/vm2-wasm-spike-log.md`.
The reviewable upstream patch series distilled from this lives in
`codetracer-specs/upstream-bugs/aztec-*` (see the index there for order).

## Upstream base

Everything here is against `AztecProtocol/aztec-packages` commit **`233d8e0993`**
(v5.2.0 era, 2026-08). A clone is at `../upstream/aztec-packages` (gitignored).

## What is committed, and what is not

| path | committed | note |
|---|---|---|
| `spike.patch` | yes | **The complete source change set**, `git format-patch` against `233d8e0993`. Applies with `git am`. |
| `spike.diff` | yes | The original spike-produced diff, kept for provenance. Not `git`-format (no `diff --git` headers) — use `spike.patch` to apply. |
| `avm.wasm` | yes | Standalone AVM reactor, `-Oz`, stripped. 1,259,737 bytes raw; `gzip -9 -c avm.wasm \| wc -c` → 272,661 (the "266 KiB gzipped" number). |
| `native.results`, `wasm.results`, `node.results` | yes | The three transcripts that match. `diff` any pair. |
| `probe/exc.cpp`, `probe/exc33.wasm`, `probe/exc33b.wasm`, `probe/run_node.mjs` | yes | The C++-exceptions-on-wasm probe and the V8 runner. `exc33.wasm` uses LLVM's default *legacy* EH encoding (V8 rejects it); `exc33b.wasm` adds `-mllvm -wasm-use-legacy-eh=false` (V8 accepts it). The pair is the evidence for that flag. |
| `SHA256SUMS` | yes | Hashes of the committed binaries and of the excluded inputs, so provenance survives. |
| `src/barretenberg`, `src/ipc-runtime` | **no** | Full copies of the upstream trees (365 MiB incl. two build directories). Every delta is in `spike.patch`; see "Reconstructing" below. |
| `src/barretenberg/cpp/build-{wasm-avm,native-avm-spike}` | **no** | 311 MiB of CMake/Ninja build output, fully regenerable. |
| `wasi-sdk-33/` | **no** | 642 MiB vendored toolchain tarball. Pinned reproducibly instead by `../nix/wasi-sdk.nix` (with release hashes for all four host platforms) and exposed by `../flake.nix` as `packages.wasi-sdk` / the dev shell's `WASI_SDK_PATH`. That derivation *is* the toolchain evidence; a copy of the unpacked tree adds nothing. |
| `shims/lmdb.h` | **no** | Byte-identical to the stock LMDB header that barretenberg's own build already fetches (`build-*/\_deps/lmdb/src/lmdb_repo/libraries/liblmdb/lmdb.h`) — third-party code under the OpenLDAP Public License, recoverable from any barretenberg native build. It was only ever a spike stand-in for the `crypto_merkle_tree`/LMDB module split, which the upstream patch series does properly. Its hash is in `SHA256SUMS`. |
| `avm.wasm.gz` | **no** | `gzip -9 -c avm.wasm` reproduces it byte-for-byte (272,661); verified before deletion. |

Nothing excluded is irrecoverable: the two trees come from a public upstream commit
plus `spike.patch`, the toolchain from a pinned Nix derivation, the LMDB header from
barretenberg's own dependency fetch, and the build directories from running the build.

## Reconstructing the working tree

```sh
cd aztec-avm-runtime
git -C upstream/aztec-packages worktree add /tmp/vm2wasm-tree 233d8e0993
cd /tmp/vm2wasm-tree && git am < .../vm2wasm/spike.patch
```

Then, from `nix develop` (which supplies wasi-sdk 33 and pins `WASI_SDK_PATH`):

```sh
cd /tmp/vm2wasm-tree/barretenberg/cpp
# aztec_constants.hpp is generated, not checked in:
node ../../protocol/constants-codegen/src/cli.ts --cpp src/barretenberg/aztec/aztec_constants.hpp \
     --selection ../../protocol/constants-codegen/cpp.json
cmake --preset wasm-avm         && ninja -C build-wasm-avm avm_spike_runner avm.wasm
cmake --preset native-avm-spike && ninja -C build-native-avm-spike avm_spike_runner
build-native-avm-spike/bin/avm_spike_runner    > native.out
wasmtime run build-wasm-avm/bin/avm_spike_runner > wasm.out
node .../vm2wasm/probe/run_node.mjs build-wasm-avm/bin/avm_spike_runner > node.out
```

The `.results` sections of those three outputs are what is committed here.

## The exception probe, standalone

```sh
wasmtime run probe/exc33b.wasm       # prints "reverted: out of gas" then "survived"
node   --experimental-wasi-unstable-preview1 probe/run_node.mjs probe/exc33b.wasm
wasmtime run probe/exc33.wasm        # runs, but V8 rejects the legacy try/catch encoding
```

`probe/exc.cpp` is 544 bytes and rebuilds in one command:

```sh
$WASI_SDK_PATH/bin/clang++ --target=wasm32-wasip1 -O2 -fwasm-exceptions \
    -mllvm -wasm-use-legacy-eh=false probe/exc.cpp -lunwind -o probe/exc33b.wasm
```

Against wasi-sdk **27** — the version upstream pins — the same command fails to link
(`undefined symbol: __cxa_allocate_exception`, `__cxa_throw`,
`_Unwind_CallPersonality`), because that sysroot's `libc++abi.a` is built
`-fno-exceptions`. That is the whole reason `BB_NO_EXCEPTIONS` and
`common/try_catch_shim.hpp` exist.

## Spike-only code in `spike.patch`

`spike.patch` is the change set *as executed*, not an upstream proposal. Two of its
directories exist only to measure things and are not offered upstream:

- `cpp/src/barretenberg/vm2_spike/` — the differential driver (seven AVM programs,
  built from identical sources for native and wasm).
- `cpp/src/barretenberg/vm2_reactor/` — the standalone size probe that produces
  `avm.wasm`.

It also carries a `CMakePresets.json` diff that is ~95% reformatting noise, and a
header-only-`crypto_merkle_tree`-plus-stray-`lmdb.h` hack that the upstream series
replaces with a real module split. Read `codetracer-specs/upstream-bugs/aztec-*` for
what is actually being proposed.
