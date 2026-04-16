# Hardware

## Host Machine

| Component | Details |
|---|---|
| **Model** | Dell OptiPlex 9020 SFF |
| **CPU** | Intel Core i5-4590 @ 3.3GHz (4 cores) |
| **RAM** | 32GB DDR3 |
| **Storage** | 4TB HDD (HGST HUS726T4) |
| **Form Factor** | Small Form Factor (SFF) |
| **Condition** | Refurbished |

## Add-on Hardware

| Component | Details |
|---|---|
| **NIC** | H!Fiber Dual Port Intel I350 (Low Profile PCIe) |
| **Raspberry Pi 4 Model B** | 4GB RAM, 32GB MicroSD, Ubuntu Pi OS Lite 64-bit |
| **Sparkle Intel Arc A310 Omni View** | 4GB GDDR6, 4x HDMI, 50W TDP, Single Slot Low Profile |

**NIC Purpose:** Provides dedicated WAN + LAN interfaces for OPNsense firewall VM, keeping firewall traffic completely separate from Proxmox management traffic.

## Storage Layout

| Disk | Type | Size | Usage |
|---|---|---|---|
| /dev/sda | HDD (HGST HUS726T4) | 4TB | Proxmox OS + VM/LXC storage |

- **local** — ISO images, container templates, backups
- **local-lvm** — VM disks and LXC containers (LVM-Thin)

## Raspberry Pi 4 — Pi-hole DNS Server

| Configuration | Value |
|---|---|
| **IP Address** | 192.168.0.50 |
| **Hostname** | leonspi |
| **OS** | Raspberry Pi OS Lite 64-bit |
| **Storage** | 32GB MicroSD |
| **Power** | USB-C 5V/3A (20W charger) |
| **Purpose** | Network-wide DNS ad blocker (Pi-hole) |
| **Upstream DNS** | Cloudflare (DNSSEC) |

### Blocklists
| List | URL |
|---|---|
| Steven Black | `https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts` |
| OISD Big | `https://big.oisd.nl` |
| Hagezi Pro | `https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt` |

## Notes

- HDD SMART status: Good (44,803 power on hours at time of setup)
- NIC confirmed detected in BIOS on both ports before Proxmox install
- SFF case limits GPU to low profile cards only (relevant for Phase 5 Arc A310 ECO)
- No dedicated SSD for OS — Proxmox runs directly from the 4TB HDD

