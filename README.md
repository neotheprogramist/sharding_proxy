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

first element 0x2d is length of the output, then each element is a felt252 value of snos output, last element 0x3 is shard id.

```
0x2d 0x1 0x2 0x3 0x600c7a82c53a4bceb845f1a691eb5ff0da03cf96dfca7856064e766e15d90d3 0x10d8554dcb7a9bc71a67716e12eacb893be7fbb6ed474708a343685fd837ed5 0x9 0xa 0x20d7e8bcc51950f49f5d6c935e7ddf23ab3612303da87809b4481efe62b6626 0x77d2b1d9bba4bd7bd817419c46b2a248f68dce4c82d57e87d8adb3e8d20f7d3 0x0 0x5b13f57af91266140394eaca3080289e3e8881564e71d52f04030c5a35e4d7b 0x0 0x1 0x0 0x0 0x4 0x1 0x6 0x0 0x0 0x0 0x0 0x91d4543643690ba5de910936502f11a7e153c9cefa606060a334b505ed5e58 0x1f401c745d3dba9b9da11921d1fb006c96f571e9039a0ece3f3b0dc14f04c3d 0x28000000000000003402 0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2 0x7dc7899aa655b0aae51eadff6d801a58e97dd99cf4666ee59e704249e51adf2 0x2e7442625bab778683501c0eadbc1ea17b3535da040a12ac7d281066e915eea 0xa 0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac 0xa2475bc66197c751d854ea8c39c6ad9781eb284103bcd856b58e6b500078ac 0x67840c21d0d3cba9ed504d8867dffe868f3d43708cfc0d7ed7980b511850070 0x21e19e0c9bab23ec53e 0x21e19e0c9bab23e9b86 0x7b62949c85c6af8a50c11c22927f9302f7a2e40bc93b4c988415915b0f97f09 0x13ac2 0x1647a 0x67afb2f65a238d3a5b9992c98e669753cd49d616a9740bb8fa92f11e3775762 0x6 0x48675ee1d853f408203c04aa712c255b151e1b07ce5dd05058a68b69f21b765 0x48675ee1d853f408203c04aa712c255b151e1b07ce5dd05058a68b69f21b765 0x7ebcc807b5c7e19f245995a55aed6f46f5f582f476a886b91b834b0ddf5854 0x0 0x3 0x0 0x3 0x1
```