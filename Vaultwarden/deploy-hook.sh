# This script is a deploy hook for Certbot to copy renewed certificates to a directory where poduser can access them and restart the Caddy server.
# Real domain is being replaced by test.example.com for privacy reasons.

#!/bin/bash
set -e

echo "Certbot deploy hook triggered: $(date)" >> /var/log/certbot-deploy.log

DOMAIN="test.example.com"
SRC="/etc/letsencrypt/live/$DOMAIN"
DEST="/srv/vw-certs"
OWNER="poduser"
GROUP="poduser"

# remove old files if they exist
rm -f "$DEST/fullchain.pem" "$DEST/privkey.pem"

# copy new ones
cp "$SRC/fullchain.pem" "$DEST/fullchain.pem"
cp "$SRC/privkey.pem" "$DEST/privkey.pem"

# set owner and permissions
chown "$OWNER:$GROUP" "$DEST/fullchain.pem" "$DEST/privkey.pem"
chmod 640 "$DEST/fullchain.pem" "$DEST/privkey.pem"


cd /home/poduser/vault
sudo -u poduser /usr/bin/podman-compose restart caddy