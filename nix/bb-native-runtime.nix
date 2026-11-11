# Byte-preserving runtime for the existing locked native differential oracle.
{ lib, stdenv, stdenvNoCC, fetchurl, writeShellScriptBin }:
let
  locked = (builtins.fromJSON (builtins.readFile ../diffsim/package-lock.json)).packages."node_modules/@aztec/bb.js";
  buildDirectory =
    if stdenv.hostPlatform.isx86_64 then "amd64-linux"
    else if stdenv.hostPlatform.isAarch64 then "arm64-linux"
    else throw "bb native runtime: unsupported original Linux architecture";
  payload = stdenvNoCC.mkDerivation {
    pname = "aztec-bb-original-payload";
    inherit (locked) version;
    src = fetchurl { url = locked.resolved; hash = locked.integrity; };
    dontConfigure = true;
    dontBuild = true;
    # This archive is the original executable, not a new ELF build. Preserve
    # every byte rather than stripping or changing its interpreter/RPATH.
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      test -f build/${buildDirectory}/bb
      mkdir -p "$out/libexec"
      cp -p build/${buildDirectory}/bb "$out/libexec/bb-original"
      test -x "$out/libexec/bb-original"
      cmp build/${buildDirectory}/bb "$out/libexec/bb-original"
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
in
assert stdenv.hostPlatform.isLinux;
assert locked.version == "5.0.0-nightly.20260626";
writeShellScriptBin "bb" ''
  exec ${stdenv.cc.bintools.dynamicLinker} \
    --library-path ${lib.makeLibraryPath [ stdenv.cc.libc ]} \
    ${payload}/libexec/bb-original "$@"
''
