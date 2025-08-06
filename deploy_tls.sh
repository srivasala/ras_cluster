#!/bin/bash

if [[ -z "$1" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

NS=$1

generate_cert() {
  NAME=$1
  openssl genrsa -out ${NAME}.key 2048
  openssl req -new -key ${NAME}.key -out ${NAME}.csr -subj "/CN=${NAME}"
  openssl x509 -req -in ${NAME}.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out ${NAME}.crt -days 365 -sha256

#kubectl create secret tls ${NAME}-tls \
#	  --cert=${NAME}.crt --key=${NAME}.key -n $NS

  if [[ "$NAME" == "verifier" ]]; then
    # Verifier acts as both client and server
    kubectl create secret generic ${NAME}-tls \
      --from-file=client-cert.crt=${NAME}.crt \
      --from-file=client-private.pem=${NAME}.key \
      --from-file=server-cert.crt=${NAME}.crt \
      --from-file=server-private.pem=${NAME}.key \
      --from-file=ca.crt=ca.crt \
      -n $NS
  elif [[ "$NAME" == "tenant" ]]; then
    kubectl create secret generic ${NAME}-tls \
      --from-file=client-cert.crt=${NAME}.crt \
      --from-file=client-private.pem=${NAME}.key \
      --from-file=ca.crt=ca.crt \
      -n $NS
  else
    kubectl create secret generic ${NAME}-tls \
      --from-file=server-cert.crt=${NAME}.crt \
      --from-file=server-private.pem=${NAME}.key \
      --from-file=ca.crt=ca.crt \
      -n $NS
  fi
}

# Generate CA key
openssl genrsa -out ca.key 2048

# Generate CA cert with extensions using a config file
cat > ca.cnf <<EOF
[ req ]
default_bits       = 2048
default_md         = sha256
prompt             = no
distinguished_name = dn
x509_extensions    = v3_ca

[ dn ]
CN = keylime-ca

[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, keyCertSign, cRLSign
EOF

openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -out ca.crt -config ca.cnf

#generate_cert $1

generate_cert registrar
generate_cert verifier
generate_cert tenant
generate_cert agent


kubectl create secret generic keylime-ca \
	  --from-file=ca.crt -n $NS

