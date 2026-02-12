use starknet::ContractAddress;

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add: (ContractAddress, slot_value),
    SetLock: (ContractAddress, slot_value),
    #[default]
    Set: (ContractAddress, slot_value),
    Lock: (ContractAddress, slot_value),
}

type slot_key = felt252;
type slot_value = felt252;

pub trait CRDTypeTrait {
    fn verify_crd_type(self: CRDType, crd_type: CRDType);
    fn is_same_variant(self: CRDType, other: CRDType) -> bool;
    fn contract_address(self: CRDType) -> ContractAddress;
    fn slot(self: CRDType) -> slot_value;
}

impl CRDTypeImpl of CRDTypeTrait {
    fn verify_crd_type(self: CRDType, crd_type: CRDType) {
        // When init_count == 0, current type is always Set (base state after unlock).
        // Set can transition to any type — this is the only valid starting point.
        let is_valid = match self {
            CRDType::Set => true,
            _ => false,
        };
        assert(is_valid, 'Sharding already initialized');
    }

    fn is_same_variant(self: CRDType, other: CRDType) -> bool {
        match (self, other) {
            (CRDType::Add(_), CRDType::Add(_)) => true,
            (CRDType::SetLock(_), CRDType::SetLock(_)) => true,
            (CRDType::Set(_), CRDType::Set(_)) => true,
            (CRDType::Lock(_), CRDType::Lock(_)) => true,
            _ => false,
        }
    }
    fn contract_address(self: CRDType) -> ContractAddress {
        match self {
            CRDType::Add((address, _)) | CRDType::SetLock((address, _)) |
            CRDType::Set((address, _)) | CRDType::Lock((address, _)) => address,
        }
    }

    fn slot(self: CRDType) -> felt252 {
        match self {
            CRDType::Add((_, slot)) | CRDType::SetLock((_, slot)) | CRDType::Set((_, slot)) |
            CRDType::Lock((_, slot)) => slot,
        }
    }
}

#[starknet::interface]
pub trait IContractComponent<TContractState> {
    fn initialize_shard(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        contract_slots_changes: Span<CRDType>,
    );
    fn update_shard_state(
        ref self: TContractState, storage_changes: Array<(slot_key, slot_value)>, shard_id: felt252,
    );
    fn cancel_shard_state(ref self: TContractState, slots: Span<felt252>, shard_id: felt252);
    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;

    /// Forward a sharding request to the sharding proxy.
    /// Call this from the game contract so the proxy emits `ShardingRequested`.
    fn request_sharding(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        storage_slots: Span<CRDType>,
    );

    /// Signal end of shard to the sharding proxy.
    /// The proxy emits `ShardFinished` which the operator watches.
    fn end_shard(ref self: TContractState);
}

#[starknet::component]
pub mod contract_component {
    use core::num::traits::Zero;
    use core::starknet::SyscallResultTrait;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::sharding::{
        IShardingDispatcher, IShardingDispatcherTrait, StorageSlotWithContract,
    };
    use sharding_tests::utils::safe_increment;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::storage_access::StorageAddress;
    use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::{CRDType, CRDTypeTrait, slot_value};

    type shard_id = felt252;
    type init_count = felt252;

    #[storage]
    pub struct Storage {
        slots: Map<slot_value, (CRDType, init_count)>,
        sharding_contract_address: ContractAddress,
        shard_id: Map<ContractAddress, shard_id>,
        shard_id_for_slot: Map<StorageSlotWithContract, shard_id>,
        /// Snapshot of Add slot values at initialization time.
        /// Used to compute delta = (shard_value - initial) during settlement.
        initial_add_values: Map<slot_value, felt252>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ContractSlotUpdated: ContractSlotUpdated,
        ContractComponentUpdated: ContractComponentUpdated,
    }

    #[derive(Drop, starknet::Event, Clone)]
    pub struct ContractSlotUpdated {
        pub contract_address: ContractAddress,
        pub shard_id: felt252,
        pub slots_to_change: Array<(felt252, felt252)>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub storage_changes: Array<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'Component: Not initialized';
        pub const STORAGE_UNLOCKED: felt252 = 'Component: Storage is unlocked';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Component: No contracts';
        pub const NO_SLOTS_MATCHED: felt252 = 'Component: No slots matched';
    }

    #[embeddable_as(ContractComponentImpl)]
    impl ContractImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::IContractComponent<ComponentState<TContractState>> {
        fn initialize_shard(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            contract_slots_changes: Span<CRDType>,
        ) {
            let caller = get_caller_address();
            self.sharding_contract_address.write(sharding_contract_address);
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = safe_increment(current_shard_id, 'Shard ID overflow');
            self.shard_id.write(caller, new_shard_id);

            for crd_type in contract_slots_changes {
                let crd_type = *crd_type;

                let (prev_crd_type, init_count) = self.slots.read(crd_type.slot());

                if init_count != 0 {
                    // Slot is active — SetLock and Lock are exclusive (no stacking)
                    let is_locking = match prev_crd_type {
                        CRDType::SetLock(_) | CRDType::Lock(_) => true,
                        _ => false,
                    };
                    assert(!is_locking, 'Slot locked by active shard');
                    // Set and Add allow same-type stacking only
                    assert(
                        prev_crd_type.is_same_variant(crd_type), 'Type change while slot active',
                    );
                } else {
                    // Slot is free (init_count == 0) — check type transition from Set
                    prev_crd_type.verify_crd_type(crd_type);
                }

                let slot = StorageSlotWithContract {
                    contract_address: crd_type.contract_address(), slot: crd_type.slot(),
                };

                let new_init_count = safe_increment(init_count, 'Init count overflow');
                self.slots.write(crd_type.slot(), (crd_type, new_init_count));
                self.shard_id_for_slot.write(slot, new_shard_id);

                // For Add CRDTs, snapshot the current value so we can compute
                // delta = (shard_value - initial) during settlement.
                if let CRDType::Add(_) = crd_type {
                    let storage_address: StorageAddress = crd_type.slot().try_into().unwrap();
                    let current = storage_read_syscall(0, storage_address).unwrap_syscall();
                    self.initial_add_values.write(crd_type.slot(), current);
                }
            }

            // Emit initialization event
            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);
        }

