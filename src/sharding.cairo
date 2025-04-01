use starknet::{ContractAddress};

#[derive(Drop, Serde, starknet::Store, Hash, Copy, Debug)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub slot: felt252,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_shard(ref self: TContractState, storage_slots: Span<StorageSlotWithContract>);

    fn update_state(ref self: TContractState, snos_output: Span<felt252>, shard_id: felt252);

    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;
}

#[starknet::contract]
pub mod sharding {
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use sharding_tests::shard_output::ShardOutput;
    use super::ISharding;
    use super::StorageSlotWithContract;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::contract_component::IContractComponentDispatcher;
    use sharding_tests::contract_component::IContractComponentDispatcherTrait;
    use sharding_tests::config::{config_cpt, config_cpt::InternalTrait as ConfigInternal};


    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    type shard_id = felt252;

    #[storage]
    struct Storage {
        initialized_storage: Map<StorageSlotWithContract, bool>,
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
        ShardInitialized: ShardInitialized,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ConfigEvent: config_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardInitialized {
        pub initializer: ContractAddress,
        pub shard_id: felt252,
    }

    pub mod Errors {
        pub const SHARDING_ERROR: felt252 = 'Sharding: here sharding error';
        pub const ALREADY_INITIALIZED: felt252 = 'Sharding: already initialized';
        pub const NOT_INITIALIZED: felt252 = 'Sharding: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'Sharding: storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Sharding: storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Sharding: shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Sharding: shard id not set';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_shard(ref self: ContractState, storage_slots: Span<StorageSlotWithContract>) {
            self.config.assert_only_owner_or_operator();

            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = current_shard_id + 1;
            self.shard_id.write(caller, new_shard_id);

            println!(
                "Initializing shard for caller: {:?}, new shard_id: {:?}", caller, new_shard_id,
            );

            for i in 0..storage_slots.len() {
                let storage_slot = *storage_slots.at(i);

                let is_initialized = self.initialized_storage.read(storage_slot);
                assert(!is_initialized, Errors::ALREADY_INITIALIZED);

                // Lock this storage key
                self.initialized_storage.write(storage_slot, true);
                self.shard_id_for_slot.write(storage_slot, new_shard_id);
                println!("Initialized slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id);
            };

            // Emit initialization event
            self.initializer_contract_address.write(caller);

            self.emit(ShardInitialized { initializer: caller, shard_id: new_shard_id });
        }

        fn update_state(ref self: ContractState, snos_output: Span<felt252>, shard_id: felt252) {
            self.config.assert_only_owner_or_operator();
            let mut snos_output = snos_output;
            let program_output_struct: ShardOutput = Serde::deserialize(ref snos_output).unwrap();
            for contract in program_output_struct.state_diff.span() {
                let contract_address: ContractAddress = (*contract.addr)
                    .try_into()
                    .expect('Invalid contract address');

                if self.initializer_contract_address.read() == contract_address {
                    let contract_shard_id = self.shard_id.read(contract_address);
                    assert(contract_shard_id != 0, Errors::SHARD_ID_NOT_SET);
                    assert(contract_shard_id == shard_id, Errors::SHARD_ID_MISMATCH);
                    println!("Processing contract: {:?}", contract_address);

                    let mut slots_to_change = ArrayTrait::new();

                    for storage_change in contract.storage_changes.span() {
                        let (storage_key, storage_value) = *storage_change;

                        // Create a StorageSlot to check if it's locked
                        let slot = StorageSlotWithContract {
                            contract_address: contract_address, slot: storage_key,
                        };

                        let slot_shard_id = self.shard_id_for_slot.read(slot);

                        println!(
                            "Checking slot: {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}",
                            slot,
                            slot_shard_id,
                            shard_id,
                        );

                        if slot_shard_id == shard_id {
                            if self.initialized_storage.read(slot) {
                                slots_to_change.append((storage_key, storage_value));
                            }
                        } else {
                            println!("Skipping slot with mismatched shard_id: {:?}", slot);
                        }
                    };

                    // Call update on the specific contract
                    let contract_dispatcher = IContractComponentDispatcher {
                        contract_address: contract_address,
                    };

                    contract_dispatcher.update_shard(slots_to_change.span());

                    // After updating, unlock the slots for this contract
                    for storage_change in contract.storage_changes.span() {
                        let (storage_key, _storage_value) = *storage_change;

                        // Create a StorageSlot to unlock
                        let slot = StorageSlotWithContract {
                            contract_address: contract_address, slot: storage_key,
                        };

                        let is_initialized = self.initialized_storage.read(slot);
                        let slot_shard_id = self.shard_id_for_slot.read(slot);

                        if is_initialized && slot_shard_id == shard_id {
                            println!("Unlocking slot: {:?}", slot);
                            self.initialized_storage.write(slot, false);
                        }
                    }
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
