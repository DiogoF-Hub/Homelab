#! /bin/bash
# This script runs via poduser crontab @reboot to start the Podman containers for Vaultwarden
# All output is suppressed to prevent environment variable leakage in logs

set -eu

cd /home/poduser/vault || exit 1

# 1. Wait for a default route (network up)
for i in $(seq 1 60); do
    if /usr/sbin/ip route | /bin/grep -q '^default '; then
        break
    fi
    /bin/sleep 1
done

# 2. Wait for resolv.conf to contain at least one nameserver
for i in $(seq 1 60); do
    if /bin/grep -qE '^\s*nameserver\s+[0-9.]+' /etc/resolv.conf; then
        break
    fi
    /bin/sleep 1
done

# 3. Optional: wait until DNS actually resolves
for i in $(seq 1 60); do
    if /usr/bin/getent hosts cloudflare.com >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 1
done

/usr/bin/podman-compose up -d --force-recreate