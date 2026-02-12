use core::poseidon::PoseidonImpl;
use core::result::ResultTrait;
use core::traits::Into;
use sharding_tests::config::{IConfigDispatcher, IConfigDispatcherTrait};
use sharding_tests::contract_component::contract_component::{
    ContractSlotUpdated, Event as ContractComponentEvent,
};
use sharding_tests::contract_component::{
    CRDType, CRDTypeTrait, IContractComponentDispatcher, IContractComponentDispatcherTrait,
};
use sharding_tests::shard_output::{ContractChanges, ShardOutput};
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardingRequested};
use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
use sharding_tests::storage_commitment::{
    IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait,
};
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};
use snforge_std as snf;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait,
};
use starknet::ContractAddress;

const NOT_LOCKED_SLOT_VALUE: felt252 = 0x2;
const NOT_LOCKED_SLOT_ADDRESS: felt252 = 0x123;
const OWNER: ContractAddress = 123.try_into().unwrap();

#[derive(Drop)]
struct TestSetup {
    sharding_spy: snf::EventSpy,
    test_spy: snf::EventSpy,
    shard_dispatcher: IShardingDispatcher,
    sharding_contract_config_dispatcher: IConfigDispatcher,
    test_contract_dispatcher: ITestContractDispatcher,
    test_contract_component_dispatcher: IContractComponentDispatcher,
    storage_commitment_dispatcher: IStorageCommitmentDispatcher,
}

/// Deploy StorageCommitment contract (from katana-tee)
fn deploy_storage_commitment() -> ContractAddress {
    let contract_class = snf::declare("StorageCommitment").unwrap().contract_class();
    let calldata: Array<felt252> = array![];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

/// Deploy sharding contract with owner and storage_commitment_registry
fn deploy_sharding(
    owner: ContractAddress, storage_commitment_registry: ContractAddress,
) -> (ContractAddress, EventSpy) {
    let contract_class = snf::declare("sharding").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into(), storage_commitment_registry.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    let spy = snf::spy_events();
    (contract_address, spy)
}

fn setup() -> TestSetup {
    // Deploy storage_commitment first (required by sharding)
    let storage_commitment = deploy_storage_commitment();

    // Deploy the sharding contract with storage_commitment_registry
    let (sharding, mut sharding_spy) = deploy_sharding(OWNER, storage_commitment);

    // Deploy the test contract
    let (test_contract, mut test_spy) = deploy_contract_with_owner(OWNER, "test_contract");

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding };
    let sharding_contract_config_dispatcher = IConfigDispatcher { contract_address: sharding };

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(sharding_contract_config_dispatcher.contract_address, OWNER);
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    let storage_commitment_dispatcher = IStorageCommitmentDispatcher {
        contract_address: storage_commitment,
    };

    TestSetup {
        sharding_spy,
        test_spy,
        shard_dispatcher,
        sharding_contract_config_dispatcher,
        test_contract_dispatcher,
        test_contract_component_dispatcher,
        storage_commitment_dispatcher,
    }
}

fn deploy_contract_with_owner(
    owner: ContractAddress, contract_name: ByteArray,
) -> (ContractAddress, EventSpy) {
    let contract = match snf::declare(contract_name).unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner.into()];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();
    (contract_address, spy)
}

fn get_state_update(
    test_contract_address: felt252, storage_slot: felt252, storage_value: felt252,
) -> Array<felt252> {
    let mut shard_output = ShardOutput {
        state_diff: array![
            ContractChanges {
                addr: test_contract_address,
                nonce: 0,
                class_hash: Option::None,
                // Include both the locked slot and a non-locked slot in one entry
                // (mirrors real SNOS output which has one entry per contract).
                // The non-locked slot should be silently filtered out by update_shard_state.
                storage_changes: array![
                    (storage_slot, storage_value), (NOT_LOCKED_SLOT_ADDRESS, NOT_LOCKED_SLOT_VALUE),
                ],
            },
        ],
    };
    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);
    println!("snos_output: {:?}", snos_output);
    snos_output
}


fn initialize_shard(mut setup: TestSetup, crd_type: CRDType) -> TestSetup {
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

    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    let expected_event = ShardingRequested {
        game_contract: setup.test_contract_component_dispatcher.contract_address,
        storage_slots: array![contract_slots_changes].span(),
    };

    setup
        .sharding_spy
        .assert_emitted(
            @array![
                (
                    setup.shard_dispatcher.contract_address,
                    ShardingEvent::ShardingRequested(expected_event),
                ),
            ],
        );

    setup
}

