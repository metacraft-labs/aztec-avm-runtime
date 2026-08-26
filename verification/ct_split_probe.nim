## ct_split_probe — read a `.ct` container's SPLIT STREAMS with the reference reader.
##
## ---------------------------------------------------------------------------
## WHY THIS EXISTS: `ct-print` CANNOT ANSWER THE QUESTION, AND SAYS SO ITSELF.
##
## `codetracer_ct_print.nim` decides which reader to use by whether the container carries
## `events.log`, and diverts to the LEGACY combined-stream reader when it does — which is every
## container the Rust `CtfsTraceWriter` produces. Its own comment gives the reason:
##
##   "the SECONDARY Rust `CtfsTraceWriter` now also default-emits the split streams, but
##    ADDITIVELY … and its `steps.dat` / `values.dat` / `events.dat` wire formats are NOT
##    v4-readable … Routing such a bundle through the v4 reader would yield an empty/garbled
##    event array. So ANY bundle that carries `events.log` is read via the legacy reader"
##
## So every decode assertion in `test_ct_container_roundtrip_ct_print` — step count, value count,
## path, program, workdir, call, function, the variable names, first and last line — was satisfied
## out of `events.log`, and the check never touched `steps.dat`, `values.dat`, `calls.dat` or
## `events.dat`. It reported green over a container in which all four are unreadable by the
## reference reader, which is exactly what a Path A container at the OLD `trace_format` anchor is:
## every stream compressed with a streaming zstd encoder, whose frame header omits the pledged
## content size, which the v4 stream readers require. Three of the four then read back as ZERO
## RECORDS rather than refusing — the silent wrong answer.
##
## This probe opens the SAME container through `openNewTrace` — the v4 split-stream reader, the
## one `ct-print` refuses to use here — and reports what each stream answers. It is built from the
## SAME pinned `trace_format_nim` revision as both `ct-print` binaries, out of the object store,
## by `verification/build_ct_print.sh`.
## ---------------------------------------------------------------------------
##
## Output is one `KEY<TAB>VALUE` line per fact, on stdout, and the process exits 0 whatever the
## container says. THAT IS DELIBERATE: a probe that exits non-zero on a bad container makes the
## caller's failure "the probe died", and this campaign has twice mistaken a dead instrument for a
## discovery about its subject. Every failure is reported as a VALUE beginning `ERR:` against the
## key it belongs to, so the check that reads this names the STREAM that could not be read.
##
## Usage: ct-split-probe <container.ct>

import std/[os, strutils, algorithm]
import results
import codetracer_trace_writer/new_trace_reader
import codetracer_ctfs/container as ctfs_container
import codetracer_ctfs/zstd_bindings

proc sanitise(v: string): string =
  ## ONE FACT PER LINE, AND A VALUE CANNOT BREAK THAT.
  ##
  ## Not a nicety: `funcs.dat` records are NOT bare UTF-8 here — the Rust writer's differ from
  ## the Nim writer's, which is a declared divergence — and the first function name this probe
  ## read back came out as `\x01\n<toplevel>`. Emitted raw, that newline invented a line the
  ## caller's `sed -n 's/^KEY\t//p'` would then read as a fact of its own, and the KEY it broke
  ## would have read as empty. Every control byte is escaped, so a malformed record shows up as a
  ## visibly odd VALUE instead of as a corrupt protocol.
  result = newStringOfCap(v.len + 8)
  for c in v:
    case c
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\\': result.add "\\\\"
    else:
      if c < ' ' or c == '\x7F': result.add "\\x" & toHex(ord(c), 2)
      else: result.add c

proc emit(key, value: string) =
  echo key & "\t" & sanitise(value)

proc framePledgeCensus(bytes: seq[byte]): string =
  ## Walk every Zstd frame in a stream and report how many pledge their
  ## decompressed size.
  ##
  ## THIS IS THE PROPERTY, MEASURED DIRECTLY RATHER THAN INFERRED FROM A
  ## DECODE. The v4 stream readers size every destination buffer from
  ## `ZSTD_getFrameContentSize` and treat `ZSTD_CONTENTSIZE_UNKNOWN` as a hard
  ## failure, and for three of the four families that failure surfaces as ZERO
  ## RECORDS rather than an error. So "the stream decoded" is the consequence
  ## and "every frame pledges" is the cause, and reporting the cause is what
  ## makes a red assertion name the defect instead of describing a symptom.
  ##
  ## Returns `frames=<n> pledged=<n> unpledged=<n>`, or a reason it could not
  ## walk them. An empty stream is `frames=0 pledged=0 unpledged=0`, which the
  ## caller must not read as good news — the count of frames is reported so a
  ## degenerate case is visible rather than silently satisfying.
  if bytes.len == 0:
    return "frames=0 pledged=0 unpledged=0"
  var off = 0
  var frames, pledged, unpledged = 0
  while off < bytes.len:
    let remaining = csize_t(bytes.len - off)
    let comp = ZSTD_findFrameCompressedSize(unsafeAddr bytes[off], remaining)
    # `ZSTD_isError` is not bound here; an error return is >= the remaining
    # length or zero, and either is unusable as a stride.
    if comp == csize_t(0) or uint64(comp) > uint64(remaining):
      return "ERR:not a zstd frame at byte " & $off & " (after " & $frames & " frame(s))"
    let cs = ZSTD_getFrameContentSize(unsafeAddr bytes[off], remaining)
    if cs == ZSTD_CONTENTSIZE_UNKNOWN: inc unpledged
    elif cs == ZSTD_CONTENTSIZE_ERROR:
      return "ERR:unreadable frame header at byte " & $off
    else: inc pledged
    inc frames
    off += int(comp)
  "frames=" & $frames & " pledged=" & $pledged & " unpledged=" & $unpledged

