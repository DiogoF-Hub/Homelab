#!/usr/bin/env bash
set -euo pipefail

# === DEPENDENCY CHECK ===
if ! command -v openssl &> /dev/null; then
  echo "Error: openssl is not installed or not in PATH."
  exit 1
fi

# === CONSTANTS ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/generator.conf"
ROOT_CA_KEY="rootCA.key"
ROOT_CA_CERT="rootCA.pem"
BASE_DIR="certs"

# === USAGE ===
if [ -z "$1" ]; then
  echo "Usage:"
  echo "  $0 setup                               Configure script settings"
  echo "  $0 ca                                  Generate root CA (ECDSA P-384)"
  echo "  $0 <device-hostname> [options]         Generate device certificate"
  echo ""
  echo "Options:"
  echo "  --no-local      Exclude local domain suffix from SANs"
  echo "  --no-tailnet    Exclude Tailscale domain from SANs"
  echo "  --no-ip         Exclude IP addresses from SANs"
  echo "  --ip <x.x.x.x> Add IP address to SANs (repeatable)"
  exit 1
fi

# === SETUP ===
run_setup() {
  echo "=== HTTPS Generator Setup ==="
  echo ""
  echo "Press Enter to accept the default value shown in brackets."
  echo ""

  # --- Certificate identity ---
  echo "--- Certificate Identity ---"
  echo "These fields appear in the certificate subject (e.g., C=US, O=Homelab)."
  echo ""

  read -rp "Country code (2 letters) [US]: " input
  CA_C="${input:-US}"

  read -rp "State [Washington]: " input
  CA_ST="${input:-Washington}"

  read -rp "City [Washington]: " input
  CA_L="${input:-Washington}"

  read -rp "Organization [Homelab]: " input
  CA_O="${input:-Homelab}"

  read -rp "Root CA name [Homelab Root CA]: " input
  CA_CN="${input:-Homelab Root CA}"

  # --- Local domain suffix ---
  echo ""
  echo "--- Local Domain Suffix ---"
  echo "Appended to hostnames as an extra SAN (e.g., server01.localdomain)."
  echo "Examples: localdomain, home.lan, local, internal"
  echo "Type 'none' to disable."
  echo ""

  read -rp "Local domain suffix [localdomain]: " input
  input="${input:-localdomain}"
  if [ "$input" = "none" ]; then
    LOCAL_SUFFIX=""
  else
    LOCAL_SUFFIX="$input"
  fi

  # --- Tailscale suffix ---
  echo ""
  echo "--- Tailscale Suffix ---"
  echo "Your Tailscale tailnet domain, appended as a SAN (e.g., server01.taile2aadd.ts.net)."
  echo "Find it in Tailscale admin under DNS."
  echo "Type 'none' or leave empty to disable."
  echo ""

  read -rp "Tailscale suffix: " input
  if [ "$input" = "none" ]; then
    TAILNET_SUFFIX=""
  else
    TAILNET_SUFFIX="$input"
  fi

  # Write config
  cat > "$CONFIG_FILE" <<EOF
# HTTPS Generator configuration
# Re-run './generate_cert.sh setup' to change these values

CA_C="${CA_C}"
CA_ST="${CA_ST}"
CA_L="${CA_L}"
CA_O="${CA_O}"
CA_CN="${CA_CN}"
LOCAL_SUFFIX="${LOCAL_SUFFIX}"
TAILNET_SUFFIX="${TAILNET_SUFFIX}"
EOF

  echo ""
  echo "Configuration saved to generator.conf"
}

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "No configuration found. Running first-time setup..."
    echo ""
    run_setup
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
}

# Handle setup subcommand
if [ "$1" = "setup" ]; then
  run_setup
  exit 0
fi

# Load config for all other commands
load_config

# Build CA subject from config values
CA_SUBJECT="/C=${CA_C}/ST=${CA_ST}/L=${CA_L}/O=${CA_O}/OU=RootCA/CN=${CA_CN}"

# === ROOT CA GENERATION ===
if [ "$1" = "ca" ]; then
  if [ -f "$ROOT_CA_KEY" ] || [ -f "$ROOT_CA_CERT" ]; then
    echo "Root CA files already exist ($ROOT_CA_KEY / $ROOT_CA_CERT)."
    read -rp "Overwrite? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  echo "Generating root CA (ECDSA P-384, 20-year validity)..."

  openssl ecparam -name secp384r1 -genkey -noout -out "$ROOT_CA_KEY"
  openssl req -x509 -new -key "$ROOT_CA_KEY" -sha384 -days 7300 -out "$ROOT_CA_CERT" \
    -subj "$CA_SUBJECT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

  echo ""
  echo "Root CA generated:"
  echo "  Subject:      $CA_SUBJECT"
  echo "  Private key:  $ROOT_CA_KEY (keep this safe!)"
  echo "  Certificate:  $ROOT_CA_CERT (install on devices)"
  echo "  Valid for:    20 years"
  exit 0
