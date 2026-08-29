// index.ts — the replay package's public surface.
//
// L0 only. This package talks to a node and refuses everything else; it does not execute, it does
// not write a container, and it does not know what a `.ct` is. L1 adds the fetch of a settled
// transaction, L2 the historical state, L3 the recording.

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
