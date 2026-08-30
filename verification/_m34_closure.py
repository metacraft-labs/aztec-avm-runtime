#!/usr/bin/env python3
"""M34's enumeration, taken with M33's walker rather than with a second one.

    _m34_closure.py <materialised-anchor-root> <group>

The walker, the resolver, the type-erasure rule, the residue categories and the dynamic-import
census are all `_m33_closure.py`'s and are imported rather than copied — this file adds four
GROUPS and nothing else. `CAMPAIGN-BRIEF.md`'s reuse discipline applies to instruments too, and a
second walker would be a second answer to one question: M25's review found two independent walks of
one closure disagreeing, which is the only reason a 2,338-line undercount was caught.

The groups, and the question each one answers:

  `basewallet`   `wallet-sdk/src/base-wallet/index.ts` ALONE — the 666-line class M34 was told to
                 subclass. M33 measured the whole wallet half (base-wallet + both handlers); this
                 is the class on its own, so "BaseWallet reaches @aztec/pxe" is a statement about
                 BaseWallet rather than about the handlers beside it.
  `entrypoints`  `@aztec/entrypoints`'s own index — the package M33 already installed, so the
                 question "is it clean" has a bearing on what M34 may call.
  `walletschema` `aztec.js/src/wallet/wallet.ts` — RI-89, re-derived here so M34's numbers do not
                 quote M33's.
  `accounts`     `@aztec/accounts`'s index, which is where upstream's account CONTRACTS live and is
                 the first place a dev wallet's key derivation would look.

Every figure this prints is re-derived and compared against `DEV-WALLET.md` by
`e2e_wallet_public_transfer` §8 on every run. (This line named the wrong check and the wrong
section until M34's review; a citation that points at nothing is how a reader concludes a figure is
unpinned when it is not, and how the next agent concludes it is pinned when it is not.)
"""

import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "_m33_closure", os.path.join(_HERE, "_m33_closure.py")
)
m33 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m33)

M34_GROUPS = {
    "basewallet": ["yarn-project/wallet-sdk/src/base-wallet/index.ts"],
    "entrypoints": ["yarn-project/entrypoints/src/index.ts"],
    "walletschema": ["yarn-project/aztec.js/src/wallet/wallet.ts"],
    "accounts": ["yarn-project/accounts/src/index.ts"],
}

if __name__ == "__main__":
    m33.GROUPS.update(M34_GROUPS)
    raise SystemExit(m33.main(sys.argv[1], sys.argv[2]))
