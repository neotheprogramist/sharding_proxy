#!/bin/bash

TEST_CONTRACT_ADDRESS=$(cat test_contract_address.txt)
SHARDING_CONTRACT_ADDRESS=$(cat sharding_contract_address.txt)

echo "Calling get_storage_slots to get slot information..."
SLOTS_OUTPUT=$(sncast call \
    --contract-address "$TEST_CONTRACT_ADDRESS" \
    --function "get_storage_slots"\
    --calldata 0x1)

echo "Slots output: $SLOTS_OUTPUT"

SLOTS_ARRAY=$(echo "$SLOTS_OUTPUT" | grep -o "response: \[.*\]" | sed 's/response: \[//' | sed 's/\]//' | sed 's/,//g')

echo "Slots array: $SLOTS_ARRAY"
#Hardcoded array lenght
ARRAY_LENGHT="1" 

CALLDATA="$SHARDING_CONTRACT_ADDRESS $ARRAY_LENGTH $SLOTS_ARRAY"

echo "Invoking initialize_shard with sharding contract address: $SHARDING_CONTRACT_ADDRESS"
echo "Calldata: $CALLDATA"

sncast invoke \
    --contract-address "$TEST_CONTRACT_ADDRESS" \
    --function "initialize_shard" \
    --fee-token eth \
    --calldata "$CALLDATA"