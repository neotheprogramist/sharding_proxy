#!/bin/bash

sncast invoke \
  --contract-address 0x6bff4b50d6705ee090fb8447c983b1662741c964815b08e1238fe45f1b06597 \
  --function "deposit" \
  --calldata 100 0 \
  --fee-token eth