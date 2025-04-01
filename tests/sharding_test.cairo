use snforge_std::EventSpyTrait;
use core::traits::Into;
use core::result::ResultTrait;
use core::poseidon::PoseidonImpl;
use openzeppelin_testing::constants as c;
use snforge_std as snf;
use snforge_std::{ContractClassTrait, EventSpy, EventSpyAssertionsTrait};
use sharding_tests::sharding::CRDType;
use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::sharding::IShardingDispatcherTrait;
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardInitialized};

use sharding_tests::contract_component::IContractComponentDispatcher;
use sharding_tests::contract_component::IContractComponentDispatcherTrait;

use sharding_tests::config::IConfigDispatcher;
use sharding_tests::config::IConfigDispatcherTrait;

use sharding_tests::test_contract::ITestContractDispatcher;
use sharding_tests::test_contract::ITestContractDispatcherTrait;
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use sharding_tests::shard_output::{ShardOutput, ContractChanges};

const NOT_LOCKED_SLOT_VALUE: felt252 = 0x2;
const NOT_LOCKED_SLOT_ADDRESS: felt252 = 0x123;

fn deploy_sharding_with_owner(owner: felt252) -> (IShardingDispatcher, EventSpy) {
    let contract = match snf::declare("sharding").unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();

    (IShardingDispatcher { contract_address }, spy)
}

fn deploy_test_contract_with_owner(owner: felt252) -> (ITestContractDispatcher, EventSpy) {
    let contract = match snf::declare("test_contract").unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();

    (ITestContractDispatcher { contract_address }, spy)
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
                storage_changes: array![(storage_slot, storage_value)],
            },
            // Not locked slot, should not be updated, so we add it this dummy value to the state
            // diff to verify that it is not updated
            ContractChanges {
                addr: test_contract_address,
                nonce: 0,
                class_hash: Option::None,
                storage_changes: array![(NOT_LOCKED_SLOT_ADDRESS, NOT_LOCKED_SLOT_VALUE)],
            },
        ],
    };
    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);
    snos_output
}

#[test]
fn test_update_state() {
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_sharding_with_owner(owner: c::OWNER().into());

    // Deploy the test contract
    let (test_contract, mut test_spy) = deploy_test_contract_with_owner(owner: c::OWNER().into());

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };
    let sharding_contract_config_dispatcher = IConfigDispatcher {
        contract_address: sharding.contract_address,
    };

    //Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };
    //Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract.contract_address,
    };
    let expected_slot_value = 5;
    let snos_output = get_state_update(
        test_contract_dispatcher.contract_address.into(),
        test_contract_dispatcher.get_storage_slots(CRDType::Lock).slot,
        expected_slot_value,
    );

    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);

    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    // Initialize the shard by connecting the test contract to the sharding system
    snf::start_cheat_caller_address(
        test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Lock);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    let expected_increment = ShardInitialized {
        initializer: test_contract_component_dispatcher.contract_address, shard_id: 1,
    };

    sharding_spy
        .assert_emitted(
            @array![
                (
                    shard_dispatcher.contract_address,
                    ShardingEvent::ShardInitialized(expected_increment),
                ),
            ],
        );

    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 1, CRDType::Lock);

    //Counter is updated by snos_output
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == expected_slot_value, "Counter is not set");
    println!("counter: {:?}", counter);

    // Verify that an unchanged storage slot remains at its default value
    let unchanged_slot = test_contract_dispatcher.read_storage_slot(NOT_LOCKED_SLOT_ADDRESS);
    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    //TODO! we need to talk about silent consent to not update unsent slots

    let shard_id = shard_dispatcher.get_shard_id(test_contract_dispatcher.contract_address);
    assert!(shard_id == 1, "Shard id is not set");

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    let shard_id = shard_dispatcher.get_shard_id(test_contract_dispatcher.contract_address);
    assert!(shard_id == 2, "Wrong shard id");

    let events = test_spy.get_events();
    println!("events: {:?}", events);
}

