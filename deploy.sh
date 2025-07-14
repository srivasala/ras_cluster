#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# --- Help Function ---
usage() {
    echo "Usage: $0 [--namespace <namespace>] [--agents <n>] [component...]"
    echo
    echo "Deploys Keylime components to a Kubernetes cluster."
    echo
    echo "Options:"
    echo "  --namespace <ns>  Specify the namespace to deploy to (default: keylime-system)."
    echo "  --agents <n>      Specify the number of agent pods to deploy (default: 1)."
    echo "  -h, --help        Show this help message."
    echo
    echo "Components:"
    echo "  namespace         Deploys the namespace."
    echo "  config            Deploys all ConfigMaps (including all agent configs)."
    echo "  database          Deploys the PostgreSQL database."
    echo "  registrar         Deploys the Keylime registrar."
    echo "  verifier          Deploys the Keylime verifier."
    echo "  agent             Deploys the Keylime agent(s)."
    echo "  tenant            Deploys the Keylime tenant CLI pod."
    echo
    echo "If no components are specified, all components will be deployed in the correct order."
    echo "Example: $0 --namespace my-app --agents 3 agent verifier"
    exit 0
}

# --- Configuration & Argument Parsing ---
NAMESPACE=""
AGENT_COUNT=1
COMPONENTS_TO_DEPLOY=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
    --agents)
        AGENT_COUNT="$2"
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    *) # Assume it's a component
        COMPONENTS_TO_DEPLOY+=("$1")
        shift
        ;;
    esac
done

if [ "$NAMESPACE" == "" ] ; then
   usage
fi

# If no components are specified, default to deploying all
if [ ${#COMPONENTS_TO_DEPLOY[@]} -eq 0 ]; then
    COMPONENTS_TO_DEPLOY=(namespace config database registrar verifier agent tenant)
fi

ARTIFACTS_DIR="artifacts"

# --- Banner ---
echo "--------------------------------------------------"
echo " Keylime Deployment Script"
echo "--------------------------------------------------"
echo "Namespace: $NAMESPACE"
echo "Agents: $AGENT_COUNT"
echo "Components: ${COMPONENTS_TO_DEPLOY[@]}"
echo "--------------------------------------------------"

# --- 1. Generate Manifests ---
echo ">>> Generating Kubernetes manifests..."
python3 keylime_res_gen.py --namespace "$NAMESPACE" --agents "$AGENT_COUNT"
echo ">>> Manifests generated successfully."
echo "--------------------------------------------------"

# --- 2. Apply Manifests ---
echo ">>> Applying manifests to the cluster..."

apply_manifest() {
    local file="$1"
    local description="$2"
    if [ -f "$file" ]; then
        echo "Applying $description: $file"
        if ! kubectl apply -f "$file"; then
            echo "Error applying $file. Aborting."
            exit 1
        fi
    else
        echo "Warning: Manifest file not found: $file. Skipping."
    fi
}

# --- Deployment Logic ---
for component in "${COMPONENTS_TO_DEPLOY[@]}"; do
    case "$component" in
    namespace)
        apply_manifest "$ARTIFACTS_DIR/01-namespace.yaml" "Namespace"
        bash deploy_tls.sh "$NAMESPACE"
        ;;
    config)
        apply_manifest "$ARTIFACTS_DIR/02-keylime-tenant-config.yaml" "Tenant ConfigMap"
        apply_manifest "$ARTIFACTS_DIR/03-registrar-config.yaml" "Registrar ConfigMap"
        apply_manifest "$ARTIFACTS_DIR/04-verifier-config.yaml" "Verifier ConfigMap"
        for i in $(seq 1 $AGENT_COUNT); do
            apply_manifest "$ARTIFACTS_DIR/05-agent-config-$i.yaml" "Agent $i ConfigMap"
        done
        ;;
    database)
        apply_manifest "$ARTIFACTS_DIR/14-pgdb-deployment.yaml" "Postgres PVC and Deployment"
        sleep 10
        ;;
    registrar)
        apply_manifest "$ARTIFACTS_DIR/10-deployment-registrar.yaml" "Registrar Deployment"
        sleep 10
        ;;
    verifier)
        apply_manifest "$ARTIFACTS_DIR/11-deployment-verifier.yaml" "Verifier Deployment"
        sleep 10
        ;;
    agent)
        for i in $(seq 1 $AGENT_COUNT); do
            apply_manifest "$ARTIFACTS_DIR/12-deployment-agent-swtpm-$i.yaml" "Agent $i Pod"
        done
        ;;
    tenant)
        apply_manifest "$ARTIFACTS_DIR/13-tenant-cli.yaml" "Tenant CLI Pod"
        ;;
    *)
        echo "Unknown component: '$component'. Skipping."
        ;;
    esac
done

echo "--------------------------------------------------"
echo ">>> Deployment to namespace '$NAMESPACE' completed successfully!"
echo "--------------------------------------------------"
