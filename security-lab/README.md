# Security Lab

## Overview
A local attack lab environment built on Proxmox VE for cybersecurity practice, penetration testing, and SOC analyst skill development. The lab follows the attack → detect → investigate workflow used by real security professionals.

## Lab Architecture
| Machine | Role | IP Address | OS |
|---|---|---|---|
| Kali Linux Laptop | Attacker | 192.168.0.31 | Kali Linux (dedicated hardware) |
| Metasploitable2 | Target | 192.168.0.24 | Ubuntu 8.04 (intentionally vulnerable) |
| Proxmox Host | Hypervisor | 192.168.0.2 | Proxmox VE 9.1 |

## Network Configuration
All lab machines operate on the `192.168.0.0/24` subnet connected via virtual bridge `vmbr0` on Proxmox.

## Deployed Vulnerable VMs
| VM | Purpose | VM ID | Status |
|---|---|---|---|
| Metasploitable2 | General exploitation practice | 101 | ✅ Running |

## Planned Additions
- Metasploitable3 — more modern vulnerabilities
- DVWA (Damn Vulnerable Web App) — web application testing
- Wazuh SIEM — log monitoring and threat detection

## Metasploitable2 Setup
- Downloaded from SourceForge as VMware vmdk
- Converted from vmdk to qcow2 using `qemu-img convert`
- Imported to Proxmox using `qm importdisk`
- Attached as IDE controller (required for LVM compatibility)
- Default credentials: `msfadmin / msfadmin`

## Attack Workflow
```
Kali Linux (192.168.0.31)
        |
        | nmap scan / enumeration
        |
        v
Metasploitable2 (192.168.0.24)
        |
        | logs generated
        v
   [Phase 4] Wazuh SIEM detects suspicious activity
        |
        v
   Investigate alerts → learn both offense and defense
```

## Tools Used
| Tool | Purpose | Location |
|---|---|---|
| Metasploit Framework | Exploitation framework | Kali Linux |
| Nmap | Network scanning and enumeration | Kali Linux |
| Burp Suite | Web application testing | Kali Linux |
| Wazuh | SIEM and log monitoring | Planned Phase 4 |

## ⚠️ Security Warning
Metasploitable2 is intentionally vulnerable. It is isolated to the local network and should never be exposed to the internet.
