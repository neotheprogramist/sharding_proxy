#!/bin/bash

# This script is used only for testing purposes, not for production.
# It's purpose is to invoke the update_contract_state function on the sharding contract.
# It takes one argument, which is the operation to perform.
# The operations are:
# - add: sums the diff value of the slot with the previous value
# - lock_set: locks the slot and sets a new value for it
# - set: sets a new value for the slot
# - lock: locks the contract slots (locked slots are immutable)
# It's used only for one slot "counter" in the contract.
# Only one argument is needed, the operation to perform (add, lock_set, set, lock) 
# and it will test these scenarios.

SHARDING_CONTRACT_ADDRESS=$(cat sharding_contract_address.txt)
TEST_CONTRACT_ADDRESS=$(cat test_contract_address.txt)

case $1 in 
    "add")
    MERKLE_ROOT="1088731836374661937316403012596633712556092219051229030186340742080999950526"
    ;;
    "lock_set")
    MERKLE_ROOT="2593822693257527360629682722657325507423907612061312602434083242003220225256"
    ;;
    "set")
    MERKLE_ROOT="3520766144213897562552881619374108766483354628115502834427570184352579212299"
    ;;
    "lock")
    MERKLE_ROOT="1070232253276935331580276395998304824284648789420506986359207788844401125346"
    ;;
    *)  
    echo "Error: Invalid operation. Use 'add', 'lock_set', 'set', or 'lock'."  
    exit 1  
    ;; 
esac

SNOS_OUTPUT=$(cat snos_output.txt)
ELEMENT_COUNT=$(echo $SNOS_OUTPUT | wc -w)
OUTPUT_LENGTH=$(printf "0x%x" $ELEMENT_COUNT)

# Replace the last element with the selected merkle root and keep OUTPUT_LENGTH
MODIFIED_SNOS=$(echo "$SNOS_OUTPUT" | sed "s/[^ ]*$/$MERKLE_ROOT/")
CALLDATA="$OUTPUT_LENGTH $MODIFIED_SNOS"

echo "Invoking update_contract_state with merkle root: $MERKLE_ROOT"
echo "Calldata: $CALLDATA"

sncast invoke \
    --contract-address "$SHARDING_CONTRACT_ADDRESS" \
    --function "update_contract_state" \
    --fee-token eth \
    --calldata $CALLDATA
    