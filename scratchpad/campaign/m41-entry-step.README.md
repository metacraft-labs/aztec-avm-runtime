# The entry-step change, implemented and held

`m41-entry-step.patch` applies to **`codetracer-trace-format` at `c8802c548f`** (the revision
`pins.json`'s `trace_format` anchor names). It is two things:

- `codetracer_trace_writer/src/abstract_trace_writer.rs` — `start()` emits the entry step, after
  the `<toplevel>` call so the step sits inside the root frame.
- `codetracer_trace_writer/tests/start_records_the_entry_step.rs` — three cases: the step exists and
  is at the position `start` was given; `<toplevel>` is interned first and called before the step;
  and the counting control, that a recorder emitting N steps produces N + 1.

It was written red-green — all three cases fail at `c8802c548f` with
`start() emitted 0 steps`, and pass with the one-line change — and it is **held rather than
landed**. `WRITER-SEAM.md` §5b carries the three measurements that is based on:

1. **Seven in-repo constants break**, all `N → N+1`: `Expected 9 step events, got 10`, `19 → 20`,
   `999 → 1000`, `47 → 48`, and one IO-attribution index. Two further failures in that run are a
   worktree artefact — tests that read sibling recorder repos by relative path — and not the change.
2. **The branches are divergent.** That repository's mainline is `dev`; this runtime pins
   `wasm/ctfs-writer`, which is 8 commits ahead of the merge base and does not have `dev` as an
   ancestor. The change needs to land on both, and which is "mainline" for a pin is that
   repository's decision.
3. **It does not make m24/m25's step-count constants pass — it makes them fail for both writers.**
   They read "the decoded step count equals the events the host wrote", which encodes *no entry
   step*. Once both writers obey the spec they both produce `events + 1`.

The spec half IS landed: `codetracer-trace-format-spec` `latest`, `trace-events.md`, "Recorder
Integration — Starting a Recording". So the contract is written down; this patch is the pure-Rust
writer catching up to it.
