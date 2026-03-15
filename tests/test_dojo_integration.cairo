//! Integration tests: dojo world + real sharding proxy.
//!
//! Verifies the full round-trip: world.request_sharding → proxy.initialize_sharding
//! → proxy settlement → world.update_shard_state → model values updated.

use dojo::model::{Model, ModelStorage, ModelStorageTest};
use dojo::sharding::compute_dojo_field_slot;
use dojo::sharding::request::{
    CRDVariant, IntoShardField, IntoShardModel, ShardCoverage, ShardFieldSelection, ShardModel,
};
use dojo::utils::entity_id_from_keys;
use dojo::world::{IShardingProxyDispatcher, IShardingProxyDispatcherTrait, IWorldDispatcherTrait};
use dojo_snf_test::world::{NamespaceDef, TestResource, spawn_test_world};
use sharding_tests::config::{IConfigDispatcher, IConfigDispatcherTrait};
use sharding_tests::dojo_test_model::Resource;
use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::storage_commitment::{
    IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait,
};
use snforge_std as snf;
use snforge_std::{ContractClassTrait, DeclareResultTrait};
use starknet::ContractAddress;

const OWNER: ContractAddress = 123.try_into().unwrap();

/// The dojo namespace hash for "dojo" namespace.
/// Must match the value used by dojo core tests.
const DOJO_NSH: felt252 = 0x309e09669bc1fdc1dd6563a7ef862aa6227c97d099d08cc7b81bad58a7443fa;

/// Helper: get layout field selectors for Resource (gold, wood).
fn resource_field_selectors() -> (felt252, felt252) {
    let layout = Model::<Resource>::layout();
    if let dojo::meta::Layout::Struct(fields) = layout {
        ((*fields[0]).selector, (*fields[1]).selector)
    } else {
        panic!("expected struct layout")
    }
}

