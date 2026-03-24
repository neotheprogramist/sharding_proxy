#[starknet::interface]
pub trait ITournament<TContractState> {
    fn play_round(ref self: TContractState, score: felt252);
    fn record_win(ref self: TContractState);
    fn end_tournament(ref self: TContractState);
    fn get_total_score(self: @TContractState) -> felt252;
    fn get_rounds_played(self: @TContractState) -> felt252;
    fn get_wins(self: @TContractState) -> felt252;
    fn get_high_score(self: @TContractState) -> felt252;
    fn get_tournament_active(self: @TContractState) -> felt252;
    fn get_health(self: @TContractState) -> felt252;
    fn set_health(ref self: TContractState, value: felt252);
}

#[starknet::contract]
pub mod tournament {
    use openzeppelin_access::ownable::OwnableComponent as ownable_cpt;
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternal;
    use sharding_tests::contract_component::contract_component;
    use starknet::event::EventEmitter;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::ITournament;

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
        total_score: felt252,
        rounds_played: felt252,
        wins: felt252,
        high_score: felt252,
        tournament_active: felt252,
        health: felt252,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        contract_component: contract_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        RoundPlayed: RoundPlayed,
        WinRecorded: WinRecorded,
        TournamentFinished: TournamentFinished,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ContractComponentEvent: contract_component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RoundPlayed {
        pub caller: ContractAddress,
        pub score: felt252,
        pub total_score: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct WinRecorded {
        pub caller: ContractAddress,
        pub wins: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TournamentFinished {
        pub caller: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
        self.tournament_active.write(1);
        self.health.write(100);
    }

    #[abi(embed_v0)]
    impl TournamentImpl of ITournament<ContractState> {
        fn play_round(ref self: ContractState, score: felt252) {
            let new_total = self.total_score.read() + score;
            self.total_score.write(new_total);

            let new_rounds: felt252 = self.rounds_played.read() + 1;
            self.rounds_played.write(new_rounds);

            // Update high_score if this score is higher (compare as u256)
            let current_high: u256 = self.high_score.read().into();
            let score_u256: u256 = score.into();
            if score_u256 > current_high {
                self.high_score.write(score);
            }

            // Each round costs 10 HP
            let current_health: u256 = self.health.read().into();
            if current_health >= 10 {
                self.health.write((current_health - 10).try_into().unwrap());
            }

            let caller = get_caller_address();
            self.emit(RoundPlayed { caller, score, total_score: new_total });
        }

        fn record_win(ref self: ContractState) {
            let new_wins = self.wins.read() + 1;
            self.wins.write(new_wins);

            let caller = get_caller_address();
            self.emit(WinRecorded { caller, wins: new_wins });
        }

        fn end_tournament(ref self: ContractState) {
            self.tournament_active.write(0);
            let caller = get_caller_address();
            self.contract_component.end_current_shard();
            self.emit(TournamentFinished { caller });
        }

        fn get_total_score(self: @ContractState) -> felt252 {
            self.total_score.read()
        }

        fn get_rounds_played(self: @ContractState) -> felt252 {
            self.rounds_played.read()
        }

        fn get_wins(self: @ContractState) -> felt252 {
            self.wins.read()
        }

        fn get_high_score(self: @ContractState) -> felt252 {
            self.high_score.read()
        }

        fn get_tournament_active(self: @ContractState) -> felt252 {
            self.tournament_active.read()
        }

        fn get_health(self: @ContractState) -> felt252 {
            self.health.read()
        }

        fn set_health(ref self: ContractState, value: felt252) {
            self.health.write(value);
        }
    }
}
