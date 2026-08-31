// The AVM opcodes this fixture needs, declared as Brillig foreign calls.
//
// WHY THEY ARE IN A MODULE AND NOT IN THE CONTRACT BLOCK. Noir treats a function declared directly
// inside a `contract { … }` as an ENTRY POINT, so an oracle stub there is rejected twice over:
// `[Field; N]` is "Invalid entry point type" and a `-> Field` return "missing pub keyword". Both
// errors were produced before this file existed. `aztec-nr` puts the same declarations in
// `aztec/src/oracle/avm.nr` for the same reason; this is that file, cut down to six opcodes, and it
// is the only reason the fixture is multi-file.
//
// EVERY NAME HERE IS THE TRANSPILER'S OWN. `avm-transpiler/src/transpile.rs` at the campaign's
// `cpp` anchor matches `ForeignCall { function }` against exactly these strings and emits the
// corresponding AVM opcode; a name it does not know makes the transpiler PANIC rather than emit
// something wrong, so a typo here is a build failure and not a silent no-op.

#[oracle(aztec_avm_address)]
pub unconstrained fn address_opcode() -> Field {}

#[oracle(aztec_avm_call)]
pub unconstrained fn call_opcode<let N: u32>(
    l2_gas_allocation: u32,
    da_gas_allocation: u32,
    address: Field,
    length: u32,
    args: [Field; N],
) {}

#[oracle(aztec_avm_successCopy)]
pub unconstrained fn success_copy_opcode() -> bool {}

#[oracle(aztec_avm_storageWrite)]
pub unconstrained fn storage_write_opcode(storage_slot: Field, value: Field) {}

#[oracle(aztec_avm_storageRead)]
pub unconstrained fn storage_read_opcode(storage_slot: Field, contract_address: Field) -> Field {}

#[oracle(aztec_avm_emitNullifier)]
pub unconstrained fn emit_nullifier_opcode(nullifier: Field) {}
