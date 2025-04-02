#!/bin/bash

SHARDING_CONTRACT_ADDRESS=$(cat sharding_contract_address.txt)
TEST_CONTRACT_ADDRESS=$(cat test_contract_address.txt)

SNOS_OUTPUT=$(cat snos_output.txt)
ELEMENT_COUNT=$(echo $SNOS_OUTPUT | wc -w)
OUTPUT_LENGTH=$(printf "0x%x" $ELEMENT_COUNT)

echo "Getting current shard_id for contract: $TEST_CONTRACT_ADDRESS..."
SHARD_ID_OUTPUT=$(sncast call \
    --contract-address "$SHARDING_CONTRACT_ADDRESS" \
    --function "get_shard_id" \
    --calldata "$TEST_CONTRACT_ADDRESS")

CURRENT_SHARD_ID=$(echo "$SHARD_ID_OUTPUT" | grep -oP '0x[0-9a-fA-F]+')
echo "Current shard_id: $CURRENT_SHARD_ID"
SHARD_ID="$CURRENT_SHARD_ID"

CALLDATA="$OUTPUT_LENGTH $SNOS_OUTPUT $SHARD_ID"

sncast invoke \
    --contract-address "$SHARDING_CONTRACT_ADDRESS" \
    --function "update_contract_state" \
    --fee-token eth \
    --calldata $CALLDATA
    