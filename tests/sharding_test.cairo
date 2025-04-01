use snforge_std::EventSpyTrait;
use core::traits::Into;
use core::result::ResultTrait;
use core::iter::IntoIterator;
use core::poseidon::PoseidonImpl;
use openzeppelin_testing::constants as c;
use snforge_std as snf;
use snforge_std::{ContractClassTrait, EventSpy, EventSpyAssertionsTrait};
use sharding_tests::snos_output::{StarknetOsOutput, deserialize_os_output};

use sharding_tests::sharding::CRDType;
use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::sharding::IShardingDispatcherTrait;
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardingInitialized};

use sharding_tests::contract_component::IContractComponentDispatcher;
use sharding_tests::contract_component::IContractComponentDispatcherTrait;

use sharding_tests::config::IConfigDispatcher;
use sharding_tests::config::IConfigDispatcherTrait;

use sharding_tests::test_contract::ITestContractDispatcher;
use sharding_tests::test_contract::ITestContractDispatcherTrait;
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use starknet::ContractAddress;

#[derive(Drop, Copy)]
struct TestEnvironment {
    sharding: IShardingDispatcher,
    config: IConfigDispatcher,
    test_contract: ITestContractDispatcher,
    test_component: IContractComponentDispatcher,
}

fn deploy_contract_with_owner(owner: felt252, contract_name: ByteArray) -> (ContractAddress, EventSpy) {
    let contract = match snf::declare(contract_name).unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();

    (contract_address, spy)
}

fn get_state_update(test_contract_address: felt252) -> Array<felt252> {
    let felts = array![
        1,
        2,
        'snos_hash',
        0xb7414b09eb0af8f04d0f961a25ae369887b267eeab419dcfa071d5c062949f,
        0x743e5ff21a9905d2e50de3ab08d019d5db4da699a7d4018ae211d5b0a3c5641,
        0x4,
        0x5,
        0x44019d2d59b8aae6df9092b324f3e00577308a9f3ed6fe85abaa7206a9f5dcf,
        0x5b3ad1cfa3b46a7bcc5b14e6ea3e7295788190dc31468cae86a25f50b3406f9,
        0x0,
        0x5b13f57af91266140394eaca3080289e3e8881564e71d52f04030c5a35e4d7b,
        0x0,
        0x1,
        0x0,
        0x0,
        0x3,
        test_contract_address,
        0x18000000000000002402,
        0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2,
        0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2,
        test_contract_address,
        0xa,
        0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac,
        0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac,
        0x67840c21d0d3cba9ed504d8867dffe868f3d43708cfc0d7ed7980b511850070,
        0x21e19e0c9bab23f4979,
        0x21e19e0c9bab23f1fc1,
        0x7b62949c85c6af8a50c11c22927f9302f7a2e40bc93b4c988415915b0f97f09,
        0xb687,
        0xe03f,
        test_contract_address,
        0x6,
        0x1702ecc0c929e0651e55c1558c9005bf7f80f82a24c8f3abffb165f03de2289,
        0x1702ecc0c929e0651e55c1558c9005bf7f80f82a24c8f3abffb165f03de2289,
        0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854,
        0x0,
        0x5,
        0x0,
    ];
    felts
}

fn setup_test_environment() -> (TestEnvironment, EventSpy, EventSpy) {
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_contract_with_owner(c::OWNER().into(), "sharding");

    // Deploy the test contract
    let (test_contract, mut test_spy) = deploy_contract_with_owner(c::OWNER().into(), "test_contract");

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding};
    let sharding_contract_config_dispatcher = IConfigDispatcher {
        contract_address: sharding,
    };

    // Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract,
    };
    // Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    let env = TestEnvironment {
        sharding: shard_dispatcher,
        config: sharding_contract_config_dispatcher,
        test_contract: test_contract_dispatcher,
        test_component: test_contract_component_dispatcher,
    };

    (env, sharding_spy, test_spy)
}

fn initialize_shard_with_spy(
    env: TestEnvironment, crd_type: CRDType, ref spy: EventSpy
) -> () {
    snf::start_cheat_caller_address(
        env.test_component.contract_address, c::OWNER(),
    );

    let contract_slots_changes = env.test_contract.get_storage_slots(crd_type);

    env.test_component.initialize_shard(
        env.sharding.contract_address, contract_slots_changes.span(),
    );

    let expected_event = ShardingInitialized {
        initializer: env.test_component.contract_address, shard_id: 1, storage_slots: contract_slots_changes.span(),
    };

    spy.assert_emitted(
        @array![
            (
                env.sharding.contract_address,
                ShardingEvent::ShardingInitialized(expected_event),
            ),
        ],
    );
}

