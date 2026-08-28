// No `abi_public` function at all. The transpiler must APPEND its own reverting
// `public_dispatch` (transpile_contract.rs `create_revert_dispatch_fn`), which is a code path
// nothing else in this corpus reaches.
contract PrivateOnly {
    #['abi_private]
    fn only_private(a: Field, b: Field) -> pub Field {
        a * b
    }
}
