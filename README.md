# Starknet Sharding System

A modular system for implementing sharding in Starknet contracts, allowing for efficient state management and updates across multiple contracts.

## Overview

This project implements a sharding mechanism that enables contracts to:

- Register specific storage slots with a central sharding proxy contract
- Process state updates from Starknet OS in a controlled manner
- Update only specific storage slots that belong to a particular shard

By using this approach, contracts can start shard by initializing proxy and settle shard by providing an output from starknet os.

## Architecture

### Core Components

1. **Sharding Proxy Contract** (`src/sharding.cairo`)

   - Central contract that manages shards and processes state updates
   - Maintains a registry of storage slots and their associated shards
   - Routes storage updates to the appropriate contracts

2. **Contract Component** (`src/contract_component.cairo`)

   - Embeddable component for making contracts "sharding-capable"
   - Handles registration with the sharding system
   - Processes storage updates from the sharding contract

3. **Test Contract** (`src/test_contract.cairo`)

   - Example implementation using the sharding system
   - Simple example with counter that is incremented
   - Emits end-event when shard is finished

4. **SNOS Output Parser** (`src/snos_output.cairo`)
   - Utilities for parsing Starknet OS output
   - Extracts state changes for processing by the sharding system

## How It Works

1. **Initialization**

   - Test contract initializes sharding proxy by calling initialize_shard function with slots to be changed
   - Proxy contract registers specific storage slots and a caller-contract address
   - Each contract is assigned a unique shard ID

2. **State Updates**

   - The sharding contract receives state updates from Starknet OS
   - It filters updates based on registered storage slots, shard ID and a caller-contract address
   - Only relevant changes are forwarded to the appropriate contracts

3. **Storage Management**
   - Contracts only process updates for storage slots they've registered
   - Shard ID is checked to ensure that only authorized changes are applied
   - Only changes from the caller-contract address are applied
   - This prevents unauthorized modifications to contract storage

## Usage

### Environment

To test the sharding system, you need to have a local network running. You can download dojo-katana network from [here](https://github.com/dojoengine/dojo.git) and run it with `katana init` command to setup the network, set chain id to sharding. And `katana --chain sharding --block-time 5000 --db-dir katana.db` to run the network with name `sharding` and block time 5 seconds and database in `katana.db` directory.

```
katana init
> Id sharding
> Settlement chain Sepolia
> Account <sepolia account address>
> Private key <sepolia account private key>
> Deploy settlement contract? Yes
✓ Deployment successful (0x7a1444f2fba2175328d5d381b19f163772f70d8912d6d54f2f2a5ae48b334b3) at block #639113
> Add Slot paymaster account? No
```

Next you need to deploy the contracts to the network with the scripts below to see how it works.

### Setup and Deployment

#### Deploy the sharding contract

Deploy the sharding contract, you need to change the class hash to the declared one.
Constructor calldata is one felt252 value:

- owner

#### To setup the test contract with the sharding system

```bash
./scripts/setup.sh
```

#### Initialize the test contract with the sharding system

To initialize shard you need to provide StorageSlotWithContract array which contains contract address, slot and crd_type for each slot you want to change.

```bash
./scripts/invoke_initialize_shard.sh
```

### Updating State

#### Process a state update

You need to provide snos_output.txt file with state changes and a sharding contract address.

```bash
./scripts/invoke_update_shard.sh
```

### Interacting with Contracts

#### Increment the counter in the test contract

Increment the counter in the test contract, provide the test contract address.

```bash
./scripts/invoke_increment.sh
```

#### Read the current counter value

Read the current counter value, provide the test contract address.

```bash
./scripts/call_get_counter.sh
```

## Testing

Run the tests to verify the sharding functionality:

```bash
scarb test
```

The main test file (`tests/sharding_test.cairo`) demonstrates how the sharding system processes state updates and ensures that only authorized changes are applied.

## Development

### Prerequisites

- Scarb 2.9.2
- Starknet Foundry 0.34.0

### Building

```bash
scarb build
```

### Example of snos_output.txt file:

0x1 is length of the output,
0x03848ec13a1bd89afecb7399fa2d0c0becc43aa01d82da046f77074a3be122ac - contract address (where slots are changed),
0x0,
0x1 - inner array length (how many slots),
0x1 - Lock/Add/Set/SetLock variant,
0x7EBCC807B5C7E19F245995A55AED6F46F5F582F476A886B91B834B0DDF5854 - slot key,
0x5 - slot value,
0x25DBAE090B03459D9C6F49CEBC642558115415AC9B0F5ECFCA54089AE4D67E2 - merkle root.

```
0x1 0x03848ec13a1bd89afecb7399fa2d0c0becc43aa01d82da046f77074a3be122ac 0x0 0x1 0x1 0x7EBCC807B5C7E19F245995A55AED6F46F5F582F476A886B91B834B0DDF5854 0x5 0x25DBAE090B03459D9C6F49CEBC642558115415AC9B0F5ECFCA54089AE4D67E2
```