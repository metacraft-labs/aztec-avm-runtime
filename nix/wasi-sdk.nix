# wasi-sdk, from the upstream release tarballs. Defaults to 33.
#
# Why a hand-rolled derivation: nixpkgs has no `wasi-sdk` attribute at all (only
# `wasilibc`, and a `pkgsCross.wasi32` toolchain whose libc++abi is not built with
# exception support). Version 33 is not optional for this project:
#
#   wasi-sdk 27 — which barretenberg currently pins — CANNOT COMPILE C++ EXCEPTIONS.
#   The AVM signals reverts by throwing, so `-fno-exceptions` (what upstream forces
#   on every wasm build) is not an option for us. wasi-sdk 33 ships an exception-
#   enabled sysroot and is what makes the wasm AVM build possible at all.
#
# 27 is nevertheless BUILDABLE from here, by passing `version = "27.0"`. It exists
# for one purpose: the M4 verification set has to demonstrate the "cannot" above by
# execution rather than by citation, and it has to build `barretenberg.wasm` with
# the toolchain upstream actually pins so the two artefacts can be compared. Both
# are negative/differential evidence for the bump; nothing in this repo's own build
# uses 27.
#
# The tarballs are relocatable: bin/clang.cfg points the sysroot at
# `<CFGDIR>/../share/wasi-sysroot`, so no path rewriting is needed beyond
# autoPatchelf on Linux.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  stdenv,
  ncurses,
  zlib,
  libxml2,
  version ? "33.0",
}:

let
  # sha256 of each official release tarball, obtained with `nix store prefetch-file`.
  releases = {
    "33.0" = {
      x86_64-linux = {
        asset = "x86_64-linux";
        hash = "sha256-C6i1v66yrfPym6tYQdds9TGKuOFkLqGV+IuroavUe84=";
      };
      aarch64-linux = {
        asset = "arm64-linux";
        hash = "sha256-T5juc4x6u0XIGpTRRh/FPMVp0c0BSYlRyBhNhBoCeEQ=";
      };
      x86_64-darwin = {
        asset = "x86_64-macos";
        hash = "sha256-GPPyAbqXNOakRVsLZBBpA5WlXp/6n29QZvZgg6lLk7M=";
      };
      aarch64-darwin = {
        asset = "arm64-macos";
        hash = "sha256-hcmXomZerZFnO1u4i30N8/yJAN87+iRPcg1HgYe73Hg=";
      };
    };
    "27.0" = {
      x86_64-linux = {
        asset = "x86_64-linux";
        hash = "sha256-t9TZRMiFA+TyHYSvB6wpPjRAsbYhC/1/544K/ZLCO8I=";
      };
      aarch64-linux = {
        asset = "arm64-linux";
        hash = "sha256-TPTFU8RkDmPngEQhRvh9g/3/Vzf5iMBqbjsvAijjdmU=";
      };
      x86_64-darwin = {
        asset = "x86_64-macos";
        hash = "sha256-Fj39R/mJsaaCdEwa4fDgmoP/XEu6ydzYVGkJq1TNpaE=";
      };
      aarch64-darwin = {
        asset = "arm64-macos";
        hash = "sha256-BVw9wnZncsOOcaBdNT41wyLHssZFijaiaoNvmAilUPg=";
      };
    };
  };

  sources = releases.${version} or (throw "wasi-sdk: no recorded release ${version}");
  tag = "wasi-sdk-${lib.versions.major version}";

  src =
    let
      s =
        sources.${stdenvNoCC.hostPlatform.system}
          or (throw "wasi-sdk ${version}: no release tarball for ${stdenvNoCC.hostPlatform.system}");
    in
    fetchurl {
      url = "https://github.com/WebAssembly/wasi-sdk/releases/download/${tag}/wasi-sdk-${version}-${s.asset}.tar.gz";
      inherit (s) hash;
    };
in
stdenvNoCC.mkDerivation {
  pname = "wasi-sdk";
  inherit version src;

  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [
    stdenv.cc.cc.lib # libstdc++, libgcc_s
    ncurses # libtinfo, for clang's diagnostics
    zlib
    libxml2
  ];

  # The tarball ships prebuilt LLVM shared objects; nothing to strip or rebuild.
  dontStrip = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out/"
    runHook postInstall
  '';

  # `clang --version` must work and the wasi sysroot must be found through the
  # relocatable clang.cfg. If either regresses, the build fails here rather than
  # halfway through a barretenberg compile.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/clang" --version
    test -d "$out/share/wasi-sysroot/include/wasm32-wasip1"
    runHook postInstallCheck
  '';

  passthru.sysroot = "share/wasi-sysroot";

  meta = {
    description = "WASI SDK ${version}: clang/lld/wasi-libc toolchain for WebAssembly";
    homepage = "https://github.com/WebAssembly/wasi-sdk";
    license = lib.licenses.asl20;
    platforms = lib.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