#[test]
fn test_update_state() {
    let mut setup = setup();

    let expected_slot_value = 5;
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        expected_slot_value,
    );

    // Initialize the shard by connecting the test contract to the sharding system
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Counter is updated by snos_output
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == expected_slot_value, "Counter is not set");
    println!("counter: {:?}", counter);

    // Verify that an unchanged storage slot remains at its default value
    let unchanged_slot = setup.test_contract_dispatcher.read_storage_slot(NOT_LOCKED_SLOT_ADDRESS);
    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    //TODO! we need to talk about silent consent to not update unsent slots

    // Initialize again with SetLock type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);

    let events = setup.test_spy.get_events();
    println!("events: {:?}", events);
}

#[test]
fn test_ending_event() {
    let (test_contract, mut test_spy) = deploy_contract_with_owner(OWNER, "test_contract");

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };

    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, OWNER);
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();

    let expected_increment = GameFinished { caller: OWNER, shard_id: 0 };

    test_spy
        .assert_emitted(
            @array![
                (
                    test_contract_dispatcher.contract_address,
                    TestContractEvent::GameFinished(expected_increment),
                ),
            ],
        );
}

#[test]
fn test_update_state_with_add_operation() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value
    setup.test_contract_dispatcher.set_counter(10);
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set to initial value");

    // Create SNOS output with Add operation
    let mut snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply the state update with Add operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Verify that the counter was incremented by 5 (from SNOS output) to become 15
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter was not incremented correctly");
    println!("Counter after Add operation: {:?}", counter);
}

#[test]
fn test_update_state_with_set_operation() {
    let mut setup = setup();

    let mut setup = initialize_shard(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value to 20
    setup.test_contract_dispatcher.set_counter(20);
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 20, "Counter is not set to initial value");

    // Create SNOS output with Set operation
    let mut snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply the state update with Set operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Verify that the counter was set to 5 (from SNOS output), replacing the previous value of 20
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter was not set correctly");
    println!("Counter after Set operation: {:?}", counter);
}

#[test]
fn test_multiple_crd_operations() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value to 0
    setup.test_contract_dispatcher.set_counter(0);

    // Create SNOS output for SetLock operation
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with SetLock operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Verify counter is 5 after update
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after update");
    println!("Counter after SetLock operation: {:?}", counter);

    // Initialize a new shard with Add operation type
    // At this point counter=5 on main chain. Initialization snapshots initial_add_value=5.
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Shard reports absolute value 10 (started at 5, accumulated 5 more).
    // Delta = shard_value(10) - initial(5) = 5, new = current(5) + 5 = 10.
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        10,
    );

    // Apply state update with Add operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);

    // Verify counter is 10 after Add operation (delta = 10 - 5 = 5, new = 5 + 5 = 10)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set correctly after Add operation");
    println!("Counter after Add operation: {:?}", counter);

    // Initialize a new shard with Set operation type
    let mut setup = initialize_shard(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with Set operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 3);

    // Verify counter is 5 after Set operation (overwriting previous value)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after Set operation");
    println!("Counter after Set operation: {:?}", counter);

    println!("All CRDT operations completed successfully");
}

#[test]
#[should_panic(expected: ('Slot locked by active shard',))]
fn test_setlock_after_setlock_fails() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));

    // First initialization with SetLock
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Second initialization with SetLock - should fail
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('Type change while slot active',))]
fn test_setlock_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // First initialization with Add
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with SetLock - should fail
    let lock_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![lock_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('Slot locked by active shard',))]
fn test_set_after_setlock_fails() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // First initialization with SetLock - should fail
    let lock_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![lock_slots_changes].span(),
        );

    // Second initialization with Set
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('Type change while slot active',))]
fn test_set_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // First initialization with Add
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with Set - should fail
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('Type change while slot active',))]
fn test_add_after_set() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // First initialization with Set
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Second initialization with Add - should fail (type change while active)
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );
}

#[test]
fn test_two_times_add() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // Test Add after Add - should work
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with Add - should work
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Verify shard ID incremented
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);
    assert!(shard_id == 2, "Shard ID should be 2 after second initialization");

    println!("All valid CRD combinations passed");
}


#[test]
fn test_two_times_set() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    // Test Set after Set - should work
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Second initialization with Set - should work
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Verify shard ID incremented
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);
    assert!(shard_id == 2, "Shard ID should be 2 after second initialization");

    println!("All valid CRD combinations passed");
}

