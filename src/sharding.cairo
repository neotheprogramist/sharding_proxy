use starknet::{ContractAddress};

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize(ref self: TContractState);

    fn update_state(
        ref self: TContractState,         
        snos_output: Span<felt252>,
        base_contract_address: ContractAddress,
    );
}

#[starknet::contract]
pub mod sharding {
    use core::iter::IntoIterator;
    use core::poseidon::{PoseidonImpl, poseidon_hash_span};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use openzeppelin::security::reentrancyguard::{
        ReentrancyGuardComponent,
        ReentrancyGuardComponent::InternalTrait as InternalReentrancyGuardImpl,
    };
    use openzeppelin::upgrades::{
        UpgradeableComponent as upgradeable_cpt,
        UpgradeableComponent::InternalTrait as UpgradeableInternal, interface::IUpgradeable,
    };
    use starknet::{
        get_caller_address, get_contract_address, ContractAddress,
        storage::{
            StoragePointerReadAccess, StoragePointerWriteAccess, StorageMapReadAccess,
            StorageMapWriteAccess, Map
        }
    };
    use starknet::{ClassHash};
    use sharding_tests::snos_output::deserialize_os_output;
    use sharding_tests::state::{IState, state_cpt, state_cpt::InternalTrait, state_cpt::InternalImpl};
    use core::starknet::SyscallResultTrait;
    use super::ISharding;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);
    component!(path: state_cpt, storage: state, event: StateEvent);
    
    #[abi(embed_v0)]
    impl StateImpl = state_cpt::StateImpl<ContractState>;

    #[storage]
    struct Storage {
        initialized_storage: Map<felt252, bool>,
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
        fn initialize(ref self: ContractState) {

            // Lock critical storage slots
            let owner_key = self.owner.__base_address__;
            let shard_root_key = self.shard_root.__base_address__;
            let shard_hash_key = self.shard_hash.__base_address__;

            // Check if already initialized
            assert(!self.initialized_storage.read(owner_key), Errors::ALREADY_INITIALIZED);
            assert(!self.initialized_storage.read(shard_root_key), Errors::ALREADY_INITIALIZED);
            assert(!self.initialized_storage.read(shard_hash_key), Errors::ALREADY_INITIALIZED);
            
            self.initialized_storage.write(owner_key, true);
            self.initialized_storage.write(shard_root_key, true);
            self.initialized_storage.write(shard_hash_key, true);
            
            // Emit initialization event
            let caller = get_caller_address();
            
            self.emit(ContractInitialized { initializer: caller });
        }
        
        fn update_state(ref self: ContractState,      
            snos_output: Span<felt252>,
            base_contract_address: ContractAddress,
        ) {
            let mut _snos_output_iter = snos_output.into_iter();
            let program_output_struct = deserialize_os_output(ref _snos_output_iter);
            self.state.update(program_output_struct);
        }
    }
}
