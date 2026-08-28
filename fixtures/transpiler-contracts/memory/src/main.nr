// Arrays and slices: memory addressing, MOV, indirect operands.
contract Memory {

    // `outputs.structs["functions"]` is what `@aztec/stdlib`'s `loadContractArtifact`
    // (`dest/abi/contract_artifact.js:148`) reads to find a public function's return type:
    // it looks up `<Contract>::<fn>_abi` and takes that struct's `return_type` field. The
    // aztec-nr macros generate these; a hand-written contract has to declare them, and
    // without them the loader throws `Cannot read properties of undefined (reading 'find')`.
    // They are inert — an unreferenced struct changes no bytecode — and they are here so the
    // execution check drives UPSTREAM's loader rather than a hand-built artifact object.
    #[abi(functions)]
    pub struct public_dispatch_abi {
        return_type: Field,
    }

    #['abi_public]
    unconstrained fn public_dispatch(selector: Field) -> pub Field {
        let mut xs: [Field; 6] = [0; 6];
        for i in 0..6 {
            xs[i] = selector + (i as Field);
        }
        let mut sum: Field = 0;
        for i in 0..6 {
            sum = sum + xs[5 - i];
        }
        sum
    }
}
