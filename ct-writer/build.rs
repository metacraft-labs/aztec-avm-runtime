//! Build the Nim writer — Path B — into a static library this crate links.
//!
//! # What this does, and what it deliberately does not
//!
//! Under the default feature set this script does **nothing at all**: Path A is pure Rust and
//! needs no build step, so a `cargo build` of the shipped configuration is unchanged by this
//! file's existence. Everything below runs only when `path-b` is enabled.
//!
//! Under `path-b` it performs the four steps M41 names, in order:
//!
//! 1. **Materialise** `codetracer-trace-format-nim` at the revision `pins.json` declares as the
//!    `trace_format_nim_writer` anchor, out of that repository's OBJECT STORE.
//! 2. **Cross-build libzstd** for `wasm32-unknown-unknown`. `zstd_bindings.nim` carries an
//!    unconditional `{.passL: "-lzstd".}`, so the writer needs a real libzstd rather than a
//!    binding stub.
//! 3. **Run `nim c --compileOnly`** over `src/codetracer_trace_writer_ffi.nim` and compile the C
//!    it emits, using the compile commands NIM ITSELF wrote into the build plan.
//! 4. **Archive** the objects and tell cargo to link them.
//!
//! # Why the dependency comes out of the object store and not out of a worktree
//!
//! `git archive <rev>` reads the object database. The trap this closes is a REVISION difference,
//! not a location one: the sibling checkout is a working tree that other work moves and edits, and
//! copying from it would silently pick up whatever it currently holds. This is
//! `verification/build_ct_writer_wasm.sh`'s rule for the Rust half, applied to the Nim half by the
//! same argument.
//!
//! The revision is NOT declared here. `pins.json` is the single authority for every pin this repo
//! depends on (`PINS.md`), and a sha1 typed into a build script is a second authority by another
//! name.
//!
//! # Why the toolchain is resolved through `--inputs-from`
//!
//! `nix build 'nixpkgs#clang'` resolves against whatever the invoking user's flake registry
//! happens to point at, which is a different clang on two machines and a different clang on one
//! machine a month apart. `nix build --inputs-from <repo> 'nixpkgs#clang'` resolves against the
//! nixpkgs THIS REPOSITORY's `flake.lock` pins. The two answer differently here — measured, not
//! assumed — which is what makes the second one a pin rather than a spelling.
//!
//! `nim` is the exception and is taken from `PATH`, because no nixpkgs attribute names the
//! compiler this workspace builds Nim code with. It is not therefore unpinned: the version is
//! declared in `pins.json` under `toolchain.nim` and this script REFUSES a different one rather
//! than building with it. A build that silently used another compiler is the failure the
//! declaration exists to prevent.

