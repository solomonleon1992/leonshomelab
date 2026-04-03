# Security Lab

## Overview
A local attack lab environment built on Proxmox VE for cybersecurity practice, penetration testing, and SOC analyst skill development. The lab follows the attack → detect → investigate workflow used by real security professionals.

## Lab Architecture
| Machine | Role | IP Address | OS |
|---|---|---|---|
| Kali Linux Laptop | Attacker | 192.168.0.31 | Kali Linux |
| Metasploitable2 | Target | 192.168.0.24 | Ubuntu 8.04 |
| Proxmox Host | Hypervisor | 192.168.0.2 | Proxmox VE 9.1 |

## Network Configuration
All lab machines operate on the `192.168.0.0/24` subnet via virtual bridge `vmbr0`.

## Deployed Vulnerable VMs
| VM | Purpose | ID | Status |
|---|---|---|---|
| Metasploitable2 | General exploitation practice | 101 | ✅ Running |
| DVWA | Web application attack practice | 102 | ✅ Running |

## Planned Additions
- Metasploitable3

## Metasploitable2 Setup
- Downloaded from SourceForge as VMware vmdk
- Converted to qcow2: `qemu-img convert`
- Imported to Proxmox: `qm importdisk`
- Attached as IDE controller (required for LVM compatibility)
- Default credentials: `msfadmin / msfadmin`

## Tools Used
| Tool | Purpose |
|---|---|
| Nmap | Network scanning and enumeration |
| Netdiscover | Host discovery |
| OpenVAS (GVM) | Vulnerability scanning |
| Metasploit Framework | Exploitation |
| Burp Suite | Web application testing |
| Wazuh | SIEM |
| DVWA | Vulnerable web app for SQLi, XSS, brute force practice |

## OpenVAS Scanning

### Install & Setup
```bash
sudo apt install gvm -y
sudo gvm-setup
```
Save the generated admin password — displayed once at end of setup.

### Starting GVM (required after every reboot)
```bash
sudo systemctl start postgresql
sudo mkdir -p /run/gvmd && sudo chown _gvm /run/gvmd
sudo systemctl start gvmd ospd-openvas
sudo mkdir -p /run/gsad && sudo chown _gvm /run/gsad
sudo systemctl start gsad
```

To persist across reboots: `sudo systemctl enable gvmd gsad ospd-openvas postgresql`

### Access
`https://127.0.0.1:9392` — login: `admin` / generated password

### Scan Results — Metasploitable2 (March 31, 2026)
- 635 total findings, multiple Critical 10.0 severity
- Key findings: dRuby RCE, Ingreslock backdoor, rexec service, OS EOL

## Attack Workflow
```
Kali (attacker) → Metasploitable2 (target) → [Phase 4] Wazuh detects → investigate
```

## Troubleshooting

### gvmd/gsad won't start after reboot
`/run/gvmd` and `/run/gsad` are wiped on reboot (tmpfs). Recreate them:
```bash
sudo mkdir -p /run/gvmd /run/gsad
sudo chown _gvm /run/gvmd /run/gsad
sudo systemctl start gvmd gsad
```

### Feed sync error / scan config not available
Feeds take 1-2 hours on first install. Wait until all four feeds show a date under **Administration > Feed Status** before scanning.

### GVM broken after hard reboot / system freeze
Full reinstall required:
```bash
sudo apt purge gvm* openvas* ospd* -y && sudo apt autoremove --purge -y
sudo rm -rf /etc/openvas /var/lib/openvas /var/lib/gvm /var/log/gvm
sudo apt install gvm -y && sudo gvm-setup
```

### System freezes during scan
GVM is resource intensive on low-RAM machines. Close all other apps before scanning. Set lid close to "Switch off display" to keep scan running.

## ⚠️ Security Warning
Metasploitable2 is intentionally vulnerable. Never expose it to the internet.
