use starknet::{ContractAddress};
use sharding_tests::sharding::StorageSlotWithContract;
use sharding_tests::sharding::CRDTStorageSlot;

#[starknet::interface]
pub trait IContractComponent<TContractState> {
    fn initialize_shard(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        contract_slots_changes: Span<StorageSlotWithContract>,
    );
    fn update_state(
        ref self: TContractState, snos_output: Array<CRDTStorageSlot>, shard_id: felt252,
    );
}

#[starknet::component]
pub mod contract_component {
    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use starknet::syscalls::storage_read_syscall;
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::sharding::StorageSlotWithContract;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::sharding::CRDType;
    use sharding_tests::sharding::CRDTStorageSlot;
    use starknet::storage_access::StorageAddress;

    type shard_id = felt252;

    #[storage]
    pub struct Storage {
        contract_address: ContractAddress,
        sharding_contract_address: ContractAddress,
        locked_slots: Map<StorageSlotWithContract, bool>,
        add_slots: Map<StorageSlotWithContract, bool>,
        set_slots: Map<StorageSlotWithContract, bool>,
        initializer_contract_address: ContractAddress,
        shard_id: Map<ContractAddress, shard_id>,
        shard_id_for_slot: Map<StorageSlotWithContract, shard_id>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ContractComponentInitialized: ContractComponentInitialized,
        ContractComponentUpdated: ContractComponentUpdated,
        ShardInitialized: ShardInitialized,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentInitialized {
        pub contract_address: ContractAddress,
        pub sharding_contract_address: ContractAddress,
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub storage_changes: Array<CRDTStorageSlot>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardInitialized {
        pub initializer: ContractAddress,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'Component: Not initialized';
        pub const ALREADY_INITIALIZED: felt252 = 'Component: Already initialized';
        pub const STORAGE_LOCKED: felt252 = 'Component: Storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Component: Storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Component: Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Component: Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Component: No contracts';
    }

    #[embeddable_as(ContractComponentImpl)]
    impl ContractImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::IContractComponent<ComponentState<TContractState>> {
        fn initialize_shard(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            contract_slots_changes: Span<StorageSlotWithContract>,
        ) {
            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = current_shard_id + 1;
            self.shard_id.write(caller, new_shard_id);

            println!(
                "Initializing shard for caller: {:?}, new shard_id: {:?}", caller, new_shard_id,
            );

            for i in 0..contract_slots_changes.len() {
                let storage_slot = *contract_slots_changes.at(i);
                let crd_type = storage_slot.crd_type;

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
                        let storage_slot = *contract_slots_changes.at(i);
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
                        let storage_slot = *contract_slots_changes.at(i);
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

            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);

            self.emit(ShardInitialized { initializer: caller });
        }

        fn update_state(
            ref self: ComponentState<TContractState>,
            snos_output: Array<CRDTStorageSlot>,
            shard_id: felt252,
        ) {
            assert(snos_output.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);

            for storage_change in snos_output.span() {
                let contract_address: ContractAddress = (*storage_change.key)
                    .try_into()
                    .expect('Invalid contract address');

                if self.initializer_contract_address.read() == contract_address {
                    let contract_shard_id = self.shard_id.read(contract_address);
                    assert(contract_shard_id != 0, Errors::SHARD_ID_NOT_SET);
                    assert(contract_shard_id == shard_id, Errors::SHARD_ID_MISMATCH);
                    println!("Processing contract: {:?}", contract_address);

                    let mut slots_to_change = ArrayTrait::new();
                    let crd_type = storage_change.crd_type;

                    match crd_type {
                        CRDType::Lock => {
                            for storage_change in snos_output.span() {
                                let (storage_key, storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

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
                            for storage_change in snos_output.span() {
                                let (storage_key, storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

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
                            for storage_change in snos_output.span() {
                                let (storage_key, storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

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
                        self.update_shard(slots_to_change);
                    } else {
                        println!("No slots to update");
                    }

                    match crd_type {
                        CRDType::Lock => {
                            println!("Unlocking slots");
                            for storage_change in snos_output.span() {
                                let (storage_key, _storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

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
                        CRDType::Add => {
                            println!("Unlocking Add slots");
                            for storage_change in snos_output.span() {
                                let (storage_key, _storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

                                // Create a StorageSlot to unlock
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Add,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_add = self.add_slots.read(slot);

                                println!(
                                    "Checking for unlock - slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                );

                                if slot_shard_id == shard_id {
                                    if is_add {
                                        println!("Unlocking Add slot: {:?}", slot);
                                        self.add_slots.write(slot, false);
                                    } else {
                                        println!(
                                            "Add slot shard_id mismatch: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                            slot,
                                            slot_shard_id,
                                            shard_id,
                                        );
                                    }
                                } else {
                                    println!(
                                        "Not unlocking Add slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                        slot,
                                        slot_shard_id,
                                        shard_id,
                                    );
                                }
                            }
                        },
                        CRDType::Set => {
                            for storage_change in snos_output.span() {
                                let (storage_key, _storage_value) = (
                                    *storage_change.key, *storage_change.value,
                                );

                                // Create a StorageSlot to unlock
                                let slot = StorageSlotWithContract {
                                    contract_address: contract_address,
                                    slot: storage_key,
                                    crd_type: CRDType::Set,
                                };

                                let slot_shard_id = self.shard_id_for_slot.read(slot);
                                let is_set = self.set_slots.read(slot);

                                println!(
                                    "Checking for unlock - slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                    slot,
                                    slot_shard_id,
                                    shard_id,
                                );

                                if slot_shard_id == shard_id {
                                    if is_set {
                                        println!("Unlocking Set slot: {:?}", slot);
                                        self.set_slots.write(slot, false);
                                    } else {
                                        println!(
                                            "Set slot shard_id mismatch: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
                                            slot,
                                            slot_shard_id,
                                            shard_id,
                                        );
                                    }
                                } else {
                                    println!(
                                        "Not unlocking Set slot: {:?}, slot_shard_id: {:?}, shard_id: {:?}",
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
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn assert_initialized(self: @ComponentState<TContractState>) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);
        }

        fn update_shard(
            ref self: ComponentState<TContractState>, storage_changes: Array<CRDTStorageSlot>,
        ) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);

            let mut i: usize = 0;
            while i < storage_changes.len() {
                let storage_change = storage_changes.at(i);
                let (key, value) = (*storage_change.key, *storage_change.value);
                let crd_type = storage_change.crd_type;

                let storage_address: StorageAddress = key.try_into().unwrap();

                match crd_type {
                    CRDType::Lock => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Lock operation: key={}, value={}", key, value);
                    },
                    CRDType::Set => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Set operation: key={}, value={}", key, value);
                    },
                    CRDType::Add => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let new_value = current_value + value;
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                        println!(
                            "Add operation: key={}, current_value={}, added_value={}, new_value={}",
                            key,
                            current_value,
                            value,
                            new_value,
                        );
                    },
                }

                i += 1;
            };

            self.emit(ContractComponentUpdated { storage_changes });
        }
    }
}
