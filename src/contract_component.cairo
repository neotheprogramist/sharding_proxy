use starknet::{ContractAddress};

#[starknet::interface]
pub trait IContractComponent<TContractState> {
    fn initialize_shard(ref self: TContractState, sharding_contract_address: ContractAddress);
    fn update_shard(ref self: TContractState, storage_changes: Span<(felt252, felt252)>);
}

#[starknet::component]
pub mod contract_component {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::sharding::StorageSlotWithContract;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

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
        pub storage_changes: Span<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'ContractComponent: not init';
    }

    #[embeddable_as(ContractComponentImpl)]
    impl ContractImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::IContractComponent<ComponentState<TContractState>> {
        fn initialize_shard(
            ref self: ComponentState<TContractState>, sharding_contract_address: ContractAddress,
        ) {
            self.sharding_contract_address.write(sharding_contract_address);

            let current_contract_address = get_contract_address();
            self.contract_address.write(current_contract_address);

            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };

            sharding_dispatcher.initialize_shard(self.get_storage_slots().span());

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
            ref self: ComponentState<TContractState>, storage_changes: Span<(felt252, felt252)>,
        ) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);

            let mut i: usize = 0;
            while i < storage_changes.len() {
                let (key, value) = *storage_changes.at(i);

                let storage_address = key.try_into().unwrap();

                storage_write_syscall(0, storage_address, value).unwrap_syscall();

                i += 1;
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

        fn get_storage_slots(
            self: @ComponentState<TContractState>,
        ) -> Array<StorageSlotWithContract> {
            array![
                StorageSlotWithContract {
                    contract_address: self.contract_address.read(), slot: selector!("counter"),
                },
            ]
        }
    }
}
