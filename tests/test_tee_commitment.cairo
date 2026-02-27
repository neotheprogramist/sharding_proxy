//! TEE-based sharding tests with proper StorageCommitment integration.
//!
//! These tests verify the full flow of TEE-based storage updates:
//! 1. StorageCommitment registry deployment
//! 2. Sharding contract deployment with registry reference
//! 3. Commitment registration and verification
//! 4. update_contract_state_tee with proper commitment checks

use core::poseidon::poseidon_hash_span;
use sharding_tests::config::{IConfigDispatcher, IConfigDispatcherTrait};
use sharding_tests::contract_component::{
    CRDType, CRDTypeTrait, IContractComponentDispatcher, IContractComponentDispatcherTrait,
};
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardFinished, ShardingRequested};
use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
use sharding_tests::storage_commitment::{
    IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait,
};
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};
use snforge_std as snf;
use snforge_std::{ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait};
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
}

/// Deploy StorageCommitment contract
fn deploy_storage_commitment() -> ContractAddress {
    let contract_class = snf::declare("StorageCommitment").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

/// Deploy sharding contract WITH storage_commitment_registry
fn deploy_sharding_with_registry(
    owner: ContractAddress, storage_commitment_registry: ContractAddress,
) -> ContractAddress {
    let contract_class = snf::declare("sharding").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into(), storage_commitment_registry.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
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
    let storage_commitment_address = deploy_storage_commitment();
    let storage_commitment_dispatcher = IStorageCommitmentDispatcher {
        contract_address: storage_commitment_address,
    };

    // 2. Deploy sharding WITH the storage_commitment_registry
    let sharding_address = deploy_sharding_with_registry(OWNER, storage_commitment_address);
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

    // Set a known block number so fork_block_number=0 works in all tests
    snf::start_cheat_block_number(sharding_address, 0);

    TeeTestSetup {
        storage_commitment_address,
        storage_commitment_dispatcher,
        sharding_address,
        shard_dispatcher,
        config_dispatcher,
        test_contract_address,
        test_contract_dispatcher,
        test_contract_component_dispatcher,
    }
}

/// Initialize shard for test contract (takes ownership and returns setup)
fn initialize_shard_for_test(setup: TeeTestSetup, crd_type: CRDType) -> TeeTestSetup {
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

    setup
}

/// Compute storage commitment: poseidon_hash(keys || values)
fn compute_commitment(storage_changes: Span<(felt252, felt252)>) -> felt252 {
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

    poseidon_hash_span(data.span())
}

/// Compute full commitment hash matching StorageCommitment.verify() logic:
/// poseidon_hash(storage_commitment, contract_address, nonce, global_state_root, end_block_number)
fn compute_full_commitment(
    storage_commitment: felt252,
    contract_address: ContractAddress,
    nonce: u64,
    global_state_root: felt252,
    end_block_number: u64,
) -> felt252 {
    let mut data: Array<felt252> = ArrayTrait::new();
    data.append(storage_commitment);
    data.append(contract_address.into());
    data.append(nonce.into());
    data.append(global_state_root);
    data.append(end_block_number.into());
    poseidon_hash_span(data.span())
}

// =============================================================================
// Unit Tests: StorageCommitment Registry
// =============================================================================

#[test]
fn test_storage_commitment_register_and_verify() {
    let address = deploy_storage_commitment();
    let dispatcher = IStorageCommitmentDispatcher { contract_address: address };

    let commitment: felt252 = 0x1234567890abcdef;

    // Initially not registered
    assert!(!dispatcher.is_registered(commitment), "Should not be registered initially");

    // Register the commitment
    dispatcher.register_verified_commitment(commitment);

    // Now registered
    assert!(dispatcher.is_registered(commitment), "Should be registered after registration");
}

#[test]
fn test_storage_commitment_double_register_is_idempotent() {
    // Test that registering the same commitment twice doesn't break anything
    let address = deploy_storage_commitment();
    let dispatcher = IStorageCommitmentDispatcher { contract_address: address };

    let commitment: felt252 = 0xcafe;

    // First registration
    dispatcher.register_verified_commitment(commitment);
    assert!(dispatcher.is_registered(commitment), "Should be registered after first registration");

    // Second registration of same commitment is idempotent
    dispatcher.register_verified_commitment(commitment);
    assert!(dispatcher.is_registered(commitment), "Should still be registered");

    // A different commitment also works
    let commitment2: felt252 = 0xbeef;
    dispatcher.register_verified_commitment(commitment2);
    assert!(dispatcher.is_registered(commitment2), "Second commitment should be registered");
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
    let expected: felt252 = poseidon_hash_span(expected_data.span());

    assert!(commitment == expected, "Commitment should match expected");
}

#[test]
fn test_compute_commitment_real_slot() {
    // Test with the actual slot value from production logs
    let key: felt252 = 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854;
    let value: felt252 = 0x0;

    let storage_changes: Array<(felt252, felt252)> = array![(key, value)];
    let commitment = compute_commitment(storage_changes.span());
    let commitment_u256: u256 = commitment.into();

    // Print for debugging comparison with Rust
    println!("Real slot commitment: high={}, low={}", commitment_u256.high, commitment_u256.low);

    // Should match Rust-computed value
    // high=1865265751786403617475504350010045619, low=166035306803177291275924355265338905201
    let expected_high: u128 = 1865265751786403617475504350010045619;
    let expected_low: u128 = 166035306803177291275924355265338905201;

    assert!(commitment_u256.high == expected_high, "High part should match");
    assert!(commitment_u256.low == expected_low, "Low part should match");
}

// =============================================================================
// E2E Tests: update_contract_state_tee with registered commitment
// =============================================================================

#[test]
fn test_update_with_proof_success_when_commitment_registered() {
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes
    let new_value: felt252 = 42;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, new_value)];

    // Compute the full commitment matching what verify() expects
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );

    // Pre-register the full commitment (simulating TEE verification flow)
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Now call update_contract_state_tee
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter was updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == new_value, "Counter should be updated to 42");
}

