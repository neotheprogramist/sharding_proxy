use snforge_std::EventSpyTrait;
use core::traits::Into;
use core::result::ResultTrait;
use core::iter::IntoIterator;
use core::poseidon::PoseidonImpl;
use openzeppelin_testing::constants as c;
use snforge_std as snf;
use snforge_std::{ContractClassTrait, EventSpy};

use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::sharding::IShardingDispatcherTrait;
use sharding_tests::snos_output::{StarknetOsOutput, deserialize_os_output};
use sharding_tests::test_contract::ITestContractDispatcher;
use sharding_tests::test_contract::ITestContractDispatcherTrait;
use sharding_tests::contract_component::IContractComponentDispatcher;
use sharding_tests::contract_component::IContractComponentDispatcherTrait;

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

    println!("contract_address: 0x{:x}", contract_address);
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

    println!("contract_address: 0x{:x}", contract_address);
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
        0x793ca6f0a9c316340d5e8a9afc324a493f2bf03420992d85c006b92954cf2a9,
        0x274ab9432ec9e654bd358af1bab72673bb518969356ceea21146077f7c72132,
        0x1,
        0x2,
        0x1f96a23f2636fe713667cbb322bb9503abcd14556fc19042296d00a7f200d05,
        0x23ce3c50bbd0c7e645230ffcdbd775730434795ea79bf8e7ea5e8dcf3d69da3,
        0x0,
        0x438be9915def8bc153122d026cc6ae4430d30ebe1dbfb72c7b303278449c06f,
        0x0,
        0x1,
        0x0,
        0x0,
        0x4,
        test_contract_address,
        0x8000000000000000c02,
        0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2,
        0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2,
        test_contract_address,
        0xa,
        0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac,
        0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac,
        0x7EBCC807B5C7E19F245995A55AED6F46F5F582F476A886B91B834B0DDF5854,
        0x21e19e0c9bab23fccd5,
        0x21e19e0c9bab23fafd5,
        0x7b62949c85c6af8a50c11c22927f9302f7a2e40bc93b4c988415915b0f97f09,
        0x332b,
        0x502b,
        test_contract_address,
        0x2,
        0x7b3e05f48f0c69e4a65ce5e076a66271a527aff2c34ce1083ec6e1526997a69,
        0x7b3e05f48f0c69e4a65ce5e076a66271a527aff2c34ce1083ec6e1526997a69,
        test_contract_address,
        0x13,
        0x0,
        0x4810002cdfed6c4fd50781f083f7d43f70b378d6acf4f5b33c3cac2857a0b5d,
        0xa3e35b50432cd1669313bd75e434458dd8bc8d21437d2aa29d6c256f7b13d1,
        0x0,
        0x1,
        0x27f5e07830ee1ad079cf8c8462d2edc585bda982dbded162e761eb7fd71d84a,
        0x0,
        0x1,
        0x2bd557f4ba80dfabefabe45e9b2dd35db1b9a78e96c72bc2b69b655ce47a930,
        0x0,
        0x1,
        0x3fd94528f836b27f28ba8d7c354705dfc5827b048ca48870ac47c9d5b9aa181,
        0x0,
        0x1,
        0x0,
    ];
    felts
}

#[cfg(feature: 'slot_test')]
#[test]
fn test_update_state() {
    let (sharding, mut _spy) = deploy_with_owner_and_state(
        owner: c::OWNER().into(),
        state_root: 1120029756675208924496185249815549700817638276364867982519015153297469423111,
        block_number: 97999,
        block_hash: 0,
    );

    let ((test_contract_dispatcher, contract_component_dispatcher), mut test_spy) =
        deploy_with_owner(
        owner: c::OWNER().into(),
    );

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding.contract_address };
    let test_contract_dispatcher = ITestContractDispatcher {
        contract_address: test_contract_dispatcher.contract_address,
    };
    let contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: contract_component_dispatcher.contract_address,
    };

    let mut felts = get_state_update(test_contract_dispatcher.contract_address.into())
        .span()
        .into_iter();
    let output: StarknetOsOutput = deserialize_os_output(ref felts);
    println!("output: {:?}", output);

    let snos_output = get_state_update(test_contract_dispatcher.contract_address.into());

    snf::start_cheat_caller_address(contract_component_dispatcher.contract_address, c::OWNER());
    contract_component_dispatcher.initialize_shard(shard_dispatcher.contract_address);

    snf::start_cheat_caller_address(shard_dispatcher.contract_address, c::OWNER());

    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    shard_dispatcher.update_state(snos_output.span());

    let counter = test_contract_dispatcher.get_counter();
    assert!(counter == 9999999999999999979477, "Counter is not set");
    println!("counter: {:?}", counter);

    let unchanged_slot = test_contract_dispatcher
        .read_storage_slot(0x7B62949C85C6AF8A50C11C22927F9302F7A2E40BC93B4C988415915B0F97F09);
    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    let events = test_spy.get_events();
    println!("events: {:?}", events);
}
