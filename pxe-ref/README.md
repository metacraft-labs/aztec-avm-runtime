# `pxe-ref` — upstream's own PXE, installed as a REFERENCE and never shipped

M21's `test_form_b_tx_matches_pxe_bytes` asks a differential question: *for the same request and
inputs, is the `Tx` this runtime builds byte-identical to the one PXE builds?* Answering it needs
PXE, and DD-9 forbids `@aztec/pxe` in the shipped graph — it hard-depends on `@aztec/simulator`,
which hard-depends on `@aztec/native` and `@aztec/world-state`.

**So it is installed HERE, in a tree nothing ships**, exactly as `diffsim/`, `spike/`, `drift/` and
`probe-mt/` install what the shipped graph must not reach. `verify_npm_pack_no_optional_native`
classifies this tree by the same rule it classifies those four by, and
`verify_differential_containment` and the import-graph checks are over the shipped packages and do
not read this one.

## What it produces

`src/build_reference_tx.mjs` runs upstream's own two steps, in upstream's own order:

1. `generateSimulatedProvingResult(privateExecutionResult, nameGetter, node)` — `@aztec/pxe`'s own
   export, from `@aztec/pxe/simulator`. It is the step this repository does NOT have: `form_b.ts`
   records that it lives in `@aztec/pxe` and why it is not vendored.
2. `new PrivateSimulationResult(…).toSimulatedTx()` — which is the step this repository DOES have,
   as `orchestration/src/form_b.ts`'s `txFromTail`.

and writes both the tail it produced and the transaction bytes, so the check can hand the SAME tail
to this runtime's own seam and compare the two transactions byte for byte.

It also builds the **inlined** form TXE and `wallet-sdk` use — `Tx.create({ …,
contractClassLogFields: [] })` — because that is the divergence `form_b.ts` documents and it is what
makes the byte-identity above a measurement rather than a restatement: over a private execution that
carries a contract-class log, PXE's form and the inlined form are DIFFERENT transactions, and this
runtime is asserted to match the first and to differ from the second.

## The node

`generateSimulatedProvingResult`'s third parameter is an `AztecNode`, used only by
`verifyReadRequests` to resolve SETTLED note-hash and nullifier read requests. The reference
execution has none, so the stub passed here THROWS if it is consulted — an unused parameter that is
asserted unused rather than quietly satisfied.
