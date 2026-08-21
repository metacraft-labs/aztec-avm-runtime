// Stand-in for @aztec/native (the NAPI bridge to the C++ AVM). Reached only from the
// four cpp_* simulator files, which the browser build never executes.
const nope = () => { throw new Error('@aztec/native is not available in the browser build'); };
export const avmSimulate = nope, avmSimulateWithHintedDbs = nope, cancelSimulation = nope;
export const createCancellationToken = () => ({ cancel: () => {} });
export class MsgpackChannel {}
export default {};
