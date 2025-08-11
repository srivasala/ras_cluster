#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# --- Help Function ---
usage() {
    echo "Usage: $0 --namespace <namespace>"
    echo
    echo "Deploys Keylime Verifier and Registrar to RAS Cluster."
    echo
    echo "Options:"
    echo "  --namespace <ns>           Specify the namespace to deploy to."
    echo "  -h, --help                 Show this help message."
    exit 0
}

# --- Configuration & Argument Parsing ---
NAMESPACE=""

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    *)
        echo "Unknown option: $1"
        usage
        ;;
    esac
done

if [ -z "$NAMESPACE" ]; then
    usage
fi

# --- Prerequisites Check ---
if ! command -v kubectl &> /dev/null; then
    echo "kubectl could not be found. Please install it."
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "python3 could not be found. Please install it."
    exit 1
fi

# --- Banner ---
echo "--------------------------------------------------"
echo " Keylime RAS Cluster Deployment"
echo "--------------------------------------------------"
echo "Namespace: $NAMESPACE"
echo "--------------------------------------------------"

# --- 1. Generate Manifests ---
echo ">>> Generating Kubernetes manifests for RAS Cluster..."
python3 ras_res_gen.py --namespace "$NAMESPACE"
echo ">>> Manifests generated successfully in '$NAMESPACE/'"
echo "--------------------------------------------------"

# Apply manifests in order
kubectl apply -f "$NAMESPACE/01-namespace.yaml"

# --- 2. Generate TLS Secrets ---
echo ">>> Generating TLS secrets..."
bash generate_tls_secrets.sh "$NAMESPACE"
echo ">>> TLS secrets generated successfully."
echo "--------------------------------------------------"

# --- 3. Apply Manifests ---
echo ">>> Applying manifests to the RAS cluster..."

echo ">>> Waiting for PostgreSQL to be ready..."
kubectl apply -f "$NAMESPACE/14-pgdb-deployment.yaml"
kubectl wait --for=condition=Ready pod -l app=keylime-db -n "$NAMESPACE" --timeout=300s

echo ">>> Waiting for Registrar to be ready..."
kubectl apply -f "$NAMESPACE/03-registrar-config.yaml"
kubectl apply -f "$NAMESPACE/10-deployment-registrar.yaml"
kubectl wait --for=condition=Ready pod -l app=registrar -n "$NAMESPACE" --timeout=300s

echo ">>> Waiting for Verifier to be ready..."
kubectl apply -f "$NAMESPACE/04-verifier-config.yaml"
kubectl apply -f "$NAMESPACE/11-deployment-verifier.yaml"
kubectl wait --for=condition=Ready pod -l app=verifier -n "$NAMESPACE" --timeout=300s

kubectl apply -f "$NAMESPACE/02-keylime-tenant-config.yaml"
kubectl apply -f "$NAMESPACE/13-tenant-cli.yaml"

echo "--------------------------------------------------"
echo ">>> Deployment to cluster 'ras' in namespace '$NAMESPACE' completed successfully!"
echo "--------------------------------------------------"
