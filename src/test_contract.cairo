use starknet::{ContractAddress};
use sharding_tests::sharding::StorageSlotWithContract;

#[starknet::interface]
pub trait ITestContract<TContractState> {
    fn initialize_test(ref self: TContractState, sharding_contract_address: ContractAddress);

    fn update(
        ref self: TContractState,         
        storage_changes: Span<(felt252, felt252)>,
    );

    fn get_storage_slots(ref self: TContractState, test_contract_address: felt252) -> Array<StorageSlotWithContract>;
}

#[starknet::contract]
pub mod test_contract {
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
    use super::ITestContract;
    use sharding_tests::sharding::StorageSlotWithContract;
    use sharding_tests::sharding::IShardingDispatcher;
    use sharding_tests::sharding::IShardingDispatcherTrait;
    use starknet::syscalls::storage_read_syscall;
    use starknet::syscalls::storage_write_syscall;

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent);
    
    #[storage]
    struct Storage {
        owner: ContractAddress,
        storage_values: Map<felt252, felt252>,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TestContractInitialized: TestContractInitialized,
        TestContractUpdated: TestContractUpdated,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractInitialized {
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractUpdated {
        pub storage_changes: Span<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const TEST_CONTRACT_ERROR: felt252 = 'TestContract: test error';
        pub const ALREADY_INITIALIZED: felt252 = 'TestContract: alr initialized';
        pub const NOT_INITIALIZED: felt252 = 'TestContract: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'TestContract: storage is locked';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
    ) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl TestContractImpl of ITestContract<ContractState> {
        fn initialize_test(ref self: ContractState, sharding_contract_address: ContractAddress) {
            // Emit initialization event
            let sharding_dispatcher = IShardingDispatcher { contract_address: sharding_contract_address };
            sharding_dispatcher.initialize_shard(self.get_storage_slots(get_contract_address().into()).span());

        }
        
        fn update(ref self: ContractState,      
            storage_changes: Span<(felt252, felt252)>,
        ) {
            let mut i: usize = 0;
            while i < storage_changes.len() {
                let (key, value) = *storage_changes.at(i);
                
                storage_write_syscall(0, key.try_into().unwrap(), value).unwrap_syscall();
                
                i += 1;
            };
            
            self.emit(TestContractUpdated { storage_changes });
        }

        fn get_storage_slots(ref self: ContractState, test_contract_address: felt252) -> Array<StorageSlotWithContract> {
            array![
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 2926345684328354409014039193448755836334301647171549754784433265613851656304,
                },
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 3488041066649332616440110253331181934927363442882040970594983370166361489161,
                },
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 289565229787362368933081636443797405535488074065834425092593015835915391953,
                },
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 1129664241071644691371073118594794953592340198277473102285062464307545102410,
                },
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 1239149872729906871793169171313897310809028090219849129902089947133222824240,
                },
                StorageSlotWithContract {
                    contract_address: test_contract_address.try_into().unwrap(),
                    slot: 1804974537427402286278400303388660593172206410421526189703894999503593972097,
                },
            ]
        }
        
    }
}