use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/nim_host_shim.c");
    println!("cargo:rerun-if-env-changed=CT_TRACE_FORMAT_NIM_REPO");
    // CCP-7: the two hooks that let a SANDBOX build Path B. Declared here so a
    // change to any of them re-runs this script, which is the whole point of
    // them being environment and not arguments.
    for k in [
        "CT_TRACE_FORMAT_NIM_SRC",
        "CT_TRACE_FORMAT_NIM_SRC_REV",
        "CT_WASM_CLANG",
        "CT_WASM_LLVM_AR",
        "CT_WASM_LLD_BIN",
        "CT_WASM_SYSROOT_INCLUDE",
        "CT_ZSTD_SRC",
        "CT_NIM_EXTRA_PATHS",
    ] {
        println!("cargo:rerun-if-env-changed={k}");
    }

    if std::env::var("CARGO_FEATURE_PATH_B").is_err() {
        // Path A only. Nothing to build, and saying so is cheaper than a comment.
        return;
    }

    let manifest = PathBuf::from(env("CARGO_MANIFEST_DIR"));
    let repo_root = manifest
        .parent()
        .expect("ct-writer has a parent")
        .to_path_buf();
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("pins.json").display()
    );

    let pins = Pins::read(&repo_root.join("pins.json"));
    let nim_src = materialise(&manifest, &repo_root, &pins);
    require_nim_version(&pins);
    // READ AND VALIDATED HERE, NOT WHERE IT IS USED. `nim_static_lib` runs
    // AFTER the libzstd cross-build, so validating these paths at the point of
    // use would spend that whole build before reporting a typo in an
    // environment variable — and, on a host where the zstd build cannot
    // succeed, would never report it at all. Measured: with a stand-in clang
    // the zstd step failed first and the bad path went unmentioned.
    let nim_paths = nim_extra_paths();

    let out = PathBuf::from(env("OUT_DIR"));
    let target = env("TARGET");

    if !target.starts_with("wasm32") {
        // Path B is a wasm32 configuration and refusing here is the honest answer rather than a
        // limitation. The Nim writer builds for a host perfectly well — `codetracer_trace_writer_nim`
        // does exactly that — but a SECOND host toolchain in this file would be a second thing to
        // keep true, and nothing in this runtime consumes a native Path B. The comparison M41 owes
        // is between the two WASM modules, driven by one host script, and that comparison is
        // stronger for both arms sharing a target: a difference it finds is the writer's and cannot
        // be the target's.
        die(&format!(
            "the `path-b` feature builds only for wasm32; this build targets {target}. \
             Build the module with verification/build_ct_writer_wasm.sh --path-b, or drop the \
             feature for a host build."
        ));
    }

    let tools = Toolchain::resolve(&repo_root);
    let zstd = build_zstd_wasm(&out, &tools);
    let flags = format!(
        "--target=wasm32-unknown-unknown -nostdlib -isystem {} -I{}/lib",
        tools.sysroot_include.display(),
        tools.zstd_src.display()
    );
    nim_static_lib(&out, &nim_src, &tools, &flags, &nim_paths);
    compile_shim(&out, &tools, &flags);
    println!("cargo:rustc-link-search=native={}", zstd.display());

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=ct_nim_writer");
    println!("cargo:rustc-link-lib=static=ct_nim_host_shim");
    println!("cargo:rustc-link-lib=static=zstd");
}

fn env(k: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| panic!("build.rs: {k} is not set"))
}

fn die(msg: &str) -> ! {
    panic!("ct-writer build.rs: {msg}");
}

