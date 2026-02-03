//! TEE-based sharding tests with proper StorageCommitment integration.
//!
//! These tests verify the full flow of TEE-based storage updates:
//! 1. StorageCommitment registry deployment
//! 2. Sharding contract deployment with registry reference
//! 3. Commitment registration and verification
//! 4. update_contract_state_with_proof with proper commitment checks

use core::poseidon::poseidon_hash_span;
use sharding_tests::config::{IConfigDispatcher, IConfigDispatcherTrait};
use sharding_tests::contract_component::{
    CRDType, CRDTypeTrait, IContractComponentDispatcher, IContractComponentDispatcherTrait,
};
use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
use sharding_tests::storage_commitment::{
    IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait,
};
use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};
use snforge_std as snf;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait,
};
use starknet::ContractAddress;

const OWNER: ContractAddress = 123.try_into().unwrap();

// =============================================================================
// Test Setup with proper StorageCommitment
// =============================================================================

#[derive(Drop)]
struct TeeTestSetup {
    storage_commitment_address: ContractAddress,
    storage_commitment_dispatcher: IStorageCommitmentDispatcher,
    sharding_address: ContractAddress,
    shard_dispatcher: IShardingDispatcher,
    config_dispatcher: IConfigDispatcher,
    test_contract_address: ContractAddress,
    test_contract_dispatcher: ITestContractDispatcher,
    test_contract_component_dispatcher: IContractComponentDispatcher,
    storage_commitment_spy: EventSpy,
    sharding_spy: EventSpy,
}

/// Deploy StorageCommitment contract
fn deploy_storage_commitment() -> (ContractAddress, EventSpy) {
    let contract_class = snf::declare("StorageCommitment").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    let spy = snf::spy_events();
    (contract_address, spy)
}

/// Deploy sharding contract WITH storage_commitment_registry
fn deploy_sharding_with_registry(
    owner: ContractAddress, storage_commitment_registry: ContractAddress,
) -> (ContractAddress, EventSpy) {
    let contract_class = snf::declare("sharding").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into(), storage_commitment_registry.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    let spy = snf::spy_events();
    (contract_address, spy)
}

/// Deploy test contract
fn deploy_test_contract(owner: ContractAddress) -> ContractAddress {
    let contract_class = snf::declare("test_contract").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

/// Complete setup with all contracts properly wired
fn setup_tee_test() -> TeeTestSetup {
    // 1. Deploy StorageCommitment
    let (storage_commitment_address, storage_commitment_spy) = deploy_storage_commitment();
    let storage_commitment_dispatcher = IStorageCommitmentDispatcher {
        contract_address: storage_commitment_address,
    };

    // 2. Deploy sharding WITH the storage_commitment_registry
    let (sharding_address, sharding_spy) = deploy_sharding_with_registry(
        OWNER, storage_commitment_address,
    );
    let shard_dispatcher = IShardingDispatcher { contract_address: sharding_address };
    let config_dispatcher = IConfigDispatcher { contract_address: sharding_address };

    // 3. Deploy test contract
    let test_contract_address = deploy_test_contract(OWNER);
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract_address,
    };
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract_address,
    };

    // 4. Register test contract as operator
    snf::start_cheat_caller_address(config_dispatcher.contract_address, OWNER);
    config_dispatcher.register_operator(test_contract_address);
    snf::stop_cheat_caller_address(config_dispatcher.contract_address);

    TeeTestSetup {
        storage_commitment_address,
        storage_commitment_dispatcher,
        sharding_address,
        shard_dispatcher,
        config_dispatcher,
        test_contract_address,
        test_contract_dispatcher,
        test_contract_component_dispatcher,
        storage_commitment_spy,
        sharding_spy,
    }
}

/// Initialize shard for test contract
fn initialize_shard_for_test(ref setup: TeeTestSetup, crd_type: CRDType) {
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    let contract_slots_changes = setup.test_contract_dispatcher.get_storage_slots(crd_type);

    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);
}

