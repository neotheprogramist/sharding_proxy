use starknet::{ContractAddress};

#[derive(Drop, Serde, starknet::Store, Hash, Copy, Debug)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub slot: felt252,
    pub crd_type: CRDType,
}

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add,
    #[default]
    Lock,
    Set,
}

#[derive(Drop, Serde, Hash, Copy, Debug)]
pub struct CRDTStorageSlot {
    pub key: felt252,
    pub value: felt252,
    pub crd_type: CRDType,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_sharding(ref self: TContractState, storage_slots: Span<StorageSlotWithContract>);

    fn update_contract_state(
        ref self: TContractState, snos_output: Span<felt252>, shard_id: felt252, crd_type: CRDType,
    );

    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;
}

#[starknet::contract]
pub mod sharding {
    use core::iter::IntoIterator;
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use sharding_tests::snos_output::deserialize_os_output;
    use super::ISharding;
    use super::StorageSlotWithContract;
    use super::CRDType;
    use sharding_tests::contract_component::IContractComponentDispatcher;
    use sharding_tests::contract_component::IContractComponentDispatcherTrait;
    use sharding_tests::config::{config_cpt, config_cpt::InternalTrait as ConfigInternal};
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::CRDTStorageSlot;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    type shard_id = felt252;

    #[storage]
    struct Storage {
        locked_slots: Map<StorageSlotWithContract, bool>,
        add_slots: Map<StorageSlotWithContract, bool>,
        set_slots: Map<StorageSlotWithContract, bool>,
        initializer_contract_address: ContractAddress,
        shard_id: Map<ContractAddress, shard_id>,
        shard_id_for_slot: Map<StorageSlotWithContract, shard_id>,
        owner: ContractAddress,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        config: config_cpt::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ShardingInitialized: ShardingInitialized,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ConfigEvent: config_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardingInitialized {
        pub initializer: ContractAddress,
        pub shard_id: felt252,
        pub storage_slots: Span<StorageSlotWithContract>,
    }

    pub mod Errors {
        pub const ALREADY_INITIALIZED: felt252 = 'Sharding: Already initialized';
        pub const NOT_INITIALIZED: felt252 = 'Sharding: Not initialized';
        pub const STORAGE_LOCKED: felt252 = 'Sharding: Storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Sharding: Storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Sharding: Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Sharding: Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Sharding: No contracts';
        pub const NO_STORAGE_CHANGES: felt252 = 'Sharding: No storage changes';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_sharding(
            ref self: ContractState, storage_slots: Span<StorageSlotWithContract>,
        ) {
            self.config.assert_only_owner_or_operator();

            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = current_shard_id + 1;
            self.shard_id.write(caller, new_shard_id);
            self.initializer_contract_address.write(caller);

            self
                .emit(
                    ShardingInitialized {
                        initializer: caller, shard_id: new_shard_id, storage_slots: storage_slots,
                    },
                );
        }

        fn update_contract_state(
            ref self: ContractState,
            snos_output: Span<felt252>,
            shard_id: felt252,
            crd_type: CRDType,
        ) {
            self.config.assert_only_owner_or_operator();

            let mut _snos_output_iter = snos_output.into_iter();
            let program_output_struct = deserialize_os_output(ref _snos_output_iter);

            assert(
                program_output_struct.state_diff.contracts.span().len() != 0,
                Errors::NO_CONTRACTS_SUBMITTED,
            );

            for contract in program_output_struct.state_diff.contracts.span() {
                let contract_address: ContractAddress = (*contract.addr)
                    .try_into()
                    .expect('Invalid contract address');

                if self.initializer_contract_address.read() == contract_address {
                    let contract_shard_id = self.shard_id.read(contract_address);
                    assert(contract_shard_id != 0, Errors::SHARD_ID_NOT_SET);
                    assert(contract_shard_id == shard_id, Errors::SHARD_ID_MISMATCH);
                    println!("Processing contract: {:?}", contract_address);

                    let mut storage_changes = ArrayTrait::new();
                    for storage_change in contract.storage_changes.span() {
                        let (storage_key, storage_value) = *storage_change;
                        storage_changes
                            .append(
                                CRDTStorageSlot {
                                    key: storage_key, value: storage_value, crd_type,
                                },
                            );
                    };
                    assert(storage_changes.span().len() != 0, Errors::NO_STORAGE_CHANGES);

                    let contract_dispatcher = IContractComponentDispatcher {
                        contract_address: contract_address,
                    };
                    contract_dispatcher.update_state(storage_changes, shard_id);
                }
            }
        }

        fn get_shard_id(ref self: ContractState, contract_address: ContractAddress) -> felt252 {
            let shard_id = self.shard_id.read(contract_address);
            assert(shard_id != 0, Errors::SHARD_ID_NOT_SET);
            shard_id
        }
    }
}