fn run(what: &str, cmd: &mut Command) -> String {
    let out = cmd
        .output()
        .unwrap_or_else(|e| die(&format!("{what} could not be spawned: {e}")));
    if !out.status.success() {
        die(&format!(
            "{what} failed ({}):\n{}\n{}",
            out.status,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

// ---------------------------------------------------------------------------
// pins.json
// ---------------------------------------------------------------------------

struct Pins {
    writer_commit: String,
    nim_version: String,
}

impl Pins {
    fn read(path: &Path) -> Pins {
        let text = std::fs::read_to_string(path)
            .unwrap_or_else(|e| die(&format!("pins.json could not be read: {e}")));
        Pins {
            writer_commit: scalar_after(&text, "\"trace_format_nim_writer\"", "\"commit\"")
                .unwrap_or_else(|| {
                    die("pins.json declares no anchors.trace_format_nim_writer.commit")
                }),
            nim_version: scalar_after(&text, "\"nim\"", "\"version\"")
                .unwrap_or_else(|| die("pins.json declares no toolchain.nim.version")),
        }
    }
}

/// The first `"key": "value"` after `anchor`, read without a JSON dependency.
///
/// A hand-rolled scan rather than serde because this crate's dependency graph is the artefact
/// under measurement: a build-dependency is not linked into the module, but it is one more thing
/// that must resolve for the module to be built at all, and the whole point of this file is that
/// the module's inputs are enumerable. The scan is exact rather than fuzzy — it looks for the
/// anchor and then for the key, both quoted — and a miss is a hard failure rather than a default.
fn scalar_after(text: &str, anchor: &str, key: &str) -> Option<String> {
    let start = text.find(anchor)? + anchor.len();
    let rest = &text[start..];
    let k = rest.find(key)? + key.len();
    let after = &rest[k..];
    let colon = after.find(':')? + 1;
    let after = &after[colon..];
    let open = after.find('"')? + 1;
    let close = after[open..].find('"')?;
    Some(after[open..open + close].to_string())
}

// ---------------------------------------------------------------------------
// Materialising the Nim source
// ---------------------------------------------------------------------------

fn materialise(manifest: &Path, repo_root: &Path, pins: &Pins) -> PathBuf {
    let dest = manifest.join("build-wasm-deps/ctf-nim");
    let stamp = manifest.join("build-wasm-deps/ctf-nim-materialised-at");
    let rev = &pins.writer_commit;

    // ── A PLAIN SOURCE TREE, FOR A BUILD THAT HAS NO OBJECT STORE ──────────
    //
    // Everything below this block needs a `.git` directory, because `git
    // archive <rev>` reads the object database and that is deliberate: a
    // worktree is a thing other work moves, and the revision is the contract.
    // A NIX SANDBOX HAS NEITHER. A flake input materialises as a bare source
    // tree with no `.git` at all, and the sandbox has no network to clone one,
    // so the hook above cannot be satisfied there however it is pointed. That
    // is the whole reason BlockTracer's `ctWriterWasm` derivation — which
    // builds this crate to produce the module that writes every container the
    // site publishes — can only build Path A today, and therefore cannot ask
    // for a compact container at all: measured 2026-10-14, the module it
    // produces carries 38 ABI functions and no
    // `ct_writer_set_compact_threshold`.
    //
    // So: `CT_TRACE_FORMAT_NIM_SRC` names a tree that is ALREADY at the pinned
    // revision, and `CT_TRACE_FORMAT_NIM_SRC_REV` is the caller SAYING which
    // revision that is. Both are required together, and the revision is
    // CHECKED against `pins.json` rather than trusted: a tree cannot prove its
    // own provenance, so the declaration is what is held to the pin, and a
    // caller that declares the wrong one is refused here rather than
    // discovered in the module's bytes. `pins.json` stays the single
    // authority — this hook can only agree with it.
    //
    // It is not a way to build from an arbitrary tree. Passing the SRC hook
    // without the REV hook, or with a REV that is not the pin, fails.
    if let Ok(src) = std::env::var("CT_TRACE_FORMAT_NIM_SRC") {
        let declared = std::env::var("CT_TRACE_FORMAT_NIM_SRC_REV").unwrap_or_else(|_| {
            die("CT_TRACE_FORMAT_NIM_SRC is set and CT_TRACE_FORMAT_NIM_SRC_REV is not. \
                 A source tree cannot prove which revision it is, so the caller must say, \
                 and this build checks what it says against pins.json.")
        });
        if declared.trim() != rev {
            die(&format!(
                "CT_TRACE_FORMAT_NIM_SRC_REV says {declared:?}, and pins.json declares \
                 anchors.trace_format_nim_writer.commit {rev}. Refusing: the pin is the \
                 authority and this hook can only agree with it."
            ));
        }
        let src = PathBuf::from(&src);
        if !src.join("src/codetracer_trace_writer_ffi.nim").is_file() {
            die(&format!(
                "CT_TRACE_FORMAT_NIM_SRC is {}, which carries no \
                 src/codetracer_trace_writer_ffi.nim. That is the file nim compiles for Path \
                 B, so its absence is the whole build and is worth naming before the \
                 compiler does.",
                src.display()
            ));
        }
        if std::fs::read_to_string(&stamp)
            .map(|s| s.trim() == rev)
            .unwrap_or(false)
        {
            return dest;
        }
        let _ = std::fs::remove_dir_all(&dest);
        std::fs::create_dir_all(&dest).unwrap_or_else(|e| die(&format!("mkdir {dest:?}: {e}")));
        // `cp -R` AND THEN `chmod -R u+w`, because a nix store path is read-only
        // and nim writes its build plan beside the sources it reads. The `-m`
        // reasoning below applies here as well: `touch` the tree so a
        // re-materialisation at a different revision cannot leave the new
        // sources older than a previous revision's objects.
        let status = Command::new("bash")
            .arg("-c")
            .arg(format!(
                "set -euo pipefail\ncp -R {src}/. {dest}/\nchmod -R u+w {dest}\n\
                 find {dest} -exec touch {{}} +",
                src = shq(&src),
                dest = shq(&dest)
            ))
            .status()
            .unwrap_or_else(|e| die(&format!("cp of the Nim source could not be spawned: {e}")));
        if !status.success() {
            die(&format!(
                "copying the Nim source from {} failed",
                src.display()
            ));
        }
        std::fs::write(&stamp, format!("{rev}\n"))
            .unwrap_or_else(|e| die(&format!("stamp: {e}")));
        return dest;
    }

    let repo = std::env::var("CT_TRACE_FORMAT_NIM_REPO")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            repo_root
                .parent()
                .unwrap_or_else(|| die("this repository has no parent directory"))
                .join("codetracer-trace-format-nim")
        });
    if !repo.join(".git").exists() {
        die(&format!(
            "no codetracer-trace-format-nim checkout at {} (set CT_TRACE_FORMAT_NIM_REPO)",
            repo.display()
        ));
    }
    let have = Command::new("git")
        .args(["-C", &repo.display().to_string(), "cat-file", "-e"])
        .arg(format!("{rev}^{{commit}}"))
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !have {
        die(&format!(
            "{} does not have the pinned revision {rev}",
            repo.display()
        ));
    }

    if std::fs::read_to_string(&stamp)
        .map(|s| s.trim() == rev)
        .unwrap_or(false)
    {
        return dest;
    }
    let _ = std::fs::remove_dir_all(&dest);
    std::fs::create_dir_all(&dest).unwrap_or_else(|e| die(&format!("mkdir {dest:?}: {e}")));

    // `-m` — EXTRACT WITH THE CURRENT TIME, NOT THE ARCHIVE'S. `git archive` stamps every file
    // with the commit's timestamp, and `nim`'s and cargo's staleness checks are mtime-based, so a
    // re-materialisation at a different revision can leave the new sources OLDER than objects a
    // previous revision's build left behind. `build_ct_writer_wasm.sh` records the measurement
    // that established this on the Rust half.
    let status = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "set -o pipefail; git -C {repo} archive {rev} | tar -x -m -C {dest}",
            repo = shq(&repo),
            dest = shq(&dest)
        ))
        .status()
        .unwrap_or_else(|e| die(&format!("git archive could not be spawned: {e}")));
    if !status.success() {
        die(&format!("git archive of {rev} failed"));
    }
    std::fs::write(&stamp, format!("{rev}\n")).unwrap_or_else(|e| die(&format!("stamp: {e}")));
    dest
}

