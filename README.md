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

To test the sharding system, you need to have a local network running. You can download dojo-katana network from [here](https://github.com/dojoengine/dojo.git) and run it with `katana init` command to setup the network. And `katana --chain katana --block-time 5000 --db-dir katana.db` to run the network with name `katana` and block time 5 seconds and database in `katana.db` directory.

Next you need to deploy the contracts to the network with the scripts below to see how it works.

### Setup and Deployment

#### Declare the sharding contract ####
```bash
./scripts/declare_sharding.sh
```

#### Deploy the sharding contract ####
Deploy the sharding contract, you need to change the class hash to the declared one.
Constructor calldata is 4 felt252 values:
- owner
- state_root
- block_number
- block_hash

```bash
./scripts/deploy_sharding.sh
```

#### Declare the test contract ####
```bash
./scripts/declare_test_contract.sh
```

#### Deploy the test contract ####
Deploy a test contract, you need to change the class hash to the declared one.
Constructor calldata is 1 felt252 value:
- owner

```bash
./scripts/deploy_test_contract.sh
```

#### Initialize the test contract with the sharding system ####
```bash
./scripts/invoke_initialize_shard.sh
```

#### Doing all the steps above in one go with default values ####
```bash
./scripts/setup.sh
```

### Updating State

#### Process a state update ####
You need to provide snos_output.txt file with state changes and a sharding contract address.
```bash
./scripts/invoke_update_shard.sh
```

### Interacting with Contracts

#### Increment the counter in the test contract ####
Increment the counter in the test contract, provide the test contract address.
```bash
./scripts/invoke_increment.sh
```

#### Read the current counter value ####
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
