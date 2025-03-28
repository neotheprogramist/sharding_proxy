#!/bin/bash

sncast invoke \
    --contract-address "$(cat test_contract_address.txt)" \
    --function "increment" \
    --fee-token eth 