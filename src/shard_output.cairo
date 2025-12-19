use core::array::{Array, SpanIter};
use core::iter::{IntoIterator, Iterator};
use core::num::traits::Zero;
use starknet::ContractAddress;


/// Size of the header of the output of SNOS.
const HEADER_SIZE: usize = 10;
/// Size of the header of a message to Starknet, which is
/// right before the payload content.
const MESSAGE_TO_STARKNET_HEADER_SIZE: usize = 3;
/// Size of the header of a message to appchain, which is
/// right before the payload content.
const MESSAGE_TO_APPCHAIN_HEADER_SIZE: usize = 5;

const PREVIOUS_MERKLE_UPDATE_OFFSET: usize = 0;
const NEW_MERKLE_UPDATE_OFFSET: usize = 1;
const PREV_BLOCK_NUMBER_OFFSET: usize = 2;
const NEW_BLOCK_NUMBER_OFFSET: usize = 3;
const PREV_BLOCK_HASH_OFFSET: usize = 4;
const NEW_BLOCK_HASH_OFFSET: usize = 5;
const OS_PROGRAM_HASH_OFFSET: usize = 6;
const CONFIG_HASH_OFFSET: usize = 7;
const USE_KZG_DA_OFFSET: usize = 8;
const FULL_OUTPUT_OFFSET: usize = 9;
const KZG_N_BLOBS_OFFSET: usize = 1;

#[derive(Drop, Serde, Debug, PartialEq)]
pub struct StarknetOsOutput {
    pub initial_root: felt252,
    pub final_root: felt252,
    pub prev_block_number: felt252,
    pub new_block_number: felt252,
    pub prev_block_hash: felt252,
    pub new_block_hash: felt252,
    pub os_program_hash: felt252,
    pub starknet_os_config_hash: felt252,
    pub use_kzg_da: felt252,
    pub full_output: felt252,
    pub messages_to_l1: Span<MessageToStarknet>,
    pub messages_to_l2: Span<MessageToAppchain>,
    pub state_diff: Span<FullContractChanges>,
}

#[derive(Drop, Serde, Debug, PartialEq)]
pub struct MessageToStarknet {
    /// Appchain contract address sending the message.
    pub from_address: ContractAddress,
    /// Starknet contract address receiving the message.
    pub to_address: ContractAddress,
    /// Payload of the message.
    pub payload: Span<felt252>,
}

#[derive(Drop, Serde, Debug, PartialEq)]
pub struct MessageToAppchain {
    /// Starknet address sending the message.
    pub from_address: ContractAddress,
    /// Appchain address receiving the message.
    pub to_address: ContractAddress,
    /// Nonce.
    pub nonce: felt252,
    /// Function selector (with #[l1 handler] attribute).
    pub selector: felt252,
    /// Payload size.
    pub payload: Span<felt252>,
}

#[derive(Drop, Serde, Debug, PartialEq)]
pub struct FullContractChanges {
    pub address: ContractAddress,
    pub prev_nonce: felt252,
    pub new_nonce: felt252,
    pub prev_class_hash: felt252,
    pub new_class_hash: felt252,
    pub storage_changes: Span<FullContractStorageUpdate>,
}

#[derive(Drop, Serde, Debug, PartialEq)]
pub struct FullContractStorageUpdate {
    pub key: felt252,
    pub prev_value: felt252,
    pub new_value: felt252,
}

fn read_segment(ref input_iter: SpanIter<felt252>, segment_length: usize) -> Array<felt252> {
    let mut segment = array![];
    for _i in 0..segment_length {
        let x = input_iter.next();
        if x.is_none() {
            break;
        }
        segment.append(*x.unwrap());
    }
    return segment;
}


pub fn deserialize_messages(
    ref input_iter: SpanIter<felt252>,
) -> (Span<MessageToStarknet>, Span<MessageToAppchain>) {
    let n_messages_to_l1: usize = (*(input_iter.next().unwrap()))
        .try_into()
        .expect('Invalid n_messages_to_l1');
    let messages_to_l1 = read_segment(ref input_iter, n_messages_to_l1);
    let n_messages_to_l2: usize = (*(input_iter.next().unwrap()))
        .try_into()
        .expect('Invalid n_messages_to_l2');
    let mut messages_to_l2 = read_segment(ref input_iter, n_messages_to_l2);

    let mut iter_messages_to_l1 = messages_to_l1.span().into_iter();
    let messages_to_l1 = deserialize_messages_to_l1(ref iter_messages_to_l1);

    let mut iter_messages_to_l2 = messages_to_l2.span().into_iter();
    let messages_to_l2 = deserialize_messages_to_l2(ref iter_messages_to_l2);

    (messages_to_l1.span(), messages_to_l2.span())
}

