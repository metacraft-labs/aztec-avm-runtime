// simulator_selection.ts — which AVM implementation runs, as a NAMED CONFIGURATION.
//
// THE INVERSION THIS FILE EXISTS TO END.
//
// Upstream selects between AVM implementations with a boolean called `useCppSimulator`, and the
// suites it labels read `(TS Simulator)` and `(Cpp Simulator)`. Both names are wrong about what
// they select, and the campaign has already paid for it once: M2's headline coverage figure was
// overstated by a factor of ten because "756 passing tests" was read as 756 differential
// comparisons when the real number is 77.
//
// Re-derived here from the fork at 3a68d68ac2 rather than from the earlier write-up, at the two
// places that decide it:
//
//   yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts:92-100
//     useCppSimulator = false,
//     const simulatorFactory: MeasuredSimulatorFactory = useCppSimulator
//       ? (mt, cdb, g, m, c) => new MeasuredCppPublicTxSimulator(mt, cdb, g, m, c)
//       : (mt, cdb, g, m, c) => new MeasuredCppVsTsPublicTxSimulator(mt, cdb, g, m, c);
//
//   yarn-project/simulator/src/public/public_processor/apps_tests/deployments.test.ts:51-55
//     // TS mode: use CppVsTs to compare TS and C++ results
//     // C++ mode: use only C++ (pure Cpp simulator)
//
// So `useCppSimulator: false` selects `CppVsTsPublicTxSimulator` — the DIFFERENTIAL harness,
// which runs the TypeScript interpreter AND the C++ AVM and compares them. The suites labelled
// `(TS Simulator)` are the differential ones; the suites labelled `(Cpp Simulator)` compare
// nothing. There is no pure-TypeScript suite anywhere in the tree, and the `(TS Simulator)`
// suites still require the native addon, because `cpp_vs_ts_public_tx_simulator.ts` imports
// `avmSimulate` from `@aztec/native`.
//
// WHY A NAMED CONFIGURATION AND NOT AN ENVIRONMENT VARIABLE. An environment variable reproduces
// the defect in a new spelling: it is a boolean, read far from where it is decided, whose name
// has to carry the whole meaning and cannot be type-checked. A closed union of names that say
// what they DO can be exhaustively switched, so adding an implementation is a compile error at
// every site that dispatches on it rather than a silent default.
//
// The names below describe the artefact that executes, not the language anyone associates with
// it. `AVM_IMPLEMENTATIONS` is ordered and exported so a report can print the whole vocabulary
// rather than the one it happened to select.

/**
 * Which AVM implementation a configuration runs. One member per artefact that can execute a
 * transaction, plus one for the pair that executes two and compares.
 */
export type AvmImplementation =
  /** Aztec's C++ AVM compiled to wasm32-wasip1, driven through avm.wasm. What this runtime ships. */
  | 'wasm-avm'
  /** Aztec's C++ AVM as the native NAPI addon in @aztec/bb.js. Reachable only from differential/. */
  | 'native-cpp-avm'
  /** The revived TypeScript interpreter, as a reference implementation and a second opinion. */
  | 'typescript-interpreter'
  /** Two implementations, run against one pre-transaction state and compared field by field. */
  | 'differential';

export const AVM_IMPLEMENTATIONS: readonly AvmImplementation[] = [
  'wasm-avm',
  'native-cpp-avm',
  'typescript-interpreter',
  'differential',
] as const;

/** A named configuration: which implementation runs, and — if two do — which two. */
export interface AvmConfiguration {
  readonly name: string;
  readonly implementation: AvmImplementation;
  /** Populated only for `differential`; the pair, in the order they run. */
  readonly compares?: readonly [AvmImplementation, AvmImplementation];
  /** True only of the configuration this runtime ships. Exactly one is. */
  readonly isDefault: boolean;
  /** What upstream's `useCppSimulator` boolean would have to be to select the same thing. */
  readonly upstreamUseCppSimulator: boolean | null;
  /** The upstream suite label that selects it, where one exists — recorded because it lies. */
  readonly upstreamSuiteLabel: string | null;
  readonly why: string;
}

export const WASM_AVM: AvmConfiguration = {
  name: 'wasm-avm',
  implementation: 'wasm-avm',
  isDefault: true,
  upstreamUseCppSimulator: null,
  upstreamSuiteLabel: null,
  why: 'The shipped interpreter. Aztec\'s own C++ AVM compiled to wasm32-wasip1, byte-identical '
    + 'to native on the corpus, with no native addon and no server.',
};