/// Deploy StorageCommitment contract with proper constructor args.
fn deploy_storage_commitment() -> ContractAddress {
    let contract_class = snf::declare("StorageCommitment").unwrap().contract_class();
    let deployer = snf::test_address();
    let calldata: Array<felt252> = array![deployer.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();

    let dispatcher = IStorageCommitmentDispatcher { contract_address };
    dispatcher.set_authorized_caller(snf::test_address());

    contract_address
}

/// Deploy the real sharding proxy with StorageCommitment registry.
fn deploy_sharding_proxy(
    owner: ContractAddress, storage_commitment_registry: ContractAddress,
) -> ContractAddress {
    let contract_class = snf::declare("sharding").unwrap().contract_class();
    let calldata: Array<felt252> = array![owner.into(), storage_commitment_registry.into()];
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

/// Spawn a dojo world with the Resource model and return (world, model_selector).
fn deploy_world_and_resource() -> (dojo::world::WorldStorage, felt252) {
    let namespace_def = NamespaceDef {
        namespace: "dojo", resources: [TestResource::Model("Resource")].span(),
    };

    (spawn_test_world([namespace_def].span()), Model::<Resource>::selector(DOJO_NSH))
}

/// Full test setup: dojo world + real sharding proxy, connected.
fn setup() -> (dojo::world::WorldStorage, felt252, ContractAddress, IShardingDispatcher) {
    let (mut world, model_selector) = deploy_world_and_resource();
    let world_address = world.dispatcher.contract_address;

    // Deploy StorageCommitment + real sharding proxy.
    let sc_addr = deploy_storage_commitment();
    let proxy_addr = deploy_sharding_proxy(OWNER, sc_addr);

    // Register the world as an operator on the proxy
    // (proxy checks assert_only_owner_or_operator in initialize_sharding).
    let config = IConfigDispatcher { contract_address: proxy_addr };
    snf::start_cheat_caller_address(proxy_addr, OWNER);
    config.register_operator(world_address);
    snf::stop_cheat_caller_address(proxy_addr);

    // Set block number so fork_block_number=0 works.
    snf::start_cheat_block_number(proxy_addr, 0);

    let proxy_dispatcher = IShardingDispatcher { contract_address: proxy_addr };
    (world, model_selector, proxy_addr, proxy_dispatcher)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Test: world.request_sharding with Set CRDT → dev settlement → verify overwrite.
#[test]
fn test_world_proxy_set_round_trip() {
    let (mut world, model_selector, proxy_addr, _) = setup();
    let world_address = world.dispatcher.contract_address;

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    let resource = Resource { player: bob, gold: 100, wood: 200 };
    world.write_model_test(@resource);

    // Request sharding with Set CRDT (all fields).
    let layout = Model::<Resource>::layout();
    let models = [(model_selector, layout).shard([bob.into()].span())].span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // Dev settlement: proxy overwrites gold=999 via update_shard_state.
    let (sel_gold, _) = resource_field_selectors();
    let entity_id = entity_id_from_keys(@bob);
    let slot_gold = compute_dojo_field_slot(model_selector, entity_id, sel_gold);

    // The proxy calls the world's sharding-proxy ABI.
    let sharding = IShardingProxyDispatcher { contract_address: world_address };
    snf::start_cheat_caller_address(world_address, proxy_addr);
    sharding.settle_shard_changes(1, array![(slot_gold, 999)], [].span(), [].span(), [].span());
    snf::stop_cheat_caller_address(world_address);

    let result: Resource = world.read_model(bob);
    assert(result.gold == 999, 'Set should overwrite gold');
    assert(result.wood == 200, 'wood should be unchanged');
}

/// Test: world.request_sharding with Add CRDT → verify delta merge.
#[test]
fn test_world_proxy_add_delta() {
    let (mut world, model_selector, proxy_addr, _) = setup();
    let world_address = world.dispatcher.contract_address;

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    let resource = Resource { player: bob, gold: 100, wood: 200 };
    world.write_model_test(@resource);

    // Request sharding with Add CRDT.
    let layout = Model::<Resource>::layout();
    let models = [(
        model_selector, layout,
    )
        .shard_with(
            [bob.into()].span(), CRDVariant::Add, ShardFieldSelection::AutoDeterministic,
        )]
        .span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // Mainchain changes gold from 100 → 120 while shard is active.
    let updated = Resource { player: bob, gold: 120, wood: 200 };
    world.write_model_test(@updated);

    // Shard saw initial gold=100, produced shard gold=150 (delta=50).
    let (sel_gold, _) = resource_field_selectors();
    let entity_id = entity_id_from_keys(@bob);
    let slot_gold = compute_dojo_field_slot(model_selector, entity_id, sel_gold);

    let sharding = IShardingProxyDispatcher { contract_address: world_address };
    snf::start_cheat_caller_address(world_address, proxy_addr);
    sharding.settle_shard_changes(1, array![(slot_gold, 150)], [].span(), [].span(), [].span());
    snf::stop_cheat_caller_address(world_address);

    // Expected: current(120) + (shard(150) - initial(100)) = 170
    let result: Resource = world.read_model(bob);
    assert(result.gold == 170, 'Add delta incorrect');
    assert(result.wood == 200, 'wood should be unchanged');
}

/// Test: per-field CRDT — gold as Add (delta merge), wood as Set (overwrite).
#[test]
fn test_world_proxy_per_field_mixed() {
    let (mut world, model_selector, proxy_addr, _) = setup();
    let world_address = world.dispatcher.contract_address;

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    let resource = Resource { player: bob, gold: 100, wood: 200 };
    world.write_model_test(@resource);

    // Per-field: gold → Add, wood → Set.
    let (sel_gold, sel_wood) = resource_field_selectors();
    let models = [
        ShardModel {
            selector: model_selector,
            keys: [bob.into()].span(),
            fields: [sel_gold.as_add(), sel_wood.as_set()].span(),
            coverage: ShardCoverage::Full,
        },
    ]
        .span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // Mainchain changes gold 100 → 120 while shard is active.
    let updated = Resource { player: bob, gold: 120, wood: 200 };
    world.write_model_test(@updated);

    // Shard: gold initial=100 → shard=150 (delta=50), wood overwrite=999.
    let entity_id = entity_id_from_keys(@bob);
    let slot_gold = compute_dojo_field_slot(model_selector, entity_id, sel_gold);
    let slot_wood = compute_dojo_field_slot(model_selector, entity_id, sel_wood);

    let sharding = IShardingProxyDispatcher { contract_address: world_address };
    snf::start_cheat_caller_address(world_address, proxy_addr);
    sharding
        .settle_shard_changes(1, array![(slot_gold, 150), (slot_wood, 999)], [].span(), [].span(), [].span());
    snf::stop_cheat_caller_address(world_address);

    // gold: current(120) + (shard(150) - initial(100)) = 170
    // wood: 999 (Set overwrite)
    let result: Resource = world.read_model(bob);
    assert(result.gold == 170, 'Add delta incorrect');
    assert(result.wood == 999, 'Set should overwrite wood');
}

/// Test: cancel_shard_state — values remain unchanged.
#[test]
fn test_world_proxy_cancel() {
    let (mut world, model_selector, proxy_addr, _) = setup();
    let world_address = world.dispatcher.contract_address;

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    let resource = Resource { player: bob, gold: 100, wood: 200 };
    world.write_model_test(@resource);

    let layout = Model::<Resource>::layout();
    let models = [(model_selector, layout).shard([bob.into()].span())].span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // Cancel instead of settling.
    let (sel_gold, sel_wood) = resource_field_selectors();
    let entity_id = entity_id_from_keys(@bob);
    let slot_gold = compute_dojo_field_slot(model_selector, entity_id, sel_gold);
    let slot_wood = compute_dojo_field_slot(model_selector, entity_id, sel_wood);

    let sharding = IShardingProxyDispatcher { contract_address: world_address };
    snf::start_cheat_caller_address(world_address, proxy_addr);
    sharding.cancel_shard_state(1, array![slot_gold, slot_wood].span());
    snf::stop_cheat_caller_address(world_address);

    let result: Resource = world.read_model(bob);
    assert(result.gold == 100, 'gold should be unchanged');
    assert(result.wood == 200, 'wood should be unchanged');
}

/// Test: PN-Counter — both fields as Add (G-Counter) for additions/subtractions.
#[test]
fn test_world_proxy_pn_counter() {
    let (mut world, model_selector, proxy_addr, _) = setup();
    let world_address = world.dispatcher.contract_address;

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    // gold = total additions (P), wood = total subtractions (N), balance = P - N
    let resource = Resource { player: bob, gold: 1000, wood: 200 };
    world.write_model_test(@resource);

    // PN-Counter: both fields as Add (G-Counter).
    let layout = Model::<Resource>::layout();
    let models = [(
        model_selector, layout,
    )
        .shard_with(
            [bob.into()].span(), CRDVariant::Add, ShardFieldSelection::AutoDeterministic,
        )]
        .span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // Mainchain: P 1000→1020, N 200→210
    let updated = Resource { player: bob, gold: 1020, wood: 210 };
    world.write_model_test(@updated);

    // Shard: P initial=1000 → shard=1050 (delta=50), N initial=200 → shard=230 (delta=30)
    let (sel_gold, sel_wood) = resource_field_selectors();
    let entity_id = entity_id_from_keys(@bob);
    let slot_gold = compute_dojo_field_slot(model_selector, entity_id, sel_gold);
    let slot_wood = compute_dojo_field_slot(model_selector, entity_id, sel_wood);

    let sharding = IShardingProxyDispatcher { contract_address: world_address };
    snf::start_cheat_caller_address(world_address, proxy_addr);
    sharding
        .settle_shard_changes(1, array![(slot_gold, 1050), (slot_wood, 230)], [].span(), [].span(), [].span());
    snf::stop_cheat_caller_address(world_address);

    // P: current(1020) + (shard(1050) - initial(1000)) = 1070
    // N: current(210) + (shard(230) - initial(200)) = 240
    // Balance: 1070 - 240 = 830
    let result: Resource = world.read_model(bob);
    assert(result.gold == 1070, 'PN: P delta incorrect');
    assert(result.wood == 240, 'PN: N delta incorrect');
}

/// Test: end_shard forwards to proxy.
#[test]
fn test_world_proxy_end_shard() {
    let (mut world, model_selector, proxy_addr, _) = setup();

    let bob: ContractAddress = 0xb0b.try_into().unwrap();
    let resource = Resource { player: bob, gold: 100, wood: 200 };
    world.write_model_test(@resource);

    let layout = Model::<Resource>::layout();
    let models = [(model_selector, layout).shard([bob.into()].span())].span();
    world.dispatcher.request_sharding(proxy_addr, models);

    // end_shard should not panic — forwards to proxy.end_shard().
    world.dispatcher.end_shard();
}