fn shq(p: &Path) -> String {
    format!("'{}'", p.display().to_string().replace('\'', r"'\''"))
}

fn require_nim_version(pins: &Pins) {
    let out = Command::new("nim")
        .arg("--version")
        .output()
        .unwrap_or_else(|e| {
            die(&format!(
                "`nim` is not on PATH and Path B cannot be built without it: {e}"
            ))
        });
    let text = String::from_utf8_lossy(&out.stdout);
    let first = text.lines().next().unwrap_or("");
    if !first.contains(&pins.nim_version) {
        die(&format!(
            "pins.json declares toolchain.nim.version {}, and `nim --version` says {first:?}. \
             Path B is not built with an undeclared compiler; move the pin or the PATH.",
            pins.nim_version
        ));
    }
}

// ---------------------------------------------------------------------------
// The nix-resolved toolchain
// ---------------------------------------------------------------------------

struct Toolchain {
    clang: PathBuf,
    llvm_ar: PathBuf,
    lld_bin: PathBuf,
    sysroot_include: PathBuf,
    zstd_src: PathBuf,
}

impl Toolchain {
    // ── WHY EACH PIECE CAN COME FROM THE ENVIRONMENT ───────────────────────
    //
    // `nix build --inputs-from <repo>` resolves against THIS repository's
    // flake.lock rather than the invoking user's registry, which is what makes
    // it a pin rather than a spelling, and that argument is unchanged and is
    // still the default.
    //
    // It cannot run inside a nix build. A sandbox has no daemon socket and no
    // network, so `Toolchain::resolve` aborts there before a single file is
    // compiled — which is why nothing that builds this crate hermetically can
    // select Path B, and therefore why the writer BlockTracer publishes with is
    // Path A and cannot emit a compact container.
    //
    // A derivation already has these five on hand: it declares them as inputs
    // and nix resolves them against ITS pinned nixpkgs, which is the same kind
    // of pin by the same argument. So each is overridable on its own, and each
    // that is not set is resolved exactly as before — a caller that sets none
    // sees no change, and `nix` is never spawned when all five are set, which
    // is the property the sandbox needs.
    //
    // EACH IS CHECKED RATHER THAN TAKEN. An override naming something absent
    // fails here, by name, instead of surfacing minutes later as `linker `lld`
    // not found` on the last step of a build that compiled everything — the
    // failure mode this file already records for a missing `lld`.
    fn resolve(repo_root: &Path) -> Toolchain {
        let p = |attr: &str| -> PathBuf {
            PathBuf::from(run(
                &format!("nix build {attr}"),
                Command::new("nix")
                    .args(["build", "--no-link", "--print-out-paths", "--inputs-from"])
                    .arg(repo_root)
                    .arg(attr),
            ))
        };
        // `nix build` is not spawned for an attribute that is overridden: the
        // closure is called inside the `unwrap_or_else`, not before it.
        let from_env = |var: &str, attr: &str, sub: &str| -> PathBuf {
            match std::env::var(var) {
                Ok(v) if !v.trim().is_empty() => {
                    let path = PathBuf::from(v.trim());
                    if !path.exists() {
                        die(&format!(
                            "{var} is {}, which does not exist. An override that names \
                             something absent is refused here rather than at the last link \
                             step of a build that compiled everything.",
                            path.display()
                        ));
                    }
                    path
                }
                _ => {
                    let out = p(attr);
                    if sub.is_empty() {
                        out
                    } else {
                        out.join(sub)
                    }
                }
            }
        };
        let clang = from_env("CT_WASM_CLANG", "nixpkgs#llvmPackages.clang-unwrapped", "bin/clang");
        let llvm_ar = from_env(
            "CT_WASM_LLVM_AR",
            "nixpkgs#llvmPackages.bintools-unwrapped",
            "bin/llvm-ar",
        );
        let lld_bin = from_env("CT_WASM_LLD_BIN", "nixpkgs#lld", "bin");
        let sysroot_include = from_env(
            "CT_WASM_SYSROOT_INCLUDE",
            "nixpkgs#pkgsCross.wasi32.wasilibc.dev",
            "include/wasm32-wasip1",
        );
        let zstd_src = from_env("CT_ZSTD_SRC", "nixpkgs#zstd.src", "");
        Toolchain {
            clang,
            llvm_ar,
            lld_bin,
            sysroot_include,
            zstd_src,
        }
    }
}


