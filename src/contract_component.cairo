use starknet::{ContractAddress};
use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};

#[starknet::interface]
pub trait ITestContractComponent<TContractState> {
    fn initialize_contract(ref self: TContractState, contract_address: ContractAddress);
    fn update_contract(ref self: TContractState, storage_changes: Span<(felt252, felt252)>);
    fn get_contract_address(self: @TContractState) -> ContractAddress;
}

#[starknet::component]
pub mod contract_component {
    use starknet::{ContractAddress, get_caller_address};
    use sharding_tests::test_contract::{ITestContractDispatcher, ITestContractDispatcherTrait};

    #[storage]
    pub struct Storage {
        contract_address: ContractAddress,
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
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub contract_address: ContractAddress,
        pub storage_changes: Span<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'TestContractComponent: not init';
    }

    #[embeddable_as(TestContractComponentImpl)]
    impl TestContractImpl<
        TContractState, +HasComponent<TContractState>
    > of super::ITestContractComponent<ComponentState<TContractState>> {
        fn initialize_contract(
            ref self: ComponentState<TContractState>, 
            contract_address: ContractAddress
        ) {
            self.test_contract_address.write(contract_address);
            
            let caller = get_caller_address();
            self.emit(ContractComponentInitialized { 
                contract_address, 
                initializer: caller 
            });
        }

        fn update_contract(
            ref self: ComponentState<TContractState>,
            storage_changes: Span<(felt252, felt252)>
        ) {
            let contract_address = self.contract_address.read();
            assert(!contract_address.is_zero(), Errors::NOT_INITIALIZED);
            
            let test_contract = ITestContractDispatcher { 
                contract_address: contract_address 
            };
            
            test_contract.update(storage_changes);
            
            self.emit(ContractComponentUpdated { 
                contract_address, 
                storage_changes 
            });
        }

        fn get_contract_address(self: @ComponentState<TContractState>) -> ContractAddress {
            self.contract_address.read()
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        fn assert_initialized(self: @ComponentState<TContractState>) {
            let contract_address = self.contract_address.read();
            assert(!contract_address.is_zero(), Errors::NOT_INITIALIZED);
        }
    }
}