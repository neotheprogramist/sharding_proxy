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
    fn initialize_shard(ref self: TContractState, storage_slots: Span<StorageSlotWithContract>);

    fn update_state(
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
        pub const ALREADY_INITIALIZED: felt252 = 'Sharding already initialized';
        pub const NOT_INITIALIZED: felt252 = 'Sharding not initialized';
        pub const STORAGE_LOCKED: felt252 = 'Storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'No contracts submitted';
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
                let crd_type = storage_slots.at(i).crd_type;

                match crd_type {
                    CRDType::Lock => {
                        println!("Locking storage slots");
                        let is_locked = self.locked_slots.read(storage_slot);
                        let is_add = self.add_slots.read(storage_slot);
                        let is_set = self.set_slots.read(storage_slot);

                        assert(!is_locked && !is_add && !is_set, Errors::ALREADY_INITIALIZED);

                        // Lock this storage key
                        self.locked_slots.write(storage_slot, true);
                        self.shard_id_for_slot.write(storage_slot, new_shard_id);
                        println!(
                            "Locked slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id,
                        );
                    },
                    CRDType::Add => {
                        println!("Adding storage slots");
                        let is_locked = self.locked_slots.read(storage_slot);
                        let is_set = self.set_slots.read(storage_slot);

                        assert(!is_locked && !is_set, Errors::ALREADY_INITIALIZED);

                        self.add_slots.write(storage_slot, true);
                        self.shard_id_for_slot.write(storage_slot, new_shard_id);
                        println!(
                            "Added slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id,
                        );
                    },
                    CRDType::Set => {
                        println!("Setting storage slots");
                        let is_locked = self.locked_slots.read(storage_slot);
                        let is_add = self.add_slots.read(storage_slot);

                        assert(!is_locked && !is_add, Errors::ALREADY_INITIALIZED);

                        self.set_slots.write(storage_slot, true);
                        self.shard_id_for_slot.write(storage_slot, new_shard_id);
                        println!("Set slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id);
                    },
                }
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

                    let mut slots_to_change = ArrayTrait::new();

                    match crd_type {
                        CRDType::Lock => {
                            for storage_change in contract.storage_changes.span() {
                                let (storage_key, storage_value) = *storage_change;

                                // Create a StorageSlot to check if it's locked
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Lock,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_locked = self.locked_slots.read(slot);

                                println!(
                                    "Checking slot (Lock): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, is_locked: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                    is_locked,
                                );

                                if slot_shard_id == shard_id && is_locked {
                                    slots_to_change
                                        .append(
                                            CRDTStorageSlot {
                                                key: storage_key,
                                                value: storage_value,
                                                crd_type: CRDType::Lock,
                                            },
                                        );
                                } else {
                                    println!(
                                        "Skipping slot with mismatched shard_id or not locked: {:?}",
                                        slot,
                                    );
                                }
                            };
                        },
                        CRDType::Add => {
                            for storage_change in contract.storage_changes.span() {
                                let (storage_key, storage_value) = *storage_change;

                                // Create a StorageSlot to check if it's marked as Add
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Add,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_add = self.add_slots.read(slot);

                                println!(
                                    "Checking slot (Add): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, is_add: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                    is_add,
                                );

                                if slot_shard_id == shard_id && is_add {
                                    slots_to_change
                                        .append(
                                            CRDTStorageSlot {
                                                key: storage_key,
                                                value: storage_value,
                                                crd_type: CRDType::Add,
                                            },
                                        );
                                } else {
                                    println!(
                                        "Skipping slot with mismatched shard_id or not marked as Add: {:?}",
                                        slot,
                                    );
                                }
                            }
                        },
                        CRDType::Set => {
                            for storage_change in contract.storage_changes.span() {
                                let (storage_key, storage_value) = *storage_change;

                                // Create a StorageSlot to check if it's marked as Set
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Set,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_set = self.set_slots.read(slot);

                                println!(
                                    "Checking slot (Set): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, is_set: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                    is_set,
                                );

                                if slot_shard_id == shard_id && is_set {
                                    slots_to_change
                                        .append(
                                            CRDTStorageSlot {
                                                key: storage_key,
                                                value: storage_value,
                                                crd_type: CRDType::Set,
                                            },
                                        );
                                } else {
                                    println!(
                                        "Skipping slot with mismatched shard_id or not marked as Set: {:?}",
                                        slot,
                                    );
                                }
                            }
                        },
                    }

                    if slots_to_change.len() > 0 {
                        println!("Updating contract with {} slots", slots_to_change.len());

                        let contract_dispatcher = IContractComponentDispatcher {
                            contract_address: contract_address,
                        };

                        contract_dispatcher.update_shard(slots_to_change);
                    } else {
                        println!("No slots to update");
                    }

                    match crd_type {
                        CRDType::Lock => {
                            println!("Unlocking slots");
                            for storage_change in contract.storage_changes.span() {
                                let (storage_key, _storage_value) = *storage_change;

                                // Create a StorageSlot to unlock
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Lock,
                                };

                                let is_locked = self.locked_slots.read(slot);
                                let slot_shard_id = self.shard_id_for_slot.read(slot);

                                if is_locked && slot_shard_id == shard_id {
                                    println!("Unlocking slot: {:?}", slot);
                                    self.locked_slots.write(slot, false);
                                }
                            }
                        },
                        CRDType::Add |
                        CRDType::Set => {
                            for storage_change in contract.storage_changes.span() {
                                let (storage_key, _storage_value) = *storage_change;

                                // Create a StorageSlot to unlock
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address, slot: storage_key, crd_type,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_add = self.add_slots.read(slot);
                                let is_set = self.set_slots.read(slot);

                                println!(
                                    "Checking for unlock - slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}, is_add: {:?}, is_set: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                    is_add,
                                    is_set,
                                );

                                if slot_shard_id == shard_id {
                                    if crd_type == CRDType::Add && is_add {
                                        println!("Unlocking Add slot: {:?}", slot);
                                        self.add_slots.write(slot, false);
                                    } else if crd_type == CRDType::Set && is_set {
                                        println!("Unlocking Set slot: {:?}", slot);
                                        self.set_slots.write(slot, false);
                                    }
                                } else {
                                    println!(
                                        "Not unlocking Add or Set slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                        slot,
                                        slot_shard_id,
                                        shard_id,
                                    );
                                }
                            }
                        },
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
