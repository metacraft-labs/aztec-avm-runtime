// The NEGATIVE CONTROL for the execution check, and it is not optional.
//
// M29's review established the campaign's deepest defect: a demo transaction that reverted at its
// first instruction passed a milestone, its review and a second milestone's floors, because every
// assertion was correct and none asked whether the subject had done anything. `revertCode == 0`
// on its own does not close that — a field that is always 0 reads identically. This contract's
// dispatch runs a real loop and THEN asserts something false, so the executor has to report a
// non-zero code for a transaction that demonstrably executed instructions. If both this and
// `counter` come back 0, the field is a constant and the check says so.
contract Reverting {
    #[abi(functions)]
    pub struct public_dispatch_abi {
        return_type: Field,
    }

    #['abi_public]
    unconstrained fn public_dispatch(selector: Field) -> pub Field {
        let mut acc: Field = 0;
        for i in 0..8 {
            acc = acc + selector * (i as Field) + 1;
        }
        // `selector` is the ABI-derived function selector the tester puts in calldata field 0, so
        // this is false for every real call and the assert is reached only after the loop above.
        assert(acc == 0, "M31 reverting fixture: this assert is meant to fail");
        acc
    }
}