// ---------------------------------------------------------------------------
// libzstd, cross-built
// ---------------------------------------------------------------------------

fn build_zstd_wasm(out: &Path, t: &Toolchain) -> PathBuf {
    let dir = out.join("zstd");
    if dir.join("libzstd.a").is_file() {
        return dir;
    }
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| die(&format!("mkdir zstd: {e}")));
    // NO `-DZSTD_MULTITHREAD`. zstd tests that macro with `#ifdef` and not for a value, so
    // `-DZSTD_MULTITHREAD=0` ENABLES the multithreaded path rather than disabling it, and that
    // path does not link for wasm32-unknown-unknown at all.
    let script = format!(
        "set -euo pipefail\ncd {dir}\n{clang} --target=wasm32-unknown-unknown -nostdlib \
         -isystem {inc} -c -O2 -DZSTD_DISABLE_ASM=1 -DZSTD_LEGACY_SUPPORT=0 \
         -I{z}/lib -I{z}/lib/common -I{z}/lib/compress -I{z}/lib/decompress \
         {z}/lib/common/*.c {z}/lib/compress/*.c {z}/lib/decompress/*.c\n\
         {ar} rcs libzstd.a ./*.o\nrm -f ./*.o\n",
        dir = shq(&dir),
        clang = shq(&t.clang),
        inc = t.sysroot_include.display(),
        z = t.zstd_src.display(),
        ar = shq(&t.llvm_ar),
    );
    run(
        "cross-building libzstd",
        Command::new("bash").arg("-c").arg(script),
    );
    dir
}

