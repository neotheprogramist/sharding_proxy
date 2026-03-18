// Dojo integration tests temporarily disabled.
//
// The dojo submodule's sharding API has changed:
// - IWorld::request_sharding(entities: Span<felt252>) — entity-based, not model-based
// - IShardingSettlement::settle(shard_id, keys, indices, values, hash) — commitment-based
// - IShardingSettlement::cancel_shard(shard_id) — no slots param
// - IWorld::end_shard(shard_id) — takes shard_id
//
// These tests need to be rewritten to match the new API.
// The proxy contract tests in sharding_test.cairo and test_tee_commitment.cairo
// provide coverage for the sharding component and proxy lifecycle.
