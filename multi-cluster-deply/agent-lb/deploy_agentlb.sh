#!/bin/bash

# Color definitions
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Logging Functions ---
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# --- Pre-flight Checks ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "Command '$1' not found. Please install it and try again."
        exit 1
    fi
}

# --- Help Function ---
usage() {
    echo "Usage: $0 --namespace <namespace>"
    echo
    echo "Deploys Keylime Agent Ingress to the agent-lb Cluster."
    echo
    echo "Options:"
    echo "  --namespace <ns>           Specify the namespace for deployment."
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
        -h|--help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$NAMESPACE" ]; then
    usage
fi

# --- Pre-flight Checks ---
info "Performing pre-flight checks..."
check_command "kubectl"
check_command "python3"

# --- Banner ---
echo -e "${BLUE}--------------------------------------------------${NC}"
echo -e "${BLUE} Keylime Agent LB Cluster Deployment               ${NC}"
echo -e "${BLUE}--------------------------------------------------${NC}"
info "Namespace: $NAMESPACE"
echo -e "${BLUE}--------------------------------------------------${NC}"

kubectl create namespace "$NAMESPACE"


MANIFEST_DIR="templates"
if [ ! -d "$MANIFEST_DIR" ]; then
    error "Manifest directory '$MANIFEST_DIR' not found."
    exit 1
fi

info "Applying manifests from '$MANIFEST_DIR'..."
for manifest in $(find "$MANIFEST_DIR" -name '*.yaml' | sort); do
    info "Applying $manifest..."
    python3 keylime_res_gen.py --namespace "$NAMESPACE" --file "$manifest" | kubectl apply -f -
done

echo -e "${BLUE}--------------------------------------------------${NC}"
success "Deployment to cluster 'agent-lb' in namespace '$NAMESPACE' completed."
echo -e "${BLUE}--------------------------------------------------${NC}"
