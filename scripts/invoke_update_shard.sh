#!/bin/bash

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
    