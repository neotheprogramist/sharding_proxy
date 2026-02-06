use sharding_tests::contract_component::CRDType;
use starknet::ContractAddress;

/// Interface for the Storage Commitment contract.
///
/// Security model:
/// - Commitments are pre-computed hashes: hash(storage_commitment, contract_address, nonce,
/// global_state_root)
/// - Registration just stores the hash (from SP1 journal)
/// - Verification recomputes the hash using stored nonce and checks if it was registered
/// - After successful verification, commitment is deleted and nonce is incremented
#[starknet::interface]
pub trait IStorageCommitment<TContractState> {
    /// Register a storage commitment hash that was verified by the TEE (SP1 proof).
    fn register_verified_commitment(ref self: TContractState, commitment: felt252);

    /// Verify a commitment by recomputing the hash with the stored nonce.
    fn verify(
        ref self: TContractState,
        storage_commitment: felt252,
        contract_address: ContractAddress,
        global_state_root: felt252,
    ) -> bool;

    fn is_registered(self: @TContractState, commitment: felt252) -> bool;

    fn get_nonce(self: @TContractState, contract_address: ContractAddress) -> u64;

    fn get_latest_global_state_root(
        self: @TContractState, contract_address: ContractAddress,
    ) -> felt252;
}

#[derive(Drop, Serde, starknet::Store, Hash, Copy, Debug)]
pub struct StorageSlotWithContract {
    pub contract_address: ContractAddress,
    pub slot: felt252,
}

#[starknet::interface]
pub trait ISharding<TContractState> {
    fn initialize_sharding(ref self: TContractState, storage_slots: Span<CRDType>);

    fn update_contract_state_snos(
        ref self: TContractState, snos_output: Span<felt252>, shard_id: felt252,
    );

    /// Update contract state with pre-verified storage changes from TEE.
    ///
    /// # Arguments
    /// * `contract_address` - The game contract to update
    /// * `storage_changes` - Array of (key, value) pairs to update
    /// * `shard_id` - The shard ID for verification
    /// * `global_state_root` - The state root from TEE attestation
    fn update_contract_state_tee(
        ref self: TContractState,
        contract_address: ContractAddress,
        storage_changes: Array<(felt252, felt252)>,
        shard_id: felt252,
        global_state_root: felt252,
    );

    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;
}

