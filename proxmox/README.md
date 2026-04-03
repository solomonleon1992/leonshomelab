# Proxmox VE

## Overview

Proxmox VE is the bare-metal hypervisor running on the Dell OptiPlex 9020 SFF. It manages all virtual machines and LXC containers in the homelab.

## VM Details

| Configuration | Value |
|---|---|
| **Version** | Proxmox VE 9.1 |
| **Kernel** | 6.17.2-1-pve |
| **Hostname** | pve.leonshomelab.local |
| **IP Address** | 192.168.0.2 |
| **Web UI Port** | 8006 |
| **Filesystem** | ext4 |
| **Install Disk** | 4TB HDD (/dev/sda) |

## Network Configuration

| Interface | Role |
|---|---|
| **nic0 (onboard)** | Proxmox management (192.168.0.2) |
| **nic1 (I350 Port 1)** | OPNsense WAN passthrough |
| **nic2 (I350 Port 2)** | OPNsense LAN passthrough |
| **vmbr0** | Virtual bridge — management network |

## Post-Install Steps

- Disabled enterprise repository (requires paid subscription)
- Added no-subscription community repository
- Installed `proxmox-archive-keyring 4.0` to resolve GPG signature errors
- Set DNS to `8.8.8.8` to fix update resolution issues
- Ran full system update: `apt dist-upgrade`

## Storage Configuration

| Storage Name | Type | Usage |
|---|---|---|
| local | Directory | ISO images, CT templates, backups |
| local-lvm | LVM-Thin | VM disks, LXC containers |

## Virtual Machines & Container Inventory

| ID | Name | Purpose | OS | IP | Status |
|---|---|---|---|---|---|
| 100 | OPNsense | Firewall / Router | FreeBSD | 192.168.0.22 / 192.168.1.1 | ✅ Running |
| 101 | Metasploitable2 | General exploitation practice | Ubuntu 8.04 | 192.168.0.24 | ✅ Running |
| 102 | Docker Host | Portainer, Jellyfin, Pi-hole | Ubuntu 22.04 | 192.168.0.25 | ✅ Running |
| 103 | Twingate Connector | Remote access tunnel | Ubuntu 24.04 | 192.168.0.26 | ✅ Running |
| 104 | Wazuh SIEM | SIEM + XDR threat detection | Ubuntu 22.04 | 192.168.0.27 | ✅ Running |
