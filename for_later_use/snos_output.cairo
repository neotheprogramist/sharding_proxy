//! SNOS output related types and variables.
//!
use core::array::SpanIter;
use core::iter::IntoIterator;
use core::iter::Iterator;
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

#[derive(Drop, Serde, Debug)]
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
    // pub contracts: Array<ContractChanges>,
    // pub classes: Array<(felt252, felt252)>,
    pub state_diff: StateDiff,
}

#[derive(Drop, Serde, Debug)]
pub struct MessageToStarknet {
    /// Appchain contract address sending the message.
    pub from_address: ContractAddress,
    /// Starknet contract address receiving the message.
    pub to_address: ContractAddress,
    /// Payload of the message.
    pub payload: Span<felt252>,
}

#[derive(Drop, Serde, Debug)]
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

#[derive(Drop, Serde, Debug)]
pub struct StateDiff {
    pub contracts: Array<ContractChanges>,
    pub classes: Array<(felt252, felt252)>,
}

#[derive(Drop, Serde, Debug)]
pub struct ContractChanges {
    pub addr: felt252,
    pub nonce: felt252,
    pub class_hash: Option<felt252>,
    pub storage_changes: Array<(felt252, felt252)>,
}

fn read_segment(ref input_iter: SpanIter<felt252>, segment_length: usize) -> Array<felt252> {
    let mut segment = array![];
    for _i in 0..segment_length {
        let x = input_iter.next();
        if x.is_none() {
            break;
        }
        segment.append(*(x.unwrap()));
    };
    return segment;
}

/// Custom deserialization function, inspired by
/// https://github.com/starkware-libs/cairo-lang/blob/8e11b8cc65ae1d0959328b1b4a40b92df8b58595/src/starkware/starknet/core/aggregator/output_parser.py
pub fn deserialize_os_output(ref input_iter: SpanIter<felt252>) -> StarknetOsOutput {
    let _ = read_segment(ref input_iter, 3);
    let header = read_segment(ref input_iter, HEADER_SIZE);
    let use_kzg_da = header[USE_KZG_DA_OFFSET];
    let full_output = header[FULL_OUTPUT_OFFSET];
    if use_kzg_da.is_non_zero() {
        let kzg_segment = read_segment(ref input_iter, 2);
        let n_blobs: usize = (*kzg_segment.at(KZG_N_BLOBS_OFFSET))
            .try_into()
            .expect('Invalid n_blobs');
        let _ = read_segment(ref input_iter, 2 * 2 * n_blobs);
    }
    let (messages_to_l1, messages_to_l2) = deserialize_messages(ref input_iter);
    let (contracts, classes) = if use_kzg_da.is_zero() {
        (
            deserialize_contract_state(ref input_iter, *full_output),
            deserialize_contract_class_da_changes(ref input_iter, *full_output),
        )
    } else {
        (array![], array![])
    };
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
        state_diff: StateDiff {
            contracts,
            classes,
        },
    }
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

