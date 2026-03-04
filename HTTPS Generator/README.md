# HTTPS Generator

This folder contains a **tool to generate HTTPS certificates** signed by your own root Certificate Authority (CA).
It is ideal for securing services in a homelab environment, with full **Subject Alternative Name (SAN)** support, including IP addresses, `.localdomain`, and **Tailscale tailnet domains**.

The script is **self-contained** — only the single `generate_cert.sh` file is needed. It handles configuration, root CA creation, and device certificate generation.

Device certificates are **adapted for iOS compatibility**, which enforces a maximum certificate lifetime of **825 days** and requires proper SAN entries.

---

## Structure

```
HTTPS Generator/
├── README.md           # This documentation
├── generate_cert.sh    # All-in-one script
└── generator.conf      # Created on first run (not committed to git)
```

---

## Cryptography

| Component | Algorithm | Details |
|-----------|-----------|---------|
| Root CA key | ECDSA P-384 | Equivalent to ~RSA 7680-bit |
| Device key | ECDSA P-384 | Smaller and faster than RSA |
| Signature hash | SHA-384 | Matches P-384 curve strength |
| Root CA validity | 20 years (7300 days) | Long-lived to avoid re-trusting on devices |
| Device cert validity | 825 days | iOS maximum for TLS certificates |
| Root CA extensions | `basicConstraints`, `keyUsage` | Proper CA semantics |
| Device cert extensions | `keyUsage`, `extendedKeyUsage` | `digitalSignature` + `serverAuth` |

---

## Setup

### 1. First-time configuration

On first run, the script will interactively ask for your settings:

```bash
./generate_cert.sh ca
# or
./generate_cert.sh setup
```

You will be prompted for:

| Setting | Default | Notes |
|---------|---------|-------|
| Country code | `US` | 2-letter code |
| State | `Washington` | |
| City | `Washington` | |
| Organization | `Homelab` | |
| Root CA name | `Homelab Root CA` | |
| Local domain suffix | `localdomain` | e.g., `home.lan`, `local`, `internal` — leave blank to disable |
| Tailscale suffix | *(empty)* | e.g., `taile2aadd.ts.net` — leave blank to disable |

Settings are saved to `generator.conf`. Run `./generate_cert.sh setup` at any time to change them.

---

### 2. Generate the root CA

```bash
./generate_cert.sh ca
```

This creates:

* `rootCA.key` — Keep this file private and secure.
* `rootCA.pem` — This **is the root certificate** to be installed on all devices.
  * Optionally rename it to `rootCA.crt` for easier installation.
  * Valid for **20 years**.

If files already exist, the script will ask before overwriting.

---

### Installing the root certificate

* **iPhone/iPad (iOS)**

  1. Send the `rootCA.crt` file to your device.
  2. Install it via Settings > Profile Downloaded.
  3. Go to Settings > General > About > Certificate Trust Settings, and **enable full trust** for this root certificate.

* **Windows**

  1. Rename `rootCA.pem` to `rootCA.crt`.
  2. Open `certmgr.msc`.
  3. Place the certificate under **Trusted Root Certification Authorities**.

* **Other devices**
  Use their respective tools or trust settings to add the root certificate as a trusted CA.

---

### 3. Generate a device certificate

```bash
./generate_cert.sh <device-hostname> [options]
```

**Options:**

| Flag | Description |
|------|-------------|
| `--no-local` | Exclude the local domain suffix from the SAN list |
| `--no-tailnet` | Exclude the Tailscale domain from the SAN list |
| `--no-ip` | Exclude IP addresses from the SAN list |
| `--ip <x.x.x.x>` | Add an IP address to the SAN (repeatable) |

If a suffix was left empty during setup, the corresponding SAN is disabled automatically (no need for `--no-local` or `--no-tailnet`).

**Examples:**

```bash
# Basic device certificate with default SANs
./generate_cert.sh server01

# Custom domain (e.g., for local DNS records pointing to the device)
./generate_cert.sh vault.example.com --no-local --no-tailnet

# Add multiple IP addresses
./generate_cert.sh server01 --ip 192.168.1.10 --ip 10.0.0.5

# Custom domain with IP fallback
./generate_cert.sh pihole.home.lab --no-local --no-tailnet --ip 192.168.1.2

# Generate without Tailscale domain
./generate_cert.sh server01 --no-tailnet

# Hostname only, no extras
./generate_cert.sh server01 --no-local --no-tailnet
```

---

## Output

Each device gets its own folder inside `certs/`:

```
certs/<device-hostname>/
├── key.pem        # Private key (ECDSA P-384)
├── cert.pem       # Signed device certificate
├── combined.pem   # Certificate + key (useful for Caddy or Nginx)
```

---

## iOS Compatibility

* Device certificates are valid for **825 days** to comply with iOS restrictions.
* Proper SAN entries ensure HTTPS connections work without warnings.
* After adding the root certificate, **make sure to enable full trust** in the certificate settings on iOS.
* On iOS, accessing a service via its **IP address** will never show as fully verified, even if the IP is included in the certificate. This is a **security limitation of iOS**, not an issue with the script.

---

## Notes

* Always **keep your `rootCA.key` private**; if compromised, regenerate a new CA.
* Distribute `rootCA.pem` or `rootCA.crt` to all devices that need to trust your certificates.
* Re-run the script whenever you need to issue a new certificate or update SAN entries.
* If you regenerate the root CA, **all existing device certificates become untrusted** — you will need to re-trust the new root CA on every device and regenerate device certificates.
* `generator.conf` contains your settings — do not commit it if it has sensitive info.
* Requires **OpenSSL 1.1.1+** (for `-addext` support). Debian 13 and modern distros ship with OpenSSL 3.x.
