# Starknet Sharding System

A modular system for implementing sharding in Starknet contracts, enabling efficient state management and updates via TEE attestation or SNOS proofs.

## Overview

This project implements a sharding mechanism that enables contracts to:

- Register specific storage slots with a central sharding contract
- Define CRDT-like conflict resolution types per slot (Add, Set, SetLock, Lock)
- Process state updates via TEE-attested storage commitments or SNOS output
- Stack multiple shards on the same slot (for Set and Add types)

## Architecture

### Core Components

1. **Sharding Contract** (`src/sharding.cairo`)
   - Central coordinator that manages shards and processes state updates
   - Two update paths: `update_contract_state_tee` (TEE) and `update_contract_state_snos` (SNOS)
   - Verifies storage commitments via StorageCommitment registry (TEE path)
   - Routes storage updates to the appropriate game contracts

2. **Contract Component** (`src/contract_component.cairo`)
   - Embeddable component for making contracts sharding-capable
   - Manages slot registration with CRD types and init_count tracking
   - Applies CRDT logic on update: Set/SetLock overwrite, Add accumulates, Lock reserves
   - Handles slot locking/unlocking lifecycle

3. **StorageCommitment** (external, from `katana-tee`)
   - Nonce-based commitment registry for replay protection
   - Verifies `hash(storage_commitment, contract_address, nonce, global_state_root)`

4. **Config Component** (`src/config.cairo`)
   - Owner/operator access control for the sharding contract

5. **Test Contract** (`src/test_contract.cairo`)
   - Example game contract with `counter`, `score`, `health` storage slots
   - Helpers: `get_storage_slots()`, `get_storage_slot_for(selector, crd_type)`

### CRD Types

| Type | Behavior | Stackable | Description |
|------|----------|-----------|-------------|
| `Set` | Last-write-wins | Yes (same type) | Overwrites slot value. Multiple shards can stack. |
| `Add` | Commutative sum | Yes (same type) | Adds shard value to current value. Multiple shards can stack. |
| `SetLock` | Exclusive overwrite | No | Overwrites slot value. Slot is locked during shard execution. |
| `Lock` | Reserve only | No | Reserves the slot during shard but discards the shard value. |

**Transition rules:**
- Slot free (`init_count = 0`): any type can be initialized (base state is always `Set`)
- Slot active + SetLock/Lock: **BLOCKED** (exclusive, no stacking allowed)
- Slot active + Set/Add: same-type stacking only (`init_count++`), type change blocked
- After unlock: slot resets to `Set` with `init_count = 0`

## Security Model

The system splits authorization between the **Sharding proxy** and the **Game contract (ContractComponent)**:

| Responsibility | Owner |
|----------------|-------|
| **Who** can settle a shard | Sharding proxy (owner/operator access control) |
| **Which** shard is being settled | Sharding proxy (shard_id verification) |
| **Whether** storage changes are authentic | Sharding proxy (TEE commitment verification) |
| **What** slots can be modified | Game contract (only locked slots with `init_count > 0`) |
| **How** slot values are merged | Game contract (CRDT logic: Set overwrites, Add computes delta, Lock discards) |

The game contract does **not** track shard IDs — it trusts the proxy (verified via caller check) and only processes slots that were locked during initialization.

## How It Works

### TEE Update Flow

1. Game contract calls `initialize_shard()` on its ContractComponent with slot CRD types
2. ContractComponent validates slots, locks them (`init_count++`), snapshots Add values
3. ContractComponent calls `initialize_sharding()` on the Sharding proxy
4. Sharding proxy increments shard_id and emits `ShardingRequested` event
5. TEE executes the shard off-chain
6. TEE registers a storage commitment hash via `StorageCommitment.register_verified_commitment()`
7. Operator calls `update_contract_state_tee()` on the Sharding proxy
8. Proxy verifies shard_id, computes storage commitment, verifies against registry
9. Proxy forwards changes to ContractComponent via `update_shard_state()`
10. ContractComponent filters to locked slots, applies CRDT logic, and unlocks (`init_count--`)

### SNOS Update Flow

Similar to TEE but uses SNOS output instead of storage commitments:
1. Initialize shard (same as above)
2. Operator calls `update_contract_state_snos()` with serialized SNOS output
3. Sharding parses output and forwards changes to registered contracts

## Development

### Prerequisites

- Scarb 2.15.0
- Starknet Foundry 0.55.0

### Building

```bash
scarb build
```

### Testing

```bash
scarb test --all-features
```

### Formatting

```bash
scarb fmt --check
```

## Deployment

### Deploy the sharding contract

Constructor calldata: `(owner_address, storage_commitment_registry_address)`

### Initialize a game contract

Call `initialize_shard()` on the game contract's ContractComponent with:
- `sharding_contract_address` - address of the deployed sharding contract
- `contract_slots_changes` - array of `CRDType` values specifying slots and their conflict resolution types

### Update state (TEE path)

1. Register commitment via `StorageCommitment.register_verified_commitment(hash)`
2. Call `update_contract_state_tee(contract_address, storage_changes, shard_id, global_state_root)` on the sharding contract
