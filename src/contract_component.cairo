use starknet::{ContractAddress};

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add: (ContractAddress, slot_key),
    SetLock: (ContractAddress, slot_key),
    #[default]
    Set: (ContractAddress, slot_key),
    Lock: (ContractAddress, slot_key),
}

type slot_key = felt252;
type slot_value = felt252;

pub trait CRDTypeTrait {
    fn verify_crd_type(self: CRDType, crd_type: CRDType);
    fn contract_address(self: CRDType) -> ContractAddress;
    fn slot_key(self: CRDType) -> slot_key;
}

impl CRDTypeImpl of CRDTypeTrait {
    fn verify_crd_type(self: CRDType, crd_type: CRDType) {
        let (is_valid, error_msg) = match (self, crd_type) {
            (CRDType::Add, CRDType::Add) => (true, 'A: Sharding already initialized'),
            (CRDType::Set, CRDType::Add) => (true, 'A: Sharding already initialized'),
            (CRDType::Set, CRDType::SetLock) => (true, 'SL:Sharding already initialized'),
            (CRDType::Set, CRDType::Set) => (true, 'S: Sharding already initialized'),
            (CRDType::Set, CRDType::Lock) => (true, 'L: Sharding already initialized'),
            (_, CRDType::Add) => (false, 'A: Sharding already initialized'),
            (_, CRDType::SetLock) => (false, 'SL:Sharding already initialized'),
            (_, CRDType::Set) => (false, 'S: Sharding already initialized'),
            (_, CRDType::Lock) => (false, 'L: Sharding already initialized'),
        };
        assert(is_valid, error_msg);
    }
    fn contract_address(self: CRDType) -> ContractAddress {
        match self {
            CRDType::Add((address, _)) | CRDType::SetLock((address, _)) |
            CRDType::Set((address, _)) | CRDType::Lock((address, _)) => address,
        }
    }

    fn slot_key(self: CRDType) -> slot_key {
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
        ref self: TContractState,
        storage_changes: Array<(slot_key, slot_value)>,
        merkle_root: felt252,
    );
}

#[starknet::component]
pub mod contract_component {
    use starknet::{
        get_caller_address, ContractAddress, get_contract_address,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use starknet::syscalls::storage_read_syscall;
    use sharding_tests::proxy::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::proxy::StorageSlotWithContract;
    use core::starknet::storage::StoragePointerWriteAccess;
    use starknet::storage_access::StorageAddress;
    use super::CRDType;
    use super::CRDTypeTrait;
    use super::slot_key;
    use core::array::ArrayTrait;
    use core::poseidon::{poseidon_hash_span, PoseidonImpl};
    use core::pedersen::PedersenImpl;
    use cairo_lib::hashing::poseidon::PoseidonHasher;
    use cairo_lib::data_structures::mmr::mmr::MMRTrait;

    type init_count = felt252;
    type index = felt252;
    type merkle_root = felt252;

    #[storage]
    pub struct Storage {
        slots: Map<slot_key, (CRDType, init_count)>,
        sharding_contract_address: ContractAddress,
        merkle_roots: Map<merkle_root, bool>,
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
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Component: No contracts';
        pub const WRONG_MERKLE_ROOT: felt252 = 'Component: Wrong merkle root';
        pub const SLOTS_NOT_ORDERED: felt252 = 'Component:Slots must be ASC ord';
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

            println!("Initializing shard for caller: {:?}", caller);

            let mut merkle_leaves = ArrayTrait::new();

            for crd_type in contract_slots_changes {
                let crd_type = *crd_type;

                let (prev_crd_type, init_count) = self.slots.read(crd_type.slot_key());

                prev_crd_type.verify_crd_type(crd_type);

                self.slots.write(crd_type.slot_key(), (crd_type, init_count + 1));

                // Calculate hash of slot and CRDType variant
                let mut hash_input = ArrayTrait::new();
                hash_input.append(crd_type.slot_key());
                hash_input
                    .append(
                        match crd_type {
                            CRDType::Add => 1,
                            CRDType::SetLock => 2, // add to_felt method
                            CRDType::Set => 3,
                            CRDType::Lock => 4,
                        },
                    );
                let hash = poseidon_hash_span(hash_input.span());
                merkle_leaves.append(hash);

                println!("Processed slot: {:?}", crd_type);
            };

            // Calculate Merkle root
            let merkle_root = self.calculate_merkle_root(merkle_leaves.clone());
            println!("Calculated Merkle root: {:?}", merkle_root);

            // Store merkle root
            self.merkle_roots.write(merkle_root, true);

            // Emit initialization event
            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);
        }

        fn update_shard_state(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<(felt252, felt252)>,
            merkle_root: felt252,
        ) {
            println!("Updating shard state for merkle root: {:?}", merkle_root);

            assert(self.merkle_roots.read(merkle_root), Errors::WRONG_MERKLE_ROOT);
            assert(storage_changes.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);
            let mut slots_to_change = ArrayTrait::new();

            let contract_address = get_contract_address();

            // Then process updates for other types
            for storage_change in storage_changes.span() {
                let (storage_key, storage_value) = *storage_change;

                // Create a StorageSlot to check if it's locked
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, key: storage_key,
                };

                let (crd_type, _) = self.slots.read(slot.key);

                println!("Checking slot: {:?}, crd_type: {:?}", slot, crd_type);

                slots_to_change.append((storage_key, storage_value));
            };

            if slots_to_change.len() == 0 {
                println!("WARNING: No slots to update for contract: {:?}", contract_address);
            };

            self.update_shard(slots_to_change.clone(), contract_address);
            // self.merkle_roots.write(merkle_root, false);

            for slot_to_unlock in slots_to_change.span() {
                let (storage_key, _) = *slot_to_unlock;
                // Create a StorageSlot to unlock
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, key: storage_key,
                };

                println!("Unlocking slot: {:?}", slot);
                let (crd_type, init_count) = self.slots.read(slot.key);
                assert(init_count != 0, Errors::STORAGE_UNLOCKED);

                let new_init_count = init_count - 1;

                if new_init_count == 0 {
                    self.slots.write(slot.key, (CRDType::Set((contract_address, slot.key)), 0));
                    self.merkle_roots.write(merkle_root, false);
                } else {
                    self.slots.write(slot.key, (crd_type, new_init_count));
                }
            };

            self.emit(ContractSlotUpdated { contract_address, slots_to_change });
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
                    CRDType::SetLock => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Lock: Updating key={}, with value={}", key, value);
                    },
                    CRDType::Set => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Set: Updating key={}, with value={}", key, value);
                    },
                    CRDType::Add => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let new_value = current_value + value;
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                        println!(
                            "Add: Updating key={}, current_value={}, added_value={}, new_value={}",
                            key,
                            current_value,
                            value,
                            new_value,
                        );
                    },
                    CRDType::Lock => {
                        //Do nothing
                        println!("Lock: Unlocking");
                    },
                }
            };
            self.emit(ContractComponentUpdated { storage_changes });
        }

        fn calculate_merkle_root(
            ref self: ComponentState<TContractState>, mut leaves: Array<felt252>,
        ) -> felt252 {
            let mut mmr = MMRTrait::new(PoseidonHasher::hash_double(0, 0), 0);
            let mut peaks = ArrayTrait::new().span();

            for leaf in leaves.span() {
                match mmr.append(*leaf, peaks) {
                    Result::Ok((_, new_peaks)) => { peaks = new_peaks; },
                    Result::Err(err) => { panic!("Error: {:?}", err); },
                }
            };
            mmr.root
        }
    }
}