// ---------------------------------------------------------------------------
// The Nim writer, compiled and archived
// ---------------------------------------------------------------------------

/// `CT_NIM_EXTRA_PATHS`, split, trimmed and checked.
///
/// Empty entries are skipped rather than refused: a colon-joined list built in
/// a shell or a nix expression picks up leading, trailing and doubled
/// separators without anyone meaning them, and refusing those would be a check
/// about string assembly rather than about the paths.
fn nim_extra_paths() -> Vec<String> {
    let Ok(extra) = std::env::var("CT_NIM_EXTRA_PATHS") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for part in extra.split(':') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if !Path::new(part).exists() {
            die(&format!(
                "CT_NIM_EXTRA_PATHS names {part}, which does not exist. An entry that names \
                 something absent is refused here rather than as `cannot open file` from a \
                 compiler that cannot say which path was wrong."
            ));
        }
        out.push(part.to_string());
    }
    out
}

fn nim_static_lib(out: &Path, nim_src: &Path, t: &Toolchain, pass_c: &str, nim_paths: &[String]) {
    let nimcache = out.join("nimcache");
    let entry = nim_src.join("src/codetracer_trace_writer_ffi.nim");
    if !entry.is_file() {
        die(&format!("the materialised tree has no {}", entry.display()));
    }

    let mut nim = Command::new("nim");
    nim.arg("c")
        .arg("--compileOnly")
        .arg("--mm:arc")
        .arg("-d:useMalloc")
        .arg("--threads:off")
        .arg("--noMain")
        .arg("-d:noSignalHandler")
        .arg("-d:release")
        .arg("--opt:size")
        .arg("--hints:off")
        // MUST match the `codetracerTraceWriterNimMain` importc in
        // `codetracer_trace_writer_ffi.nim`. Without it the module's own init entry point is
        // named `NimMain` and the FFI's forward declaration goes unresolved at link.
        .arg("--nimMainPrefix:codetracerTraceWriter")
        .arg(format!("-p:{}", nim_src.join("src").display()))
        .arg(format!("--nimcache:{}", nimcache.display()))
        .arg(format!("--passC:{pass_c}"))
        .arg(format!("-o:{}", out.join("unused.out").display()));
    // `--os:any` rather than `--os:standalone`: standalone drops the parts of `system` the
    // writer's own data structures use, while `any` keeps them and drops the OS surface.
    // `-d:ctHostClock` makes the clock a host symbol instead of a syscall; `-d:ctLeanRecord` is
    // the writer's own size switch. `nim` invokes clang, and clang needs `wasm-ld` on PATH.
    nim.arg("--os:any")
        .arg("--cpu:wasm32")
        .arg("--cc:clang")
        .arg(format!("--clang.exe:{}", t.clang.display()))
        .arg(format!("--clang.linkerexe:{}", t.clang.display()))
        .arg("-d:ctHostClock")
        .arg("-d:ctLeanRecord")
        .env("PATH", prepend_path(&t.lld_bin));
    // ── THE .nimble's `requires`, WHICH NOTHING HERE HAS EVER SUPPLIED ─────
    //
    // `codetracer_trace_format.nimble` requires `stew` and `results`, and
    // `stew` transitively requires `unittest2`. The only `-p:` above is the
    // writer's own `src`, so on a machine where those three are not already
    // discoverable — a nimble dir, a parent `config.nims` — this compile fails
    // with `cannot open file: results`, which reads as a broken checkout.
    // Measured 2026-10-14 inside a nix sandbox, which is exactly such a
    // machine, after CCP-7's other two hooks had got the build that far.
    //
    // THAT IS AN AMBIENT DEPENDENCY, and the writer repository's own flake
    // already names the fix: its `nimDepPaths` is described there as the
    // "`--path:` arguments that make the .nimble's `requires` importable from a
    // bare `nim c` (the package build below, AND THE FFI STATIC LIB THE RUST
    // SIBLING'S build.rs COMPILES)". It had no way to reach this file. This is
    // that way.
    //
    // Colon-separated, in order, each becoming one `-p:`. The REVISIONS are the
    // caller's to pin — the writer repository's `flake.lock` is where they are
    // declared — because a sha1 typed into a build script is a second authority
    // by another name, which is the argument `pins.json` already carries here.
    // Unset leaves the invocation byte-for-byte as it was.
    for part in nim_paths {
        nim.arg(format!("-p:{part}"));
    }

    nim.arg(&entry);
    run("nim c --compileOnly over the writer FFI", &mut nim);

    // The compile commands come from the build plan NIM wrote, not from this file. Re-deriving
    // them here would mean maintaining a second copy of the compiler's own flag set, and the two
    // would diverge on the first `nim.cfg` change in the materialised tree.
    let plan = std::fs::read_to_string(nimcache.join("unused.json"))
        .or_else(|_| std::fs::read_to_string(nimcache.join("ffi.json")))
        .unwrap_or_else(|_| {
            let found: Vec<_> = std::fs::read_dir(&nimcache)
                .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name()).collect())
                .unwrap_or_default();
            die(&format!(
                "nim wrote no build plan into {nimcache:?}; it holds {found:?}"
            ))
        });

    let objects = compile_from_plan(&plan);
    let archive = out.join("libct_nim_writer.a");
    let _ = std::fs::remove_file(&archive);
    let mut cmd = Command::new(&t.llvm_ar);
    cmd.arg("rcs").arg(&archive);
    for o in &objects {
        cmd.arg(o);
    }
    run("archiving the Nim objects", &mut cmd);
}