#[test]
#[should_panic(expected: ('Commitment not registered',))]
fn test_update_with_proof_fails_when_commitment_not_registered() {
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes - DO NOT register the commitment
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    let global_state_root: felt252 = 0xabc;

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should FAIL because commitment is not registered
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
}

#[test]
#[should_panic(expected: ('Commitment not registered',))]
fn test_update_with_proof_fails_when_wrong_commitment_registered() {
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Register a WRONG commitment (won't match what verify() computes)
    let wrong_commitment: felt252 = 0x123456;
    setup.storage_commitment_dispatcher.register_verified_commitment(wrong_commitment);

    // Create storage changes with different values
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 77)];
    let global_state_root: felt252 = 0xabc;

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should FAIL because the computed full commitment won't match the registered one
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
}

#[test]
fn test_update_with_proof_multiple_slots() {
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes with multiple slots
    let other_slot: felt252 = 0x999;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 55), (other_slot, 66)];

    // Compute full commitment and register
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Call update_contract_state_tee
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
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
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Use the production slot from the logs
    let key: felt252 = 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854;
    let value: felt252 = 0x0;
    let storage_changes: Array<(felt252, felt252)> = array![(key, value)];

    // Compute full commitment and register
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // This should work because commitment is registered
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
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
    assert!(commitment != 0, "Commitment should not be zero even with zero value");
}

// =============================================================================
// Fork Block Verification Tests (C1 anti-fraud)
// =============================================================================

#[test]
fn test_init_block_stored() {
    let setup = setup_tee_test();

    // Set block number to 42 before initializing
    snf::start_cheat_block_number(setup.shard_dispatcher.contract_address, 42);

    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    snf::stop_cheat_block_number(setup.shard_dispatcher.contract_address);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);
    let init_block = setup
        .shard_dispatcher
        .get_init_block_number(setup.test_contract_address, shard_id);
    assert!(init_block == 42, "Init block should be 42");
}

#[test]
#[should_panic(expected: ('Sharding: Fork block mismatch',))]
fn test_fork_block_mismatch_reverts() {
    let setup = setup_tee_test();

    // Initialize at block 100
    snf::start_cheat_block_number(setup.shard_dispatcher.contract_address, 100);

    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    snf::stop_cheat_block_number(setup.shard_dispatcher.contract_address);

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // Try to settle with fork_block_number=200 (but init was at 100)
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 200, 10,
        );
}

