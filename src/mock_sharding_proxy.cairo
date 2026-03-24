/// No-op mock of the sharding proxy interface.
/// Used by dojo's sharding component for test initialization.
#[starknet::contract]
pub mod mock_sharding_proxy {
    use sharding_tests::contract_component::CRDType;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        shard_id: Map<ContractAddress, felt252>,
    }

    #[abi(embed_v0)]
    impl IShardingImpl of sharding_tests::sharding::ISharding<ContractState> {
        fn initialize_sharding(ref self: ContractState, storage_slots: Span<CRDType>) {
            let caller = get_caller_address();
            let current = self.shard_id.read(caller);
            self.shard_id.write(caller, current + 1);
        }

        fn end_shard(ref self: ContractState, shard_id: felt252) {}

        fn deactivate_shard(
            ref self: ContractState, game_contract: ContractAddress, shard_id: felt252,
        ) {}

        fn cancel_shard(
            ref self: ContractState,
            contract_address: ContractAddress,
            shard_id: felt252,
            slots: Span<felt252>,
        ) {}

        fn get_shard_id(ref self: ContractState, contract_address: ContractAddress) -> felt252 {
            self.shard_id.read(contract_address)
        }

        fn is_shard_active(
            self: @ContractState, contract_address: ContractAddress, shard_id: felt252,
        ) -> bool {
            true
        }

        fn notify_shard_requested(
            ref self: ContractState,
            shard_id: felt252,
            entities: Span<felt252>,
            entity_keys_flat: Span<felt252>,
        ) {}
    }
}
