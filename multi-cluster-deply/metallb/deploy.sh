#!/bin/bash

# This script deploys the MetalLB manifests to a Kubernetes cluster.

# Exit immediately if a command exits with a non-zero status.
set -e

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Deploy the MetalLB namespace
echo "Applying MetalLB namespace..."
kubectl create namespace metallb-system

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.11/config/manifests/metallb-native.yaml
# Deploy the MetalLB installation
echo "Applying MetalLB config..."
kubectl apply -f "${SCRIPT_DIR}/metallb-config.yaml"

echo "MetalLB deployment script finished."
