use core::poseidon::PoseidonImpl;
use core::result::ResultTrait;
use core::traits::Into;
use openzeppelin_testing::constants as c;
use sharding_tests::config::{IConfigDispatcher, IConfigDispatcherTrait};
use sharding_tests::contract_component::contract_component::{
    ContractSlotUpdated, Event as ContractComponentEvent,
};
use sharding_tests::contract_component::{
    CRDType, CRDTypeTrait, IContractComponentDispatcher, IContractComponentDispatcherTrait,
};
use sharding_tests::shard_output::{
    FullContractChanges, FullContractStorageUpdate, StarknetOsOutput,
    deserialize_os_output,
};
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardInitialized};
use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};
use snforge_std as snf;
use snforge_std::{ContractClassTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait};
use starknet::ContractAddress;

const NOT_LOCKED_SLOT_VALUE: felt252 = 0x2;
const NOT_LOCKED_SLOT_ADDRESS: felt252 = 0x123;

#[derive(Drop)]
struct TestSetup {
    sharding_spy: snf::EventSpy,
    test_spy: snf::EventSpy,
    shard_dispatcher: IShardingDispatcher,
    sharding_contract_config_dispatcher: IConfigDispatcher,
    test_contract_dispatcher: ITestContractDispatcher,
    test_contract_component_dispatcher: IContractComponentDispatcher,
}

fn setup() -> TestSetup {
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_contract_with_owner(c::OWNER.into(), "sharding");

    // Deploy the test contract
    let (test_contract, mut test_spy) = deploy_contract_with_owner(
        c::OWNER.into(), "test_contract",
    );

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding };
    let sharding_contract_config_dispatcher = IConfigDispatcher { contract_address: sharding };

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(sharding_contract_config_dispatcher.contract_address, c::OWNER);
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    TestSetup {
        sharding_spy,
        test_spy,
        shard_dispatcher,
        sharding_contract_config_dispatcher,
        test_contract_dispatcher,
        test_contract_component_dispatcher,
    }
}

fn deploy_contract_with_owner(
    owner: felt252, contract_name: ByteArray,
) -> (ContractAddress, EventSpy) {
    let contract = match snf::declare(contract_name).unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();
    (contract_address, spy)
}

fn get_state_update(
    test_contract_address: felt252, storage_slot: felt252, storage_value: felt252,
) -> Array<felt252> {
    let mut shard_output = StarknetOsOutput {
        initial_root: 'root',
        final_root: 'final_root',
        prev_block_number: 'prev_block',
        new_block_number: 'new_block',
        prev_block_hash: 'prev_block_hash',
        new_block_hash: 'new_block_hash',
        os_program_hash: 0x0,
        use_kzg_da: 0x0,
        full_output: 0x1,
        messages_to_l1: array![].span(),
        messages_to_l2: array![].span(),
        starknet_os_config_hash: 'config',
        state_diff: array![
            FullContractChanges {
                address: test_contract_address.try_into().unwrap(),
                prev_nonce: 0,
                new_nonce: 0,
                prev_class_hash: 0,
                new_class_hash: 0,
                storage_changes: array![
                    FullContractStorageUpdate {
                        key: storage_slot, prev_value: 0x0, new_value: storage_value,
                    },
                ]
                    .span(),
            },
            // Not locked slot, should not be updated, so we add it this dummy value to the state
            // diff to verify that it is not updated
            FullContractChanges {
                address: test_contract_address.try_into().unwrap(),
                prev_nonce: 0,
                new_nonce: 0,
                prev_class_hash: 0,
                new_class_hash: 0,
                storage_changes: array![
                    FullContractStorageUpdate {
                        key: NOT_LOCKED_SLOT_ADDRESS,
                        prev_value: 0x0,
                        new_value: NOT_LOCKED_SLOT_VALUE,
                    },
                ]
                    .span(),
            },
        ]
            .span(),
    };
    println!("{:?}",shard_output);
    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);
    let mut x = snos_output.span().into_iter();
    let os_output = deserialize_os_output(ref x);
    assert_eq!(os_output,shard_output, "difference in serialization/deserialization");
    snos_output
}

