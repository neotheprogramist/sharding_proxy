#!/bin/bash


declare_contract() {
  local contract_name=$1
  local class_hash_file=$2

  echo "Declaring $contract_name contrac+t..."
  output=$(sncast declare \
    --contract-name $contract_name \
    --url http://localhost:5050/ \
    --fee-token eth)

  class_hash=$(echo "$output" | grep "class_hash" | awk '{print $2}')
  echo $class_hash > $class_hash_file
  echo "$contract_name class_hash: $class_hash"
  sleep 20
}

# Function to deploy a contract with retry policy
deploy_contract() {
  local class_hash_file=$1
  local contract_address_file=$2
  local calldata=$3
  local max_retries=5
  local attempt=0

  class_hash=$(cat $class_hash_file)

  while [ $attempt -lt $max_retries ]; do
    echo "Deploying contract with class_hash $class_hash (Attempt $((attempt + 1))/$max_retries)..."
    output=$(sncast deploy \
      --class-hash $class_hash \
      --fee-token eth \
      --constructor-calldata $calldata)

    if echo "$output" | grep -q "contract_address"; then
      contract_address=$(echo "$output" | grep "contract_address" | awk '{print $2}')
      echo $contract_address > $contract_address_file
      echo "Contract deployed at address: $contract_address"
      break
    else
      echo "Deployment failed, retrying..."
      attempt=$((attempt + 1))
      sleep 10
    fi
  done

  if [ $attempt -eq $max_retries ]; then
    echo "Deployment failed after $max_retries attempts."
    exit 1
  fi

  sleep 5
}

# Function to invoke a function on a contract
invoke_function() {
  local contract_address_file=$1
  local function_name=$2
  local calldata=$3

  contract_address=$(cat $contract_address_file)

  echo "Invoking $function_name on contract at address $contract_address..."
  sncast invoke \
    --contract-address $contract_address \
    --function $function_name \
    --fee-token eth \
    --calldata $calldata
  echo "Function $function_name invoked."
  sleep 5
}

# Declare and deploy shard contract
declare_contract "sharding" "sharding_class_hash.txt"
deploy_contract "sharding_class_hash.txt" "sharding_contract_address.txt" "0x1 0x1 0x1 0x1"

# Declare and deploy test contract
declare_contract "test_contract" "test_contract_class_hash.txt"
deploy_contract "test_contract_class_hash.txt" "test_contract_address.txt" "$(cat sharding_contract_address.txt)"

# Invoke initialize_test on test contract
invoke_function "test_contract_address.txt" "initialize_test" "$(cat sharding_contract_address.txt)" 