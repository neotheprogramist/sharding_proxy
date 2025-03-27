use snforge_std::EventSpyTrait;
use core::traits::Into;
use core::result::ResultTrait;
use core::iter::IntoIterator;
use core::poseidon::PoseidonImpl;
use openzeppelin_testing::constants as c;
use snforge_std as snf;
use snforge_std::{ContractClassTrait, EventSpy, EventSpyAssertionsTrait};

use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::sharding::IShardingDispatcherTrait;
use sharding_tests::snos_output::{StarknetOsOutput, deserialize_os_output};
use sharding_tests::test_contract::ITestContractDispatcher;
use sharding_tests::test_contract::ITestContractDispatcherTrait;
use sharding_tests::contract_component::IContractComponentDispatcher;
use sharding_tests::contract_component::IContractComponentDispatcherTrait;
use sharding_tests::test_contract::test_contract::{Event, GameFinished};

fn deploy_with_owner_and_state(
    owner: felt252, state_root: felt252, block_number: felt252, block_hash: felt252,
) -> (IShardingDispatcher, EventSpy) {
    let contract = match snf::declare("sharding").unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let block_number: felt252 = block_number.into();
    let calldata = array![owner, state_root, block_number, block_hash];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();

    (IShardingDispatcher { contract_address }, spy)
}

fn deploy_with_owner(
    owner: felt252,
) -> ((IContractComponentDispatcher, ITestContractDispatcher), EventSpy) {
    let contract = match snf::declare("test_contract").unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();

    (
        (
            IContractComponentDispatcher { contract_address },
            ITestContractDispatcher { contract_address },
        ),
        spy,
    )
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

// #[cfg(feature: 'slot_test')]
#[test]
fn test_update_state() {
    // Deploy the sharding contract with owner, state root, block number, and block hash
    let (sharding, mut _spy) = deploy_with_owner_and_state(
        owner: c::OWNER().into(),
        state_root: 1120029756675208924496185249815549700817638276364867982519015153297469423111,
        block_number: 97999,
        block_hash: 0,
    );

    // Deploy the test contract with owner
    let ((test_contract, test_contract_component), mut test_spy) = deploy_with_owner(
        owner: c::OWNER().into(),
    );

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };

    //Created first dispatcher for test contract interface
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };
    //Created second dispatcher for component interface
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract_component.contract_address,
    };

    let mut felts = get_state_update(test_contract_dispatcher.contract_address.into())
        .span()
        .into_iter();
    let output: StarknetOsOutput = deserialize_os_output(ref felts);
    println!("output: {:?}", output);

    let snos_output = get_state_update(test_contract_dispatcher.contract_address.into());

    // Initialize the shard by connecting the test contract to the sharding system
    snf::start_cheat_caller_address(
        test_contract_component_dispatcher.contract_address, c::OWNER(),
    );
    test_contract_component_dispatcher.initialize_shard(shard_dispatcher.contract_address);

    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    shard_dispatcher.update_state(snos_output.span(), 1);

    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set");
    println!("counter: {:?}", counter);

    // Verify that an unchanged storage slot remains at its default value
    let unchanged_slot = test_contract_dispatcher
        .read_storage_slot(0x7B62949C85C6AF8A50C11C22927F9302F7A2E40BC93B4C988415915B0F97F09);
    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    //TODO! we need to talk about silent consent to not update unsent slots

    let shard_id = shard_dispatcher.get_shard_id(test_contract_dispatcher.contract_address);
    assert!(shard_id == 1, "Shard id is not set");

    let events = test_spy.get_events();
    println!("events: {:?}", events);
}

#[test]
fn test_ending_event() {
    let ((test_contract, _), mut test_spy) = deploy_with_owner(owner: c::OWNER().into());

    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract.contract_address,
    };

    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER());
    test_contract_dispatcher.increment();
    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER());
    test_contract_dispatcher.increment();
    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER());
    test_contract_dispatcher.increment();

    let expected_increment = GameFinished { caller: c::OWNER() };

    test_spy
        .assert_emitted(
            @array![
                (
                    test_contract_dispatcher.contract_address,
                    Event::GameFinished(expected_increment),
                ),
            ],
        );
}
