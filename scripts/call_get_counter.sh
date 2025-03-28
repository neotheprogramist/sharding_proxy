#!/bin/bash

sncast call \
    --contract-address "$(cat test_contract_address.txt)" \
    --function "get_counter"