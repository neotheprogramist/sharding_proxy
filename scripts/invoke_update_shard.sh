#!/bin/bash
OUTPUT_LENGTH="0xd" #snos output length
SNOS_OUTPUT=$(cat snos_output.txt)
SHARD_ID="0x1"

CALLDATA="$OUTPUT_LENGTH $SNOS_OUTPUT $SHARD_ID"

sncast invoke \
    --contract-address "$(cat sharding_contract_address.txt)" \
    --function "update_contract_state" \
    --fee-token eth \
    --calldata $CALLDATA
    