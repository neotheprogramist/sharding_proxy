#!/bin/bash

sncast invoke \
    --contract-address "$(cat sharding_contract_address.txt)" \
    --function "update_state" \
    --fee-token eth \
    --calldata $(cat snos_output.txt)
    