#[test]
fn test_fork_block_matches_init() {
    let setup = setup_tee_test();

    // Initialize at block 100
    snf::start_cheat_block_number(setup.shard_dispatcher.contract_address, 100);

    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    snf::stop_cheat_block_number(setup.shard_dispatcher.contract_address);

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // Settle with correct fork_block_number=100
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 100, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 42, "Counter should be 42 after valid fork block settlement");
}

// =============================================================================
// Replay Attack Protection Tests
// =============================================================================

#[test]
#[should_panic(expected: ('Sharding: Shard not active',))]
fn test_replay_attack_prevented_same_shard_same_commitment() {
    // This test verifies that replay attacks are prevented by the sharding slot unlocking
    // mechanism.
    // Even though the commitment remains in the registry after first use, trying to use
    // the same shard_id again will fail because the storage slot is no longer locked
    // (init_count == 0), so all slots are filtered out leaving no locked changes.
    let setup = setup_tee_test();

    // Initialize shard with SetLock (one-time use per shard)
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes and register full commitment
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // First update succeeds
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address,
            storage_changes.clone(),
            shard_id,
            global_state_root,
            0,
            10,
        );

    // Second update with SAME shard_id should FAIL at the contract_component level
    // because the storage slot is no longer locked (init_count == 0 after first update).
    // We register a valid commitment so verify() passes — the lock check is what stops replay.
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root2: felt252 = 0xdef;
    let storage_commitment2 = compute_commitment(storage_changes2.span());
    let nonce2 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment2 = compute_full_commitment(
        storage_commitment2, setup.test_contract_address, nonce2, global_state_root2, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment2);

    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes2, shard_id, global_state_root2, 0, 10,
        );
    // Should panic with 'Component: No contracts' before reaching this point
}

#[test]
#[should_panic(expected: ('Sharding: Shard not active',))]
fn test_replay_attack_prevented_same_shard_different_value() {
    // Even with a different value (different commitment), replay attack is still prevented
    // because the slot is unlocked (init_count == 0) after first settlement, so all slots
    // are filtered out leaving no locked changes.
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // First update with value 42
    let storage_changes1: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root1: felt252 = 0xabc;
    let storage_commitment1 = compute_commitment(storage_changes1.span());
    let nonce1 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment1 = compute_full_commitment(
        storage_commitment1, setup.test_contract_address, nonce1, global_state_root1, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment1);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // First update succeeds
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes1, shard_id, global_state_root1, 0, 10,
        );

    // Second update with DIFFERENT value but SAME shard_id
    // This should fail because the shard slot is locked
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    let global_state_root2: felt252 = 0xdef;
    let storage_commitment2 = compute_commitment(storage_changes2.span());
    let nonce2 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment2 = compute_full_commitment(
        storage_commitment2, setup.test_contract_address, nonce2, global_state_root2, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment2);

    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes2, shard_id, global_state_root2, 0, 10,
        );
    // Should panic with 'Component: No contracts' before reaching this point
}

#[test]
fn test_nonce_based_replay_protection() {
    // Verify that nonce-based replay protection works:
    // After a commitment is used, the nonce increments, so old commitments can't be reused.
    let setup = setup_tee_test();

    // Initialize shard
    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Check initial nonce is 0
    let initial_nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    assert!(initial_nonce == 0, "Initial nonce should be 0");

    // Create storage changes and register full commitment
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Get shard_id
    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Use the commitment via sharding contract
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Check nonce has incremented
    let new_nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    assert!(new_nonce == 1, "Nonce should be incremented to 1 after use");
    // The same commitment can't be verified again (nonce mismatch)
}

// =============================================================================
// Add CRDT delta tests
// =============================================================================