fi

# === DEVICE CERTIFICATE GENERATION ===
DEVICE_HOSTNAME="$1"
INCLUDE_LOCAL=true
INCLUDE_TAILNET=true
INCLUDE_IP=true
DEVICE_IPS=()

# Disable SANs automatically if suffix is not configured
if [ -z "$LOCAL_SUFFIX" ]; then
  INCLUDE_LOCAL=false
fi
if [ -z "$TAILNET_SUFFIX" ]; then
  INCLUDE_TAILNET=false
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-local)    INCLUDE_LOCAL=false;  shift ;;
    --no-tailnet)  INCLUDE_TAILNET=false; shift ;;
    --no-ip)       INCLUDE_IP=false;     shift ;;
    --ip)          DEVICE_IPS+=("$2"); INCLUDE_IP=true; shift 2 ;;
    *)             echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Check root CA exists
if [ ! -f "$ROOT_CA_KEY" ] || [ ! -f "$ROOT_CA_CERT" ]; then
  echo "Error: Root CA not found. Run '$0 ca' first to generate it."
  exit 1
fi

# === DERIVED VALUES ===
DEVICE_TAILNET="${DEVICE_HOSTNAME}.${TAILNET_SUFFIX}"
DEVICE_FQDN="${DEVICE_HOSTNAME}.${LOCAL_SUFFIX}"
OUT_DIR="${BASE_DIR}/${DEVICE_HOSTNAME}"
mkdir -p "$OUT_DIR"

# === FILE PATHS ===
CONFIG_TMP="${OUT_DIR}/openssl.cnf"
KEY="${OUT_DIR}/key.pem"
CSR="${OUT_DIR}/request.csr"
CRT="${OUT_DIR}/cert.pem"
COMBINED="${OUT_DIR}/combined.pem"

# === BUILD OPENSSL CONFIG ===
DNS_INDEX=1
SAN_ENTRIES="DNS.${DNS_INDEX} = ${DEVICE_HOSTNAME}"

if $INCLUDE_LOCAL; then
  DNS_INDEX=$((DNS_INDEX + 1))
  SAN_ENTRIES="${SAN_ENTRIES}
DNS.${DNS_INDEX} = ${DEVICE_FQDN}"
fi

if $INCLUDE_TAILNET; then
  DNS_INDEX=$((DNS_INDEX + 1))
  SAN_ENTRIES="${SAN_ENTRIES}
DNS.${DNS_INDEX} = ${DEVICE_TAILNET}"
fi

if $INCLUDE_IP && [ ${#DEVICE_IPS[@]} -gt 0 ]; then
  IP_INDEX=0
  for ip in "${DEVICE_IPS[@]}"; do
    IP_INDEX=$((IP_INDEX + 1))
    SAN_ENTRIES="${SAN_ENTRIES}
IP.${IP_INDEX} = ${ip}"
  done
fi

cat > "$CONFIG_TMP" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no

[req_distinguished_name]
C = ${CA_C}
ST = ${CA_ST}
L = ${CA_L}
O = ${CA_O}
OU = Devices
CN = ${DEVICE_HOSTNAME}

[req_ext]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth

[alt_names]
${SAN_ENTRIES}
EOF

# === GENERATE KEY (ECDSA P-384) ===
openssl ecparam -name secp384r1 -genkey -noout -out "$KEY"

# === GENERATE CSR ===
openssl req -new -key "$KEY" -sha384 -out "$CSR" -config "$CONFIG_TMP"

# === SIGN CERTIFICATE ===
openssl x509 -req -in "$CSR" -CA "$ROOT_CA_CERT" -CAkey "$ROOT_CA_KEY" \
  -CAcreateserial -out "$CRT" -days 825 -sha384 \
  -extfile "$CONFIG_TMP" -extensions req_ext

# === COMBINE CERT + KEY ===
cat "$CRT" "$KEY" > "$COMBINED"

# === CLEANUP ===
rm "$CSR" "$CONFIG_TMP"
rm -f "rootCA.srl"

# === SUMMARY ===
echo ""
echo "Certificate generated for: $DEVICE_HOSTNAME"
echo "Files stored in: $OUT_DIR"
echo "SANs included:"
echo "  - $DEVICE_HOSTNAME"
if $INCLUDE_LOCAL; then
  echo "  - $DEVICE_FQDN"
fi
if $INCLUDE_TAILNET; then
  echo "  - $DEVICE_TAILNET"
fi
if $INCLUDE_IP && [ ${#DEVICE_IPS[@]} -gt 0 ]; then
  for ip in "${DEVICE_IPS[@]}"; do
    echo "  - $ip"
  done
fi
