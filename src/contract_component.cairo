use starknet::ContractAddress;

pub type SlotKey = felt252;
pub type SlotValue = felt252;

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add: (ContractAddress, SlotValue),
    SetLock: (ContractAddress, SlotValue),
    #[default]
    Set: (ContractAddress, SlotValue),
    Lock: (ContractAddress, SlotValue),
}

pub trait CRDTypeTrait {
    fn assert_is_base_set(self: CRDType);
    fn is_same_variant(self: CRDType, other: CRDType) -> bool;
    fn is_lock(self: CRDType) -> bool;
    fn is_exclusive(self: CRDType) -> bool;
    fn contract_address(self: CRDType) -> ContractAddress;
    fn slot(self: CRDType) -> SlotValue;
}

pub impl CRDTypeImpl of CRDTypeTrait {
    fn assert_is_base_set(self: CRDType) {
        let is_valid = match self {
            CRDType::Set(_) => true,
            _ => false,
        };
        assert(is_valid, 'Component: Already initialized');
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

    fn is_lock(self: CRDType) -> bool {
        match self {
            CRDType::Lock(_) => true,
            _ => false,
        }
    }

    fn is_exclusive(self: CRDType) -> bool {
        match self {
            CRDType::SetLock(_) | CRDType::Lock(_) => true,
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
    fn settle_shard_changes(
        ref self: TContractState,
        shard_id: felt252,
        slot_changes: Array<(felt252, felt252)>,
        dynamic_members: Span<dojo::world::ShardDynamicMemberChanges>,
        dynamic_changes: Span<(felt252, felt252)>,
        dynamic_tracking_proofs: Span<(felt252, felt252)>,
    );
    fn update_shard_state(
        ref self: TContractState, shard_id: felt252, storage_changes: Array<(SlotKey, SlotValue)>,
    );
    fn cancel_shard_state(ref self: TContractState, shard_id: felt252, slots: Span<felt252>);
    fn request_sharding(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        storage_slots: Span<CRDType>,
    );
    fn end_shard(ref self: TContractState);
}

#[starknet::component]
pub mod contract_component {
    use core::num::traits::Zero;
    use core::starknet::SyscallResultTrait;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::utils::safe_increment;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::storage_access::StorageAddress;
    use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::{CRDType, CRDTypeTrait, SlotValue};

    type InitCount = felt252;

    #[storage]
    pub struct Storage {
        slots: Map<SlotValue, (CRDType, InitCount)>,
        sharding_contract_address: ContractAddress,
        /// Add CRDT snapshots for delta computation: delta = shard_value - initial.
        initial_add_values: Map<(felt252, SlotValue), felt252>,
        active_shard_slots: Map<(felt252, SlotValue), bool>,
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
        pub slots_to_change: Array<(felt252, felt252)>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub storage_changes: Array<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'Component: Not initialized';
        pub const STORAGE_UNLOCKED: felt252 = 'Component: Storage is unlocked';
        pub const NO_STORAGE_CHANGES: felt252 = 'Component: No storage changes';
        pub const UNAUTHORIZED_CALLER: felt252 = 'Component: Unauthorized caller';
        pub const ALREADY_INITIALIZED: felt252 = 'Component: Already initialized';
        pub const SLOT_LOCKED: felt252 = 'Component: Slot locked by shard';
        pub const TYPE_CHANGE_WHILE_ACTIVE: felt252 = 'Component: Type change active';
        pub const ADD_DELTA_UNDERFLOW: felt252 = 'Component: Add delta underflow';
        pub const ARITHMETIC_OVERFLOW: felt252 = 'Component: Arithmetic overflow';
        pub const SHARDING_PROXY_MISMATCH: felt252 = 'Component: Proxy mismatch';
        pub const DYNAMIC_SETTLEMENT_UNSUPPORTED: felt252 = 'Component: Dyn settle';
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
            let current_proxy = self.sharding_contract_address.read();
            if !current_proxy.is_zero() {
                assert(current_proxy == sharding_contract_address, Errors::SHARDING_PROXY_MISMATCH);
            }
            self.sharding_contract_address.write(sharding_contract_address);

            for crd_type in contract_slots_changes {
                let crd_type = *crd_type;

                let (prev_crd_type, init_count) = self.slots.read(crd_type.slot());

                if init_count != 0 {
                    assert(!prev_crd_type.is_exclusive(), Errors::SLOT_LOCKED);
                    assert(
                        prev_crd_type.is_same_variant(crd_type), Errors::TYPE_CHANGE_WHILE_ACTIVE,
                    );
                } else {
                    prev_crd_type.assert_is_base_set();
                }
            }

            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);
            let contract_address = get_contract_address();
            let shard_id = sharding_dispatcher.get_shard_id(contract_address);

            for crd_type in contract_slots_changes {
                let crd_type = *crd_type;
                let (_, init_count) = self.slots.read(crd_type.slot());
                let new_init_count = safe_increment(init_count, 'Init count overflow');
                self.slots.write(crd_type.slot(), (crd_type, new_init_count));
                self.active_shard_slots.write((shard_id, crd_type.slot()), true);

                // Multi-shard correctness requires an Add snapshot per shard session.
                if let CRDType::Add(_) = crd_type {
                    let storage_address: StorageAddress = crd_type.slot().try_into().unwrap();
                    let current = storage_read_syscall(0, storage_address).unwrap_syscall();
                    self.initial_add_values.write((shard_id, crd_type.slot()), current);
                }
            }
        }

        fn update_shard_state(
            ref self: ComponentState<TContractState>,
            shard_id: felt252,
            storage_changes: Array<(felt252, felt252)>,
        ) {
            let caller = get_caller_address();
            assert(caller == self.sharding_contract_address.read(), Errors::UNAUTHORIZED_CALLER);

            assert(storage_changes.len() != 0, Errors::NO_STORAGE_CHANGES);

            let contract_address = get_contract_address();

            // Filter to locked slots only. Unregistered slots are silently ignored —
            // the settlement proof may contain slots from other contracts.
            let mut locked_changes: Array<(felt252, felt252)> = ArrayTrait::new();
            for slot_entry in storage_changes.span() {
                let (storage_key, storage_value) = *slot_entry;
                if self.active_shard_slots.read((shard_id, storage_key)) {
                    locked_changes.append((storage_key, storage_value));
                }
            }

            assert(locked_changes.len() != 0, Errors::NO_STORAGE_CHANGES);

            self.update_shard(shard_id, locked_changes.clone(), contract_address);

            for slot_entry in locked_changes.span() {
                let (storage_key, _) = *slot_entry;
                self.unlock_slot(shard_id, storage_key, contract_address);
            }
        }

        fn cancel_shard_state(
            ref self: ComponentState<TContractState>, shard_id: felt252, slots: Span<felt252>,
        ) {
            let caller = get_caller_address();
            assert(caller == self.sharding_contract_address.read(), Errors::UNAUTHORIZED_CALLER);

            let contract_address = get_contract_address();

            for slot_key in slots {
                let slot_key = *slot_key;
                if !self.active_shard_slots.read((shard_id, slot_key)) {
                    continue;
                }
                self.unlock_slot(shard_id, slot_key, contract_address);
            }
        }

        fn settle_shard_changes(
            ref self: ComponentState<TContractState>,
            shard_id: felt252,
            slot_changes: Array<(felt252, felt252)>,
            dynamic_members: Span<dojo::world::ShardDynamicMemberChanges>,
            dynamic_changes: Span<(felt252, felt252)>,
            dynamic_tracking_proofs: Span<(felt252, felt252)>,
        ) {
            assert(dynamic_members.len() == 0, Errors::DYNAMIC_SETTLEMENT_UNSUPPORTED);
            assert(dynamic_changes.len() == 0, Errors::DYNAMIC_SETTLEMENT_UNSUPPORTED);
            assert(dynamic_tracking_proofs.len() == 0, Errors::DYNAMIC_SETTLEMENT_UNSUPPORTED);
            self.update_shard_state(shard_id, slot_changes);
        }

        fn request_sharding(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            storage_slots: Span<CRDType>,
        ) {
            self.initialize_shard(sharding_contract_address, storage_slots);
        }

        fn end_shard(ref self: ComponentState<TContractState>) {
            let sharding_address = self.sharding_contract_address.read();
            assert(!sharding_address.is_zero(), Errors::NOT_INITIALIZED);
            let sharding_dispatcher = IShardingDispatcher { contract_address: sharding_address };
            sharding_dispatcher.end_shard();
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        /// Decrement init_count and reset slot to base Set when fully unlocked.
        /// Lock/SetLock are exclusive (init_count can only be 1), so they always fully reset.
        fn unlock_slot(
            ref self: ComponentState<TContractState>,
            shard_id: felt252,
            slot_key: felt252,
            contract_address: ContractAddress,
        ) {
            let (crd_type, init_count) = self.slots.read(slot_key);
            let base_set = CRDType::Set((contract_address, slot_key));
            self.active_shard_slots.write((shard_id, slot_key), false);

            if crd_type.is_lock() || init_count - 1 == 0 {
                self.slots.write(slot_key, (base_set, 0));
            } else {
                self.slots.write(slot_key, (crd_type, init_count - 1));
            }

            if let CRDType::Add(_) = crd_type {
                self.initial_add_values.write((shard_id, slot_key), 0);
            }
        }

        fn update_shard(
            ref self: ComponentState<TContractState>,
            shard_id: felt252,
            storage_changes: Array<(felt252, felt252)>,
            contract_address: ContractAddress,
        ) {
            for storage_change in storage_changes.span() {
                let (key, value) = *storage_change;
                let storage_address: StorageAddress = key.try_into().unwrap();

                let (crd_type, _) = self.slots.read(key);

                match crd_type {
                    CRDType::SetLock(_) |
                    CRDType::Set(_) => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                    },
                    CRDType::Add(_) => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let initial_value = self.initial_add_values.read((shard_id, key));
                        let current_u256: u256 = current_value.into();
                        let shard_u256: u256 = value.into();
                        let initial_u256: u256 = initial_value.into();
                        assert(shard_u256 >= initial_u256, Errors::ADD_DELTA_UNDERFLOW);
                        let delta = shard_u256 - initial_u256;
                        let sum = current_u256 + delta;
                        let new_value: felt252 = sum.try_into().expect(Errors::ARITHMETIC_OVERFLOW);
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                    },
                    CRDType::Lock(_) => {},
                }
            }
        }
    }
}
