use starknet::ContractAddress;

/// Minimal dojo model for integration testing dojo world + sharding proxy.
#[derive(Copy, Drop)]
#[dojo::model]
pub struct Resource {
    #[key]
    pub player: ContractAddress,
    pub gold: felt252,
    pub wood: felt252,
}
