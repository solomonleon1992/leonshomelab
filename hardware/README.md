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

**NIC Purpose:** Provides dedicated WAN + LAN interfaces for OPNsense firewall VM, keeping firewall traffic completely separate from Proxmox management traffic.

## Storage Layout

| Disk | Type | Size | Usage |
|---|---|---|---|
| /dev/sda | HDD (HGST HUS726T4) | 4TB | Proxmox OS + VM/LXC storage |

- **local** — ISO images, container templates, backups
- **local-lvm** — VM disks and LXC containers (LVM-Thin)

## Notes

- HDD SMART status: Good (44,803 power on hours at time of setup)
- NIC confirmed detected in BIOS on both ports before Proxmox install
- SFF case limits GPU to low profile cards only (relevant for Phase 5 Arc A310 ECO)
- No dedicated SSD for OS — Proxmox runs directly from the 4TB HDD

