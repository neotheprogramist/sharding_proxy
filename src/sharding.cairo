use sharding_tests::contract_component::CRDType;
use starknet::ContractAddress;

#[derive(Drop, Serde, starknet::Store, Hash, Copy, Debug)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub slot: felt252,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_sharding(ref self: TContractState, storage_slots: Span<CRDType>);

    fn end_shard(ref self: TContractState, shard_id: felt252);

    /// Mark a shard as inactive after settlement completes.
    /// Called by the world contract's sharding_component after apply_settle().
    fn deactivate_shard(
        ref self: TContractState, game_contract: ContractAddress, shard_id: felt252,
    );

    /// Cancel an active shard without settlement. Unlocks all specified slots
    /// without modifying storage values. Use when Katana TEE crashed and data is lost.
    fn cancel_shard(
        ref self: TContractState,
        contract_address: ContractAddress,
        shard_id: felt252,
        slots: Span<felt252>,
    );

    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;

    /// Check whether a specific shard is currently active (initialized but not yet
    /// settled/cancelled).
    fn is_shard_active(
        self: @TContractState, contract_address: ContractAddress, shard_id: felt252,
    ) -> bool;

    /// Notify the proxy that a shard has been requested on a world contract.
    /// Called by the world contract after locking entities and allocating shard_id.
    /// Emits `ShardingRequested` so the operator can discover new shards.
    fn notify_shard_requested(
        ref self: TContractState,
        shard_id: felt252,
        entities: Span<felt252>,
        entity_keys_flat: Span<felt252>,
    );
}

#[starknet::contract]
pub mod sharding {
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use dojo::world::{IShardingSettlementDispatcher, IShardingSettlementDispatcherTrait};
    use openzeppelin_access::ownable::OwnableComponent as ownable_cpt;
    use openzeppelin_access::ownable::OwnableComponent::InternalTrait as OwnableInternal;
    use sharding_tests::config::config_cpt;
    use sharding_tests::config::config_cpt::InternalTrait as ConfigInternal;
    use sharding_tests::contract_component::CRDType;
    use sharding_tests::utils::safe_increment;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::ISharding;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    type shard_id = felt252;

    #[storage]
    struct Storage {
        shard_id: Map<ContractAddress, shard_id>,
        /// Tracks which (game_contract, shard_id) pairs are currently active.
        /// Set to true on initialize, false on deactivate/cancel.
        active_shards: Map<(ContractAddress, felt252), bool>,
        owner: ContractAddress,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        config: config_cpt::Storage,
    }

