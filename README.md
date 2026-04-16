# leonshomelab
Personal homelab built on Proxmox VE for cybersecurity and self-hosting practice.

## Goals
- Cybersecurity and penetration testing practice
- Self-hosted services (Jellyfin, Pi-hole, Portainer)
- Remote access via Twingate zero-trust connector
- Network engineering with OPNsense firewall
- AI agent automation with n8n and Paperclip
- Portfolio documentation for career development

## Infrastructure Overview
| Component | Details |
|---|---|
| **Hypervisor** | Proxmox VE 9.1 |
| **Host** | Dell OptiPlex 9020 SFF |
| **CPU** | Intel Core i5-4590 @ 3.3GHz |
| **RAM** | 32GB DDR3 |
| **Storage** | 4TB HDD |
| **NIC** | H!Fiber I350 Dual Port + Onboard Intel |
| **Firewall VM** | OPNsense 26.1.2 |
| **Pi-hole DNS** | Raspberry Pi 4 (4GB) @ 192.168.0.50 |

## VM & Container Inventory
| ID | Type | Name | OS | IP | Purpose |
|---|---|---|---|---|---|
| 100 | VM | OPNsense | FreeBSD | 192.168.0.22 (WAN) / 192.168.1.1 (LAN) | Firewall / Router |
| 101 | VM | Metasploitable2 | Linux | 192.168.0.24 | Vulnerable target (security lab) |
| 102 | VM | Docker Host | Ubuntu Server 22.04 | 192.168.0.25 | Portainer, Jellyfin, DVWA |
| 103 | LXC | Twingate Connector | Ubuntu 24.04 | 192.168.0.26 | Remote access tunnel |
| 104 | VM | Wazuh SIEM | Ubuntu Server 22.04 | 192.168.0.27 | SIEM + XDR threat detection |

## Documentation Structure
- [Hardware](./hardware/README.md) - Physical hardware specs and setup
- [Proxmox](./proxmox/README.md) - Hypervisor installation and configuration
- [OPNsense](./opnsense/README.md) - Firewall setup and network configuration
- [Docker](./docker/README.md) - Container host setup and self-hosted services
- [Twingate](./twingate/README.md) - Zero-trust remote access connector setup
- [Security Lab](./security-lab/README.md) - Attack lab setup and documentation
- [Wazuh](./wazuh/README.md) - SIEM and XDR threat detection platform

## Roadmap
- [x] Phase 0 - Hardware setup
- [x] Phase 1 - Proxmox VE installation
- [x] Phase 2 - OPNsense firewall VM
- [x] Phase 3 - Docker + Jellyfin + Pi-hole + Twingate
- [x] Phase 4 - Security lab + Wazuh SIEM + Metasploitable2 + DVWA
- [ ] Phase 5 - Windows Gaming VM (Intel Arc A310 GPU + Emulation + Xbox Cloud + Sunshine/Moonlight)
- [ ] Phase 6 - AI agents with n8n + Paperclip agent orchestration
