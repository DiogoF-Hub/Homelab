#! /bin/bash
cd /home/pi/vault || exit 1
/usr/bin/docker compose up -d --force-recreate