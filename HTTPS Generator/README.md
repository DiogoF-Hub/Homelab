# HTTPS Generator

This folder contains a **tool to generate HTTPS certificates** signed by your own root Certificate Authority (CA).
It is ideal for securing services in a homelab environment, with full **Subject Alternative Name (SAN)** support, including IP addresses, `.localdomain`, and **Tailscale tailnet domains**.

The script and configuration are **adapted for iOS compatibility**, which enforces a maximum certificate lifetime of **825 days** and requires proper SAN entries.

---

## 📂 Structure

```
HTTPS Generator/
├── README.md           # This documentation
├── generate_cert.sh    # Script to generate device certificates
└── openssl.cnf         # Template configuration used by the script
```

---

## ⚙️ Setup

### **1. Generate the root CA**

Run these commands once to create your **root private key** and **self-signed root certificate**:

```bash
# 1. Generate the private key
openssl genrsa -out rootCA.key 2048

# 2. Generate the self-signed certificate
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 -out rootCA.pem \
  -subj "/C=US/ST=Washington/L=Washington/O=Homelab/OU=RootCA/CN=Homelab Root CA"
```

* `rootCA.key` → Keep this file private and secure.
* `rootCA.pem` → This **is the root certificate** to be installed on all devices.

  * Optionally rename it to `rootCA.crt` for easier installation.
  * This root certificate is valid for **10 years**.

---

### **Installing the root certificate**

* **iPhone/iPad (iOS)**

  1. Send the `rootCA.crt` file to your device.
  2. Install it via Settings → Profile Downloaded.
  3. Go to Settings → General → About → Certificate Trust Settings, and **enable full trust** for this root certificate.

* **Windows**

  1. Rename `rootCA.pem` to `rootCA.crt`.
  2. Open `certmgr.msc`.
  3. Place the certificate under **Trusted Root Certification Authorities**.

* **Other devices**
  Use their respective tools or trust settings to add the root certificate as a trusted CA.

---

### **2. Adjust Tailscale suffix**

By default, the script uses:

```
TAILNET_SUFFIX="taile2aadd.ts.net"
```

If your tailnet has a different suffix or you don’t use Tailscale, update the variable in `generate_cert.sh`.

---

### **3. Generate a device certificate**

Run the script:

```bash
./generate_cert.sh <device-hostname> [options]
```

**Options:**

* `--no-tailnet` → Exclude the Tailscale domain from the SAN list.
* `--no-ip` → Exclude IP addresses.
* `--ip <x.x.x.x>` → Add one or more IP addresses to the SAN.

**Examples:**

```bash
# Basic device certificate with default SANs
./generate_cert.sh server01

# Add multiple IP addresses
./generate_cert.sh server01 --ip 192.168.1.10 --ip 10.0.0.5

# Generate without tailnet
./generate_cert.sh server01 --no-tailnet
```

---

## 📁 Output

Each device will get its own folder inside `certs/`:

```
certs/<device-hostname>/
├── key.pem        # Private key
├── cert.pem       # Signed device certificate
├── combined.pem   # Certificate + key (useful for Caddy or Nginx)
```

---

## 🛠 Configuration (`openssl.cnf`)

The `openssl.cnf` file is used as a template:

* Automatically updated with the device hostname and SANs by the script.
* Supports `.local`, `.localdomain`, and `.tsnet` domains.
* IP addresses can also be added dynamically via the `--ip` option.

---

## 📱 iOS Compatibility

* Device certificates are valid for **825 days** to comply with iOS restrictions.
* Proper SAN entries ensure HTTPS connections work without warnings.
* After adding the root certificate, **make sure to enable full trust** in the certificate settings on iOS.
* On iOS, accessing a service via its **IP address** will never show as fully verified, even if the IP is included in the certificate. This is a **security limitation of iOS**, not an issue with the script.

---

## 🔒 Notes

* Always **keep your `rootCA.key` private**; if compromised, regenerate a new CA.
* Distribute `rootCA.pem` or `rootCA.crt` to all devices that need to trust your certificates.
* Re-run the script whenever you need to issue a new certificate or update SAN entries.
