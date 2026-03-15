/// No-op mock of the sharding proxy interface.
/// Used by dojo's sharding component for test initialization.
#[starknet::contract]
pub mod mock_sharding_proxy {
    use dojo::sharding::crdt::CRDType;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        shard_id: Map<ContractAddress, felt252>,
    }

    #[abi(embed_v0)]
    impl IShardingImpl of dojo::sharding::interface::ISharding<ContractState> {
        fn initialize_sharding(ref self: ContractState, storage_slots: Span<CRDType>) {
            let caller = get_caller_address();
            let current = self.shard_id.read(caller);
            self.shard_id.write(caller, current + 1);
        }
        fn get_shard_id(self: @ContractState, contract_address: ContractAddress) -> felt252 {
            self.shard_id.read(contract_address)
        }
        fn end_shard(ref self: ContractState) {}
    }
}
