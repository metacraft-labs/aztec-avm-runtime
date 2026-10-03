// Intern paths through the real host and report what each registration answered.
//
//   node --experimental-strip-types verification/_path_table_probe.mjs \
//       <ct-host src/index.ts> <path-a module.wasm> <path-b module.wasm>
//
// The host is a PARAMETER for the same reason as `_writer_kind_probe.mjs`: the check's mutation
// arm can point this probe at another tree without the probe changing.
//
// Every case gets a FRESH instance, because the module holds one global session and a case must
// not inherit the previous one's interned paths.
//
// Output, one tab-separated line per fact:
//
//   INTERN  <module> <case> <step> <id | REFUSED> <status> <message>
//   STEP    <module> <case> <ok | REFUSED> <message>
//   CLOSE   <module> <case> <ok | REFUSED> <container bytes | message>

import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [, , hostIndex, modulePathA, modulePathB] = process.argv;
if (!hostIndex || !modulePathA || !modulePathB) {
  console.error('usage: _path_table_probe.mjs <ct-host index.ts> <path-a.wasm> <path-b.wasm>');
  process.exit(2);
}

const h = await import(pathToFileURL(hostIndex).href);
const SOURCE = '/aztec/tx.nr';
const oneLine = (s) => String(s).replace(/[\t\n]+/g, ' ');

function open(bytes, path, columns) {
  return h.instantiateCtWriter(bytes).then(
    (instance) =>
      new h.CtWriter(
        instance,
        h.resolveTracingConfig(
          {
            program: 'path-table-probe',
            recordingId: '01949fcc-7d92-7e9c-8000-0000000041d1',
            sourcePath: SOURCE,
            workdir: '/aztec',
            columns,
            ...(columns ? { mappingRung: h.RUNG_SOURCE } : {}),
          },
          path,
        ),
      ),
  );
}

function intern(w, label, name, step, path, table) {
  try {
    const id = w.internPath(path, table);
    console.log(['INTERN', label, name, step, id, 0, ''].join('\t'));
    return id;
  } catch (e) {
    console.log(['INTERN', label, name, step, 'REFUSED', e?.status ?? '-', oneLine(e?.message ?? e)].join('\t'));
    return -1;
  }
}

function step(w, label, name, id, line, column) {
  try {
    w.sourceStep(id, line, column);
    console.log(['STEP', label, name, 'ok', ''].join('\t'));
  } catch (e) {
    console.log(['STEP', label, name, 'REFUSED', oneLine(e?.message ?? e)].join('\t'));
  }
}

function close(w, label, name) {
  try {
    const r = w.close();
    console.log(['CLOSE', label, name, 'ok', r.container.length].join('\t'));
  } catch (e) {
    console.log(['CLOSE', label, name, 'REFUSED', oneLine(e?.message ?? e)].join('\t'));
  }
}

const B = [10, 20, 30];
const B_OTHER = [5, 5];

// THE CASES. `same`, `empty` and `different` re-intern one path; `source` interns the session's
// own source path, which `start` already mentioned at open with no table.
async function cases(label, bytes, path, columns) {
  const tag = columns ? 'cols' : 'lines';
  {
    const name = `same-${tag}`;
    const w = await open(bytes, path, columns);
    const id = intern(w, label, name, 'first', '/aztec/b.nr', B);
    step(w, label, name, id, 2, columns ? 3 : 0);
    intern(w, label, name, 'again', '/aztec/b.nr', B);
    close(w, label, name);
  }
  {
    const name = `empty-${tag}`;
    const w = await open(bytes, path, columns);
    const id = intern(w, label, name, 'first', '/aztec/b.nr', B);
    step(w, label, name, id, 2, columns ? 3 : 0);
    intern(w, label, name, 'again', '/aztec/b.nr', []);
    close(w, label, name);
  }
  {
    const name = `different-${tag}`;
    const w = await open(bytes, path, columns);
    const id = intern(w, label, name, 'first', '/aztec/b.nr', B);
    step(w, label, name, id, 2, columns ? 3 : 0);
    intern(w, label, name, 'again', '/aztec/b.nr', B_OTHER);
    // The session goes on after the refusal: the next step is on the path as FIRST interned.
    step(w, label, name, id, 3, columns ? 4 : 0);
    close(w, label, name);
  }
  {
    const name = `source-${tag}`;
    const w = await open(bytes, path, columns);
    intern(w, label, name, 'first', SOURCE, B);
    close(w, label, name);
  }
}

const A = readFileSync(modulePathA);
const Bm = readFileSync(modulePathB);
await cases('path-a-module', A, h.WRITER_PATH_A_PURE_RUST, false);
await cases('path-b-module', Bm, h.WRITER_PATH_B_NIM, false);
// Columns only on Path B: the host refuses a column-aware configuration on Path A by design
// (DD-7), so there is no Path A column-aware session to ask.
await cases('path-b-module', Bm, h.WRITER_PATH_B_NIM, true);
console.log('PROBEDONE');
