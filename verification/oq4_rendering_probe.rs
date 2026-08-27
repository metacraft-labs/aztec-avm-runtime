// OQ-4's evidence, as a program: the SAME 32-byte field element rendered five ways, each written
// into its own `.ct` container by the pinned Path A writer, so a READER can be asked which of them
// it can decode.
//
// Built by `verification/build_oq4_rendering_probe.sh` into a scratch crate under `$M25_WORK`,
// against `ct-writer/build-wasm-deps/ctf` — the SAME materialised checkout `ct-writer` links, at
// the SAME `trace_format` revision — because a probe built against a different revision of the
// writer would be evidence about a writer nobody ships.
//
// EVERY ARM CARRIES THE SAME CONTROL, and that is the whole design. `control` is an
// `Int 42` present in all five containers, so an arm that a reader refuses is attributable to its
// `subject` rather than to anything about the container, the writer or the run. Four arms are
// expected to be read and one is expected to be refused; a check that only ran the refused one
// would be measuring that something, somewhere, went wrong.

use codetracer_trace_types::{Line, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use std::path::Path;

// A real full-width BN254 field element: an Aztec contract address. > 2^127, so `to_i128` panics.
const ADDR: [u8; 32] = [
    0x2f, 0x1a, 0xbc, 0xde, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
    0xcc, 0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
];

fn hex32(b: &[u8]) -> String {
    let mut s = String::with_capacity(66);
    s.push_str("0x");
    for x in b { s.push_str(&format!("{x:02x}")); }
    s
}

fn main() {
    let mut args = std::env::args().skip(1);
    let arm = args.next().expect("usage: oq4probe <arm> <out.ct>");
    let out = args.next().expect("usage: oq4probe <arm> <out.ct>");
    let mut w = CtfsTraceWriter::new_in_memory("aztec", &[]);
    w.set_recording_id("01949fcc-7d92-7e9c-8000-00000000ce11".to_string());
    w.begin_writing_trace_events(Path::new("trace")).unwrap();
    let p = std::path::PathBuf::from("/aztec/tx.avm");
    TraceWriter::set_workdir(&mut w, Path::new("/aztec"));
    TraceWriter::start(&mut w, &p, Line(1));
    let tid = TraceWriter::ensure_type_id(&mut w, TypeKind::Int, "Field");
    TraceWriter::register_step(&mut w, &p, Line(7));
    // Every arm carries this one, so an arm that fails has a control beside it that does not.
    TraceWriter::register_variable_with_full_value(
        &mut w, "control", ValueRecord::Int { i: 42, type_id: tid },
    );
    match arm.as_str() {
        "int" => {}
        "low64" => {
            let mut low = 0i64;
            for (i, b) in ADDR.iter().rev().take(8).enumerate() { low |= (*b as i64) << (8 * i); }
            TraceWriter::register_variable_with_full_value(
                &mut w, "subject", ValueRecord::Int { i: low, type_id: tid });
        }
        "bigint" => {
            TraceWriter::register_variable_with_full_value(
                &mut w, "subject",
                ValueRecord::BigInt { b: ADDR.to_vec(), negative: false, type_id: tid });
        }
        "string" => {
            TraceWriter::register_variable_with_full_value(
                &mut w, "subject", ValueRecord::String { text: hex32(&ADDR), type_id: tid });
        }
        "raw" => {
            TraceWriter::register_variable_with_full_value(
                &mut w, "subject", ValueRecord::Raw { r: hex32(&ADDR), type_id: tid });
        }
        other => panic!("unknown arm {other}"),
    }
    w.finish_writing_trace_events().unwrap();
    let bytes = w.take_container_bytes().expect("no container");
    std::fs::write(&out, &bytes).unwrap();
    println!("arm={arm} bytes={} out={out}", bytes.len());
}
