/*
 * The libc surface the Nim writer's C output needs on `wasm32-unknown-unknown`, and nothing more.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS IS C AND NOT RUST
 * ---------------------------------------------------------------------------
 *
 * Rust's `#[no_mangle]` on a `cdylib` does not merely give a symbol a stable name — rustc passes
 * an explicit `--export <name>` to the linker for every one of them. A Rust implementation of
 * `malloc` would therefore appear in the module's export table, and so would `free`, `exit`,
 * `fopen` and the twenty-odd others. A browser page could then call `free` on an address of its
 * choosing. Symbols pulled out of a static ARCHIVE are not exported: the linker resolves them and
 * stops. So the shim is C, and `verify_ct_writer_wasm_zero_imports` sees a module whose exports
 * are the thirty-eight of the ABI and `memory`, exactly as Path A's are.
 *
 * ---------------------------------------------------------------------------
 * ONE HEAP, NOT TWO
 * ---------------------------------------------------------------------------
 *
 * The obvious shim is a bump allocator, which is what the trace-format repository's own
 * freestanding build uses. It cannot be used here. That build produces ONE container and exits;
 * this module is a long-lived browser object that opens and closes a writer per transaction, and a
 * `free` that does nothing turns every transaction into a permanent cost.
 *
 * So the allocator is the module's REAL one — Rust's — reached through function pointers this
 * shim is handed before the first Nim call. Pointers rather than direct calls because a direct
 * call needs a named Rust symbol, and a named Rust symbol is an exported one; see above. A `malloc`
 * before the binding is a TRAP rather than a fallback, because a fallback would mean two heaps and
 * a pointer freed by the wrong one.
 *
 * ---------------------------------------------------------------------------
 * THE REFUSALS REFUSE
 * ---------------------------------------------------------------------------
 *
 * The stdio and filesystem entry points below exist because the Nim tree REFERENCES them, not
 * because anything on the in-memory path calls them. Each returns the failure its C contract
 * defines. None pretends to succeed: a `fopen` that returned a plausible non-null handle would
 * turn "this module cannot write files" into "this module wrote a file somewhere", and the
 * difference would surface as missing data rather than as an error.
 *
 * `getentropy` is the one that matters most and it refuses hardest. `wasm32-unknown-unknown` has
 * no CSPRNG. A shim that filled the buffer with a constant would make `newUuidV7` succeed and mint
 * the SAME recording id in every browser tab, forever — identities that collide are
 * indistinguishable in a trace store, and nothing downstream could tell that from a genuine
 * duplicate. Refusing makes `newUuidV7` fail, which makes the writer's constructor fail, which is
 * why `ct_writer_open` requires the host to supply a recording id under Path B and says so.
 */

#include <stddef.h>

typedef void *(*ct_alloc_fn)(size_t);
typedef void (*ct_free_fn)(void *);
typedef void *(*ct_realloc_fn)(void *, size_t);

static ct_alloc_fn g_alloc;
static ct_free_fn g_free;
static ct_realloc_fn g_realloc;

/* Called by `ct_writer_open` before the first Nim entry point. Not exported: this is an archive
 * symbol, and the linker resolves it without adding it to the module's export table. */
void ct_nim_shim_bind(ct_alloc_fn a, ct_free_fn f, ct_realloc_fn r) {
  g_alloc = a;
  g_free = f;
  g_realloc = r;
}

/* 1 once the binding is in place. `ct_writer_open` asserts this rather than assuming its own
 * call succeeded, so a reordering that moved the first Nim call ahead of the bind is a named
 * failure rather than a trap with no message. */
int ct_nim_shim_bound(void) { return g_alloc != 0 && g_free != 0 && g_realloc != 0; }

void *malloc(size_t n) {
  if (!g_alloc) {
    __builtin_trap();
  }
  return g_alloc(n);
}

void free(void *p) {
  if (!p) {
    return;
  }
  if (!g_free) {
    __builtin_trap();
  }
  g_free(p);
}

void *realloc(void *p, size_t n) {
  if (!g_realloc) {
    __builtin_trap();
  }
  return g_realloc(p, n);
}

void *calloc(size_t a, size_t b) {
  size_t n = a * b;
  /* The overflow check is not decoration: `calloc(x, y)` with a product that wraps would allocate
   * a short buffer and hand back a pointer the caller believes is long, which is a silently wrong
   * answer of exactly the shape this module exists to avoid. */
  if (a != 0 && n / a != b) {
    return 0;
  }
  unsigned char *p = (unsigned char *)malloc(n);
  if (p) {
    for (size_t i = 0; i < n; i++) {
      p[i] = 0;
    }
  }
  return p;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) {
    n++;
  }
  return n;
}

_Noreturn void exit(int code) {
  (void)code;
  __builtin_trap();
}

/* `errno` and `stdin` are referenced by the C the Nim compiler emits for `std/syncio`. Neither is
 * read on any path this module takes; they exist so the link resolves. */
int errno;
void *stdin;

/* --- the filesystem, refused ------------------------------------------------------------- */

void *fopen(const char *path, const char *mode) {
  (void)path;
  (void)mode;
  return 0;
}
int fclose(void *f) {
  (void)f;
  return -1;
}
int fflush(void *f) {
  (void)f;
  return -1;
}
size_t fread(void *p, size_t sz, size_t n, void *f) {
  (void)p;
  (void)sz;
  (void)n;
  (void)f;
  return 0;
}
size_t fwrite(const void *p, size_t sz, size_t n, void *f) {
  (void)p;
  (void)sz;
  (void)n;
  (void)f;
  return 0;
}
int fgetc(void *f) {
  (void)f;
  return -1;
}
int ungetc(int c, void *f) {
  (void)c;
  (void)f;
  return -1;
}
int ferror(void *f) {
  (void)f;
  return 1;
}
void clearerr(void *f) { (void)f; }
int fseeko(void *f, long long off, int whence) {
  (void)f;
  (void)off;
  (void)whence;
  return -1;
}
long long ftello(void *f) {
  (void)f;
  return -1;
}
int setvbuf(void *f, char *buf, int mode, size_t size) {
  (void)f;
  (void)buf;
  (void)mode;
  (void)size;
  return -1;
}
char *strerror(int e) {
  (void)e;
  return (char *)"this module has no filesystem";
}

/* `dlsym` is reached from the FFI's MCR shared-container probe, which asks whether a cooperative
 * recorder is present. In a browser one never is, and answering NULL is the correct answer rather
 * than a stub: it is exactly what the probe's "absent -> create our own container" branch is for. */
void *dlsym(void *handle, const char *name) {
  (void)handle;
  (void)name;
  return 0;
}

/* --- the clock and the CSPRNG ----------------------------------------------------------- */

/* Reached only from `newUuidV7`, which this module never lets succeed — see the header. Zero is
 * returned rather than trapped so that the FAILURE a caller sees is the entropy refusal, which
 * names the real reason, rather than a trap in the clock, which names an incidental one. */
unsigned long long ct_host_unix_ms(void) { return 0; }

int getentropy(void *buf, size_t n) {
  (void)buf;
  (void)n;
  return -1;
}