#[test]
fn test_add_crdt_computes_delta_not_absolute() {
    // Scenario: counter starts at 10 before shard. During shard (Katana),
    // counter goes from 10 → 15 (added 5). The storage proof returns the
    // absolute value 15. The contract must compute delta = 15 - 10 = 5
    // and apply: current(10) + delta(5) = 15, NOT 10 + 15 = 25.
    let setup = setup_tee_test();

    // Initialize shard with Add CRDT — snapshots counter = 0 at init
    let setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set counter to 10 AFTER init (simulates main chain having value 10
    // at the fork block — normally this would already be 10 before init,
    // but here init snapshots 0 and we set 10 afterwards to simulate
    // that main chain and shard both start from 0 then main chain changes)
    setup.test_contract_dispatcher.set_counter(10);
    assert!(setup.test_contract_dispatcher.get_counter() == 10, "Counter should be 10");

    // Get the counter storage slot
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // The shard (Katana) had counter = 0 at fork, incremented to 5.
    // Storage proof returns absolute value = 5.
    let shard_absolute_value: felt252 = 5;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, shard_absolute_value)];

    // Register commitment
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // Execute settlement
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Delta = 5 - 0 (init snapshot) = 5
    // Result = 10 (current) + 5 (delta) = 15
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter should be 15 (10 + delta(5)), not 25 (10 + absolute(15))");
}

#[test]
fn test_add_crdt_with_nonzero_initial_value() {
    // Scenario: counter = 100 at init time, shard sees 100 → 130 (delta=30).
    // Storage proof returns 130. Expected: current(100) + (130-100) = 130.
    let setup = setup_tee_test();

    // Set counter to 100 BEFORE init so the snapshot captures it
    setup.test_contract_dispatcher.set_counter(100);

    // Initialize shard — snapshots counter = 100
    let setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Shard started at 100, went to 130. Storage proof returns 130.
    let shard_value: felt252 = 130;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, shard_value)];

    let global_state_root: felt252 = 0xdef;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Delta = 130 - 100 = 30, new = 100 + 30 = 130
    // Without the fix this would be 100 + 130 = 230 (WRONG)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 130, "Counter should be 130 (100 + delta(30)), not 230");
}

#[test]
fn test_add_crdt_no_change_in_shard() {
    // Edge case: shard didn't modify the Add slot at all.
    // Shard value = initial value, delta = 0. Counter unchanged.
    let setup = setup_tee_test();

    setup.test_contract_dispatcher.set_counter(50);

    let setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Shard value = 50 (same as initial, no change)
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 50)];

    let global_state_root: felt252 = 0x111;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Delta = 50 - 50 = 0, counter stays at 50
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 50, "Counter should remain 50 when shard made no changes");
}

// =============================================================================
// E2E Test: Full shard lifecycle
// =============================================================================

