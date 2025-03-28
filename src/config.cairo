//! SPDX-License-Identifier: MIT
//!
//! Interface for sharding contract configuration.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IConfig<T> {
    fn register_operator(ref self: T, address: ContractAddress);
    fn unregister_operator(ref self: T, address: ContractAddress);
    fn is_operator(self: @T, address: ContractAddress) -> bool;
}

mod errors {
    pub const INVALID_CALLER: felt252 = 'Config: not owner or operator';
    pub const ALREADY_REGISTERED: felt252 = 'Config: already operator';
    pub const NOT_OPERATOR: felt252 = 'Config: not operator';
}

/// Configuration component.
///
/// Depends on `ownable` to ensure the configuration is
/// only editable by contract's owner.
#[starknet::component]
pub mod config_cpt {
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
        interface::IOwnable,
    };
    use starknet::ContractAddress;
    use starknet::storage::Map;
    use starknet::storage::{StorageMapReadAccess, StorageMapWriteAccess};
    use super::errors;
    use super::IConfig;

    #[storage]
    pub struct Storage {
        pub operators: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    pub enum Event {
        OperatorRegistered: OperatorRegistered,
    }

    #[derive(Copy, Drop, starknet::Event)]
    pub struct OperatorRegistered {
        pub operator: ContractAddress,
    }

    #[embeddable_as(ConfigImpl)]
    impl Config<
        TContractState,
        +HasComponent<TContractState>,
        impl Ownable: ownable_cpt::HasComponent<TContractState>,
    > of IConfig<ComponentState<TContractState>> {
        fn register_operator(ref self: ComponentState<TContractState>, address: ContractAddress) {
            get_dep_component!(@self, Ownable).assert_only_owner();
            assert(!self.operators.read(address), errors::ALREADY_REGISTERED);
            self.operators.write(address, true);
        }

        fn unregister_operator(ref self: ComponentState<TContractState>, address: ContractAddress) {
            get_dep_component!(@self, Ownable).assert_only_owner();
            assert(self.operators.read(address), errors::NOT_OPERATOR);
            self.operators.write(address, false);
        }

        fn is_operator(self: @ComponentState<TContractState>, address: ContractAddress) -> bool {
            self.operators.read(address)
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState,
        +HasComponent<TContractState>,
        impl Ownable: ownable_cpt::HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        /// Asserts if the caller is the owner of the contract or
        /// the authorized operator. Reverts otherwise.
        fn assert_only_owner_or_operator(ref self: ComponentState<TContractState>) {
            assert(
                self.is_owner_or_operator(starknet::get_caller_address()), errors::INVALID_CALLER,
            );
        }

        /// Verifies if the given address is the owner of the contract
        /// or the authorized operator.
        ///
        /// # Arguments
        ///
        /// * `address` - The contrat address to verify.
        fn is_owner_or_operator(
            ref self: ComponentState<TContractState>, address: ContractAddress,
        ) -> bool {
            let owner = get_dep_component!(@self, Ownable).owner();
            address == owner || self.is_operator(address)
        }
    }
}