fn initialize_shard(mut setup: TestSetup, crd_type: CRDType) -> TestSetup {
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
    );

    let contract_slots_changes = setup.test_contract_dispatcher.get_storage_slots(crd_type);

    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    let expected_init = ShardInitialized {
        initializer: setup.test_contract_component_dispatcher.contract_address,
        shard_id: shard_id,
        storage_slots: array![contract_slots_changes].span(),
    };

    setup
        .sharding_spy
        .assert_emitted(
            @array![
                (
                    setup.shard_dispatcher.contract_address,
                    ShardingEvent::ShardInitialized(expected_init),
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Counter is updated by snos_output
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == expected_slot_value, "Counter is not set");
    //println!("counter: {:?}", counter);

    // Verify that an unchanged storage slot remains at its default value
    let unchanged_slot =
    setup.test_contract_dispatcher.read_storage_slot(NOT_LOCKED_SLOT_ADDRESS);
    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    //TODO! we need to talk about silent consent to not update unsent slots

    // Initialize again with SetLock type
    let mut setup = initialize_shard(
        setup, CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let events = setup.test_spy.get_events();
    //println!("events: {:?}", events);
}
fn get_state_update_real_like(
    target_contract_address: felt252,
    target_key: felt252,
    target_value: felt252,
) -> Array<felt252> {
    let shard_output = StarknetOsOutput {
        initial_root: 0x564bd22008db5d8ee010398e1769cf53b155d5418759a3daf9748223810fa1f,
        final_root: 0x6d8c571961b70f66500f203c2867c1b7a89d991b3e12a15e2d617c73349d249,
        prev_block_number: 4116934,
        new_block_number: 4116937,
        prev_block_hash: 0x7d0ff4a6fc38a9eecb7afb74e9f19807946e1c113b988f7188587ba0b449874,
        new_block_hash: 0x10ba4a4e85f487605d7db8f2ea8b57ea772e21e30e681839caebafd8fbfb11e,
        os_program_hash: 0x0,
        use_kzg_da: 0x0,
        full_output: 0x1,
        messages_to_l1: array![].span(),
        messages_to_l2: array![].span(),
        starknet_os_config_hash: 0x1b9900f77ff5923183a7795fcfbb54ed76917bc1ddd4160cc77fa96e36cf8c5,
        state_diff: array![
            FullContractChanges {
                address: 0x1.try_into().unwrap(),
                prev_nonce: 0x0,
                new_nonce: 0x0,
                prev_class_hash: 0x0,
                new_class_hash: 0x0,
                storage_changes: array![
                    FullContractStorageUpdate {
                        key: 0x3ed1bd,
                        prev_value: 0x0,
                        new_value: 0x1ce9a92f1e2c5492481b4d10cc9386029c24af6b3d095d4ba1bbb8adb74fa62,
                    },
                    FullContractStorageUpdate {
                        key: 0x3ed1be,
                        prev_value: 0x0,
                        new_value: 0x34c99055fee7ac422b25d8522bd7d08d6f787e99b7198fb8d90650d1add3e58,
                    },
                    FullContractStorageUpdate {
                        key: 0x3ed1bf,
                        prev_value: 0x0,
                        new_value: 0x4e9a9c6f68f04f1eed27d1be22c010172ffebe6b157c90b865ce36e5161b8fb,
                    },
                ]
                    .span(),
            },
            FullContractChanges {
                address: target_contract_address.try_into().unwrap(),
                prev_nonce: 0x0,
                new_nonce: 0x0,
                prev_class_hash: 0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
                new_class_hash: 0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
                storage_changes: array![
                    FullContractStorageUpdate {
                        key: target_key,
                        prev_value: 0x0,
                        new_value: target_value,
                    },
                ]
                    .span(),
            },
            FullContractChanges {
                address: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                    .try_into()
                    .unwrap(),
                prev_nonce: 0x0,
                new_nonce: 0x0,
                prev_class_hash: 0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
                new_class_hash: 0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
                storage_changes: array![
                    FullContractStorageUpdate {
                        key: 0x3968b99888bd99c0284e1af8e55f2175d0737f540e8d6440d83add8e869e4c4,
                        prev_value: 0x51d08b42e76b465ee,
                        new_value: 0x51c402f2791baadee,
                    },
                    FullContractStorageUpdate {
                        key: 0x5496768776e3db30053404f18067d81a6e06f5a2b0de326e21298fd9d569a9a,
                        prev_value: 0x2a13c459d6e6f09d0e598,
                        new_value: 0x2a13c4665f375eeca9d98,
                    },
                ]
                    .span(),
            },
            FullContractChanges {
                address: 0x69a4f598b14f8424f2ee90b7a55fbc6083635da13f96a35acae04e6c149798d
                    .try_into()
                    .unwrap(),
                prev_nonce: 0x672,
                new_nonce: 0x675,
                prev_class_hash: 0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
                new_class_hash: 0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
                storage_changes: array![].span(),
            },
        ]
            .span(),
    };

    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);
    let mut it = snos_output.span().into_iter();
    let os_output = deserialize_os_output(ref it);
    assert_eq!(os_output, shard_output, "difference in serialization/deserialization");
    snos_output
}

#[test]
fn test_update_state_real_like_output_only_updates_initialized_contract_and_slot_add() {
    let mut setup = setup();

    let target_key: felt252 =
        0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854;
    let target_value: felt252 = 0x3;

    let crd = CRDType::Add((
        setup.test_contract_dispatcher.contract_address.try_into().unwrap(),
        target_key.try_into().unwrap(),
    ));

    let mut setup = initialize_shard(setup, crd);

    let snos_output = get_state_update_real_like(
        setup.test_contract_dispatcher.contract_address.into(),
        target_key,
        target_value,
    );

    let before = setup.test_contract_dispatcher.read_storage_slot(target_key);
    assert!(before == 0, "slot not default before update");

    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let after = setup.test_contract_dispatcher.read_storage_slot(target_key);
    assert!(after == target_value, "slot not updated correctly");
}

#[test]
fn test_ending_event() {
    let (test_contract, mut test_spy) = deploy_contract_with_owner(
        c::OWNER.into(), "test_contract",
    );

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };

    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER);
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();

    let expected_increment = GameFinished { caller: c::OWNER, shard_id: 0 };

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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify that the counter was incremented by 5 (from SNOS output) to become 15
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter was not incremented correctly");
    //println!("Counter after Add operation: {:?}", counter);
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify that the counter was set to 5 (from SNOS output), replacing the previous value of
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter was not set correctly");
    //println!("Counter after Set operation: {:?}", counter);
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify counter is 5 after update
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after update");
    //println!("Counter after SetLock operation: {:?}", counter);

    // Initialize a new shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with Add operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    // Verify counter is 10 after Add operation (5 + 5)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set correctly after Add operation");
    //println!("Counter after Add operation: {:?}", counter);

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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 3);

    // Verify counter is 5 after Set operation (overwriting previous value)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after Set operation");
    //println!("Counter after Set operation: {:?}", counter);

    //println!("All CRDT operations completed successfully");
}