export const NATIVE_CPP_AVM: AvmConfiguration = {
  name: 'native-cpp-avm',
  implementation: 'native-cpp-avm',
  isDefault: false,
  upstreamUseCppSimulator: true,
  upstreamSuiteLabel: '(Cpp Simulator)',
  why: 'The oracle M19 compares against, not a shipping configuration. Upstream labels the '
    + 'suites that select it "(Cpp Simulator)", which is the one label of the two that is '
    + 'accurate — and those suites compare nothing.',
};

export const TYPESCRIPT_INTERPRETER: AvmConfiguration = {
  name: 'typescript-interpreter',
  implementation: 'typescript-interpreter',
  isDefault: false,
  upstreamUseCppSimulator: null,
  upstreamSuiteLabel: null,
  why: 'The revived TypeScript interpreter ALONE. Upstream has no configuration that selects '
    + 'this — `useCppSimulator: false` selects the differential pair, not the interpreter — so '
    + 'this name exists in our tree and not in theirs.',
};

export const DIFFERENTIAL_TS_VS_NATIVE_CPP: AvmConfiguration = {
  name: 'differential-typescript-vs-native-cpp',
  implementation: 'differential',
  compares: ['typescript-interpreter', 'native-cpp-avm'],
  isDefault: false,
  upstreamUseCppSimulator: false,
  upstreamSuiteLabel: '(TS Simulator)',
  why: 'THE INVERSION. Upstream\'s `useCppSimulator: false` selects CppVsTsPublicTxSimulator, '
    + 'which runs the TypeScript interpreter inside a checkpoint, reverts it, runs the C++ AVM '
    + 'from the identical pre-transaction state, and compares. The suites it labels '
    + '"(TS Simulator)" are these. Reading that label as "the TypeScript simulator ran" is what '
    + 'turned 77 comparisons into a reported 756.',
};

export const DIFFERENTIAL_WASM_VS_NATIVE_CPP: AvmConfiguration = {
  name: 'differential-wasm-vs-native-cpp',
  implementation: 'differential',
  compares: ['wasm-avm', 'native-cpp-avm'],
  isDefault: false,
  upstreamUseCppSimulator: null,
  upstreamSuiteLabel: null,
  why: 'M19\'s own arm: the shipped interpreter against the oracle. Upstream has no '
    + 'configuration for it because upstream has no wasm AVM.',
};

export const AVM_CONFIGURATIONS: readonly AvmConfiguration[] = [
  WASM_AVM,
  NATIVE_CPP_AVM,
  TYPESCRIPT_INTERPRETER,
  DIFFERENTIAL_TS_VS_NATIVE_CPP,
  DIFFERENTIAL_WASM_VS_NATIVE_CPP,
] as const;

/**
 * The configuration this runtime uses unless a caller names another. It is a constant and not a
 * function of the environment: DD-9's requirement is that no reachable path DEFAULTS to the C++
 * simulator, and a default read out of `process.env` is a default that a deployment can change
 * without a code review.
 */
export function defaultConfiguration(): AvmConfiguration {
  return WASM_AVM;
}

export function configurationByName(name: string): AvmConfiguration | undefined {
  return AVM_CONFIGURATIONS.find((c) => c.name === name);
}

/**
 * True when a configuration actually compares two implementations. `differential` is the only
 * implementation for which `compares` is populated, and this is the predicate a coverage report
 * should count with — the count of COMPARISONS, which is the figure M19 requires to be reported
 * separately from the test count.
 */
export function isDifferential(c: AvmConfiguration): boolean {
  return c.implementation === 'differential' && c.compares !== undefined;
}

/**
 * The translation, in one place, so nobody has to remember it. Given upstream's boolean, the
 * configuration it selects.
 *
 * `false` -> the differential pair. `true` -> the C++ AVM alone. That is the whole inversion,
 * and it is a function here rather than a comment so that a caller who gets it backwards gets a
 * different configuration rather than a different sentence.
 */
export function fromUpstreamUseCppSimulator(useCppSimulator: boolean): AvmConfiguration {
  return useCppSimulator ? NATIVE_CPP_AVM : DIFFERENTIAL_TS_VS_NATIVE_CPP;
}

/**
 * Whether a configuration can reach the native NAPI AVM. M19's containment requirement is that
 * the shipped package's import graph holds no `@aztec/native`; this is the same statement at the
 * level of configurations, so a caller can refuse one before it tries to load anything.
 */
export function reachesNativeAddon(c: AvmConfiguration): boolean {
  return (
    c.implementation === 'native-cpp-avm' ||
    (c.compares?.includes('native-cpp-avm') ?? false)
  );
}
