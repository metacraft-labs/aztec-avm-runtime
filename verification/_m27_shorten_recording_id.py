# Shorten a container's `recording_id` from 36 characters to 35, in place, into a copy.
#
# The refusal it provokes is M26's, measured: `codetracer_ct_print` rejects a `meta.dat` whose
# `recording_id` is not exactly 36 characters, with `recording_id: expected 36 chars, got N`. That
# is the control `e2e_browser_downloads_ct_container_and_ct_print_parses` needs, because HALVING the
# container does not make the reader refuse it — a `.ct` is a directory of independent streams and
# the ones that survive a truncation are still well formed.
#
# It is a file rather than an inline heredoc because the check that uses it is itself full of
# heredocs, and a nested one whose terminator appears in the outer body silently truncates the outer.
import sys

if len(sys.argv) != 4:
    sys.stderr.write("usage: _m27_shorten_recording_id.py <in.ct> <out.ct> <recording-id>\n")
    sys.exit(2)

src, dst, rec = sys.argv[1], sys.argv[2], sys.argv[3]
if len(rec) != 36:
    sys.stderr.write("the recording id is %d characters, not 36; nothing to shorten\n" % len(rec))
    sys.exit(3)

data = bytearray(open(src, "rb").read())
needle = rec.encode("ascii")
at = data.find(needle)
if at < 0:
    sys.stderr.write("the recording id %s does not appear in %s\n" % (rec, src))
    sys.exit(4)
data[at:at + len(needle)] = needle[:-1]
open(dst, "wb").write(bytes(data))
sys.stdout.write("shortened the recording id at offset %d\n" % at)
