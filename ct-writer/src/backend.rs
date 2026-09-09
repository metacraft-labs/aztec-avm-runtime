//! The seam between the module's event ABI and the writer that serves it.
//!
//! # Why this exists
//!
//! Until M41 this crate named `CtfsTraceWriter` at the type level in two places and there was no
//! switch of any kind — no `[features]` block, no `cfg`, nothing that named a second writer. The
//! only way to change what wrote a container was to change `pins.json`, which is to say: to change
//! which *revision* of the one writer was used. DD-7's "Path A" and "Path B" were a decision
//! recorded in prose about code that could express only one of them.
//!
//! This trait is that switch. It is the complete set of operations this module asks a writer for
//! — eighteen of them — and nothing else in the crate mentions a concrete writer type.
//!
//! # Why a trait and not an enum, and why not `dyn`
//!
//! The artefact under measurement is a wasm module whose size and export set are asserted by
//! checks. A `dyn` object would add a vtable and an indirect call per step to a module whose whole
//! job is to write steps; an enum would compile BOTH writers into every build, which would make
//! the Path A module carry the Nim writer's bytes. A trait with one concrete implementation chosen
//! at compile time costs neither: [`ActiveBackend`] is a type alias, the calls are direct, and a
//! Path A module links no Nim at all.
//!
//! The cost of that choice is that "both selectable" means two builds rather than one build with a
//! runtime flag. That is the honest shape for this ABI: `ct_writer_kind()` takes no argument and
//! the milestone forbids changing the ABI, so there is nowhere for a caller to state a preference
//! even if the module could honour one.
//!
//! # What the trait deliberately does NOT abstract
//!
//! Everything the *session* knows: the position FIFO, the interned path table, the rung
//! declarations, the counters. Those are this module's bookkeeping and are identical under both
//! writers, so putting them behind the trait would mean two copies of code that has no reason to
//! differ — and a difference between the two containers could then be this crate's rather than the
//! writers'. The trait is exactly the writer, which is what makes
//! `verify_container_equivalence_characterised` able to attribute what it finds.

use std::path::Path;

/// `ct_writer_kind()`'s value for DD-7's Path A: the pure-Rust `CtfsTraceWriter`.
pub const CT_WRITER_KIND_PATH_A_PURE_RUST: u32 = 1;

/// `ct_writer_kind()`'s value for DD-7's Path B: the Nim writer, reached through its C ABI.
///
/// A distinct value rather than a flag, because a host reading `1` must not have to know whether
/// the module it is talking to is old enough to predate the question.
pub const CT_WRITER_KIND_PATH_B_NIM: u32 = 2;

/// The type of a trace value this module writes.
///
/// Two variants and not three: a `None` value appears in exactly one place — a frame's return —
/// and [`CtWriterBackend::register_return`] takes the type id directly, because the Nim ABI's
/// `register_return` writes the `None` itself and has nowhere to put a value. A third variant
/// would exist only to be unconstructed.
///
/// The enum exists at all so the trait does not have to name `codetracer_trace_types::ValueRecord`,
/// which Path B never constructs and whose crate a Path B build does not link.
pub enum Value<'a> {
    /// A signed integer under the given interned type id.
    Int(i64, u64),
    /// A UTF-8 string under the given interned type id.
    Str(&'a str, u64),
}

/// The kind of a type this module interns. A narrowing of `codetracer_trace_types::TypeKind` to
/// the two members this module uses, for [`Value`]'s reason.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TypeKind {
    None,
    Int,
}

/// Everything this module asks of a trace writer.
///
/// Every method is called from exactly one place in `lib.rs`, and every one corresponds to a call
/// this module made directly on `CtfsTraceWriter` before the seam existed. Nothing was added for
/// symmetry: a method here means the module needs it.
pub trait CtWriterBackend: Sized {
    /// The value `ct_writer_kind()` reports for containers this backend produces.
    fn kind() -> u32;

    /// Open a writer in memory.
    ///
    /// The four arguments arrive together rather than through separate setters because the two
    /// backends order them differently and neither order is wrong: Path A constructs and then sets
    /// the recording id, while Path B must pin the id BEFORE the constructor runs, since the Nim
    /// writer resolves the identity inside `begin`. A trait that exposed the setters separately
    /// would be a trait that only one of its implementations could satisfy.
    ///
    /// `recording_id` is the host's, and may be empty. What an empty one means is the backend's to
    /// decide and to document; the two do not agree and
    /// `verify_container_equivalence_characterised` names the difference.
    fn open(
        program: &str,
        recording_id: &str,
        want_columns: bool,
        workdir: &Path,
        source: &Path,
    ) -> Result<Self, String>;

    /// Intern a type and return its id. Called for `None` first and `Int`/`"Field"` second, so the
    /// `None` type is id 0 — which is what a reader expects a `None` value to point at.
    fn ensure_type_id(&mut self, kind: TypeKind, lang_type: &str) -> u64;

    /// Intern a function and return its id.
    fn ensure_function_id(&mut self, name: &str, path: &Path, line: i64) -> u64;

    /// Write one `TraceLogEvent` with an arbitrary metadata key and content.
    fn register_special_event(&mut self, metadata: &str, content: &str);

    /// Open a frame. `arg` is the single `(name, value)` pair this module ever passes.
    fn register_call(&mut self, function_id: u64, arg: Option<(&str, Value<'_>)>);

    /// Close the innermost frame with a `None` return value under `none_type_id`.
    fn register_return(&mut self, none_type_id: u64);

    /// Intern a source path along with its per-line lengths.
    fn register_path_with_line_lengths(&mut self, path: &Path, line_lengths: &[u32]);

    /// Record a step at `(path, line)`.
    fn register_step(&mut self, path: &Path, line: i64);

    /// Record a step at `(path, line, column)`. `None` means line-only.
    fn register_step_with_column(&mut self, path: &Path, line: i64, column: Option<i64>);

    /// Record one variable against the step just written.
    fn register_variable(&mut self, name: &str, value: Value<'_>);

    /// The WRITER's own signal that a column-aware request was accepted and dropped.
    ///
    /// Read from the writer rather than derived from what was asked for. DD-7's whole point is
    /// that the *writer* decides it cannot honour the request; a module that answered this from
    /// its own `want_columns` would be printing a literal back.
    fn dropped_column_awareness(&self) -> bool;

    /// Finish the event stream. Separate from [`take_container_bytes`](Self::take_container_bytes)
    /// because a writer can refuse to finish, and a refusal must be distinguishable from a
    /// container that finished and turned out to be empty.
    fn finish(&mut self) -> Result<(), String>;

    /// The finished container's bytes, or `None` if there is no container.
    fn take_container_bytes(&mut self) -> Option<Vec<u8>>;
}

// ---------------------------------------------------------------------------
// WHICH BACKEND THIS BUILD USES.
//
// `path-b` wins when both features are on, and that precedence is stated here rather than left for
// a reader to derive from `cfg` polarity. Cargo features are additive — a dependency that turns
// `path-b` on cannot turn `path-a` off — so "both on" is a state that arises without anyone asking
// for it, and the build must have an answer rather than a coin toss.
// ---------------------------------------------------------------------------

#[cfg(feature = "path-b")]
pub use crate::backend_nim::NimBackend as ActiveBackend;

#[cfg(all(feature = "path-a", not(feature = "path-b")))]
pub use crate::backend_rust::RustBackend as ActiveBackend;
