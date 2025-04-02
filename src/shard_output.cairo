use core::array::Array;
use sharding_tests::contract_component::CRDType;

#[derive(Drop, Clone, PartialEq, Serde)]
pub struct ContractChanges {
    /// The address of the contract.
    pub addr: felt252,
    /// The new nonce of the contract (for account contracts).
    pub nonce: felt252,
    /// The new class hash (if changed).
    pub class_hash: Option<felt252>,
    /// A map from storage key to its new value.
    pub storage_changes: Array<StorageChange>,
}

#[derive(Drop, Clone, PartialEq, Serde)]
pub struct ShardOutput {
    pub state_diff: Array<ContractChanges>,
}

#[derive(Drop, Clone, PartialEq, Serde)]
pub struct StorageChange {
    pub key: felt252,
    pub value: felt252,
    pub crd_type: CRDType,
}