#[test]
fn test_ending_event() {
    let (test_contract, mut test_spy) = deploy_test_contract_with_owner(owner: c::OWNER().into());

    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };

    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER());
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();

    let expected_increment = GameFinished { caller: c::OWNER() };

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
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_sharding_with_owner(owner: c::OWNER().into());

    // Deploy the test contract
    let (test_contract, _) = deploy_test_contract_with_owner(owner: c::OWNER().into());

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };
    let sharding_contract_config_dispatcher = IConfigDispatcher {
        contract_address: sharding.contract_address,
    };

    //Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };
    //Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract.contract_address,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Add);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    let expected_increment = ShardInitialized {
        initializer: test_contract_component_dispatcher.contract_address, shard_id: 1,
    };

    sharding_spy
        .assert_emitted(
            @array![
                (
                    shard_dispatcher.contract_address,
                    ShardingEvent::ShardInitialized(expected_increment),
                ),
            ],
        );

    // Set initial counter value
    test_contract_dispatcher.set_counter(10);
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set to initial value");

    // Create SNOS output with Add operation
    let mut snos_output = get_state_update(test_contract_dispatcher.contract_address.into(),test_contract_dispatcher.get_storage_slots(CRDType::Add).slot, 5);

    // Apply the state update with Add operation
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 1, CRDType::Add);

    // Verify that the counter was incremented by 5 (from SNOS output) to become 15
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter was not incremented correctly");
    println!("Counter after Add operation: {:?}", counter);
}

#[test]
fn test_update_state_with_set_operation() {
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_sharding_with_owner(owner: c::OWNER().into());

    // Deploy the test contract
    let (test_contract, _) = deploy_test_contract_with_owner(owner: c::OWNER().into());

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };
    let sharding_contract_config_dispatcher = IConfigDispatcher {
        contract_address: sharding.contract_address,
    };

    //Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };
    //Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract.contract_address,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Set);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    let expected_increment = ShardInitialized {
        initializer: test_contract_component_dispatcher.contract_address, shard_id: 1,
    };

    sharding_spy
        .assert_emitted(
            @array![
                (
                    shard_dispatcher.contract_address,
                    ShardingEvent::ShardInitialized(expected_increment),
                ),
            ],
        );

    // Set initial counter value to 20
    test_contract_dispatcher.set_counter(20);
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 20, "Counter is not set to initial value");

    // Create SNOS output with Set operation
    let mut snos_output = get_state_update(test_contract_dispatcher.contract_address.into(),test_contract_dispatcher.get_storage_slots(CRDType::Set).slot, 5);

    // Apply the state update with Set operation
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 1, CRDType::Set);

    // Verify that the counter was set to 5 (from SNOS output), replacing the previous value of 20
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter was not set correctly");
    println!("Counter after Set operation: {:?}", counter);
}

#[test]
fn test_multiple_crd_operations() {
    // Deploy the sharding contract
    let (sharding, _) = deploy_sharding_with_owner(owner: c::OWNER().into());

    // Deploy the test contract
    let (test_contract, _) = deploy_test_contract_with_owner(owner: c::OWNER().into());

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };
    let sharding_contract_config_dispatcher = IConfigDispatcher {
        contract_address: sharding.contract_address,
    };

    //Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };
    //Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract.contract_address,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    // Initialize the shard with Lock operation type
    snf::start_cheat_caller_address(
        test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Lock);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    // Set initial counter value to 0
    test_contract_dispatcher.set_counter(0);

    // Create SNOS output
    let snos_output = get_state_update(test_contract_dispatcher.contract_address.into(),test_contract_dispatcher.get_storage_slots(CRDType::Lock).slot, 5);

    // Apply state update with Lock operation
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 1, CRDType::Lock);

    // Verify counter is 5 after update
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after update");
    println!("Counter after Lock operation: {:?}", counter);

    // Initialize a new shard with Add operation type
    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Add);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    // Apply state update with Add operation
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 2, CRDType::Add);

    // Verify counter is 10 after Add operation (5 + 5)
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set correctly after Add operation");
    println!("Counter after Add operation: {:?}", counter);

    // Initialize a new shard with Set operation type
    let contract_slots_changes = test_contract_dispatcher.get_storage_slots(CRDType::Set);

    test_contract_component_dispatcher
        .initialize_shard(shard_dispatcher.contract_address, array![contract_slots_changes].span());

    // Apply state update with Set operation
    snf::start_cheat_caller_address(
        shard_dispatcher.contract_address, test_contract_component_dispatcher.contract_address,
    );
    shard_dispatcher.update_state(snos_output.span(), 3, CRDType::Set);

    // Verify counter is 5 after Set operation (overwriting previous value)
    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after Set operation");
    println!("Counter after Set operation: {:?}", counter);

    println!("All CRDT operations completed successfully");
}
