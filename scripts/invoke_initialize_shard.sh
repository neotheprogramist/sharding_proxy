#!/bin/bash

sncast invoke \
    --contract-address "$(cat test_contract_address.txt)" \
    --function "initialize_shard" \
    --fee-token eth \
    --calldata "$(cat sharding_contract_address.txt)"