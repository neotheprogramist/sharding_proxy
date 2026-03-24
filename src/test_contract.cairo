//! Example game contract demonstrating sharding integration.
//!
//! This is a minimal reference implementation. To integrate your own game:
//! 1. Embed `contract_component` in your contract's storage
//! 2. Emit an event when a shard round finishes (like `GameFinished` here)
//! 3. Call `initialize_shard()` with your storage slots + CRDT types
//!
//! See the main README for a full integration guide.

use sharding_tests::contract_component::CRDType;

#[starknet::interface]
pub trait ITestContract<TContractState> {
    fn increment(ref self: TContractState);

    fn get_counter(ref self: TContractState) -> felt252;

    fn set_counter(ref self: TContractState, value: felt252);

    fn read_storage_slot(ref self: TContractState, key: felt252) -> felt252;

    fn write_storage_slot(ref self: TContractState, key: felt252, value: felt252);

    fn get_storage_slots(ref self: TContractState, crd_type: CRDType) -> CRDType;

    /// Returns a CRDType for a specific slot identified by its selector.
    /// Use with selector!("counter").
    fn get_storage_slot_for(
        ref self: TContractState, slot_name: felt252, crd_type: CRDType,
    ) -> CRDType;
}

#[starknet::contract]
pub mod test_contract {
    use core::poseidon::PoseidonImpl;
    use core::starknet::SyscallResultTrait;
    use openzeppelin_access::ownable::OwnableComponent as ownable_cpt;
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternal;
    use sharding_tests::contract_component::{CRDType, contract_component};
    use starknet::event::EventEmitter;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::storage_read_syscall;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use super::ITestContract;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
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
        contract_component: contract_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        Increment: Increment,
        GameFinished: GameFinished,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ContractComponentEvent: contract_component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Increment {
        pub caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GameFinished {
        pub caller: ContractAddress,
    }

    pub mod Errors {
        pub const TEST_CONTRACT_ERROR: felt252 = 'TestContract: test error';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl TestContractImpl of ITestContract<ContractState> {
        fn increment(ref self: ContractState) {
            self.counter.write(self.counter.read() + 1);

            let caller = get_caller_address();
            self.emit(Increment { caller });

            // Emit GameFinished every 3 increments (3, 6, 9, ...)
            // Convert to u256 for modulo operation (felt252 doesn't support %)
            let counter_u256: u256 = self.counter.read().into();
            if counter_u256 > 0 && counter_u256 % 3 == 0 {
                self.contract_component.end_current_shard();
                self.emit(GameFinished { caller });
            }
        }

        fn get_counter(ref self: ContractState) -> felt252 {
            let counter = self.counter.read();
            counter
        }

        fn set_counter(ref self: ContractState, value: felt252) {
            self.counter.write(value);
        }

        fn read_storage_slot(ref self: ContractState, key: felt252) -> felt252 {
            storage_read_syscall(0, key.try_into().unwrap()).unwrap_syscall()
        }

        fn write_storage_slot(ref self: ContractState, key: felt252, value: felt252) {
            starknet::syscalls::storage_write_syscall(0, key.try_into().unwrap(), value)
                .unwrap_syscall();
        }

        fn get_storage_slots(ref self: ContractState, crd_type: CRDType) -> CRDType {
            match crd_type {
                CRDType::Add => CRDType::Add((get_contract_address(), selector!("counter"))),
                CRDType::SetLock => CRDType::SetLock(
                    (get_contract_address(), selector!("counter")),
                ),
                CRDType::Set => CRDType::Set((get_contract_address(), selector!("counter"))),
                CRDType::Lock => CRDType::Lock((get_contract_address(), selector!("counter"))),
            }
        }

        fn get_storage_slot_for(
            ref self: ContractState, slot_name: felt252, crd_type: CRDType,
        ) -> CRDType {
            let addr = get_contract_address();
            match crd_type {
                CRDType::Add => CRDType::Add((addr, slot_name)),
                CRDType::SetLock => CRDType::SetLock((addr, slot_name)),
                CRDType::Set => CRDType::Set((addr, slot_name)),
                CRDType::Lock => CRDType::Lock((addr, slot_name)),
            }
        }
    }
}