/// Run every `compile` entry in nim's build plan and return the `link` list.
///
/// The plan is JSON, and this reads it with a scan for the same reason `scalar_after` does. The
/// two arrays it needs — `compile`, an array of `[source, command]` pairs, and `link`, an array of
/// object paths — are both arrays of strings at a known key, and a miss is a hard failure.
fn compile_from_plan(plan: &str) -> Vec<String> {
    let commands = json_pairs(plan, "\"compile\"");
    // AN EMPTY `compile` LIST IS NORMAL AND IS NOT AN ERROR.
    //
    // Nim only lists a translation unit under `compile` when it has decided the unit is STALE. On a
    // warm `--nimcache` -- which is the ordinary case, because `OUT_DIR` survives a `cargo build`
    // that changed nothing -- the list is empty and every object named under `link` is already on
    // disk. The first version of this treated that as fatal, and the failure appeared only when the
    // build was run a second time in a different shell: a green build followed by
    // `nim's build plan lists no compile commands`, which names the wrong thing entirely.
    //
    // What IS an error is an object that does not exist. That is checked below, by name, rather
    // than inferred from the length of a list.
    for (src, cmd) in &commands {
        let status = Command::new("bash")
            .arg("-c")
            .arg(cmd)
            .status()
            .unwrap_or_else(|e| die(&format!("compiling {src}: {e}")));
        if !status.success() {
            die(&format!("compiling {src} failed:\n  {cmd}"));
        }
    }
    let objects = json_strings(plan, "\"link\"");
    if objects.is_empty() {
        die("nim's build plan lists no objects to link");
    }
    let missing: Vec<&String> = objects.iter().filter(|o| !Path::new(o).is_file()).collect();
    if !missing.is_empty() {
        die(&format!(
            "nim's build plan names {} object(s) that are not on disk, and compiled {} unit(s) \
             this run. The first missing one is {}. A stale nimcache under a reused OUT_DIR is the \
             usual cause; `cargo clean` or `--force` re-materialising will rebuild it.",
            missing.len(),
            commands.len(),
            missing[0]
        ));
    }
    objects
}

