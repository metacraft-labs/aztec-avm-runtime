// A CONTROL, NOT A TEST. It registers nothing.
//
// `runner.js` must report `status: 'error'`, `reason: 'no-tests'` for this — never `ok`. It is the
// `ok: 0/0 published files match` shape: a checker that exited 0 while checking nothing. If this
// file ever produces a green report, the runner cannot tell a loaded suite from an empty one and
// every other arm's green is worthless.
export default async function register() {
  // deliberately empty
}
