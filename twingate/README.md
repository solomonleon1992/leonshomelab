# Twingate Remote Access

## Overview

Twingate provides zero-trust remote access to the homelab without exposing any ports to the internet. A lightweight connector runs as an LXC container on Proxmox and maintains an outbound-only tunnel to Twingate's cloud. Remote devices connect via the Twingate client app.

## LXC Container Details

| Configuration | Value |
|---|---|
| **Container ID** | 103 |
| **Type** | LXC (Unprivileged) |
| **OS** | Ubuntu 24.04 LTS |
| **IP Address** | 192.168.0.26 |
| **CPU** | 1 core |
| **RAM** | 1024 MB |
| **Disk** | 3GB |
| **Hostname** | twingate.leonshomelab.local |

## Deployment Method

Deployed using the Offical Twingate documentation: [Twingate](https://www.twingate.com/docs/proxmox-getting-started/)

1. Open Proxmox shell
2. Run the Twingate Connector LXC script
3. Script automatically:
   - Downloads Ubuntu 24.04 template
   - Creates LXC container (CT 103)
   - Configures networking (192.168.0.26)
   - Installs Twingate connector service
4. Enter Twingate access token when prompted
5. Connector authenticates and shows Online in Twingate dashboard

## Twingate Network Configuration

| Setting | Value |
|---|---|
| **Network Name** | leonshomelab |
| **Connector Status** | ✅ Running |
| **Admin Panel** | app.twingate.com |

## Resources (Remote Access Targets)

| Resource | Address | Purpose |
|---|---|---|
| Proxmox Web UI | 192.168.0.2:8006 | Hypervisor management |
| Portainer | 192.168.0.25:9000 | Container management |
| Jellyfin | 192.168.0.25:8096 | Media streaming |
| Pi-hole | 192.168.0.25/admin | DNS management |
| OPNsense | 192.168.0.22 | Firewall management |
| Full subnet | 192.168.0.0/24 | Full homelab access |

## Client Setup

1. Install Twingate client on remote device (Windows/macOS/iOS/Android)
2. Sign in with your Twingate account
3. Connect to the network just created
4. Access homelab resources using their local IPs as if on the same network

## Security Notes

- No ports are opened on the router/firewall — Twingate uses outbound-only connections
- All traffic is encrypted end-to-end
- Access is controlled per-resource and per-user in the Twingate admin panel
- The connector itself has no inbound firewall rules required
