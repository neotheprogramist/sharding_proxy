use starknet::{ContractAddress};

#[derive(Drop, Serde, starknet::Store, Hash, Copy)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub slot: felt252,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_shard(ref self: TContractState, storage_slots: Span<StorageSlotWithContract>);

    fn update_state(ref self: TContractState, snos_output: Span<felt252>);
}

#[starknet::interface]
pub trait IState<TContractState> {
    fn update(ref self: TContractState, storage_changes: Span<(felt252, felt252)>);
}

#[starknet::contract]
pub mod sharding {
    use core::iter::IntoIterator;
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use openzeppelin::security::reentrancyguard::{ReentrancyGuardComponent};

    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use sharding_tests::snos_output::deserialize_os_output;
    use sharding_tests::state::{state_cpt, state_cpt::InternalTrait, state_cpt::InternalImpl};
    use super::ISharding;
    use super::StorageSlotWithContract;

    use sharding_tests::contract_component::IContractComponentDispatcher;
    use sharding_tests::contract_component::IContractComponentDispatcherTrait;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );
    component!(path: state_cpt, storage: state, event: StateEvent);

    #[abi(embed_v0)]
    impl StateImpl = state_cpt::StateImpl<ContractState>;

    #[storage]
    struct Storage {
        initialized_storage: Map<StorageSlotWithContract, bool>,
        owner: ContractAddress,
        shard_root: felt252,
        shard_hash: felt252,
        #[substorage(v0)]
        state: state_cpt::Storage,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ShardingStateUpdate: ShardingStateUpdate,
        ContractInitialized: ContractInitialized,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        StateEvent: state_cpt::Event,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardingStateUpdate {
        pub shard_root: felt252,
        pub shard_number: felt252,
        pub shard_hash: felt252,
        pub shard_data: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractInitialized {
        pub initializer: ContractAddress,
    }

    pub mod Errors {
        pub const SHARDING_ERROR: felt252 = 'Sharding: here sharding error';
        pub const ALREADY_INITIALIZED: felt252 = 'Sharding: already initialized';
        pub const NOT_INITIALIZED: felt252 = 'Sharding: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'Sharding: storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Sharding: storage is unlocked';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        state_root: felt252,
        block_number: felt252,
        block_hash: felt252,
    ) {
        self.ownable.initializer(owner);
        self.state.initialize(state_root, block_number, block_hash);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_shard(ref self: ContractState, storage_slots: Span<StorageSlotWithContract>) {
            // assert(self.initialized_storage.len() == 0, Errors::ALREADY_INITIALIZED); //todo

            for i in 0..storage_slots.len() {
                let storage_slot = *storage_slots.at(i);
                // Lock this storage key
                self.initialized_storage.write(storage_slot, true);
            };

            // Emit initialization event
            let caller = get_caller_address();
            self.emit(ContractInitialized { initializer: caller });
        }

        fn update_state(ref self: ContractState, snos_output: Span<felt252>) {
            let mut _snos_output_iter = snos_output.into_iter();
            let program_output_struct = deserialize_os_output(ref _snos_output_iter);

            for contract in program_output_struct.state_diff.contracts.span() {
                let contract_address: ContractAddress = (*contract.addr)
                    .try_into()
                    .expect('Invalid contract address');

                let mut slots_to_change = ArrayTrait::new();

                for storage_change in contract.storage_changes.span() {
                    let (storage_key, storage_value) = *storage_change;

                    // Create a StorageSlot to check if it's locked
                    let slot = StorageSlotWithContract {
                        contract_address: contract_address, slot: storage_key,
                    };
                    if self.initialized_storage.read(slot) {
                        slots_to_change.append((storage_key, storage_value));
                    }
                };

                // Call update on the specific contract
                let contract_dispatcher = IContractComponentDispatcher {
                    contract_address: contract_address,
                };

                contract_dispatcher.update_shard(slots_to_change.span());

                // After updating, unlock the slots for this contract
                for storage_change in contract.storage_changes.span() {
                    let (storage_key, _storage_value) = *storage_change;

                    // Create a StorageSlot to unlock
                    let slot = StorageSlotWithContract {
                        contract_address: contract_address, slot: storage_key,
                    };

                    self.initialized_storage.write(slot, false);
                }
            }
        }
    }
}