fn deserialize_contract_state_inner(
    ref input_iter: SpanIter<felt252>, full_output: felt252,
) -> Option<ContractChanges> {
    let FLAG_BOUND: u256 = 2;
    let N_UPDATES_SMALL_PACKING_BOUND: u256 = 4294967296; //2^32
    let N_UPDATES_BOUND: u256 = 18446744073709551616; //2^64
    let NONCE_BOUND: u256 = 18446744073709551616; //2^64
    
    // Get addr
    let addr_option = input_iter.next();
    if addr_option.is_none() {
        println!("Warning: No data for addr");
        return Option::None;
    }
    let addr = *addr_option.unwrap();
    
    // Get nonce_n_changes_two_flags
    let flags_option = input_iter.next();
    if flags_option.is_none() {
        println!("Warning: No data for nonce_n_changes_two_flags");
        return Option::None;
    }
    
    // Convert to u256 for calculations
    let nonce_n_changes_two_flags: u256 = match (*flags_option.unwrap()).try_into() {
        Option::Some(v) => v,
        Option::None => {
            println!("Warning: Invalid nonce_n_changes_two_flags");
            return Option::None;
        }
    };
    
    // Parse flags
    let nonce_n_changes_one_flag = nonce_n_changes_two_flags / FLAG_BOUND;
    let class_updated = nonce_n_changes_two_flags % FLAG_BOUND;
    
    let nonce_n_changes = nonce_n_changes_one_flag / FLAG_BOUND;
    let is_n_updates_small = nonce_n_changes_one_flag % FLAG_BOUND;
    
    // Parse n_changes
    let n_updates_bound = if is_n_updates_small.is_non_zero() {
        N_UPDATES_SMALL_PACKING_BOUND
    } else {
        N_UPDATES_BOUND
    };
    
    let nonce = nonce_n_changes / n_updates_bound;
    let n_changes = nonce_n_changes % n_updates_bound;
    
    // Parse class hash
    let new_class_hash = if !full_output.is_zero() {
        // Get prev_class_hash
        let prev_hash_option = input_iter.next();
        if prev_hash_option.is_none() {
            println!("Warning: No data for prev_class_hash");
            return Option::None;
        }
        
        // Get new_class_hash
        let new_hash_option = input_iter.next();
        if new_hash_option.is_none() {
            println!("Warning: No data for new_class_hash");
            return Option::None;
        }
        
        Option::Some(*new_hash_option.unwrap())
    } else {
        if !class_updated.is_zero() {
            // Get new_class_hash
            let new_hash_option = input_iter.next();
            if new_hash_option.is_none() {
                println!("Warning: No data for new_class_hash");
                return Option::None;
            }
            
            Option::Some(*new_hash_option.unwrap())
        } else {
            Option::None
        }
    };
    
    // Parse nonce
    let nonce_felt: felt252 = if !full_output.is_zero() {
        // In full output mode, nonce is divided by NONCE_BOUND
        // We only care about new_nonce
        let new_nonce = nonce % NONCE_BOUND;
        match new_nonce.try_into() {
            Option::Some(n) => n,
            Option::None => {
                println!("Warning: Failed to convert new_nonce to felt252");
                0.into() // Use a default value
            }
        }
    } else {
        // In non-full output mode, nonce is used directly if non-zero
        if nonce.is_zero() {
            0.into()
        } else {
            match nonce.try_into() {
                Option::Some(n) => n,
                Option::None => {
                    println!("Warning: Failed to convert nonce to felt252");
                    0.into() // Use a default value
                }
            }
        }
    };
    
    // Parse storage changes
    let n_changes_usize: usize = match n_changes.try_into() {
        Option::Some(n) => n,
        Option::None => {
            println!("Warning: Invalid n_changes");
            return Option::None;
        }
    };
    
    let mut storage_changes = array![];
    for i in 0..n_changes_usize {
        // Get key
        let key_option = input_iter.next();
        if key_option.is_none() {
            println!("Warning: Ran out of data while reading key at index {}", i);
            break;
        }
        let key = *key_option.unwrap();
        
        // Get prev_value if in full output mode
        if !full_output.is_zero() {
            let prev_value_option = input_iter.next();
            if prev_value_option.is_none() {
                println!("Warning: Ran out of data while reading prev_value at index {}", i);
                break;
            }
            // We don't need to use prev_value, just consume it
        }
        
        // Get new_value
        let new_value_option = input_iter.next();
        if new_value_option.is_none() {
            println!("Warning: Ran out of data while reading new_value at index {}", i);
            break;
        }
        let new_value = *new_value_option.unwrap();
        
        storage_changes.append((key, new_value));
    };
    
    // Return the contract changes
    Option::Some(ContractChanges {
        addr: addr,
        nonce: nonce_felt,
        class_hash: new_class_hash,
        storage_changes: storage_changes,
    })
}

fn deserialize_contract_state(
    ref input_iter: SpanIter<felt252>, full_output: felt252,
) -> Array<ContractChanges> {
    // Get the number of updates
    let output_n_updates_option = input_iter.next();
    if output_n_updates_option.is_none() {
        println!("Warning: No data for output_n_updates");
        return array![];
    }
    
    let output_n_updates: usize = match (*output_n_updates_option.unwrap()).try_into() {
        Option::Some(n) => {
            println!("output_n_updates: {}", n);
            n
        },
        Option::None => {
            println!("Warning: Invalid output_n_updates");
            return array![];
        }
    };
    
    let mut contract_changes = array![];
    let mut i = 0;
    while i < output_n_updates {
        match deserialize_contract_state_inner(ref input_iter, full_output) {
            Option::Some(changes) => {
                contract_changes.append(changes);
                i += 1;
            },
            Option::None => {
                println!("Warning: Failed to deserialize contract state at index {}", i);
                // Don't increment i here, as we want to try again with the next data
                break;
            }
        }
    };
    
    contract_changes
}

fn deserialize_contract_class_da_changes(
    ref input_iter: SpanIter<felt252>, full_output: felt252,
) -> Array<(felt252, felt252)> {
    let output_n_updates_option = input_iter.next();
    if output_n_updates_option.is_none() {
        println!("Warning: No data for class output_n_updates");
        return array![];
    }
    
    let output_n_updates: usize = match (*output_n_updates_option.unwrap()).try_into() {
        Option::Some(n) => n,
        Option::None => {
            println!("Warning: Invalid class output_n_updates");
            return array![];
        }
    };
    
    let mut contract_changes = array![];
    for i in 0..output_n_updates {
        let class_hash_option = input_iter.next();
        if class_hash_option.is_none() {
            println!("Warning: No data for class_hash at index {}", i);
            break;
        }
        let class_hash = *class_hash_option.unwrap();
        
        if full_output.is_non_zero() {
            let prev_compiled_class_hash_option = input_iter.next();
            if prev_compiled_class_hash_option.is_none() {
                println!("Warning: No data for prev_compiled_class_hash at index {}", i);
                break;
            }
            // We don't need to use prev_compiled_class_hash, just consume it
        }
        
        let compiled_class_hash_option = input_iter.next();
        if compiled_class_hash_option.is_none() {
            println!("Warning: No data for compiled_class_hash at index {}", i);
            break;
        }
        let compiled_class_hash = *compiled_class_hash_option.unwrap();
        
        contract_changes.append((class_hash, compiled_class_hash));
    };
    
    contract_changes
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
    };
    return messages_to_starknet;
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
    };
    return messages_to_appchain;
}