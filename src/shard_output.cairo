use core::array::Array;
use core::poseidon::poseidon_hash_span;

#[derive(Drop, Clone, PartialEq, Serde)]
pub struct ContractChanges {
    /// The address of the contract.
    pub addr: felt252,
    /// The new nonce of the contract (for account contracts).
    pub nonce: felt252,
    /// The new class hash (if changed).
    pub class_hash: Option<felt252>,
    /// A map from storage key to its new value.
    pub storage_changes: Array<(felt252, felt252)>,
}

#[derive(Drop, Clone, PartialEq, Serde)]
pub struct ShardOutput {
    pub merkle_root: felt252,
    pub state_diff: Array<ContractChanges>,
}

pub fn merkle_tree_hash(array: Span<felt252>) -> felt252 {
    let length = array.len();
    if length == 1 {
        return array[0].clone();
    }
    poseidon_hash_span(
        [
            merkle_tree_hash(array.slice(0, length / 2)),
            merkle_tree_hash(array.slice(length / 2, length / 2)),
        ]
            .span(),
    )
}

pub fn is_power_of_two(n: usize) -> bool {
    n != 0 && (n & (n - 1)) == 0
}