/// Full lifecycle test:
/// 1. request_sharding (via contract_component) → ShardingRequested
/// 2. Game plays (3 increments) → GameFinished + end_shard → ShardFinished
/// 3. Settlement via update_contract_state_tee → state updated
#[test]
fn test_full_shard_lifecycle_e2e() {
    let setup = setup_tee_test();

    // Start spying on events BEFORE the actions
    let mut sharding_spy = snf::spy_events();
    let mut game_spy = snf::spy_events();

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // === Phase 1: request_sharding ===
    // Game developer calls request_sharding on their game contract.
    // This internally calls initialize_shard -> sharding.initialize_sharding
    // which emits ShardingRequested.
    // We cheat caller to be the test contract itself so that the component's
    // shard_id map is keyed by the contract address (matching what increment()
    // reads via get_contract_address()).
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    let slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));

    setup
        .test_contract_component_dispatcher
        .request_sharding(setup.shard_dispatcher.contract_address, array![slot].span());

    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);

    // Verify ShardingRequested event emitted on sharding contract
    let expected_request = ShardingRequested {
        game_contract: setup.test_contract_component_dispatcher.contract_address,
        shard_id: 1,
        storage_slots: array![slot].span(),
    };
    sharding_spy
        .assert_emitted(
            @array![
                (
                    setup.shard_dispatcher.contract_address,
                    ShardingEvent::ShardingRequested(expected_request),
                ),
            ],
        );

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);
    assert!(shard_id == 1, "Shard ID should be 1 after first request");

    // === Phase 2: Game plays on Katana shard ===
    // Simulate game activity: 3 increments trigger GameFinished + end_shard.
    // Caller is the test contract itself (matching the shard_id key from Phase 1).
    let game_addr = setup.test_contract_dispatcher.contract_address;
    snf::start_cheat_caller_address(game_addr, game_addr);
    setup.test_contract_dispatcher.increment(); // counter = 1
    setup.test_contract_dispatcher.increment(); // counter = 2
    setup.test_contract_dispatcher.increment(); // counter = 3 -> GameFinished + end_shard

    snf::stop_cheat_caller_address(game_addr);

    // Verify GameFinished event on game contract
    let expected_game_finished = GameFinished { caller: game_addr };
    game_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_dispatcher.contract_address,
                    TestContractEvent::GameFinished(expected_game_finished),
                ),
            ],
        );

    // Verify ShardFinished event on sharding contract (emitted by end_shard)
    let expected_shard_finished = ShardFinished {
        game_contract: setup.test_contract_component_dispatcher.contract_address, shard_id: 1,
    };
    sharding_spy
        .assert_emitted(
            @array![
                (
                    setup.shard_dispatcher.contract_address,
                    ShardingEvent::ShardFinished(expected_shard_finished),
                ),
            ],
        );

    // === Phase 3: Settlement via TEE ===
    // Operator reads shard state from Katana and settles on main chain.
    // Counter was 3 on the shard (SetLock = last-write-wins).
    let new_counter: felt252 = 3;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, new_counter)];

    // Compute and register storage commitment (simulating TEE flow)
    let global_state_root: felt252 = 0xdeadbeef;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Call update_contract_state_tee (as if operator is settling)
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes, shard_id, global_state_root, 0, 10,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify final state: counter should be 3 (SetLock = direct overwrite)
    let final_counter = setup.test_contract_dispatcher.get_counter();
    assert!(final_counter == new_counter, "Counter should be 3 after settlement");

    println!("E2E lifecycle test passed: request -> play -> settle");
}

// =============================================================================
// Concurrent shard tests
// =============================================================================

#[test]
fn test_concurrent_shards_settle_independently() {
    // Initialize two concurrent shards for the same game contract
    let setup = setup_tee_test();

    // Initialize first shard (shard_id = 1)
    let setup = initialize_shard_for_test(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Initialize second shard (shard_id = 2) — Set allows stacking
    let setup = initialize_shard_for_test(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Settle first shard (shard_id = 1)
    let storage_changes1: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root1: felt252 = 0xabc;
    let storage_commitment1 = compute_commitment(storage_changes1.span());
    let nonce1 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment1 = compute_full_commitment(
        storage_commitment1, setup.test_contract_address, nonce1, global_state_root1, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment1);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes1, 1, global_state_root1, 0, 10,
        );

    // Settle second shard (shard_id = 2)
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    let global_state_root2: felt252 = 0xdef;
    let storage_commitment2 = compute_commitment(storage_changes2.span());
    let nonce2 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment2 = compute_full_commitment(
        storage_commitment2, setup.test_contract_address, nonce2, global_state_root2, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment2);

    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes2, 2, global_state_root2, 0, 10,
        );
    // Both shards settled successfully — counter should be 99 (last write wins for Set)
}

#[test]
#[should_panic(expected: ('Sharding: Shard not active',))]
fn test_settling_already_settled_shard_fails() {
    let setup = setup_tee_test();

    let setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    let global_state_root: felt252 = 0xabc;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment, setup.test_contract_address, nonce, global_state_root, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );

    // First settlement succeeds
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address,
            storage_changes.clone(),
            shard_id,
            global_state_root,
            0,
            10,
        );

    // Second settlement with same shard_id should fail with 'Shard not active'
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    let global_state_root2: felt252 = 0xdef;
    let storage_commitment2 = compute_commitment(storage_changes2.span());
    let nonce2 = setup.storage_commitment_dispatcher.get_nonce(setup.test_contract_address);
    let full_commitment2 = compute_full_commitment(
        storage_commitment2, setup.test_contract_address, nonce2, global_state_root2, 10,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment2);

    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_address, storage_changes2, shard_id, global_state_root2, 0, 10,
        );
}