/// Compute commitment the same way as sharding contract
fn compute_commitment(storage_changes: Span<(felt252, felt252)>) -> u256 {
    let mut data: Array<felt252> = ArrayTrait::new();

    // First all keys
    for change in storage_changes {
        let (key, _) = *change;
        data.append(key);
    }

    // Then all values
    for change in storage_changes {
        let (_, value) = *change;
        data.append(value);
    }

    poseidon_hash_span(data.span()).into()
}

// =============================================================================
// Unit Tests: StorageCommitment Registry
// =============================================================================

#[test]
fn test_storage_commitment_register_and_verify() {
    let (address, _) = deploy_storage_commitment();
    let dispatcher = IStorageCommitmentDispatcher { contract_address: address };

    let commitment: u256 = 0x1234567890abcdef_u256;

    // Initially not verified
    assert!(!dispatcher.is_verified(commitment), "Should not be verified initially");

    // Register
    dispatcher.register_verified_commitment(commitment);

    // Now verified
    assert!(dispatcher.is_verified(commitment), "Should be verified after registration");
}

#[test]
fn test_storage_commitment_double_register_is_idempotent() {
    // Test that registering the same commitment twice doesn't break anything
    let (address, _) = deploy_storage_commitment();
    let dispatcher = IStorageCommitmentDispatcher { contract_address: address };

    let commitment: u256 = 0xcafe_u256;

    // First registration
    dispatcher.register_verified_commitment(commitment);
    assert!(dispatcher.is_verified(commitment), "Should be verified after first registration");

    // Second registration should be idempotent
    dispatcher.register_verified_commitment(commitment);
    assert!(
        dispatcher.is_verified(commitment), "Should still be verified after second registration",
    );
}

// =============================================================================
// Unit Tests: Commitment Computation
// =============================================================================

#[test]
fn test_compute_commitment_matches_expected() {
    // Test with known values
    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x100), (0x2, 0x200)];

    let commitment = compute_commitment(storage_changes.span());

    // Expected: poseidon_hash([0x1, 0x2, 0x100, 0x200])
    let expected_data: Array<felt252> = array![0x1, 0x2, 0x100, 0x200];
    let expected: u256 = poseidon_hash_span(expected_data.span()).into();

    assert!(commitment == expected, "Commitment should match expected");
}

#[test]
fn test_compute_commitment_real_slot() {
    // Test with the actual slot value from production logs
    let key: felt252 = 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854;
    let value: felt252 = 0x0;

    let storage_changes: Array<(felt252, felt252)> = array![(key, value)];
    let commitment = compute_commitment(storage_changes.span());

    // Print for debugging comparison with Rust
    println!("Real slot commitment: high={}, low={}", commitment.high, commitment.low);

    // Should match Rust-computed value
    // high=1865265751786403617475504350010045619, low=166035306803177291275924355265338905201
    let expected_high: u128 = 1865265751786403617475504350010045619;
    let expected_low: u128 = 166035306803177291275924355265338905201;

    assert!(commitment.high == expected_high, "High part should match");
    assert!(commitment.low == expected_low, "Low part should match");
}

// =============================================================================
// E2E Tests: update_contract_state_with_proof with registered commitment
// =============================================================================

#[test]
fn test_update_with_proof_success_when_commitment_registered() {
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes
    let new_value: felt252 = 42;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, new_value)];

    // Compute the commitment that the sharding contract will compute
    let commitment = compute_commitment(storage_changes.span());
    println!("Computed commitment: high={}, low={}", commitment.high, commitment.low);

    // Pre-register the commitment (simulating TEE verification flow)
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment);

    // Verify it's registered
    assert!(
        setup.storage_commitment_dispatcher.is_verified(commitment),
        "Commitment should be registered",
    );

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Now call update_contract_state_with_proof
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter was updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == new_value, "Counter should be updated to 42");
}

#[test]
#[should_panic(expected: ('Storage commitment not verified',))]
fn test_update_with_proof_fails_when_commitment_not_registered() {
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes - DO NOT register the commitment
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 99)];

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should FAIL because commitment is not registered
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
}

#[test]
#[should_panic(expected: ('Storage commitment not verified',))]
fn test_update_with_proof_fails_when_wrong_commitment_registered() {
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Register a WRONG commitment
    let wrong_commitment: u256 = 0x123456_u256;
    setup.storage_commitment_dispatcher.register_verified_commitment(wrong_commitment);

    // Create storage changes with different values
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 77)];

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should FAIL because the computed commitment won't match the registered one
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
}