fn deserialize_messages_to_l1(ref input_iter: SpanIter<felt252>) -> Array<MessageToStarknet> {
    let mut messages_to_starknet = array![];
    loop {
        let header = read_segment(ref input_iter, MESSAGE_TO_STARKNET_HEADER_SIZE);
        if header.len() < MESSAGE_TO_STARKNET_HEADER_SIZE {
            break;
        }
        let payload_size: usize = (*header[2]).try_into().expect('Invalid payload size');
        let mut payload = read_segment(ref input_iter, payload_size);
        let payload = payload.span();
        let from_address: ContractAddress = (*header[0]).try_into().expect('Invalid from address');
        let to_address: ContractAddress = (*header[1]).try_into().expect('Invalid to address');
        let message_to_starknet = MessageToStarknet { from_address, to_address, payload };
        messages_to_starknet.append(message_to_starknet);
    }
    return messages_to_starknet;
}

fn deserialize_state_diff(ref input_iter: SpanIter<felt252>) -> Array<FullContractChanges> {
    let mut contract_changes_array = array![];
    let n_contracts: usize = (*(input_iter.next().unwrap()))
        .try_into()
        .expect('Invalid number of contracts');
    for _ in 0..n_contracts {
        let address: ContractAddress = (*(input_iter.next().unwrap()))
            .try_into()
            .expect('Invalid contract address');
        let prev_nonce: felt252 = *(input_iter.next().unwrap());
        let new_nonce: felt252 = *(input_iter.next().unwrap());
        let prev_class_hash: felt252 = *(input_iter.next().unwrap());
        let new_class_hash: felt252 = *(input_iter.next().unwrap());
        let n_storage_changes: usize = (*(input_iter.next().unwrap()))
            .try_into()
            .expect('Invalid number of storage ch');
        let mut storage_changes_array = array![];
        for _ in 0..n_storage_changes {
            let key: felt252 = *(input_iter.next().unwrap());
            let prev_value: felt252 = *(input_iter.next().unwrap());
            let new_value: felt252 = *(input_iter.next().unwrap());
            let storage_change = FullContractStorageUpdate { key, prev_value, new_value };
            storage_changes_array.append(storage_change);
        }
        let contract_changes = FullContractChanges {
            address,
            prev_nonce,
            new_nonce,
            prev_class_hash,
            new_class_hash,
            storage_changes: storage_changes_array.span(),
        };
        contract_changes_array.append(contract_changes);
    }
    return contract_changes_array;
}
fn deserialize_messages_to_l2(ref input_iter: SpanIter<felt252>) -> Array<MessageToAppchain> {
    let mut messages_to_appchain = array![];
    loop {
        let header = read_segment(ref input_iter, MESSAGE_TO_APPCHAIN_HEADER_SIZE);
        if header.len() < MESSAGE_TO_APPCHAIN_HEADER_SIZE {
            break;
        }
        let payload_size: usize = (*header[4]).try_into().expect('Invalid payload size');
        let mut payload = read_segment(ref input_iter, payload_size);
        let payload = payload.span();
        let from_address: ContractAddress = (*header[0]).try_into().expect('Invalid from address');
        let to_address: ContractAddress = (*header[1]).try_into().expect('Invalid to address');
        let message_to_appchain = MessageToAppchain {
            from_address, to_address, nonce: *header[2], selector: *header[3], payload,
        };
        messages_to_appchain.append(message_to_appchain);
    }
    return messages_to_appchain;
}


