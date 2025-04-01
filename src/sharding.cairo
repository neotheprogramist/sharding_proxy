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

trait CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType);
}

impl CRDTypeImpl of CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType) {
        match crd_type {
            CRDType::Add => {
                assert(
                    self == Option::None || self == Option::Some(CRDType::Add),
                    'Sharding already initialized',
                );
            },
            CRDType::Lock => { assert(self == Option::None, 'Sharding already initialized'); },
            CRDType::Set => {
                assert(
                    self == Option::None || self == Option::Some(CRDType::Set),
                    'Sharding already initialized',
                );
            },
        }
    }
}

#[derive(Drop, Serde, Hash, Copy, Debug)]
pub struct CRDTStorageSlot {
    pub key: felt252,
    pub value: felt252,
    pub crd_type: CRDType,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_shard(ref self: TContractState, storage_slots: Span<StorageSlotWithContract>);

    fn update_state(
        ref self: TContractState, snos_output: Span<felt252>, shard_id: felt252, crd_type: CRDType,
    );

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
    use super::CRDType;
    use super::CRDTypeTrait;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::contract_component::IContractComponentDispatcher;
    use sharding_tests::contract_component::IContractComponentDispatcherTrait;
    use sharding_tests::config::{config_cpt, config_cpt::InternalTrait as ConfigInternal};
    use super::CRDTStorageSlot;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    type shard_id = felt252;

    #[storage]
    struct Storage {
        slots: Map<(ContractAddress, felt252), (Option<CRDType>, felt252)>,
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
        ContractSlotUpdated: ContractSlotUpdated,
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

    #[derive(Drop, starknet::Event, Clone)]
    pub struct ContractSlotUpdated {
        pub contract_address: ContractAddress,
        pub shard_id: felt252,
        pub slots_to_change: Array<CRDTStorageSlot>,
    }

    pub mod Errors {
        pub const ALREADY_INITIALIZED: felt252 = 'Sharding already initialized';
        pub const NOT_INITIALIZED: felt252 = 'Sharding not initialized';
        pub const STORAGE_LOCKED: felt252 = 'Storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'No contracts submitted';
        pub const NO_SLOTS_TO_UPDATE: felt252 = 'No slots to update';
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

            for storage_slot in storage_slots {
                let storage_slot = *storage_slot;
                let crd_type = storage_slot.crd_type;

                let (prev_crd_type, init_count) = self
                    .slots
                    .read((storage_slot.contract_address, storage_slot.slot));

                prev_crd_type.verify_crd_type(crd_type);

                println!("Locking storage slots");
                // Lock this storage key
                self
                    .slots
                    .write(
                        (storage_slot.contract_address, storage_slot.slot),
                        (Option::Some(crd_type), init_count + 1),
                    );
                self.shard_id_for_slot.write(storage_slot, new_shard_id);
                println!("Locked slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id);
            };
            // Emit initialization event
            self.initializer_contract_address.write(caller);

            self.emit(ShardInitialized { initializer: caller, shard_id: new_shard_id });
        }

        fn update_state(
            ref self: ContractState,
            snos_output: Span<felt252>,
            shard_id: felt252,
            crd_type: CRDType,
        ) {
            self.config.assert_only_owner_or_operator();
            let mut snos_output = snos_output;
            let program_output_struct: ShardOutput = Serde::deserialize(ref snos_output).unwrap();
            assert(program_output_struct.state_diff.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);
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
                            contract_address: contract_address, slot: storage_key, crd_type,
                        };

                        let slot_shard_id = self.shard_id_for_slot.read(slot);
                        let (prev_crd_type, _) = self
                            .slots
                            .read((slot.contract_address, slot.slot));

                        println!(
                            "Checking slot (Lock): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, prev_crd_type: {:?}",
                            slot,
                            slot_shard_id,
                            shard_id,
                            prev_crd_type,
                        );

                        if slot_shard_id == shard_id && prev_crd_type == Option::Some(crd_type) {
                            slots_to_change
                                .append(
                                    CRDTStorageSlot {
                                        key: storage_key, value: storage_value, crd_type,
                                    },
                                );
                        } else {
                            println!(
                                "Skipping slot with mismatched shard_id or not locked: {:?}", slot,
                            );
                        }
                    };

                    println!("Updating contract with {} slots", slots_to_change.len());

                    let contract_dispatcher = IContractComponentDispatcher {
                        contract_address: contract_address,
                    };

                    if slots_to_change.len() == 0 {
                        println!("No slots to update");
                    };

                    contract_dispatcher.update_shard(slots_to_change.clone());

                    for slot_to_unlock in slots_to_change.span() {
                        // Create a StorageSlot to unlock
                        let slot = StorageSlotWithContract {
                            contract_address: contract_address,
                            slot: *slot_to_unlock.key,
                            crd_type: *slot_to_unlock.crd_type,
                        };
                        println!("Unlocking slot: {:?}", slot);
                        let (prev_crd_type, init_count) = self
                            .slots
                            .read((slot.contract_address, slot.slot));
                        assert(init_count != 0, Errors::STORAGE_UNLOCKED);
                        if init_count - 1 == 0 {
                            self.slots.write((slot.contract_address, slot.slot), (Option::None, 0));
                        } else {
                            self
                                .slots
                                .write(
                                    (slot.contract_address, slot.slot),
                                    (prev_crd_type, init_count - 1),
                                );
                        }
                    };
                    self.emit(ContractSlotUpdated { contract_address, shard_id, slots_to_change });
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