#[test]
fn test_update_with_proof_multiple_slots() {
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes with multiple slots
    let other_slot: felt252 = 0x999;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 55), (other_slot, 66)];

    // Compute and register the commitment
    let commitment = compute_commitment(storage_changes.span());
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Call update_contract_state_with_proof
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter was updated (only the registered slot should be updated)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 55, "Counter should be updated to 55");
}

// =============================================================================
// E2E Tests: Real production values
// =============================================================================

#[test]
fn test_update_with_proof_production_slot_value() {
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Use the production slot from the logs
    let key: felt252 = 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854;
    let value: felt252 = 0x0;
    let storage_changes: Array<(felt252, felt252)> = array![(key, value)];

    // Compute and register the commitment
    let commitment = compute_commitment(storage_changes.span());
    println!("Production slot commitment: high={}, low={}", commitment.high, commitment.low);

    setup.storage_commitment_dispatcher.register_verified_commitment(commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should work because commitment is registered
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);
    // Storage was updated (even though slot doesn't match counter slot, the flow succeeded)
}

// =============================================================================
// Edge case tests
// =============================================================================

#[test]
fn test_commitment_with_zero_value() {
    // Verify that zero values work correctly
    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x0)];
    let commitment = compute_commitment(storage_changes.span());

    // Should not be zero even though value is zero
    assert!(commitment != 0_u256, "Commitment should not be zero even with zero value");
}

// =============================================================================
// Replay Attack Protection Tests
// =============================================================================

#[test]
#[should_panic(expected: ('Component: Storage is unlocked',))]
fn test_replay_attack_prevented_same_shard_same_commitment() {
    // This test verifies that replay attacks are prevented by the sharding slot unlocking
    // mechanism.
    // Even though the commitment remains in the registry after first use, trying to use
    // the same shard_id again will fail because the storage slot is no longer unlocked.
    let mut setup = setup_tee_test();

    // Initialize shard with SetLock (one-time use per shard)
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];

    // Compute and register the commitment
    let commitment = compute_commitment(storage_changes.span());
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // First update succeeds
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(
            setup.test_contract_address, storage_changes.clone(), shard_id,
        );

    // Second update with SAME shard_id and SAME commitment should FAIL
    // This is the replay attack that gets prevented
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes2, shard_id);
    // Should panic with 'Component: Storage is unlocked' before reaching this point
}

#[test]
#[should_panic(expected: ('Component: Storage is unlocked',))]
fn test_replay_attack_prevented_same_shard_different_value() {
    // Even with a different value (different commitment), replay attack is still prevented
    // because the shard slot itself is locked after first use.
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // First update with value 42
    let storage_changes1: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let commitment1 = compute_commitment(storage_changes1.span());
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment1);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // First update succeeds
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes1, shard_id);

    // Second update with DIFFERENT value (different commitment) but SAME shard_id
    // This should also fail because the shard slot is locked
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    let commitment2 = compute_commitment(storage_changes2.span());
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment2);

    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes2, shard_id);
    // Should panic with 'Component: Storage is unlocked' before reaching this point
}

#[test]
fn test_commitment_remains_in_registry_after_use() {
    // Verify that the commitment stays in the registry even after being used.
    // Replay protection comes from the sharding slot mechanism, not the registry.
    let mut setup = setup_tee_test();

    // Initialize shard
    initialize_shard_for_test(
        ref setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let commitment = compute_commitment(storage_changes.span());
    setup.storage_commitment_dispatcher.register_verified_commitment(commitment);

    // Verify commitment is registered
    assert!(
        setup.storage_commitment_dispatcher.is_verified(commitment),
        "Commitment should be registered before use",
    );

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Use the commitment
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_with_proof(setup.test_contract_address, storage_changes, shard_id);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Commitment should STILL be in registry after use
    // (replay protection is from shard unlocking, not registry clearing)
    assert!(
        setup.storage_commitment_dispatcher.is_verified(commitment),
        "Commitment should remain in registry after use",
    );
}

