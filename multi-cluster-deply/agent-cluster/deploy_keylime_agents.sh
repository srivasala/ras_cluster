#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# --- Help Function ---
usage() {
    echo "Usage: $0 --namespace <namespace> [--replicas <number>] [--lb-ip <ip-address>]"
    echo
    echo "Deploys a Keylime agent cluster."
    echo
    echo "Options:"
    echo "  --namespace <ns>           Specify the namespace to deploy to. If it doesn't exist, it will be created."
    echo "  --replicas <number>        Specify the number of agent pods to deploy. Defaults to 1."
    echo "  --lb-ip <ip>    Optional: Specify the IP address of the load balancer to restrict Ingress access."
    echo "  -h, --help                 Show this help message."
    exit 0
}

# --- Configuration & Argument Parsing ---
NAMESPACE=""
REPLICAS=1
LOAD_BALANCER_IP=""

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
    --replicas)
        REPLICAS="$2"
        shift 2
        ;;
    --lb-ip)
        LOAD_BALANCER_IP="$2"
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
    echo "Error: --namespace is a required argument."
    usage
fi

# --- Prerequisites Check ---
if ! command -v kubectl &> /dev/null; then
    echo "kubectl could not be found. Please install it."
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "openssl could not be found. Please install it."
    exit 1
fi

if ! command -v uuidgen &> /dev/null; then
    echo "uuidgen could not be found. Please install it."
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "python3 could not be found. Please install it."
    exit 1
fi

if ! python3 -c "import jinja2" &> /dev/null; then
    echo "Jinja2 python library not found. Please install it using 'pip install jinja2'"
    exit 1
fi


# --- Banner ---
echo "--------------------------------------------------"
echo " Mock Keylime Agent Cluster Deployment"
echo "--------------------------------------------------"
echo "Namespace: $NAMESPACE"
echo "Replicas: $REPLICAS"
echo "--------------------------------------------------"

# --- 1. Apply Namespace ---
echo ">>> Applying namespace..."
./render_template.py "templates/01-namespace.yaml" "namespace" "$NAMESPACE" | kubectl apply -f -
echo "--------------------------------------------------"

# --- 2. Generate TLS Secrets ---
generate_tls_secrets() {
    echo ">>> Generating TLS secrets..."
    if kubectl get secret agent-tls -n "$NAMESPACE" &> /dev/null; then
        echo ">>> TLS secret 'agent-tls' already exists. Skipping generation."
        echo "--------------------------------------------------"
        return
    fi

    CERT_DIR="temp_certs"
    rm -rf "$CERT_DIR"
    mkdir -p "$CERT_DIR"

    # Generate CA
    openssl genrsa -out "$CERT_DIR/ca.key" 2048
    openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 365 -out "$CERT_DIR/ca.crt" -subj "/CN=Mock-Agent-CA"

    # Generate Server Certificate
    openssl genrsa -out "$CERT_DIR/agent.key" 2048
    openssl req -new -key "$CERT_DIR/agent.key" -out "$CERT_DIR/agent.csr" -subj "/CN=agent"
    openssl x509 -req -in "$CERT_DIR/agent.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/agent.crt" -days 365 -sha256

    # Create Kubernetes Secret
    kubectl create secret generic agent-tls \
      --from-file=tls.crt="$CERT_DIR/agent.crt" \
      --from-file=tls.key="$CERT_DIR/agent.key" \
      --from-file=ca.crt="$CERT_DIR/ca.crt" \
      -n "$NAMESPACE"

    rm -rf "$CERT_DIR"
    echo ">>> TLS secrets generated successfully."
    echo "--------------------------------------------------"
}

# --- 3. Apply Manifests ---
apply_manifests() {
    echo ">>> Rendering manifests..."
    
    RENDERED_DIR="rendered_manifests"
    rm -rf "$RENDERED_DIR"
    mkdir -p "$RENDERED_DIR"

    INGRESS_HOST_SUFFIX="keylime.example.com"
    AGENTS=()
    AGENT_UUID_HEX_LIST=()

    for i in $(seq 1 "$REPLICAS"); do
        AGENT_UUID=$(uuidgen)
        AGENT_UUID_HEX=$(echo -n "$AGENT_UUID" | xxd -p | tr -d '\n')
        AGENT_ID=$i
        
        echo "--> Rendering manifests for Agent $AGENT_ID (UUID: $AGENT_UUID)"

        # Render ConfigMap
        ./render_template.py "templates/05-agent-config.yaml" \
            "namespace" "$NAMESPACE" \
            "agent_id" "$AGENT_ID" \
            "agent_uuid" "$AGENT_UUID" \
            "registrar_fqdn" "registrar.$NAMESPACE" \
            > "$RENDERED_DIR/05-agent-$AGENT_ID-config.yaml"

        # Render Deployment (Pod)
        ./render_template.py "templates/12-deployment-agent-swtpm.yaml" \
            "namespace" "$NAMESPACE" \
            "agent_id" "$AGENT_ID" \
            > "$RENDERED_DIR/12-agent-$AGENT_ID-deployment.yaml"

        # Render Service
        ./render_template.py "templates/17-agent-service.yaml" \
            "namespace" "$NAMESPACE" \
            "agent_id" "$AGENT_ID" \
            > "$RENDERED_DIR/17-agent-$AGENT_ID-service.yaml"
        
        AGENTS+=("{\"id\": \"$AGENT_ID\", \"uuid_hex\": \"$AGENT_UUID_HEX\"}")
        AGENT_UUID_HEX_LIST+=("$AGENT_UUID_HEX")
    done

    # Render Ingress
    echo "--> Rendering Ingress..."
    # Convert bash array to comma-separated string for python script
    AGENT_LIST_JSON=$(printf '[%s]' "$(IFS=,; echo "${AGENTS[*]}")")
    ./render_template.py "templates/16-ingress.yaml"         "namespace" "$NAMESPACE"         "agents" "$AGENT_LIST_JSON"         "ingress_host_suffix" "$INGRESS_HOST_SUFFIX"         "load_balancer_ip" "$LOAD_BALANCER_IP"         > "$RENDERED_DIR/16-ingress.yaml"

    echo "--------------------------------------------------"
    echo ">>> Applying all rendered manifests from '$RENDERED_DIR'..."
    kubectl apply -f "$RENDERED_DIR/"
    echo "--------------------------------------------------"

    echo ">>> Waiting for all agent pods to be ready..."
    for AGENT_ID in $(seq 1 "$REPLICAS"); do
        kubectl wait --for=condition=Ready pod -l "app=agent-$AGENT_ID" -n "$NAMESPACE" --timeout=300s
    done
}

# --- Main Execution ---
generate_tls_secrets
apply_manifests

echo "--------------------------------------------------"
echo ">>> Deployment to namespace '$NAMESPACE' completed successfully!"
echo "--------------------------------------------------"