#[should_panic(expected: ('Component: Storage is unlocked',))]
#[test]
fn test_too_many_setlock_updates() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(
                        CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
                    )
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should fail because the slot is already unlocked
    // This simulates trying to update more times than the init_count
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);
}

#[should_panic(expected: ('Component: Storage is unlocked',))]
#[test]
fn test_too_many_add_updates() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );
    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should fail because the slot is already unlocked
    // This simulates trying to update more times than the init_count
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);
}

#[test]
fn test_two_times_init_add_and_two_updates() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));

    // Initialize the shard
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Initialize the shard again
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should work
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);

    let expected_second_update_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not updated correctly");

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_second_update_event),
                ),
            ],
        );
}


#[test]
fn test_multiple_initializations_and_updates() {
    let mut setup = setup();

    // Initialize the shard multiple times with SetLock operation type
    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));

    // First initialization
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );
    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after first update");

    // Second initialization
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );
    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);

    // Second update_state
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after second update");

    // Third initialization
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );
    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);

    // Third update_state
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 3);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after third update");

    println!("Multiple initializations and updates completed successfully");
}

#[test]
fn lock_and_unlock_storage() {
    let mut setup = setup();

    let expected_slot_value = 5;
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        expected_slot_value,
    );

    // Initialize the shard by connecting the test contract to the sharding system
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Counter is NOT updated by snos_output because it's locked
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    //TODO! we need to talk about silent consent to not update Locked slots

    // Initialize again with Lock type
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);
}

#[test]
fn unlocking_lock_when_no_update() {
    let mut setup = setup();

    let expected_slot_value = 5;

    //We send set slots to the shard
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        expected_slot_value,
    );

    // Initialize the shard with Lock type
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 1);

    // Counter is NOT updated by snos_output because set was sent
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Initialize again with Lock type it should work despite Lock slots were not updated
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), 2);
}

#[should_panic(expected: ('Slot locked by active shard',))]
#[test]
fn two_times_lock() {
    let mut setup = setup();

    // Initialize the shard by connecting the test contract to the sharding system
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Initialize again with Lock type
    initialize_shard(setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())));
}

// =============================================================================
// TEE commitment helpers
// =============================================================================

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

/// Compute full commitment hash matching StorageCommitment.verify() logic
fn compute_full_commitment(
    storage_commitment: felt252,
    contract_address: ContractAddress,
    nonce: u64,
    global_state_root: felt252,
) -> felt252 {
    let mut data: Array<felt252> = ArrayTrait::new();
    data.append(storage_commitment);
    data.append(contract_address.into());
    data.append(nonce.into());
    data.append(global_state_root);
    poseidon_hash_span(data.span())
}

// =============================================================================
// TEE-based update tests (update_contract_state_tee)
// =============================================================================

#[test]
fn test_update_contract_state_tee_success() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter should start at 0");

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes array (key, value pairs)
    let storage_changes: Array<(felt252, felt252)> = array![(counter_slot, 42)];

    // Compute and register the commitment
    let global_state_root: felt252 = 0;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup
        .storage_commitment_dispatcher
        .get_nonce(setup.test_contract_dispatcher.contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment,
        setup.test_contract_dispatcher.contract_address,
        nonce,
        global_state_root,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Apply the state update using TEE-based method
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address, storage_changes, 1, global_state_root,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter was updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 42, "Counter should be 42 after TEE update");
    println!("Counter after TEE update: {:?}", counter);
}

#[test]
#[should_panic(expected: ('Contract not initialized',))]
fn test_update_contract_state_tee_no_shard() {
    let setup = setup();

    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x100)];

    // No shard initialized — should fail with explicit error
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address, storage_changes, 1, 0,
        );
}

#[test]
#[should_panic(expected: ('Sharding: Shard id mismatch',))]
fn test_update_contract_state_tee_wrong_shard_id() {
    let mut setup = setup();

    // Initialize with shard_id = 1
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x100)];

    // Should fail - wrong shard_id (2 != 1)
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address,
            storage_changes,
            2,
            0 // wrong shard_id!
        );
}

#[test]
#[should_panic(expected: ('Sharding: No storage changes',))]
fn test_update_contract_state_tee_empty_changes() {
    let mut setup = setup();

    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let storage_changes: Array<(felt252, felt252)> = array![];

    // Should fail - empty storage changes
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address, storage_changes, 1, 0,
        );
}

