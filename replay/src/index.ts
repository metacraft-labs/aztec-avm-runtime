// index.ts — the replay package's public surface.
//
// L0 and L1. This package talks to a node, refuses everything else, and turns a transaction hash
// into an upstream `Tx` plus the block coordinates and contract artifacts a replay needs. It does
// not execute, it does not write a container, and it does not know what a `.ct` is. L2 adds the
// historical state, L3 the recording.

export {
  ANCHOR_ONLY_METHODS,
  AZTEC_NODE_METHOD_COUNT,
  PACKAGE_ONLY_METHODS,
  REFUSAL_GROUPS,
  REFUSED_METHODS,
  REPLAY_NODE_SURFACE,
  type RefusalGroup,
  type ReplayNodeMethod,
  type ReplayNodeSurface,
} from './node_surface.ts';

export {
  ALLOWED_SURFACE,
  NodeUnreachable,
  ProtocolVersionMismatch,
  REPLAY_CLIENT_OWN_MEMBERS,
  ReplayNodeSurfaceExceeded,
  SettledTransactionNotFound,
  createReplayNodeClient,
  createUnguardedNodeClientForControls,
  type ObservedVersionHeaders,
  type ReplayNodeClient,
  type ReplayNodeClientOptions,
} from './node_client.ts';

export { strictSurface } from './strict_surface.ts';

export {
  COMPONENTS_VERSION_FIELDS,
  PINNED_NETWORK,
  PINNED_PROTOCOL_VERSION,
  type ComponentsVersionField,
} from './pinned_protocol_version.ts';

export {
  MEMBERSHIP_WITNESS_QUERIES,
  type AssertReplayClientIsAWitnessSource,
  type MembershipWitnessQuery,
  type MembershipWitnessSource,
} from './membership_witness_source.ts';

// ---- L1 ------------------------------------------------------------------------------------

export {
  CONTRACT_RESOLUTION_METHODS,
  CONTRACT_RESOLUTION_REFERENCE_BLOCK,
  MISSING_ARTIFACT_STAGES,
  MissingContractArtifact,
  SettlingBlockUnavailable,
  declarePublicHalf,
  fetchSettledTransaction,
  publicCallTargets,
  resolvePublicContracts,
  resolvePublicContractsUnguardedForControls,
  type ContractReferenceBlock,
  type ContractResolution,
  type FetchSettledTransactionOptions,
  type MissingArtifactStage,
  type PublicHalfDeclaration,
  type SettledTransaction,
} from './settled_transaction.ts';

export {
  PRIVATE_HALF_AVAILABLE,
  PRIVATE_HALF_AVAILABLE_REASON,
  PRIVATE_HALF_UNAVAILABLE,
  PRIVATE_HALF_UNAVAILABLE_REASON,
  declarePrivateHalf,
  measureLocalPrivateExecution,
  type LocalPrivateExecution,
  type PrivateHalfDeclaration,
  type PrivateHalfSource,
  type PublishedPrivateEffects,
} from './private_half.ts';

// THE FIXTURE FORMAT IS DELIBERATELY NOT RE-EXPORTED HERE. It lives in `replay/tools/
// settled_fixture.ts` because it assembles a JSON-RPC envelope by hand, and L0's
// `verify_client_uses_upstream_schema` asserts that nothing in `replay/src` declares a wire type —
// which is the invariant that says this client's request and response types are upstream's alone.
// That check is what moved the file; see its header. A caller who wants to record or replay a
// fixture imports it from `replay/tools/settled_fixture.ts` on purpose.