        fn update_shard_state(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<(felt252, felt252)>,
            shard_id: felt252,
        ) {
            let caller = get_caller_address();
            assert(caller == self.sharding_contract_address.read(), 'Unauthorized caller');

            assert(storage_changes.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);
            let mut slots_to_change = ArrayTrait::new();

            let contract_address = get_contract_address();

            // Filter slots belonging to this shard_id
            for storage_change in storage_changes.span() {
                let (storage_key, storage_value) = *storage_change;
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: storage_key,
                };

                if self.shard_id_for_slot.read(slot) == shard_id {
                    slots_to_change.append((storage_key, storage_value));
                }
            }

            assert(slots_to_change.len() != 0, Errors::NO_SLOTS_MATCHED);

            self.update_shard(slots_to_change.clone(), contract_address);

            // Unlock slots: decrement init_count, reset Lock types to Set
            for slot_to_unlock in slots_to_change.span() {
                let (storage_key, _) = *slot_to_unlock;
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: storage_key,
                };

                let (crd_type, init_count) = self.slots.read(slot.slot);
                assert(init_count != 0, Errors::STORAGE_UNLOCKED);

                // Lock slots reserve the storage key during shard execution
                // but always discard the shard value — reset fully on unlock.
                let is_lock = match crd_type {
                    CRDType::Lock => true,
                    _ => false,
                };

                if is_lock {
                    self.slots.write(slot.slot, (CRDType::Set((contract_address, slot.slot)), 0));
                } else {
                    let new_init_count = init_count - 1;
                    if new_init_count == 0 {
                        self
                            .slots
                            .write(slot.slot, (CRDType::Set((contract_address, slot.slot)), 0));
                        if let CRDType::Add(_) = crd_type {
                            self.initial_add_values.write(slot.slot, 0);
                        }
                    } else {
                        self.slots.write(slot.slot, (crd_type, new_init_count));
                    }
                }
            }

            self.emit(ContractSlotUpdated { contract_address, shard_id, slots_to_change });
        }

        fn cancel_shard_state(
            ref self: ComponentState<TContractState>, slots: Span<felt252>, shard_id: felt252,
        ) {
            let caller = get_caller_address();
            assert(caller == self.sharding_contract_address.read(), 'Unauthorized caller');

            let contract_address = get_contract_address();

            for slot_key in slots {
                let slot_key = *slot_key;
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: slot_key,
                };

                // Only unlock slots belonging to this shard_id
                if self.shard_id_for_slot.read(slot) != shard_id {
                    continue;
                }

                let (crd_type, init_count) = self.slots.read(slot_key);
                if init_count == 0 {
                    continue;
                }

                let new_init_count = init_count - 1;
                if new_init_count == 0 {
                    // Fully unlocked — reset to base Set type
                    self.slots.write(slot_key, (CRDType::Set((contract_address, slot_key)), 0));
                    if let CRDType::Add(_) = crd_type {
                        self.initial_add_values.write(slot_key, 0);
                    }
                } else {
                    // Other shards still active on this slot — just decrement
                    self.slots.write(slot_key, (crd_type, new_init_count));
                }
            }
        }

        fn get_shard_id(
            ref self: ComponentState<TContractState>, contract_address: ContractAddress,
        ) -> felt252 {
            self.shard_id.read(contract_address)
        }

        fn request_sharding(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            storage_slots: Span<CRDType>,
        ) {
            // Initialize shard: locks slots, snapshots Add values, and emits ShardingRequested
            // via the sharding proxy's initialize_sharding
            self.initialize_shard(sharding_contract_address, storage_slots);
        }

        fn end_shard(ref self: ComponentState<TContractState>) {
            let sharding_address = self.sharding_contract_address.read();
            if sharding_address.is_zero() {
                return;
            }
            let sharding_dispatcher = IShardingDispatcher { contract_address: sharding_address };
            sharding_dispatcher.end_shard();
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn update_shard(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<(felt252, felt252)>,
            contract_address: ContractAddress,
        ) {
            for storage_change in storage_changes.span() {
                let (key, value) = *storage_change;
                let storage_address: StorageAddress = key.try_into().unwrap();

                let (crd_type, _) = self.slots.read(key);

                match crd_type {
                    CRDType::SetLock |
                    CRDType::Set => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                    },
                    CRDType::Add => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let initial_value = self.initial_add_values.read(key);
                        // value is the absolute shard state; compute delta vs fork snapshot
                        let current_u256: u256 = current_value.into();
                        let shard_u256: u256 = value.into();
                        let initial_u256: u256 = initial_value.into();
                        assert(shard_u256 >= initial_u256, 'Add delta underflow');
                        let delta = shard_u256 - initial_u256;
                        let sum = current_u256 + delta;
                        let new_value: felt252 = sum.try_into().expect('Arithmetic overflow');
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                    },
                    // Lock reserves the slot during shard execution but discards
                    // the shard's value; the slot is unlocked in update_shard_state.
                    CRDType::Lock => {},
                }
            }
            self.emit(ContractComponentUpdated { storage_changes });
        }
    }
}
