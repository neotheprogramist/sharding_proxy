#!/bin/bash

sncast invoke \
    --contract-address "$(cat sharding_contract_address.txt)" \
    --function "register_operator" \
    --fee-token eth \
    --calldata "$(cat test_contract_address.txt)"