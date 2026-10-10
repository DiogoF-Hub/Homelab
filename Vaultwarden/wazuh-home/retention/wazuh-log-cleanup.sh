#!/bin/bash
# wazuh-home: prune the manager's own on-disk copies of alerts and archives.
# The indexer's ISM policies (ism-delete-*.json) only cover the indices; the
# manager keeps /var/ossec/logs/{alerts,archives}/<year>/<month>/ forever.
# -mindepth 2 only matches files inside the dated folders, so the live
# alerts.json / archives.json are never touched.

# 1. Delete manager archive files older than 30 days
find /var/ossec/logs/archives -mindepth 2 -type f -mtime +30 -delete
# 2. Delete manager alert files older than 180 days
find /var/ossec/logs/alerts -mindepth 2 -type f -mtime +180 -delete
# 3. Remove empty folders left behind
find /var/ossec/logs/archives /var/ossec/logs/alerts -mindepth 1 -type d -empty -delete