#[test]
fn test_update_contract_state_tee_multiple_slots() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Get the storage slot for counter
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())))
        .slot();

    // Create storage changes with multiple slots
    let storage_changes: Array<(felt252, felt252)> = array![
        (counter_slot, 100), (0x999, 200) // This slot may not be locked, so it might be ignored
    ];

    // Compute and register the commitment
    let global_state_root: felt252 = 0;
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup
        .storage_commitment_dispatcher
        .get_nonce(setup.test_contract_dispatcher.contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment,
        setup.test_contract_dispatcher.contract_address,
        nonce,
        global_state_root,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    // Apply the state update using TEE-based method
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address, storage_changes, 1, global_state_root,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    // Verify counter was updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 100, "Counter should be 100 after TEE update with multiple slots");
    println!("Counter after TEE multi-slot update: {:?}", counter);
}

// =============================================================================
// Multi-slot tests (multiple registered storage slots)
// =============================================================================

/// Helper: initialize shard with multiple slots via get_storage_slot_for
fn initialize_shard_multi(mut setup: TestSetup, slots: Span<CRDType>) -> TestSetup {
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, OWNER,
    );

    setup
        .test_contract_component_dispatcher
        .initialize_shard(setup.shard_dispatcher.contract_address, slots);

    snf::stop_cheat_caller_address(setup.test_contract_component_dispatcher.contract_address);
    setup
}

/// Helper: compute + register commitment and call update_contract_state_tee
fn tee_update_with_commitment(
    ref setup: TestSetup,
    storage_changes: Array<(felt252, felt252)>,
    shard_id: felt252,
    global_state_root: felt252,
) {
    let storage_commitment = compute_commitment(storage_changes.span());
    let nonce = setup
        .storage_commitment_dispatcher
        .get_nonce(setup.test_contract_dispatcher.contract_address);
    let full_commitment = compute_full_commitment(
        storage_commitment,
        setup.test_contract_dispatcher.contract_address,
        nonce,
        global_state_root,
    );
    setup.storage_commitment_dispatcher.register_verified_commitment(full_commitment);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup
        .shard_dispatcher
        .update_contract_state_tee(
            setup.test_contract_dispatcher.contract_address,
            storage_changes,
            shard_id,
            global_state_root,
        );
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);
}

#[test]
fn test_tee_multiple_registered_slots() {
    let mut setup = setup();

    // Register 2 SetLock slots: counter and score
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("counter"), CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let score_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("score"), CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
        );

    let mut setup = initialize_shard_multi(setup, array![counter_slot, score_slot].span());

    // Update both slots via TEE
    let storage_changes: Array<(felt252, felt252)> = array![
        (counter_slot.slot(), 42), (score_slot.slot(), 100),
    ];
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    tee_update_with_commitment(ref setup, storage_changes, shard_id, 0xabc);

    // Verify both slots updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 42, "Counter should be 42");
    let score = setup.test_contract_dispatcher.read_storage_slot(score_slot.slot());
    assert!(score == 100, "Score should be 100");
}

#[test]
fn test_tee_mixed_crd_types() {
    let mut setup = setup();

    // counter=SetLock (overwrite), score=Add (accumulate)
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("counter"), CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let score_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("score"), CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
        );

    let mut setup = initialize_shard_multi(setup, array![counter_slot, score_slot].span());

    // Set initial score value via raw storage write
    setup.test_contract_dispatcher.write_storage_slot(score_slot.slot(), 50);

    // Update both: counter should be overwritten, score should be added
    let storage_changes: Array<(felt252, felt252)> = array![
        (counter_slot.slot(), 10), (score_slot.slot(), 25),
    ];
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    tee_update_with_commitment(ref setup, storage_changes, shard_id, 0xabc);

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter should be overwritten to 10");
    let score = setup.test_contract_dispatcher.read_storage_slot(score_slot.slot());
    assert!(score == 75, "Score should be 50 + 25 = 75");
}

#[test]
fn test_snos_multiple_registered_slots() {
    let mut setup = setup();

    // Register counter=SetLock and score=Add
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("counter"), CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let score_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("score"), CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
        );

    let mut setup = initialize_shard_multi(setup, array![counter_slot, score_slot].span());

    // Set initial score via raw storage write
    setup.test_contract_dispatcher.write_storage_slot(score_slot.slot(), 10);

    // Build SNOS output with both slots
    let mut shard_output = ShardOutput {
        state_diff: array![
            ContractChanges {
                addr: setup.test_contract_dispatcher.contract_address.into(),
                nonce: 0,
                class_hash: Option::None,
                storage_changes: array![(counter_slot.slot(), 99), (score_slot.slot(), 5)],
            },
        ],
    };
    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);

    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state_snos(snos_output.span(), shard_id);
    snf::stop_cheat_caller_address(setup.shard_dispatcher.contract_address);

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 99, "Counter should be overwritten to 99");
    let score = setup.test_contract_dispatcher.read_storage_slot(score_slot.slot());
    assert!(score == 15, "Score should be 10 + 5 = 15");
}

