{
  description = "Aztec AVM Runtime — browser-capable public-transaction execution, and its differential oracle against the native AVM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          wasi-sdk = pkgs.callPackage ./nix/wasi-sdk.nix { };
        in
        {
          packages.wasi-sdk = wasi-sdk;

          # The version barretenberg currently pins. Not in any dev shell and not
          # used by any build here — it is the negative control the M4 checks
          # execute against (it cannot link C++ exceptions) and the toolchain the
          # "before" half of the barretenberg.wasm comparison is built with.
          packages.wasi-sdk-27 = pkgs.callPackage ./nix/wasi-sdk.nix { version = "27.0"; };

          devShells.default = pkgs.mkShell {
            packages = [
              # TypeScript orchestration and the test suites. aztec-packages'
              # .nvmrc pins v24 and its packageManager field pins yarn 4.x.
              pkgs.nodejs_24
              pkgs.yarn-berry_4

              # `tsc`, for the node host's type check. It is here rather than in an npm
              # devDependency because the trap-versus-revert distinction is enforced by the TYPE
              # SYSTEM, so the type checker is part of the toolchain the same way clang is — and a
              # checkout should be able to run that check with no `npm install` and no network.
              # node-host/ declares the three Node APIs it uses itself, so `@types/node` is not
              # needed either.
              pkgs.typescript

              # The wasm AVM toolchain. wasi-sdk 33 is load-bearing — see
              # nix/wasi-sdk.nix for why 27 (barretenberg's pin) cannot work.
              wasi-sdk
              pkgs.wasmtime
              pkgs.binaryen # wasm-opt, for size work on avm.wasm
              pkgs.wabt # wasm2wat / wasm-objdump, for inspecting exports

              # Native barretenberg builds (the differential oracle's other half)
              # and the wasm configure step, which still runs cmake/ninja.
              pkgs.cmake
              pkgs.ninja
              pkgs.clang_20
              pkgs.ccache
              pkgs.pkg-config

              # Utilities the spike scripts and bootstrap.sh reach for.
              pkgs.git
              pkgs.jq
              pkgs.python3
              pkgs.gnused
              pkgs.parallel
            ];

            # barretenberg's wasm toolchain file and its bootstrap scripts both
            # read WASI_SDK_PREFIX; CMAKE_TOOLCHAIN_FILE consumers read
            # WASI_SDK_PATH. Export both so neither spelling has to be guessed.
            WASI_SDK_PATH = "${wasi-sdk}";
            WASI_SDK_PREFIX = "${wasi-sdk}";

            # The differential oracle loads @aztec/bb.js's prebuilt NAPI AVM
            # (nodejs_module.node) out of an npm tarball. It is linked against a
            # distro libstdc++, which nixpkgs' node does not put on the search
            # path.
            LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
              pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]
            );

            shellHook = ''
              # ---- compiler cache -------------------------------------------------
              # The same six exports the fork's shell makes, with the same defaults and
              # the same `:-` overridability, so a build that moves from one shell to
              # the other does not silently lose the cache. The reasoning is written out
              # once, in aztec-packages/flake.nix; the short version is that a cache on
              # PATH but not on the compiler launcher path caches nothing while looking
              # solved, that CCACHE_BASEDIR is what lets one upstream translation unit
              # built in two different work directories share one entry, and that
              # `%compiler% --version` is used instead of the `mtime` default because
              # every binary in /nix/store has mtime 1970.
              export CCACHE_DIR="''${CCACHE_DIR:-$HOME/.cache/ccache}"
              export CCACHE_BASEDIR="''${CCACHE_BASEDIR:-$HOME}"
              export CCACHE_MAXSIZE="''${CCACHE_MAXSIZE:-60G}"
              export CCACHE_COMPILERCHECK="''${CCACHE_COMPILERCHECK:-%compiler% --version}"
              export CMAKE_C_COMPILER_LAUNCHER="''${CMAKE_C_COMPILER_LAUNCHER:-ccache}"
              export CMAKE_CXX_COMPILER_LAUNCHER="''${CMAKE_CXX_COMPILER_LAUNCHER:-ccache}"

              echo "aztec-avm-runtime: node $(node --version), yarn $(yarn --version), wasi-sdk $(cat ${wasi-sdk}/VERSION | head -1), ccache $(ccache --version | head -1 | awk '{print $3}') at $CCACHE_DIR"
            '';
          };
        };
    };
}
