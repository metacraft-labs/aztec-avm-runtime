// THE CONTRACT THE FIXTURE CORPUS COULD NOT EXPRESS.
//
// M25's `test_nested_call_reverted_contributes_no_side_effects` was `pending` behind a CORPUS gap
// that the closeout pass proved by enumeration rather than asserting: of the pinned `AvmTest`
// contract's 127 functions, fifteen make a nested call and exactly TWO recover from a failed one —
// `nested_call_to_nothing_recovers`, whose target is a garbage address with no code at all, and
// `external_call_to_divide_by_zero_recovers`, whose target's whole body is `1 / denominator`.
// **Neither nested target makes a side effect.** So no fixture in the corpus makes one in a nested
// frame that reverts while the OUTER call goes on to succeed, which is precisely what that entry
// asks for.
//
// This is that contract, and it is authored here because that is what M30 and M31 are for: M30
// compiles Noir from a virtual filesystem and M31 transpiles it to AVM bytecode in the browser, so
// a contract this repository needs is a file rather than a request to upstream.
//
// ---------------------------------------------------------------------------------------------
// THE SHAPE, AND WHY EACH MODE EXISTS.
// ---------------------------------------------------------------------------------------------
//
// One contract, six modes, selected by calldata field 1, with calldata field 2 as the mode's
// argument. It calls ITSELF at its own address, which is how `AvmTest.create_same_nullifier_in_
// nested_call` does it too — a second contract would add a registration and prove nothing extra.
//
//   0  OUTER, reverting callee    writes slot 1, emits nullifier 700101, CALLs mode 1 forwarding
//                                 its own `arg`, reads the success flag, and writes the flag to
//                                 slot 3. It does NOT propagate the failure: the outer call goes
//                                 on to succeed, which is the half `AvmTest` has and the half that
//                                 must be kept.
//   1  INNER, reverting           writes slot 2 = 5151, emits nullifier 700102, and THEN fails —
//                                 unless `arg` is 1, in which case it fails FIRST and the two side
//                                 effects are never reached.
//   2  READ                       returns the value at the slot named by `arg`, so the state is
//                                 read back through the contract itself.
//   3  EMIT                       emits the nullifier named by `arg`. A nullifier that is still
//                                 free can be emitted again; one that landed cannot. That is the
//                                 FAIL/SUCCEED pair the tree itself answers.
//   4  OUTER, succeeding callee   identical to mode 0 except that it calls mode 5.
//   5  INNER, succeeding          identical to mode 1 without the failure.
//
// ---------------------------------------------------------------------------------------------
// THE TWO CONTROLS, AND WHY `arg` RATHER THAN A SEVENTH MODE.
// ---------------------------------------------------------------------------------------------
//
// **The positive control is mode 4.** "Slot 2 is empty" is equally satisfied by a nested call that
// never happened, by an SSTORE that does not work, and by a reader that always answers zero. With
// the callee succeeding, the same slot holds 5151 and the same nullifier is taken — so the
// emptiness under mode 0 is a fact about the REVERT.
//
// **The instruction-count control is `arg == 1`, and it is `arg` because a seventh mode DID NOT
// WORK.** The first draft put "revert before the side effects" in modes 6 and 7. Measured, the
// outer-with-early-revert executed **139** instructions against the late-revert's **89** — MORE,
// not fewer, because a later branch of an `if`/`else if` chain costs more dispatch comparisons to
// reach, and that difference swamped the two opcodes the control exists to count. A control that is
// not run is a control that is the wrong shape. With `arg` deciding it INSIDE one branch, both arms
// take the identical dispatch path through the identical outer and the identical callee, and the
// only difference left is where the halt happens — which is what makes "the effects were MADE and
// then discarded" a measurement rather than a reading of this file.
mod avm_ops;

contract NestedEffects {
    use crate::avm_ops::{
        address_opcode, call_opcode, emit_nullifier_opcode, storage_read_opcode,
        storage_write_opcode, success_copy_opcode,
    };

    // `outputs.structs["functions"]` is what `@aztec/stdlib`'s `loadContractArtifact` reads to find
    // a public function's return type. The aztec-nr macros generate these; a hand-written contract
    // has to declare them. Inert — an unreferenced struct changes no bytecode.
    #[abi(functions)]
    pub struct public_dispatch_abi {
        return_type: Field,
    }

    #['abi_public]
    unconstrained fn public_dispatch(selector: Field, mode: Field, arg: Field) -> pub Field {
        let me = address_opcode();
        let mut out: Field = 0;
        if mode == 0 {
            storage_write_opcode(1, 4242);
            emit_nullifier_opcode(700101);
            call_opcode(2000000, 200000, me, 3, [selector, 1, arg]);
            let ok = success_copy_opcode();
            storage_write_opcode(3, if ok { 1 } else { 2 });
            out = 9;
        } else if mode == 1 {
            // `arg == 1` halts BEFORE the two side effects; anything else halts after them. Both
            // asserts are written against `mode`, which is 1 here and never 99, so neither can be
            // folded away — and both are in the SAME branch, so the two arms reach them by the
            // same dispatch path.
            if arg == 1 {
                assert(mode == 99, "nested_effects: the inner frame reverts BEFORE its side effects");
            }
            storage_write_opcode(2, 5151);
            emit_nullifier_opcode(700102);
            if arg != 1 {
                assert(mode == 99, "nested_effects: the inner frame reverts AFTER its side effects");
            }
            out = 1;
        } else if mode == 2 {
            out = storage_read_opcode(arg, me);
        } else if mode == 3 {
            emit_nullifier_opcode(arg);
            out = 3;
        } else if mode == 4 {
            storage_write_opcode(1, 4242);
            emit_nullifier_opcode(700101);
            call_opcode(2000000, 200000, me, 3, [selector, 5, 0]);
            let ok = success_copy_opcode();
            storage_write_opcode(3, if ok { 1 } else { 2 });
            out = 9;
        } else {
            storage_write_opcode(2, 5151);
            emit_nullifier_opcode(700102);
            out = 5;
        }
        out
    }
}
