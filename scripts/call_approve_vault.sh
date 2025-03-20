#!/bin/bash

sncast invoke \
    --contract-address 0x1d4db3488b833e373fd4e960979fe038e37dd9a6c9a26fd1a4ede2375adb83f \
    --function "approve" \
    --fee-token eth \
    --calldata 0x6bff4b50d6705ee090fb8447c983b1662741c964815b08e1238fe45f1b06597 10000000 0