    /// Maximum entity_keys_flat felts per chunk event (stay well under Starknet's 300 data limit).
    const MAX_KEYS_PER_CHUNK: u32 = 250;

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ShardingRequested: ShardingRequested,
        ShardingEntityKeysChunk: ShardingEntityKeysChunk,
        ShardFinished: ShardFinished,
        ShardCancelled: ShardCancelled,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ConfigEvent: config_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardingRequested {
        #[key]
        pub game_contract: ContractAddress,
        pub shard_id: felt252,
        pub entities: Span<felt252>,
        /// Number of `ShardingEntityKeysChunk` events that follow (0 if no keys).
        pub entity_key_chunks: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardingEntityKeysChunk {
        #[key]
        pub game_contract: ContractAddress,
        #[key]
        pub shard_id: felt252,
        pub chunk_index: u32,
        pub entity_keys_flat: Span<felt252>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardFinished {
        #[key]
        pub game_contract: ContractAddress,
        pub shard_id: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardCancelled {
        #[key]
        pub game_contract: ContractAddress,
        pub shard_id: felt252,
    }

    pub mod Errors {
        pub const SHARD_NOT_ACTIVE: felt252 = 'Sharding: Shard not active';
        pub const SHARD_ID_NOT_SET: felt252 = 'Sharding: Shard id not set';
        pub const SHARD_ID_OVERFLOW: felt252 = 'Sharding: Shard ID overflow';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_sharding(ref self: ContractState, storage_slots: Span<CRDType>) {
            self.config.assert_only_owner_or_operator();

            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = safe_increment(current_shard_id, Errors::SHARD_ID_OVERFLOW);
            self.shard_id.write(caller, new_shard_id);
            self.active_shards.write((caller, new_shard_id), true);

            self.emit(ShardingRequested {
                game_contract: caller,
                shard_id: new_shard_id,
                entities: [].span(),
                entity_key_chunks: 0,
            });
        }

        fn end_shard(ref self: ContractState, shard_id: felt252) {
            self.config.assert_only_owner_or_operator();
            let caller = get_caller_address();
            assert(shard_id != 0, Errors::SHARD_ID_NOT_SET);
            self.emit(ShardFinished { game_contract: caller, shard_id });
        }

        fn deactivate_shard(
            ref self: ContractState, game_contract: ContractAddress, shard_id: felt252,
        ) {
            self.config.assert_only_owner_or_operator();
            self.active_shards.write((game_contract, shard_id), false);
        }

        fn cancel_shard(
            ref self: ContractState,
            contract_address: ContractAddress,
            shard_id: felt252,
            slots: Span<felt252>,
        ) {
            // Owner-only: prevents a malicious operator from cancelling another operator's shard.
            self.ownable.assert_only_owner();

            assert(self.active_shards.read((contract_address, shard_id)), Errors::SHARD_NOT_ACTIVE);
            self.active_shards.write((contract_address, shard_id), false);

            let settlement_dispatcher = IShardingSettlementDispatcher {
                contract_address: contract_address,
            };
            settlement_dispatcher.cancel_shard(shard_id);

            self.emit(ShardCancelled { game_contract: contract_address, shard_id });
        }

        fn get_shard_id(ref self: ContractState, contract_address: ContractAddress) -> felt252 {
            let shard_id = self.shard_id.read(contract_address);
            assert(shard_id != 0, Errors::SHARD_ID_NOT_SET);
            shard_id
        }

        fn is_shard_active(
            self: @ContractState, contract_address: ContractAddress, shard_id: felt252,
        ) -> bool {
            self.active_shards.read((contract_address, shard_id))
        }

        fn notify_shard_requested(
            ref self: ContractState,
            shard_id: felt252,
            entities: Span<felt252>,
            entity_keys_flat: Span<felt252>,
        ) {
            self.config.assert_only_owner_or_operator();
            let caller = get_caller_address();
            self.active_shards.write((caller, shard_id), true);

            // Emit main event + chunked entity keys (Starknet event data limit = 300 felts).
            let total_keys_len = entity_keys_flat.len();
            let num_chunks: u32 = if total_keys_len == 0 {
                0_u32
            } else {
                let full = total_keys_len / MAX_KEYS_PER_CHUNK;
                if total_keys_len % MAX_KEYS_PER_CHUNK != 0 { full + 1 } else { full }
            };
            self
                .emit(
                    ShardingRequested {
                        game_contract: caller, shard_id, entities, entity_key_chunks: num_chunks,
                    },
                );

            let mut chunk_idx: u32 = 0;
            let mut key_offset: u32 = 0;
            while key_offset < total_keys_len {
                let remaining = total_keys_len - key_offset;
                let chunk_size = if remaining < MAX_KEYS_PER_CHUNK {
                    remaining
                } else {
                    MAX_KEYS_PER_CHUNK
                };
                let chunk = entity_keys_flat.slice(key_offset, chunk_size);
                self
                    .emit(
                        ShardingEntityKeysChunk {
                            game_contract: caller,
                            shard_id,
                            chunk_index: chunk_idx,
                            entity_keys_flat: chunk,
                        },
                    );
                key_offset += chunk_size;
                chunk_idx += 1;
            };
        }
    }
}
