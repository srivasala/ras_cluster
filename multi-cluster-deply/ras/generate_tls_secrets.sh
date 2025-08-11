#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <namespace>"
    exit 1
fi

NAMESPACE=$1
CERT_DIR="certs"

# Check for prerequisites
if ! command -v openssl &> /dev/null; then
    echo "openssl could not be found. Please install it."
    exit 1
fi
if ! command -v kubectl &> /dev/null; then
    echo "kubectl could not be found. Please install it."
    exit 1
fi

echo ">>> Generating TLS certificates and secrets in namespace '$NAMESPACE'..."

# Clean up previous certs
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

# 1. Generate CA
echo "--> Generating CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096
openssl req -x509 -new -nodes -key "$CERT_DIR/ca.key" -sha256 -days 3650 -out "$CERT_DIR/ca.crt" -subj "/CN=Keylime-CA"

# 2. Generate Server Certificate (for Registrar and Verifier)
echo "--> Generating Server certificate..."
openssl genrsa -out "$CERT_DIR/server-private.pem" 2048
openssl req -new -key "$CERT_DIR/server-private.pem" -out "$CERT_DIR/server.csr" -subj "/CN=keylime-server"
openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/server-cert.crt" -days 365 -sha256

# 3. Generate Client Certificate (for Verifier and Tenant)
echo "--> Generating Client certificate..."
openssl genrsa -out "$CERT_DIR/client-private.pem" 2048
openssl req -new -key "$CERT_DIR/client-private.pem" -out "$CERT_DIR/client.csr" -subj "/CN=keylime-client"
openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/client-cert.crt" -days 365 -sha256

# 4. Create Kubernetes Secrets
echo "--> Creating Kubernetes secrets..."

# Delete existing secrets to avoid errors
kubectl delete secret registrar-tls -n "$NAMESPACE" --ignore-not-found
kubectl delete secret verifier-tls -n "$NAMESPACE" --ignore-not-found
kubectl delete secret tenant-tls -n "$NAMESPACE" --ignore-not-found

kubectl create secret generic registrar-tls \
  --from-file=server-cert.crt="$CERT_DIR/server-cert.crt" \
  --from-file=server-private.pem="$CERT_DIR/server-private.pem" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  -n "$NAMESPACE"

kubectl create secret generic verifier-tls \
  --from-file=server-cert.crt="$CERT_DIR/server-cert.crt" \
  --from-file=server-private.pem="$CERT_DIR/server-private.pem" \
  --from-file=client-cert.crt="$CERT_DIR/client-cert.crt" \
  --from-file=client-private.pem="$CERT_DIR/client-private.pem" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  -n "$NAMESPACE"

kubectl create secret generic tenant-tls \
  --from-file=client-cert.crt="$CERT_DIR/client-cert.crt" \
  --from-file=client-private.pem="$CERT_DIR/client-private.pem" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  -n "$NAMESPACE"

# 5. Clean up
#echo "--> Cleaning up temporary files..."
#rm -rf "$CERT_DIR"

echo ">>> TLS secrets generated successfully."