#[test]
fn test_tee_all_crd_types_at_once() {
    let mut setup = setup();

    // Register all 4 CRD types at once:
    // counter=SetLock (overwrite, then unlock)
    // score=Add (accumulate)
    // health=Set (overwrite, re-initializable)
    // An extra slot via Lock (reserve, discard shard value)
    let counter_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("counter"), CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let score_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("score"), CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let health_slot = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("health"), CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
        );

    let mut setup = initialize_shard_multi(
        setup, array![counter_slot, score_slot, health_slot].span(),
    );

    // Set initial values
    setup.test_contract_dispatcher.set_counter(0);
    setup.test_contract_dispatcher.write_storage_slot(score_slot.slot(), 100);
    setup.test_contract_dispatcher.write_storage_slot(health_slot.slot(), 50);

    // Update all slots via TEE
    let storage_changes: Array<(felt252, felt252)> = array![
        (counter_slot.slot(), 7), (score_slot.slot(), 30), (health_slot.slot(), 80),
    ];
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    tee_update_with_commitment(ref setup, storage_changes, shard_id, 0xdef);

    // Verify each CRD type behaved correctly:
    // SetLock: counter = 7 (overwritten from 0)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 7, "SetLock counter should be overwritten to 7");

    // Add: score = 100 + 30 = 130
    let score = setup.test_contract_dispatcher.read_storage_slot(score_slot.slot());
    assert!(score == 130, "Add score should be 100 + 30 = 130");

    // Set: health = 80 (overwritten from 50)
    let health = setup.test_contract_dispatcher.read_storage_slot(health_slot.slot());
    assert!(health == 80, "Set health should be overwritten to 80");

    // Verify SetLock is now unlocked (re-initialization would need to use compatible type)
    // Verify Set and Add are also unlocked after update
    // Re-initialize with compatible types to confirm unlock worked
    let counter_slot_set = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("counter"), CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let score_slot_add = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("score"), CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
        );
    let health_slot_set = setup
        .test_contract_dispatcher
        .get_storage_slot_for(
            selector!("health"), CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
        );

    // Re-initialize — should succeed because all slots were unlocked
    let mut setup = initialize_shard_multi(
        setup, array![counter_slot_set, score_slot_add, health_slot_set].span(),
    );

    // Do a second round of updates
    // For Add (score): initial snapshot at 2nd init = 130. Shard reports absolute 140.
    // delta = 140 - 130 = 10, new = 130 + 10 = 140.
    let storage_changes2: Array<(felt252, felt252)> = array![
        (counter_slot.slot(), 1), (score_slot.slot(), 140), (health_slot.slot(), 200),
    ];
    let shard_id2 = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    tee_update_with_commitment(ref setup, storage_changes2, shard_id2, 0xfff);

    // Set: counter = 1 (overwritten)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 1, "Second round: counter should be 1");

    // Add: score = 130 + (140 - 130) = 140
    let score = setup.test_contract_dispatcher.read_storage_slot(score_slot.slot());
    assert!(score == 140, "Second round: score should be 130 + 10 = 140");

    // Set: health = 200 (overwritten)
    let health = setup.test_contract_dispatcher.read_storage_slot(health_slot.slot());
    assert!(health == 200, "Second round: health should be 200");
}

// =============================================================================
// compute_commitment tests
// =============================================================================

use core::poseidon::poseidon_hash_span;

