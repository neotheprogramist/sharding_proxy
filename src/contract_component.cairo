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
    fn update_shard(ref self: TContractState, storage_changes: Array<CRDTStorageSlot>);
}

#[starknet::component]
pub mod contract_component {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use starknet::syscalls::storage_read_syscall;
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::sharding::StorageSlotWithContract;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::sharding::CRDType;
    use sharding_tests::sharding::CRDTStorageSlot;
    use starknet::storage_access::StorageAddress;

    #[storage]
    pub struct Storage {
        contract_address: ContractAddress,
        sharding_contract_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ContractComponentInitialized: ContractComponentInitialized,
        ContractComponentUpdated: ContractComponentUpdated,
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

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'ContractComponent: not init';
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
            self.sharding_contract_address.write(sharding_contract_address);

            let current_contract_address = get_contract_address();
            self.contract_address.write(current_contract_address);

            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };

            sharding_dispatcher.initialize_shard(contract_slots_changes);

            let caller = get_caller_address();

            self
                .emit(
                    ContractComponentInitialized {
                        contract_address: current_contract_address,
                        sharding_contract_address,
                        initializer: caller,
                    },
                );
        }

        fn update_shard(
            ref self: ComponentState<TContractState>, storage_changes: Array<CRDTStorageSlot>,
        ) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);

            for storage_change in storage_changes.span() {
                let (key, value, crd_type) = (
                    *storage_change.key, *storage_change.value, *storage_change.crd_type,
                );

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
            };

            self.emit(ContractComponentUpdated { storage_changes });
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
    }
}
