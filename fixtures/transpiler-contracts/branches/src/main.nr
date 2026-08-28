// Comparison and control flow: LT/EQ/JUMPI, and an early return.
contract Branches {

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
    unconstrained fn public_dispatch(selector: Field) -> pub u32 {
        let s = selector as u32;
        if s < 10 {
            s * 3
        } else if s == 42 {
            0
        } else {
            let mut t: u32 = 0;
            for i in 0..4 {
                if (s + i) % 2 == 0 {
                    t += i;
                } else {
                    t += 1;
                }
            }
            t
        }
    }
}
