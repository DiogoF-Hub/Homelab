#!/bin/bash

# === CONFIGURATION ===
ROOT_CA_KEY="rootCA.key"
ROOT_CA_CERT="rootCA.pem"
CONFIG_TEMPLATE="openssl.cnf"
BASE_DIR="certs"
TAILNET_SUFFIX="taile2aadd.ts.net"

# === INPUT ===
DEVICE_HOSTNAME="$1"
INCLUDE_LOCAL=true
INCLUDE_TAILNET=true
INCLUDE_IP=true
DEVICE_IPS=()

if [ -z "$DEVICE_HOSTNAME" ]; then
  echo "Usage: $0 <device-hostname> [--no-local] [--no-tailnet] [--no-ip] [--ip <x.x.x.x>]..."
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-local)
      INCLUDE_LOCAL=false
      shift
      ;;
    --no-tailnet)
      INCLUDE_TAILNET=false
      shift
      ;;
    --no-ip)
      INCLUDE_IP=false
      shift
      ;;
    --ip)
      DEVICE_IPS+=("$2")
      INCLUDE_IP=true
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# === DERIVED VALUES ===
DEVICE_TAILNET="${DEVICE_HOSTNAME}.${TAILNET_SUFFIX}"
DEVICE_FQDN="${DEVICE_HOSTNAME}.localdomain"
OUT_DIR="${BASE_DIR}/${DEVICE_HOSTNAME}"
mkdir -p "$OUT_DIR"

# === FILE PATHS ===
CONFIG_TMP="${OUT_DIR}/openssl.cnf"
KEY="${OUT_DIR}/key.pem"
CSR="${OUT_DIR}/request.csr"
CRT="${OUT_DIR}/cert.pem"
COMBINED="${OUT_DIR}/combined.pem"

# === BUILD CONFIG FILE ===
cp "$CONFIG_TEMPLATE" "$CONFIG_TMP"

# Simple replacements: always set the hostname DNS entry
sed -i "s/replace.local/${DEVICE_HOSTNAME}/g" "$CONFIG_TMP"

# Include or remove .localdomain and tailnet entries depending on flags
if $INCLUDE_LOCAL; then
  if $INCLUDE_TAILNET; then
    sed -i "s/replace.local.localdomain/${DEVICE_FQDN}/g" "$CONFIG_TMP"
    sed -i "s/replace.tsnet/${DEVICE_TAILNET}/g" "$CONFIG_TMP"
  else
    sed -i "/replace.local.localdomain/d" "$CONFIG_TMP"
    sed -i "/replace.tsnet/d" "$CONFIG_TMP"
  fi
else
  # When --no-local is used, remove all .localdomain and .tsnet entries
  sed -i "/replace.local.localdomain/d" "$CONFIG_TMP"
  sed -i "/replace.tsnet/d" "$CONFIG_TMP"
fi

# Append IP SAN entries at end of file if provided (keeps template simple)
if $INCLUDE_IP && [ ${#DEVICE_IPS[@]} -gt 0 ]; then
  ip_index=0
  for ip in "${DEVICE_IPS[@]}"; do
    echo "IP.$((++ip_index)) = ${ip}" >> "$CONFIG_TMP"
  done
fi

# === GENERATE KEY ===
openssl genrsa -out "$KEY" 2048

# === GENERATE CSR ===
openssl req -new -key "$KEY" -out "$CSR" -config "$CONFIG_TMP"

# === SIGN CERTIFICATE ===
openssl x509 -req -in "$CSR" -CA "$ROOT_CA_CERT" -CAkey "$ROOT_CA_KEY" \
  -CAcreateserial -out "$CRT" -days 825 -sha256 \
  -extfile "$CONFIG_TMP" -extensions req_ext

# === COMBINE CERT + KEY ===
cat "$CRT" "$KEY" > "$COMBINED"

# === CLEANUP ===
rm "$CSR" "$CONFIG_TMP"

# === SUMMARY ===
echo ""
echo "✅ Certificate generated for: $DEVICE_HOSTNAME"
echo "📁 Files stored in: $OUT_DIR"
echo "🔒 SANs included:"
echo "   - $DEVICE_HOSTNAME"
if $INCLUDE_LOCAL && $INCLUDE_TAILNET; then
  echo "   - $DEVICE_FQDN"
  echo "   - $DEVICE_TAILNET"
fi
if $INCLUDE_IP && [ ${#DEVICE_IPS[@]} -gt 0 ]; then
  for ip in "${DEVICE_IPS[@]}"; do
    echo "   - $ip"
  done
fi