#[test]
#[should_panic(expected: ('SL:Sharding already initialized',))]
fn test_setlock_after_setlock_fails() {
    let mut setup = setup();

    // Initialize the shard with SetLock operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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
#[should_panic(expected: ('SL:Sharding already initialized',))]
fn test_setlock_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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
#[should_panic(expected: ('S: Sharding already initialized',))]
fn test_set_after_setlock_fails() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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
#[should_panic(expected: ('S: Sharding already initialized',))]
fn test_set_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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
fn test_add_after_set() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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

    // Second initialization with Add - should fail
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
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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

    //println!("All valid CRD combinations passed");
}

#[test]
fn test_two_times_set() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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

    //println!("All valid CRD combinations passed");
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(),
                    0.try_into().unwrap())))
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);
}

#[test]
fn test_two_times_init_add_and_two_updates() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(),
                    0.try_into().unwrap())))
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let expected_second_update_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(),
                    0.try_into().unwrap())))
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

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER,
    );

    // Initialize the shard multiple times with SetLock operation type
    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::SetLock((0.try_into().unwrap(), 0.try_into().unwrap())));

    // First initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
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

    // First update_state
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after first update");

    // Second initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Second update_state
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after second update");

    // Third initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Third update_state
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 3);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after third update");

    //println!("Multiple initializations and updates completed successfully");
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Counter is NOT updated by snos_output because it's locked
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    //TODO! we need to talk about silent consent to not update Locked slots

    // Initialize again with Lock type
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);
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
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Counter is NOT updated by snos_output because set was sent
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Initialize again with Lock type it should work despite Lock slots were not updated
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);
}

#[should_panic(expected: ('L: Sharding already initialized',))]
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


