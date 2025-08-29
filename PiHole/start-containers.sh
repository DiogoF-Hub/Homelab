#! /bin/bash
cd /home/pi/pihole || exit 1
/usr/bin/docker compose up -d --force-recreate