/// Custom deserialization function, inspired by
/// https://github.com/starkware-libs/cairo-lang/blob/8e11b8cc65ae1d0959328b1b4a40b92df8b58595/src/starkware/starknet/core/aggregator/output_parser.py.
///
/// This deserialization function is expecting a bootloaded Starknet OS output, where the first
/// three elements of the input are part of the bootloader header.
pub fn deserialize_os_output(ref input_iter: SpanIter<felt252>) -> StarknetOsOutput {
    let header = read_segment(ref input_iter, HEADER_SIZE);
    let use_kzg_da = header[USE_KZG_DA_OFFSET];
    let full_output = header[FULL_OUTPUT_OFFSET];
    let os_program_hash = header[OS_PROGRAM_HASH_OFFSET];

    // StarknetOS (SNOS) program is expected to be run without an aggregator program at the moment.
    // Once aggregator program is supported, this will need to be updated for a conditional branch
    // to verify that the aggregator program is allowed to be run (added via the configuration
    // component).
    assert!(os_program_hash.is_zero(), "Aggregator program is not supported yet");

    // Currently not supported by the appchain logic, but will be added in the future.
    assert!(use_kzg_da.is_zero(), "KZG DA is not supported yet");

    // assert!(full_output.is_zero(), "Full output is not supported");

    let (messages_to_l1, messages_to_l2) = deserialize_messages(ref input_iter);

    let state_diff = deserialize_state_diff(ref input_iter);
    StarknetOsOutput {
        initial_root: *header[PREVIOUS_MERKLE_UPDATE_OFFSET],
        final_root: *header[NEW_MERKLE_UPDATE_OFFSET],
        prev_block_number: *header[PREV_BLOCK_NUMBER_OFFSET],
        new_block_number: *header[NEW_BLOCK_NUMBER_OFFSET],
        prev_block_hash: *header[PREV_BLOCK_HASH_OFFSET],
        new_block_hash: *header[NEW_BLOCK_HASH_OFFSET],
        os_program_hash: *header[OS_PROGRAM_HASH_OFFSET],
        starknet_os_config_hash: *header[CONFIG_HASH_OFFSET],
        use_kzg_da: *use_kzg_da,
        full_output: *full_output,
        messages_to_l1: messages_to_l1,
        messages_to_l2: messages_to_l2,
        state_diff: state_diff.span(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deserialize_os_output_with_messages() {
        let mut input = array![
               0x564bd22008db5d8ee010398e1769cf53b155d5418759a3daf9748223810fa1f,
    0x6d8c571961b70f66500f203c2867c1b7a89d991b3e12a15e2d617c73349d249,
    0x3ed1c6,
    0x3ed1c9,
    0x7d0ff4a6fc38a9eecb7afb74e9f19807946e1c113b988f7188587ba0b449874,
    0x490cbfe4cfa9f214c77a054d34a40bd5b45333aeb7aa559ae2db0031a322a26,
    0x0,
    0x1b9900f77ff5923183a7795fcfbb54ed76917bc1ddd4160cc77fa96e36cf8c5,
    0x0,
    0x1,
    0x0,
    0x0,
    0x4,
    0x1,
    0x0,
    0x0,
    0x0,
    0x0,
    0x3,
    0x3ed1bd,
    0x0,
    0x1ce9a92f1e2c5492481b4d10cc9386029c24af6b3d095d4ba1bbb8adb74fa62,
    0x3ed1be,
    0x0,
    0x34c99055fee7ac422b25d8522bd7d08d6f787e99b7198fb8d90650d1add3e58,
    0x3ed1bf,
    0x0,
    0x4e9a9c6f68f04f1eed27d1be22c010172ffebe6b157c90b865ce36e5161b8fb,
    0x446e80025dde50edb5b0735727c3de66e65947734a7893bcf6a05c8dc0b345a,
    0x0,
    0x0,
    0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
    0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
    0x1,
    0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854,
    0x0,
    0x3,
    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
    0x0,
    0x0,
    0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
    0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
    0x2,
    0x3968b99888bd99c0284e1af8e55f2175d0737f540e8d6440d83add8e869e4c4,
    0x51d08b42e76b465ee,
    0x51c402f2791baadee,
    0x5496768776e3db30053404f18067d81a6e06f5a2b0de326e21298fd9d569a9a,
    0x2a13c459d6e6f09d0e598,
    0x2a13c4665f375eeca9d98,
    0x69a4f598b14f8424f2ee90b7a55fbc6083635da13f96a35acae04e6c149798d,
    0x672,
    0x675,
    0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
    0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
    0x0,
    0x0,
        ];

        let mut input_iter = input.span().into_iter();
        let os_output = deserialize_os_output(ref input_iter);

        let expected = StarknetOsOutput {
    initial_root: 0x564bd22008db5d8ee010398e1769cf53b155d5418759a3daf9748223810fa1f,
    final_root: 0x6d8c571961b70f66500f203c2867c1b7a89d991b3e12a15e2d617c73349d249,
    prev_block_number: 4116934,
    new_block_number: 4116937,
    prev_block_hash: 0x7d0ff4a6fc38a9eecb7afb74e9f19807946e1c113b988f7188587ba0b449874,
    new_block_hash: 0x10ba4a4e85f487605d7db8f2ea8b57ea772e21e30e681839caebafd8fbfb11e,
    os_program_hash: 0x0,
    starknet_os_config_hash: 0x1b9900f77ff5923183a7795fcfbb54ed76917bc1ddd4160cc77fa96e36cf8c5,
    use_kzg_da: os_output.use_kzg_da,
    full_output: os_output.full_output,
    messages_to_l1: array![].span(),
    messages_to_l2: array![].span(),
    state_diff: array![
        FullContractChanges {
            address: 0x1.try_into().unwrap(),
            prev_nonce: 0x0,
            new_nonce: 0x0,
            prev_class_hash: 0x0,
            new_class_hash: 0x0,
            storage_changes: array![
                FullContractStorageUpdate {
                    key: 0x3ed1bd,
                    prev_value: 0x0,
                    new_value: 0x1ce9a92f1e2c5492481b4d10cc9386029c24af6b3d095d4ba1bbb8adb74fa62,
                },
                FullContractStorageUpdate {
                    key: 0x3ed1be,
                    prev_value: 0x0,
                    new_value: 0x34c99055fee7ac422b25d8522bd7d08d6f787e99b7198fb8d90650d1add3e58,
                },
                FullContractStorageUpdate {
                    key: 0x3ed1bf,
                    prev_value: 0x0,
                    new_value: 0x4e9a9c6f68f04f1eed27d1be22c010172ffebe6b157c90b865ce36e5161b8fb,
                },
            ]
            .span(),
        },
        FullContractChanges {
            address: 0x446e80025dde50edb5b0735727c3de66e65947734a7893bcf6a05c8dc0b345a
                .try_into()
                .unwrap(),
            prev_nonce: 0x0,
            new_nonce: 0x0,
            prev_class_hash: 0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
            new_class_hash: 0x406fd3dc3a4e87d24188645603d3e238d519ab1045397a4e3b1f93a9fa36565,
            storage_changes: array![
                FullContractStorageUpdate {
                    key: 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854,
                    prev_value: 0x0,
                    new_value: 0x3,
                },
            ]
            .span(),
        },
        FullContractChanges {
            address: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                .try_into()
                .unwrap(),
            prev_nonce: 0x0,
            new_nonce: 0x0,
            prev_class_hash: 0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
            new_class_hash: 0x9524a94b41c4440a16fd96d7c1ef6ad6f44c1c013e96662734502cd4ee9b1f,
            storage_changes: array![
                FullContractStorageUpdate {
                    key: 0x3968b99888bd99c0284e1af8e55f2175d0737f540e8d6440d83add8e869e4c4,
                    prev_value: 0x51d08b42e76b465ee,
                    new_value: 0x51c402f2791baadee,
                },
                FullContractStorageUpdate {
                    key: 0x5496768776e3db30053404f18067d81a6e06f5a2b0de326e21298fd9d569a9a,
                    prev_value: 0x2a13c459d6e6f09d0e598,
                    new_value: 0x2a13c4665f375eeca9d98,
                },
            ]
            .span(),
        },
        FullContractChanges {
            address: 0x69a4f598b14f8424f2ee90b7a55fbc6083635da13f96a35acae04e6c149798d
                .try_into()
                .unwrap(),
            prev_nonce: 0x672,
            new_nonce: 0x675,
            prev_class_hash: 0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
            new_class_hash: 0x36078334509b514626504edc9fb252328d1a240e4e948bef8d0c08dff45927f,
            storage_changes: array![].span(),
        },
    ]
    .span(),
};
        assert_eq!(
            os_output.state_diff,
            expected.state_diff
            
        );

    }
}
