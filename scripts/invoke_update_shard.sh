#!/bin/bash

sncast invoke \
    --contract-address 0x05510b03156806af69acd83792ee67a0a00c1c6e276fec1455149164f3d86316 \
    --function "update_state" \
    --fee-token eth \
    --calldata $(cat snos_output.txt)
    