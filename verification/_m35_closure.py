#!/usr/bin/env python3
"""M35's enumeration, taken with M33's walker rather than with a second one.

    _m35_closure.py <materialised-anchor-root> <group>

The walker, the resolver, the type-erasure rule, the residue categories and the dynamic-import
census are all `_m33_closure.py`'s and are imported rather than copied — this file adds five
GROUPS and nothing else, which is what `_m34_closure.py` did for M34. `CAMPAIGN-BRIEF.md`'s reuse
discipline applies to instruments too, and a second walker would be a second answer to one
question: M25's review found two independent walks of one closure disagreeing, which is the only
reason a 2,338-line undercount was caught.

The groups, and the question each one answers:

  `simulator`     `simulator/src/private/acvm_wasm.ts` — RI-64's WASMSimulator. M35 VENDORS this,
                  and the entry exists so RI-64's "six files, 711 lines" is re-derived on every run
                  rather than quoted from a milestone that measured it four milestones ago.
  `oraclewire`    `pxe/src/contract_function_simulator/oracle/acir_callback.ts` — the oracle WIRE
                  layer: the 68-entry registry, its type mappings, the ACIR callback that
                  dispatches into a handler, the legacy aliases and the Noir struct codecs. M35
                  VENDORS this too, because the wire ABI is upstream's and reimplementing a
                  serialisation format is how a fabricated value gets into a transaction.
  `privhandler`   `.../oracle/private_execution_oracle.ts` — upstream's own handler for the 16
                  `prv` oracles. M35 does NOT vendor it; the group exists so the rejection has a
                  measured cost beside it rather than an assertion that it would be large.
  `utlhandler`    `.../oracle/utility_execution_oracle.ts` — the same for the 49 `utl` oracles.
  `cfsim`         `.../contract_function_simulator.ts` — the 926-line file RI-65 names, whose
                  `generateSimulatedProvingResult` is the function `@aztec/pxe/simulator` exports
                  and `wallet-sdk/src/base-wallet/utils.ts` reaches for. RI-65 recorded that its
                  closure "has not been computed"; this group computes it.

Every figure this prints is re-derived and compared against `PRIVATE-EXECUTION.md` by
`verify_oracle_coverage_is_measured` on every run.
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

CFS = "yarn-project/pxe/src/contract_function_simulator"

M35_GROUPS = {
    "simulator": ["yarn-project/simulator/src/private/acvm_wasm.ts"],
    "oraclewire": [f"{CFS}/oracle/acir_callback.ts"],
    "privhandler": [f"{CFS}/oracle/private_execution_oracle.ts"],
    "utlhandler": [f"{CFS}/oracle/utility_execution_oracle.ts"],
    "cfsim": [f"{CFS}/contract_function_simulator.ts"],
}

if __name__ == "__main__":
    m33.GROUPS.update(M35_GROUPS)
    raise SystemExit(m33.main(sys.argv[1], sys.argv[2]))
