use starknet::{ContractAddress};

#[derive(Drop, Serde, starknet::Store, Hash)]
pub struct StorageSlot {
    contract_address: ContractAddress,
    slot: felt252,
}

#[starknet::interface]
pub trait IGameContract<TContractState> {
    fn initialize_game(
        ref self: TContractState,
    ); //here we should lock the storage slots for the game contract

    fn update(ref self: TContractState, storage_changes: Span<(felt252, felt252)>);

    fn increment(ref self: TContractState);
}

#[starknet::contract]
pub mod game_contract {
    use core::poseidon::PoseidonImpl;
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use openzeppelin::security::reentrancyguard::{ReentrancyGuardComponent};
    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StoragePointerReadAccess, StoragePointerWriteAccess},
    };
    use sharding_tests::state::{state_cpt, state_cpt::InternalImpl};
    use super::IGameContract;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);

    #[storage]
    struct Storage {
        counter: felt252,
        owner: ContractAddress,
        // #[substorage(v0)]
        // state: state_cpt::Storage,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        // #[substorage(v0)]
    // reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        GameContractInitialized: GameContractInitialized,
        Increment: Increment,
        GameFinished: GameFinished,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        StateEvent: state_cpt::Event,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GameContractInitialized {
        pub initializer: ContractAddress,
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
        pub const GAME_CONTRACT_ERROR: felt252 = 'GameContract: game error';
        pub const ALREADY_INITIALIZED: felt252 = 'GameContract: alr initialized';
        pub const NOT_INITIALIZED: felt252 = 'GameContract: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'GameContract: storage is locked';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl GameContractImpl of IGameContract<ContractState> {
        fn initialize_game(ref self: ContractState) {
            // Emit initialization event
            let caller = get_caller_address();
            self.emit(GameContractInitialized { initializer: caller });
        }

        fn update(ref self: ContractState, storage_changes: Span<(felt252, felt252)>) {}

        fn increment(ref self: ContractState) {
            self.counter.write(self.counter.read() + 1);

            let caller = get_caller_address();
            self.emit(Increment { caller });

            if self.counter.read() == 3 {
                self.emit(GameFinished { caller });
            }
        }
    }
}
