# Proxmox VE

## Overview
Proxmox VE is the bare-metal hypervisor running on the Dell OptiPlex 9020 SFF. It manages all virtual machines and containers in the homelab.

## Installation Details
| Configuration | Value |
|---|---|
| **Version** | Proxmox VE 9.1 |
| **Hostname** | pve.leonshomelab.local |
| **IP Address** | 192.168.0.2 |
| **Web UI Port** | 8006 |
| **Filesystem** | ext4 |
| **Install Disk** | 4TB HDD (/dev/sda) |

## Network Configuration
| Interface | Role |
|---|---|
| **nic0** | Management interface (onboard NIC) |
| **nic1** | H!Fiber I350 Port 1 (OPNsense WAN) |
| **nic2** | H!Fiber I350 Port 2 (OPNsense LAN) |
| **vmbr0** | Virtual bridge (management network) |

## Post-Install Steps
- Disabled enterprise repository
- Added no-subscription community repository
- Installed proxmox-archive-keyring 4.0 to fix GPG signature errors
- Set DNS to 8.8.8.8 to resolve update issues
- Ran full system update via `apt dist-upgrade`

## Virtual Machines
| VM ID | Name | Purpose | Status |
|---|---|---|---|
| 100 | OPNsense | Firewall / Router | ✅ Running |
| 101 | Metasploitable2 | General exploitation practice | ✅ Running |

## Access
- Web UI: `https://192.168.0.2:8006`
- SSH: `ssh root@192.168.0.2`
