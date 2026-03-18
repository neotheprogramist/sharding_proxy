//! Sharding component tests with proper settlement verification.
//!
//! Tests verify:
//! 1. StorageCommitment registry unit tests (external contract)
//! 2. Commitment computation correctness
//! 3. Add CRDT delta computation (regression tests)
//! 4. Full shard lifecycle e2e
//! 5. Concurrent shard settlement
//! 6. Double-settlement prevention

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
// Test Setup
// =============================================================================

#[derive(Drop)]
struct TeeTestSetup {
    sharding_address: ContractAddress,
    shard_dispatcher: IShardingDispatcher,
    config_dispatcher: IConfigDispatcher,
    test_contract_address: ContractAddress,
    test_contract_dispatcher: ITestContractDispatcher,
    test_contract_component_dispatcher: IContractComponentDispatcher,
}

/// Deploy StorageCommitment contract and authorize test as the caller.
fn deploy_storage_commitment() -> ContractAddress {
    let contract_class = snf::declare("StorageCommitment").unwrap().contract_class();
    let deployer = snf::test_address();
    let calldata: Array<felt252> = array![deployer.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();

    let dispatcher = IStorageCommitmentDispatcher { contract_address };
    dispatcher.set_authorized_caller(snf::test_address());

    contract_address
}

/// Deploy sharding contract
fn deploy_sharding(owner: ContractAddress) -> ContractAddress {
    let contract_class = snf::declare("sharding").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into()];
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
    let sharding_address = deploy_sharding(OWNER);
    let shard_dispatcher = IShardingDispatcher { contract_address: sharding_address };
    let config_dispatcher = IConfigDispatcher { contract_address: sharding_address };

    let test_contract_address = deploy_test_contract(OWNER);
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract_address,
    };
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract_address,
    };

    // Register test contract as operator
    snf::start_cheat_caller_address(config_dispatcher.contract_address, OWNER);
    config_dispatcher.register_operator(test_contract_address);
    snf::stop_cheat_caller_address(config_dispatcher.contract_address);

    snf::start_cheat_block_number(sharding_address, 0);

    TeeTestSetup {
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

/// Apply storage changes via the component's update_shard_state.
/// Cheats caller to be the sharding proxy address (required by component authorization).
fn settle_via_component(
    ref setup: TeeTestSetup,
    storage_changes: Array<(felt252, felt252)>,
    shard_id: felt252,
) {
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address,
        setup.shard_dispatcher.contract_address,
    );
    setup
        .test_contract_component_dispatcher
        .update_shard_state(shard_id, storage_changes);
    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);
}

/// Compute storage commitment: poseidon_hash(keys || values)
fn compute_commitment(storage_changes: Span<(felt252, felt252)>) -> felt252 {
    let mut data: Array<felt252> = ArrayTrait::new();
    for change in storage_changes {
        let (key, _) = *change;
        data.append(key);
    }
    for change in storage_changes {
        let (_, value) = *change;
        data.append(value);
    }
    poseidon_hash_span(data.span())
}

// =============================================================================
// Unit Tests: StorageCommitment Registry (external contract)
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
    let address = deploy_storage_commitment();
    let dispatcher = IStorageCommitmentDispatcher { contract_address: address };

    let commitment: felt252 = 0xcafe;

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
    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x100), (0x2, 0x200)];

    let commitment = compute_commitment(storage_changes.span());

    // Expected: poseidon_hash([0x1, 0x2, 0x100, 0x200]) — keys first, then values
    let expected_data: Array<felt252> = array![0x1, 0x2, 0x100, 0x200];
    let expected = poseidon_hash_span(expected_data.span());

    assert!(commitment == expected, "Commitment should match manual computation");
}

#[test]
fn test_compute_commitment_real_slot() {
    let storage_changes: Array<(felt252, felt252)> = array![
        (0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854, 0x3),
    ];

    let commitment = compute_commitment(storage_changes.span());

    let expected_data: Array<felt252> = array![
        0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854, 0x3,
    ];
    let expected = poseidon_hash_span(expected_data.span());

    assert!(commitment == expected, "Real slot commitment should match");
}

// =============================================================================
// Add CRDT delta computation regression tests
// =============================================================================

