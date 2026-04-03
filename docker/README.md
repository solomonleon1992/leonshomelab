# Docker Host

## Overview

A dedicated Ubuntu Server VM running Docker with Portainer for container management. Hosts all self-hosted services for the homelab.

## VM Details

| Configuration | Value |
|---|---|
| **VM ID** | 102 |
| **OS** | Ubuntu Server 22.04 LTS |
| **IP Address** | 192.168.0.25 |
| **CPU** | 2 cores |
| **RAM** | 4096 MB |
| **Disk** | 32GB (local-lvm) |
| **Hostname** | docker.leonshomelab.local |

## Deployed Services

| Service | Port | Purpose | Status |
|---|---|---|---|
| Portainer | 9000 | Docker container management UI | ✅ Running |
| Jellyfin | 8096 | Media server | ✅ Running |
| Pi-hole | 80 / 53 | DNS-based ad blocker + DNS server | ✅ Running |
| DVWA | 8080 | Damn Vulnerable Web App (security practice) | ✅ Running |
