// Two AVM functions AND an ACIR function, so the pass-through arm is exercised in the same
// artifact as the transpiled one.
contract Multi {

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

    #[abi(functions)]
    pub struct second_public_abi {
        return_type: Field,
    }

    #['abi_public]
    unconstrained fn public_dispatch(selector: Field) -> pub Field {
        let mut acc: Field = selector + selector;
        for i in 0..3 {
            acc = acc * 2 + (i as Field);
        }
        acc + 7
    }

    #['abi_public]
    unconstrained fn second_public(x: Field) -> pub Field {
        x * x
    }

    #['abi_private]
    fn constrained_one(a: Field) -> pub Field {
        assert(a != 0);
        a
    }
}