#[test]
fn test_add_crdt_computes_delta_not_absolute() {
    // Scenario: counter starts at 10 before shard. During shard (Katana),
    // counter goes from 0 → 5 (added 5). The storage proof returns the
    // absolute value 5. The contract must compute delta = 5 - 0 = 5
    // and apply: current(10) + delta(5) = 15, NOT 10 + 5 = 15.
    let mut setup = setup_tee_test();

    // Initialize shard with Add CRDT — snapshots counter = 0 at init
    let mut setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set counter to 10 AFTER init (simulates main chain having value 10
    // at the fork block — init snapshotted 0, main chain diverges to 10)
    setup.test_contract_dispatcher.set_counter(10);
    assert!(setup.test_contract_dispatcher.get_counter() == 10, "Counter should be 10");

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // The shard (Katana) had counter = 0 at fork, incremented to 5.
    let shard_absolute_value: felt252 = 5;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, shard_absolute_value)];

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);
    settle_via_component(ref setup, storage_changes, shard_id);

    // Delta = 5 - 0 (init snapshot) = 5
    // Result = 10 (current) + 5 (delta) = 15
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter should be 15 (10 + delta(5)), not 25 (10 + absolute(15))");
}

#[test]
fn test_add_crdt_with_nonzero_initial_value() {
    // Scenario: counter = 100 at init time, shard sees 100 → 130 (delta=30).
    // Storage proof returns 130. Expected: current(100) + (130-100) = 130.
    let mut setup = setup_tee_test();

    // Set counter to 100 BEFORE init so the snapshot captures it
    setup.test_contract_dispatcher.set_counter(100);

    // Initialize shard — snapshots counter = 100
    let mut setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Shard started at 100, went to 130. Storage proof returns 130.
    let shard_value: felt252 = 130;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, shard_value)];

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);
    settle_via_component(ref setup, storage_changes, shard_id);

    // Delta = 130 - 100 = 30, new = 100 + 30 = 130
    // Without the fix this would be 100 + 130 = 230 (WRONG)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 130, "Counter should be 130 (100 + delta(30)), not 230");
}

#[test]
fn test_add_crdt_no_change_in_shard() {
    // Edge case: shard didn't modify the Add slot at all.
    // Shard value = initial value, delta = 0. Counter unchanged.
    let mut setup = setup_tee_test();

    setup.test_contract_dispatcher.set_counter(50);

    let mut setup = initialize_shard_for_test(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Shard value = 50 (same as initial, no change)
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 50)];

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);
    settle_via_component(ref setup, storage_changes, shard_id);

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
/// 3. Settlement via component → state updated
#[test]
fn test_full_shard_lifecycle_e2e() {
    let mut setup = setup_tee_test();

    let mut sharding_spy = snf::spy_events();
    let mut game_spy = snf::spy_events();

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // === Phase 1: request_sharding ===
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

    // Verify ShardingRequested event
    let expected_request = ShardingRequested {
        game_contract: setup.test_contract_component_dispatcher.contract_address,
        shard_id: 1,
        entities: [].span(),
        entity_key_chunks: 0,
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
    let game_addr = setup.test_contract_dispatcher.contract_address;
    snf::start_cheat_caller_address(game_addr, game_addr);
    setup.test_contract_dispatcher.increment(); // counter = 1
    setup.test_contract_dispatcher.increment(); // counter = 2
    setup.test_contract_dispatcher.increment(); // counter = 3 -> GameFinished + end_shard

    snf::stop_cheat_caller_address(game_addr);

    // Verify GameFinished event
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

    // Verify ShardFinished event
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

    // === Phase 3: Settlement via component ===
    let new_counter: felt252 = 3;
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, new_counter)];

    settle_via_component(ref setup, storage_changes, shard_id);

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
    let mut setup = setup_tee_test();

    // Initialize first shard (shard_id = 1)
    let mut setup = initialize_shard_for_test(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Initialize second shard (shard_id = 2) — Set allows stacking
    let mut setup = initialize_shard_for_test(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Settle first shard (shard_id = 1)
    let storage_changes1: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    settle_via_component(ref setup, storage_changes1, 1);

    // Settle second shard (shard_id = 2)
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    settle_via_component(ref setup, storage_changes2, 2);

    // Both shards settled successfully — counter should be 99 (last write wins for Set)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 99, "Counter should be 99 (last write wins)");
}

#[test]
#[should_panic(expected: ('Component: No storage changes',))]
fn test_settling_already_settled_shard_fails() {
    let mut setup = setup_tee_test();

    let mut setup = initialize_shard_for_test(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    let shard_id = setup.shard_dispatcher.get_shard_id(setup.test_contract_address);

    // First settlement succeeds
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];
    settle_via_component(ref setup, storage_changes, shard_id);

    // Second settlement with same shard_id should fail — slots already unlocked
    let storage_changes2: Array<(felt252, felt252)> = array![(counter_slot, 99)];
    settle_via_component(ref setup, storage_changes2, shard_id);
}
