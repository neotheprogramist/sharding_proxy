use starknet::{ContractAddress};
use sharding_tests::contract_component::CRDType;

#[derive(Drop, Serde, starknet::Store, Hash, Copy, Debug)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub key: felt252,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_sharding(ref self: TContractState, storage_slots: Span<CRDType>);

    fn update_contract_state(ref self: TContractState, snos_output: Span<felt252>);
}

#[starknet::contract]
pub mod sharding {
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use starknet::{get_caller_address, ContractAddress};
    use sharding_tests::shard_output::ShardOutput;
    use super::ISharding;
    use sharding_tests::contract_component::IContractComponentDispatcher;
    use sharding_tests::contract_component::IContractComponentDispatcherTrait;
    use sharding_tests::config::{config_cpt, config_cpt::InternalTrait as ConfigInternal};
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::contract_component::CRDType;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    #[storage]
    struct Storage {
        initializer_contract_address: ContractAddress,
        owner: ContractAddress,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        config: config_cpt::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ShardInitialized: ShardInitialized,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ConfigEvent: config_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardInitialized {
        pub initializer: ContractAddress,
        pub storage_slots: Span<CRDType>,
    }

    pub mod Errors {
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Sharding: No contracts';
        pub const NO_STORAGE_CHANGES: felt252 = 'Sharding: No storage changes';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_sharding(ref self: ContractState, storage_slots: Span<CRDType>) {
            self.config.assert_only_owner_or_operator();

            let caller = get_caller_address();
            self.initializer_contract_address.write(caller);

            self.emit(ShardInitialized { initializer: caller, storage_slots });
        }

        fn update_contract_state(ref self: ContractState, snos_output: Span<felt252>) {
            self.config.assert_only_owner_or_operator();
            let mut snos_output = snos_output;
            let program_output_struct: ShardOutput = Serde::deserialize(ref snos_output).unwrap();

            assert(
                program_output_struct.state_diff.span().len() != 0, Errors::NO_CONTRACTS_SUBMITTED,
            );
            let mut merkle_root = program_output_struct.merkle_root;
            for contract in program_output_struct.state_diff.span() {
                let contract_address: ContractAddress = (*contract.addr)
                    .try_into()
                    .expect('Invalid contract address');

                if self.initializer_contract_address.read() == contract_address {
                    println!("Processing contract: {:?}", contract_address);

                    let mut storage_changes = ArrayTrait::new();
                    for storage_change in contract.storage_changes.span() {
                        let (storage_key, storage_value) = *storage_change;

                        storage_changes.append((storage_key, storage_value));
                    };
                    assert(storage_changes.span().len() != 0, Errors::NO_STORAGE_CHANGES);

                    let contract_dispatcher = IContractComponentDispatcher {
                        contract_address: contract_address,
                    };
                    println!("Updating shard state with merkle root: {:?}", merkle_root);
                    contract_dispatcher.update_shard_state(storage_changes, merkle_root);
                }
            }
        }
    }
}
