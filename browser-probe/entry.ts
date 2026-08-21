// Browser-viability probe: import the TypeScript AVM execution path only
// (no C++ simulator, no fuzzing CLI, no test fixtures).
export { AvmSimulator } from '../spike/src/public/avm/avm_simulator.js';
export { PublicTxSimulator } from '../spike/src/public/public_tx_simulator/public_tx_simulator.js';
export { PublicPersistableStateManager } from '../spike/src/public/state_manager/state_manager.js';
export { PublicSideEffectTrace } from '../spike/src/public/side_effect_trace.js';
export { PublicContractsDB, PublicTreesDB } from '../spike/src/public/public_db_sources.js';
export { PublicProcessor } from '../spike/src/public/public_processor/public_processor.js';
export { GuardedMerkleTreeOperations } from '../spike/src/public/public_processor/guarded_merkle_tree.js';