/// The `[[a, b], ...]` array at `key`, as pairs.
fn json_pairs(text: &str, key: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let Some(start) = text.find(key) else {
        return out;
    };
    let bytes = text[start..].as_bytes();
    let mut i = 0usize;
    // Advance to the opening bracket of the array's first inner array.
    while i < bytes.len() && bytes[i] != b'[' {
        i += 1;
    }
    i += 1;
    let region = &text[start + i..];
    let mut depth = 1i32;
    let mut cur: Vec<String> = Vec::new();
    let mut chars = region.char_indices().peekable();
    while let Some((idx, c)) = chars.next() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 1 && cur.len() == 2 {
                    out.push((cur[0].clone(), cur[1].clone()));
                    cur.clear();
                }
                if depth == 0 {
                    break;
                }
            }
            '"' => {
                let (s, next) = read_json_string(region, idx + 1);
                cur.push(s);
                while let Some(&(j, _)) = chars.peek() {
                    if j < next {
                        chars.next();
                    } else {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The `["a", "b", ...]` array at `key`.
fn json_strings(text: &str, key: &str) -> Vec<String> {
    let mut out = Vec::new();
    let Some(start) = text.find(key) else {
        return out;
    };
    let bytes = text[start..].as_bytes();
    let mut i = 0usize;
    while i < bytes.len() && bytes[i] != b'[' {
        i += 1;
    }
    let region = &text[start + i + 1..];
    let mut chars = region.char_indices().peekable();
    while let Some((idx, c)) = chars.next() {
        match c {
            ']' => break,
            '"' => {
                let (s, next) = read_json_string(region, idx + 1);
                out.push(s);
                while let Some(&(j, _)) = chars.peek() {
                    if j < next {
                        chars.next();
                    } else {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The JSON string starting at `from` (just past its opening quote). Returns it and the index just
/// past the closing quote. Handles the escapes nim's plan actually contains — `\\`, `\"`, `\n`.
fn read_json_string(text: &str, from: usize) -> (String, usize) {
    let mut s = String::new();
    let mut it = text[from..].char_indices();
    while let Some((i, c)) = it.next() {
        match c {
            '\\' => {
                if let Some((_, e)) = it.next() {
                    s.push(match e {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        other => other,
                    });
                }
            }
            '"' => return (s, from + i + 1),
            other => s.push(other),
        }
    }
    (s, text.len())
}

fn prepend_path(dir: &Path) -> String {
    let existing = std::env::var("PATH").unwrap_or_default();
    format!("{}:{}", dir.display(), existing)
}

// ---------------------------------------------------------------------------
// The host shim
// ---------------------------------------------------------------------------

fn compile_shim(out: &Path, t: &Toolchain, flags: &str) {
    let obj = out.join("nim_host_shim.o");
    let script = format!(
        "set -euo pipefail\n{clang} {flags} -O2 -c -o {obj} {src}\n{ar} rcs {lib} {obj}\n",
        clang = shq(&t.clang),
        flags = flags,
        obj = shq(&obj),
        src = shq(&PathBuf::from(env("CARGO_MANIFEST_DIR")).join("src/nim_host_shim.c")),
        ar = shq(&t.llvm_ar),
        lib = shq(&out.join("libct_nim_host_shim.a")),
    );
    run(
        "compiling the Nim host shim",
        Command::new("bash").arg("-c").arg(script),
    );
}