#[starknet::contract]
pub mod sharding {
    use core::poseidon::poseidon_hash_span;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use openzeppelin::access::ownable::OwnableComponent as ownable_cpt;
    use openzeppelin::access::ownable::OwnableComponent::InternalTrait as OwnableInternal;
    use sharding_tests::config::config_cpt;
    use sharding_tests::config::config_cpt::InternalTrait as ConfigInternal;
    use sharding_tests::contract_component::{
        CRDType, IContractComponentDispatcher, IContractComponentDispatcherTrait,
    };
    use sharding_tests::shard_output::ShardOutput;
    use sharding_tests::utils::safe_increment;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};
    use super::{ISharding, IStorageCommitmentDispatcher, IStorageCommitmentDispatcherTrait};

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: config_cpt, storage: config, event: ConfigEvent);

    #[abi(embed_v0)]
    impl ConfigImpl = config_cpt::ConfigImpl<ContractState>;

    type shard_id = felt252;

    #[storage]
    struct Storage {
        initializer_contract_address: ContractAddress,
        shard_id: Map<ContractAddress, shard_id>,
        owner: ContractAddress,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        config: config_cpt::Storage,
        storage_commitment_registry: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ShardInitialized: ShardInitialized,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ConfigEvent: config_cpt::Event,
        StorageCommitmentVerified: StorageCommitmentVerified,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StorageCommitmentVerified {
        pub storage_commitment: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ShardInitialized {
        pub initializer: ContractAddress,
        pub shard_id: felt252,
        pub storage_slots: Span<CRDType>,
    }

    pub mod Errors {
        pub const SHARD_ID_MISMATCH: felt252 = 'Sharding: Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Sharding: Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Sharding: No contracts';
        pub const NO_STORAGE_CHANGES: felt252 = 'Sharding: No storage changes';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        storage_commitment_registry: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.storage_commitment_registry.write(storage_commitment_registry);
    }

    #[abi(embed_v0)]
    impl ShardingImpl of ISharding<ContractState> {
        fn initialize_sharding(ref self: ContractState, storage_slots: Span<CRDType>) {
            self.config.assert_only_owner_or_operator();

            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = safe_increment(current_shard_id, 'Shard ID overflow');
            self.shard_id.write(caller, new_shard_id);
            self.initializer_contract_address.write(caller);

            self
                .emit(
                    ShardInitialized { initializer: caller, shard_id: new_shard_id, storage_slots },
                );
        }

        fn update_contract_state_snos(
            ref self: ContractState, snos_output: Span<felt252>, shard_id: felt252,
        ) {
            self.config.assert_only_owner_or_operator();
            let mut snos_output = snos_output;
            let program_output_struct: ShardOutput = Serde::deserialize(ref snos_output).unwrap();

            assert(
                program_output_struct.state_diff.span().len() != 0, Errors::NO_CONTRACTS_SUBMITTED,
            );
            for contract in program_output_struct.state_diff.span() {
                let contract_address: ContractAddress = (*contract.addr)
                    .try_into()
                    .expect('Invalid contract address');

                if self.initializer_contract_address.read() == contract_address {
                    let contract_shard_id = self.shard_id.read(contract_address);
                    assert(contract_shard_id != 0, Errors::SHARD_ID_NOT_SET);
                    assert(contract_shard_id == shard_id, Errors::SHARD_ID_MISMATCH);

                    let mut storage_changes = ArrayTrait::new();
                    for storage_change in contract.storage_changes.span() {
                        let (storage_key, storage_value) = *storage_change;

                        storage_changes.append((storage_key, storage_value));
                    }
                    assert(storage_changes.span().len() != 0, Errors::NO_STORAGE_CHANGES);

                    let contract_dispatcher = IContractComponentDispatcher {
                        contract_address: contract_address,
                    };
                    contract_dispatcher.update_shard_state(storage_changes, shard_id);
                }
            }
        }

        /// Update contract state with pre-verified storage changes from TEE.
        ///
        /// Flow:
        /// 1. Compute storage_commitment = hash(keys || values)
        /// 2. Call StorageCommitment.verify(storage_commitment, contract_address,
        /// global_state_root)
        ///    which internally computes full_commitment = hash(storage_commitment,
        ///    contract_address, nonce, state_root)
        ///    and checks if it was registered
        /// 3. If verified, nonce is incremented and commitment is deleted
        /// 4. Forward storage changes to contract
        fn update_contract_state_tee(
            ref self: ContractState,
            contract_address: ContractAddress,
            storage_changes: Array<(felt252, felt252)>,
            shard_id: felt252,
            global_state_root: felt252,
        ) {
            self.config.assert_only_owner_or_operator();

            if self.initializer_contract_address.read() == contract_address {
                // Verify shard_id matches
                let contract_shard_id = self.shard_id.read(contract_address);
                assert(contract_shard_id != 0, Errors::SHARD_ID_NOT_SET);
                assert(contract_shard_id == shard_id, Errors::SHARD_ID_MISMATCH);

                // Verify we have storage changes
                assert(storage_changes.len() != 0, Errors::NO_STORAGE_CHANGES);

                let storage_commitment_registry = IStorageCommitmentDispatcher {
                    contract_address: self.storage_commitment_registry.read(),
                };

                // Compute storage_commitment = hash(keys || values)
                let storage_commitment = self.compute_storage_commitment(storage_changes.span());

                // Verify: recomputes full hash with stored nonce and checks registration
                assert(
                    storage_commitment_registry
                        .verify(storage_commitment, contract_address, global_state_root),
                    'Storage commitment not verified',
                );

                self.emit(StorageCommitmentVerified { storage_commitment });

                // Forward to the contract component
                let contract_dispatcher = IContractComponentDispatcher {
                    contract_address: contract_address,
                };
                contract_dispatcher.update_shard_state(storage_changes, shard_id);
            }
        }

        fn get_shard_id(ref self: ContractState, contract_address: ContractAddress) -> felt252 {
            let shard_id = self.shard_id.read(contract_address);
            assert(shard_id != 0, Errors::SHARD_ID_NOT_SET);
            shard_id
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Computes storage commitment as poseidon_hash(keys || values).
        /// Matches Rust: compute_storage_commitment() in katana-tee.
        fn compute_storage_commitment(
            self: @ContractState, storage_changes: Span<(felt252, felt252)>,
        ) -> felt252 {
            let mut data: Array<felt252> = ArrayTrait::new();

            // First all keys
            for change in storage_changes {
                let (key, _) = *change;
                data.append(key);
            }

            // Then all values
            for change in storage_changes {
                let (_, value) = *change;
                data.append(value);
            }

            // Convert felt252 to u256 (always safe - felt252 fits in u256)
            poseidon_hash_span(data.span())
        }
    }
}
