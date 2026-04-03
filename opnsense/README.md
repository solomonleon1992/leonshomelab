# OPNsense Firewall

## Overview
OPNsense is a FreeBSD-based firewall and router VM running on Proxmox. It manages all network traffic between the homelab and the internet.

## VM Details
| Configuration | Value |
|---|---|
| **Version** | OPNsense 26.1.2 |
| **VM ID** | 100 |
| **CPU** | 2 cores |
| **RAM** | 2048MB |
| **Disk** | 20GB (ZFS) |
| **Install Type** | ZFS Stripe |

## Network Interfaces
| Interface | NIC | IP Address | Role |
|---|---|---|---|
| **WAN** | em1 | 192.168.0.22 (DHCP) | Internet uplink |
| **LAN** | em0 | 192.168.1.1/24 | Internal lab network |

## Initial Configuration
- Hostname: OPNsense.leonshomelab.local
- Domain: leonshomelab.local
- DNS: 8.8.8.8
- DHCP server enabled on LAN
- WAN firewall rules: Block RFC1918 + bogon networks

## Known Issues & Fixes
- Web UI not accessible from WAN by default
- Temporarily disabled firewall with `pfctl -d` to complete initial setup via WAN IP
- Re-enable firewall after setup: `pfctl -e`

## Firewall Rules Summary

| Rule | Interface | Action | Description |
|---|---|---|---|
| Block RFC1918 | WAN | Block | Prevents private IPs from entering WAN |
| Block bogons | WAN | Block | Blocks invalid/unroutable IPs |
| Allow LAN to any | LAN | Allow | Full outbound access for lab devices |