fn update_state_test(
    env: TestEnvironment, shard_id: felt252, crd_type: CRDType
) {
    let snos_output = get_state_update(env.test_contract.contract_address.into());

    snf::start_cheat_caller_address(
        env.sharding.contract_address, env.test_component.contract_address,
    );
    env.sharding.update_contract_state(snos_output.span(), shard_id, crd_type);
}

#[test]
fn test_update_state_with_lock_operation() {
    let (env, mut sharding_spy, _) = setup_test_environment();
    
    // Initialize shard with Lock operation
    initialize_shard_with_spy(env, CRDType::Lock, ref sharding_spy);
    let shard_id = 1;
    // Set initial counter value
    env.test_contract.set_counter(0);
    let counter = env.test_contract.get_counter();
    assert!(counter == 0, "Lock: Wrong counter value 0");
    
    // Update state with Lock operation
    update_state_test(env, shard_id, CRDType::Lock);
    
    // Verify counter value after Lock operation
    let counter = env.test_contract.get_counter();
    println!("counter {}",counter);
    assert!(counter == 5, "Lock: Wrong counter value 5");
}

#[test]
fn test_update_state_with_add_operation() {
    let (env, mut sharding_spy, _) = setup_test_environment();
    
    // Initialize shard with Add operation
    initialize_shard_with_spy(env, CRDType::Add, ref sharding_spy);
    let shard_id = 1;
    // Set initial counter value
    env.test_contract.set_counter(10);
    let counter = env.test_contract.get_counter();
    assert!(counter == 10, "Add: Wrong counter value");
    
    // Update state with Add operation
    update_state_test(env, shard_id, CRDType::Add);
    
    // Verify counter value after Add operation
    let counter = env.test_contract.get_counter();
    assert!(counter == 15, "Add: Wrong counter value");
}

#[test]
fn test_update_state_with_set_operation() {
    let (env, mut sharding_spy, _) = setup_test_environment();
    
    // Initialize shard with Set operation
    initialize_shard_with_spy(env, CRDType::Set, ref sharding_spy);
    let shard_id = 1;
    // Set initial counter value
    env.test_contract.set_counter(20);
    let counter = env.test_contract.get_counter();
    assert!(counter == 20, "Set: Wrong counter value");
    
    // Update state with Set operation
    update_state_test(env, shard_id, CRDType::Set);
    
    // Verify counter value after Set operation
    let counter = env.test_contract.get_counter();
    assert!(counter == 5, "Set: Wrong counter value");
}

#[test]
fn test_multiple_crd_operations() {
    let (env, _, _) = setup_test_environment();
    
    // Test Lock operation
    snf::start_cheat_caller_address(env.test_component.contract_address, c::OWNER());
    let contract_slots_changes = env.test_contract.get_storage_slots(CRDType::Lock);
    env.test_component.initialize_shard(
        env.sharding.contract_address, contract_slots_changes.span(),
    );
    env.test_contract.set_counter(0);
    update_state_test(env, 1, CRDType::Lock);
    let counter = env.test_contract.get_counter();
    assert!(counter == 5, "Lock: Wrong counter value");
    
    // Test Add operation
    let contract_slots_changes = env.test_contract.get_storage_slots(CRDType::Add);
    env.test_component.initialize_shard(
        env.sharding.contract_address, contract_slots_changes.span(),
    );
    update_state_test(env, 2, CRDType::Add);
    let counter = env.test_contract.get_counter();
    assert!(counter == 10, "Add: Wrong counter value");
    
    // Test Set operation
    let contract_slots_changes = env.test_contract.get_storage_slots(CRDType::Set);
    env.test_component.initialize_shard(
        env.sharding.contract_address, contract_slots_changes.span(),
    );
    update_state_test(env, 3, CRDType::Set);
    let counter = env.test_contract.get_counter();
    assert!(counter == 5, "Set: Wrong counter value");
    
    println!("All CRD operations completed successfully");
}