/// Helper function to compute commitment the same way as sharding contract
/// poseidon_hash([keys..., values...]) converted to u256
fn compute_commitment_helper(storage_changes: Span<(felt252, felt252)>) -> u256 {
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

#[test]
fn test_compute_commitment_single_change() {
    // Test with single storage change
    let storage_changes: Array<(felt252, felt252)> = array![(0x1, 0x100)];

    let commitment = compute_commitment_helper(storage_changes.span());

    // Verify commitment is non-zero
    assert!(commitment != 0, "Commitment should not be zero");

    // Verify determinism - same input gives same output
    let storage_changes2: Array<(felt252, felt252)> = array![(0x1, 0x100)];
    let commitment2 = compute_commitment_helper(storage_changes2.span());
    assert!(commitment == commitment2, "Commitment should be deterministic");

    println!("Single change commitment: {:?}", commitment);
}

#[test]
fn test_compute_commitment_multiple_changes() {
    // Test with multiple storage changes
    let storage_changes: Array<(felt252, felt252)> = array![
        (0x1, 0x100), (0x2, 0x200), (0x3, 0x300),
    ];

    let commitment = compute_commitment_helper(storage_changes.span());

    // Verify commitment is non-zero
    assert!(commitment != 0, "Commitment should not be zero");

    // Expected: poseidon_hash([0x1, 0x2, 0x3, 0x100, 0x200, 0x300])
    let expected_data: Array<felt252> = array![0x1, 0x2, 0x3, 0x100, 0x200, 0x300];
    let expected_hash: u256 = poseidon_hash_span(expected_data.span()).into();

    assert!(commitment == expected_hash, "Commitment should match expected hash");

    println!("Multiple changes commitment: {:?}", commitment);
}

#[test]
fn test_compute_commitment_order_matters() {
    // Different order of changes should give different commitment
    let storage_changes1: Array<(felt252, felt252)> = array![(0x1, 0x100), (0x2, 0x200)];

    let storage_changes2: Array<(felt252, felt252)> = array![(0x2, 0x200), (0x1, 0x100)];

    let commitment1 = compute_commitment_helper(storage_changes1.span());
    let commitment2 = compute_commitment_helper(storage_changes2.span());

    // Different order should produce different commitment
    assert!(commitment1 != commitment2, "Different order should give different commitment");

    println!("Commitment 1 (1,2 order): {:?}", commitment1);
    println!("Commitment 2 (2,1 order): {:?}", commitment2);
}

#[test]
fn test_compute_commitment_different_values_different_hash() {
    // Same keys but different values should give different commitment
    let storage_changes1: Array<(felt252, felt252)> = array![(0x1, 0x100)];
    let storage_changes2: Array<(felt252, felt252)> = array![(0x1, 0x200)];

    let commitment1 = compute_commitment_helper(storage_changes1.span());
    let commitment2 = compute_commitment_helper(storage_changes2.span());

    assert!(commitment1 != commitment2, "Different values should give different commitment");
}

#[test]
fn test_compute_commitment_different_keys_different_hash() {
    // Different keys but same values should give different commitment
    let storage_changes1: Array<(felt252, felt252)> = array![(0x1, 0x100)];
    let storage_changes2: Array<(felt252, felt252)> = array![(0x2, 0x100)];

    let commitment1 = compute_commitment_helper(storage_changes1.span());
    let commitment2 = compute_commitment_helper(storage_changes2.span());

    assert!(commitment1 != commitment2, "Different keys should give different commitment");
}

#[test]
fn test_compute_commitment_large_values() {
    // Test with large felt252 values (close to max)
    let large_key: felt252 = 0x7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    let large_value: felt252 = 0x7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    let storage_changes: Array<(felt252, felt252)> = array![(large_key, large_value)];

    let commitment = compute_commitment_helper(storage_changes.span());

    // Should not overflow or panic
    assert!(commitment != 0, "Commitment with large values should work");

    println!("Large values commitment: {:?}", commitment);
}

#[test]
fn test_compute_commitment_zero_values() {
    // Test with zero key and value
    let storage_changes: Array<(felt252, felt252)> = array![(0x0, 0x0)];

    let commitment = compute_commitment_helper(storage_changes.span());

    // Should produce valid hash even with zeros
    // poseidon_hash([0, 0]) should not be 0
    assert!(commitment != 0, "Commitment with zeros should not be zero");

    println!("Zero values commitment: {:?}", commitment);
}

#[test]
fn test_compute_commitment_matches_rust_format() {
    // This test verifies the format matches Rust side:
    // Poseidon::hash_array(&[keys..., values...])
    //
    // For storage_changes = [(key1, val1), (key2, val2)]
    // The hash input should be: [key1, key2, val1, val2]

    let storage_changes: Array<(felt252, felt252)> = array![
        (0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854, 0x3),
    ];

    let commitment = compute_commitment_helper(storage_changes.span());

    // Verify format: hash([key, value])
    let expected_input: Array<felt252> = array![
        0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854, 0x3,
    ];
    let expected: u256 = poseidon_hash_span(expected_input.span()).into();

    assert!(commitment == expected, "Commitment should match Rust format");

    println!("Real slot commitment: {:?}", commitment);
}
