use starknet::{ContractAddress};
use sharding_tests::sharding::StorageSlotWithContract;

#[starknet::interface]
pub trait ITestContract<TContractState> {
    fn initialize_test(ref self: TContractState, sharding_contract_address: ContractAddress);

    fn update(ref self: TContractState, storage_changes: Span<(felt252, felt252)>);

    fn get_storage_slots(ref self: TContractState) -> Array<StorageSlotWithContract>;

    fn increment(ref self: TContractState);

    fn get_counter(ref self: TContractState) -> felt252;

    // #[cfg(feature: 'slot_test')]
    fn read_storage_slot(ref self: TContractState, key: felt252) -> felt252;
}

#[starknet::contract]
pub mod test_contract {
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use openzeppelin::security::reentrancyguard::{ReentrancyGuardComponent};
    use starknet::{get_contract_address, ContractAddress};
    use sharding_tests::state::{state_cpt::InternalImpl};
    use core::starknet::SyscallResultTrait;
    use super::ITestContract;
    use sharding_tests::sharding::StorageSlotWithContract;
    use sharding_tests::sharding::IShardingDispatcher;
    use sharding_tests::sharding::IShardingDispatcherTrait;
    use starknet::syscalls::storage_write_syscall;
    use sharding_tests::contract_component::contract_component;

    // #[cfg(feature: 'slot_test')]
    use starknet::syscalls::storage_read_syscall;

    use starknet::{
        get_caller_address, storage::{StoragePointerReadAccess, StoragePointerWriteAccess},
        event::EventEmitter,
    };

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );
    component!(
        path: contract_component, storage: contract_component, event: ContractComponentEvent,
    );

    #[abi(embed_v0)]
    impl ContractComponentImpl =
        contract_component::ContractComponentImpl<ContractState>;

    impl ContractComponentInternalImpl = contract_component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        counter: felt252,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        #[substorage(v0)]
        contract_component: contract_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TestContractInitialized: TestContractInitialized,
        Increment: Increment,
        GameFinished: GameFinished,
        TestContractUpdated: TestContractUpdated,
        Counter: Counter,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ContractComponentEvent: contract_component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractInitialized {
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractUpdated {
        pub storage_changes: Span<(felt252, felt252)>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Increment {
        pub caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GameFinished {
        pub caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Counter {
        pub counter: felt252,
    }

    pub mod Errors {
        pub const TEST_CONTRACT_ERROR: felt252 = 'TestContract: test error';
        pub const ALREADY_INITIALIZED: felt252 = 'TestContract: alr initialized';
        pub const NOT_INITIALIZED: felt252 = 'TestContract: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'TestContract: storage is locked';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl TestContractImpl of ITestContract<ContractState> {
        fn initialize_test(ref self: ContractState, sharding_contract_address: ContractAddress) {
            // Emit initialization event
            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_shard(self.get_storage_slots().span());
        }

        fn update(ref self: ContractState, storage_changes: Span<(felt252, felt252)>) {
            let mut i: usize = 0;
            while i < storage_changes.len() {
                let (key, value) = *storage_changes.at(i);

                storage_write_syscall(0, key.try_into().unwrap(), value).unwrap_syscall();

                i += 1;
            };

            self.emit(TestContractUpdated { storage_changes });
        }

        fn increment(ref self: ContractState) {
            self.counter.write(self.counter.read() + 1);

            let caller = get_caller_address();
            self.emit(Increment { caller });

            if self.counter.read() == 3 {
                self.emit(GameFinished { caller });
            }
        }

        fn get_counter(ref self: ContractState) -> felt252 {
            let counter = self.counter.read();
            println!("counter: {:?}", counter);
            self.emit(Counter { counter });
            counter
        }

        fn get_storage_slots(ref self: ContractState) -> Array<StorageSlotWithContract> {
            array![
                StorageSlotWithContract {
                    contract_address: get_contract_address().into(), slot: selector!("counter"),
                },
            ]
        }

        // #[cfg(feature: 'slot_test')]
        fn read_storage_slot(ref self: ContractState, key: felt252) -> felt252 {
            storage_read_syscall(0, key.try_into().unwrap()).unwrap_syscall()
        }
    }
}
