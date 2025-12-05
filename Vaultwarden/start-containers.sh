#! /bin/bash
# This script runs via poduser crontab @reboot to start the Podman containers for Vaultwarden
# All output is suppressed to prevent environment variable leakage in logs

cd /home/poduser/vault || exit 1
/usr/bin/podman-compose up -d --force-recreate >/dev/null 2>&1