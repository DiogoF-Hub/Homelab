# This script runs by root crontab @reboot to start the podman containers for vaultwarden
# I used sudo -u poduser because the podman-compose command must be run by the user that created the containers

#!/bin/bash
cd /home/poduser/vault || exit 1
/usr/bin/podman-compose up -d --force-recreate >/dev/null 2>&1