//! Path A — DD-7's pure-Rust `CtfsTraceWriter`, behind [`CtWriterBackend`].
//!
//! Every line here was previously a direct call in `lib.rs`. Nothing about what Path A does
//! changed when the seam was introduced; what changed is that `lib.rs` no longer names the type.
//! `verify_container_equivalence_characterised` compares a container built through this file
//! against one built through `backend_nim.rs`, and the comparison would be meaningless if this
//! file had taken the opportunity to write anything differently.

use std::path::Path;

use codetracer_trace_types::{
    CallRecord, EventLogKind, Line, TraceLowLevelEvent, TypeId, TypeKind as CtTypeKind, ValueRecord,
};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use crate::backend::{CT_WRITER_KIND_PATH_A_PURE_RUST, CtWriterBackend, TypeKind, Value};

pub struct RustBackend {
    writer: CtfsTraceWriter,
}

impl RustBackend {
    fn value(&mut self, v: Value<'_>) -> ValueRecord {
        match v {
            Value::Int(i, t) => ValueRecord::Int {
                i,
                type_id: TypeId(t as usize),
            },
            Value::Str(text, t) => ValueRecord::String {
                text: text.to_string(),
                type_id: TypeId(t as usize),
            },
        }
    }
}

impl CtWriterBackend for RustBackend {
    fn kind() -> u32 {
        CT_WRITER_KIND_PATH_A_PURE_RUST
    }

    fn open(
        program: &str,
        recording_id: &str,
        want_columns: bool,
        workdir: &Path,
        source: &Path,
    ) -> Result<Self, String> {
        let mut writer = CtfsTraceWriter::new_in_memory(program, &[]);
        // An EMPTY recording id is accepted and the writer picks its own. This is Path A's
        // behaviour and not a decision made here; `backend_nim.rs` refuses the same input, and the
        // difference is one of the ones M41's equivalence deliverable names rather than smooths
        // over.
        if !recording_id.is_empty() {
            writer.set_recording_id(recording_id.to_string());
        }
        // DD-7: the request is made to the writer so that the WRITER decides it cannot honour it.
        // Deciding it here, from a constant, would make `ct_dropped_column_awareness` a literal
        // this module printed rather than a signal it read.
        if want_columns {
            TraceWriter::enable_column_aware_steps(&mut writer);
            TraceWriter::enable_column_breakpoints_support(&mut writer);
            TraceWriter::enable_column_motions_support(&mut writer);
        }
        if writer
            .begin_writing_trace_events(Path::new("trace"))
            .is_err()
        {
            return Err("the writer refused to begin".to_string());
        }
        TraceWriter::set_workdir(&mut writer, workdir);
        TraceWriter::start(&mut writer, source, Line(1));
        Ok(RustBackend { writer })
    }

    fn ensure_type_id(&mut self, kind: TypeKind, lang_type: &str) -> u64 {
        let k = match kind {
            TypeKind::None => CtTypeKind::None,
            TypeKind::Int => CtTypeKind::Int,
        };
        TraceWriter::ensure_type_id(&mut self.writer, k, lang_type).0 as u64
    }

    fn ensure_function_id(&mut self, name: &str, path: &Path, line: i64) -> u64 {
        TraceWriter::ensure_function_id(&mut self.writer, name, path, Line(line)).0 as u64
    }

    fn register_special_event(&mut self, metadata: &str, content: &str) {
        TraceWriter::register_special_event(
            &mut self.writer,
            EventLogKind::TraceLogEvent,
            metadata,
            content,
        );
    }

    fn register_call(&mut self, function_id: u64, arg: Option<(&str, Value<'_>)>) {
        let args = match arg {
            Some((name, v)) => {
                let record = self.value(v);
                let arg = TraceWriter::arg(&mut self.writer, name, record);
                // `ctfs_sink.rs`'s override: a non-toplevel call's arguments are emitted as `Value`
                // events before the `Call`, because the writer's default would otherwise not
                // record them at all on this path.
                TraceWriter::add_event(&mut self.writer, TraceLowLevelEvent::Value(arg.clone()));
                vec![arg]
            }
            None => vec![],
        };
        TraceWriter::add_event(
            &mut self.writer,
            TraceLowLevelEvent::Call(CallRecord {
                function_id: codetracer_trace_types::FunctionId(function_id as usize),
                args,
            }),
        );
    }

    fn register_return(&mut self, none_type_id: u64) {
        TraceWriter::register_return(
            &mut self.writer,
            ValueRecord::None {
                type_id: TypeId(none_type_id as usize),
            },
        );
    }

    fn register_path_with_line_lengths(&mut self, path: &Path, line_lengths: &[u32]) {
        let _ =
            CtfsTraceWriter::register_path_with_line_lengths(&mut self.writer, path, line_lengths);
    }

    fn register_step(&mut self, path: &Path, line: i64) {
        TraceWriter::register_step(&mut self.writer, path, Line(line));
    }

    fn register_step_with_column(&mut self, path: &Path, line: i64, column: Option<i64>) {
        TraceWriter::register_step_with_column(
            &mut self.writer,
            path,
            Line(line),
            column.map(Line),
        );
    }

    fn register_variable(&mut self, name: &str, value: Value<'_>) {
        let record = self.value(value);
        TraceWriter::register_variable_with_full_value(&mut self.writer, name, record);
    }

    fn dropped_column_awareness(&self) -> bool {
        self.writer.dropped_column_awareness()
    }

    fn finish(&mut self) -> Result<(), String> {
        if self.writer.finish_writing_trace_events().is_err() {
            return Err("the writer refused to finish".to_string());
        }
        Ok(())
    }

    fn take_container_bytes(&mut self) -> Option<Vec<u8>> {
        self.writer.take_container_bytes()
    }
}