proc main() =
  if paramCount() < 1:
    emit("OPEN", "ERR:no container path given")
    quit(0)
  let path = paramStr(1)
  if not fileExists(path):
    emit("OPEN", "ERR:no such file: " & path)
    quit(0)

  let opened = openNewTrace(path)
  if opened.isErr:
    # The v4 reader refused the container outright. Report it against OPEN and stop; every
    # per-stream key below would otherwise be an assertion about nothing.
    emit("OPEN", "ERR:" & opened.error)
    quit(0)
  emit("OPEN", "ok")
  var r = opened.get()

  # The interning tables are loaded eagerly, so these need no error arm.
  emit("PATH_COUNT", $r.pathCount())
  if r.pathCount() > 0:
    let p0 = r.path(0'u64)
    emit("PATH0", if p0.isOk: p0.get() else: "ERR:" & p0.error)
  emit("FUNCTION_COUNT", $r.functionCount())
  emit("VARNAME_COUNT", $r.varnameCount())
  emit("COLUMN_AWARE", $r.meta.hasColumnAwareSteps)

  # --- steps.dat ------------------------------------------------------------
  let sc = r.stepCount()
  emit("STEP_COUNT", if sc.isOk: $sc.get() else: "ERR:steps.dat: " & sc.error)
  if sc.isOk and sc.get() > 0'u64:
    let last = sc.get() - 1
    let g0 = r.stepAbsoluteGlobalLineIndex(0'u64)
    emit("STEP0_GLI", if g0.isOk: $g0.get() else: "ERR:steps.dat: " & g0.error)
    let gl = r.stepAbsoluteGlobalLineIndex(last)
    emit("STEPLAST_GLI", if gl.isOk: $gl.get() else: "ERR:steps.dat: " & gl.error)

  # --- values.dat -----------------------------------------------------------
  let vc = r.valueCount()
  emit("VALUE_COUNT", if vc.isOk: $vc.get() else: "ERR:values.dat: " & vc.error)
  block:
    # A COUNT IS NOT A READ. `values.dat`'s count comes out of `values.idx`, which is
    # uncompressed — so a container whose `values.dat` frames are unreadable can still report the
    # right count. Pulling the actual records is what exercises the compressed stream.
    let v0 = r.values(0'u64)
    if v0.isOk:
      emit("VALUES0_COUNT", $v0.get().len)
      var names: seq[string] = @[]
      for v in v0.get():
        let n = r.varname(v.varnameId)
        names.add(if n.isOk: n.get() else: "?")
      names.sort()
      emit("VALUES0_NAMES", names.join(","))
      var bytes = 0
      for v in v0.get():
        bytes += v.data.len
      emit("VALUES0_BYTES", $bytes)
    else:
      emit("VALUES0_COUNT", "ERR:values.dat: " & v0.error)

  # --- calls.dat ------------------------------------------------------------
  let cc = r.callCount()
  emit("CALL_COUNT", if cc.isOk: $cc.get() else: "ERR:calls.dat: " & cc.error)
  if cc.isOk and cc.get() > 0'u64:
    let c0 = r.call(0'u64)
    if c0.isOk:
      # The record's own fields, out of `calls.dat`. The FUNCTION NAME is deliberately not
      # asserted from here: `funcs.dat` is one of the four files the two writers genuinely
      # disagree about, and its record is not a bare string on this side — reading it back gives
      # `\x01\n<toplevel>`. The name is checked through `ct-print`'s legacy decode, which is the
      # reader that owns that format; what this probe is for is that `calls.dat` decompressed and
      # decoded at all.
      emit("CALL0_ENTRY_STEP", $c0.get().entryStep)
      emit("CALL0_EXIT_STEP", $c0.get().exitStep)
      emit("CALL0_DEPTH", $c0.get().depth)
      emit("CALL0_FUNCTION_ID", $c0.get().functionId)
    else:
      emit("CALL0_ENTRY_STEP", "ERR:calls.dat: " & c0.error)

  # --- events.dat -----------------------------------------------------------
  let ec = r.ioEventCount()
  emit("IOEVENT_COUNT", if ec.isOk: $ec.get() else: "ERR:events.dat: " & ec.error)

  # --- the frame pledge, per stream, straight off the container bytes --------
  #
  # Independent of the reads above: this walks the raw stream and asks each
  # frame header whether it carries a Frame_Content_Size. It is what tells a
  # red assertion above apart from a container that is broken some other way.
  block:
    let dataR = ctfs_container.readCtfsFromFile(path)
    if dataR.isErr:
      emit("PLEDGE", "ERR:" & dataR.error)
    else:
      let raw = dataR.get()
      for name in ["steps.dat", "values.dat", "calls.dat", "events.dat"]:
        if not ctfs_container.hasInternalFile(raw, name):
          emit("PLEDGE_" & name, "absent")
          continue
        let f = ctfs_container.readInternalFile(raw, name)
        if f.isErr:
          emit("PLEDGE_" & name, "ERR:" & f.error)
        else:
          emit("PLEDGE_" & name, framePledgeCensus(f.get()))

  # --- which streams the reads above ACTUALLY opened -------------------------
  #
  # The stream readers are lazy. These four are the reader's own answer to "did you open and
  # decode this stream", so a check reading this probe can tell a real split-stream read from a
  # number that came from somewhere else.
  emit("EXEC_LOADED", $r.execStreamLoaded())
  emit("VALUE_LOADED", $r.valueStreamLoaded())
  emit("CALL_LOADED", $r.callStreamLoaded())
  emit("IOEVENT_LOADED", $r.ioEventStreamLoaded())
  emit("EXEC_CHUNK_DECOMPRESSIONS", $r.execChunkDecompressions())
  emit("DONE", "ok")

main()
