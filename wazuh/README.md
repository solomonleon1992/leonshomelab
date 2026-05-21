# Wazuh SIEM

## Overview
Wazuh is an open-source security platform providing SIEM and XDR capabilities. It collects and analyzes security events from monitored endpoints, detects threats, and generates alerts for investigation.

## VM Details
| Configuration | Value |
|---|---|
| **VM ID** | 104 |
| **OS** | Ubuntu Server 22.04 LTS |
| **IP Address** | 192.168.0.27 |
| **CPU** | 4 cores |
| **RAM** | 8192 MB |
| **Disk** | 50GB (local-lvm) |
| **Hostname** | wazuh-siem |

## Components Installed
All-in-one single node deployment including:
- Wazuh Manager
- Wazuh Indexer (OpenSearch)
- Wazuh Dashboard
- Filebeat

## Installation
```bash
curl -o wazuh-install.sh https://packages.wazuh.com/4.13/wazuh-install.sh
sudo bash wazuh-install.sh -a
```
Credentials are printed at the end of setup — save immediately.

## Access
- Dashboard: `https://192.168.0.27`
- Username: `admin`
- Password: set during install (change immediately after)

## Changing Admin Password
```bash
curl -so wazuh-passwords-tool.sh https://packages.wazuh.com/4.13/wazuh-passwords-tool.sh
sudo bash wazuh-passwords-tool.sh -u admin -p <enter new password here>
sudo systemctl restart filebeat wazuh-dashboard wazuh-manager
```
Password must contain uppercase, lowercase, number, and a symbol from `.*+?-`

## Deployed Agents
| Agent | IP | OS | Status |
|---|---|---|---|
| kali-laptop | 192.168.0.31 | Kali Linux | ✅ Active |

## Planned Agents
- Docker Host (192.168.0.25)

## Active Monitoring
| Source | Purpose |
|---|---|
| Wazuh server itself | Self-monitoring, baseline alerts |
| Kali laptop | Attacker machine activity |

## Troubleshooting

### Disk Full During Install
**Symptom:** Dashboard install fails mid-way, installation cleaned message appears.
**Fix:** Expand LVM partition before reinstalling:
```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
sudo bash wazuh-install.sh -a
```

### Cannot Log Into Dashboard
**Symptom:** Correct password rejected or dashboard shows "service not responding."
**Fix:** Reset password using the passwords tool above, then restart services.

### Services Not Starting After Reboot
**Symptom:** Dashboard unreachable after VM reboot.
**Fix:**
```bash
sudo systemctl start wazuh-indexer wazuh-manager filebeat wazuh-dashboard
```
To persist on boot:
```bash
sudo systemctl enable wazuh-indexer wazuh-manager filebeat wazuh-dashboard
```

---

## Attack Simulations & Detection

### Deployed Agents
| Agent ID | Name | IP | OS | Status |
|---|---|---|---|---|
| 000 | wazuh-siem (server) | 192.168.0.27 | Ubuntu 22.04 | ✅ Active |
| 001 | kali-noel | 192.168.0.31 | Kali Linux | ⚠️ Registered but disconnected |
| 002 | leonsdocker-host | 192.168.0.25 | Ubuntu 22.04 | ✅ Active |

### Agent 002 Deployment (Docker Host)
Installed Wazuh agent 4.13.1 to match manager version.

**Installation:**
```bash
wget https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.13.1-1_amd64.deb
sudo dpkg -i wazuh-agent_4.13.1-1_amd64.deb
sudo systemctl daemon-reload
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent
```

**Configuration:**
- Manager IP: 192.168.0.27
- Agent name: leonsdocker-host
- Static IP configured in `/etc/network/interfaces`

### Completed Attack Simulations

#### Attack 1: Nmap Port Scan
**Attacker:** Kali (192.168.0.31)  
**Target:** Docker host (192.168.0.25)  
**Result:** No Wazuh detection (expected - raw network traffic not monitored by default)

#### Attack 2: SSH Brute Force (Hydra)
**Attacker:** Kali (192.168.0.31)  
**Target:** Docker host (192.168.0.25)  
**Tool:** Hydra with rockyou.txt wordlist  
**Result:** ✅ **Detected successfully**
- Rule 5710: sshd authentication failure
- Rule 5551: sshd login session opened
- Rule 5502: PAM user login failed
- Dashboard showed "sshd authentication failure" and "PAM: User login failed" alerts

#### Attack 3: Metasploit Exploitation (Samba usermap_script)
**Attacker:** Kali (192.168.0.31)  
**Target:** Metasploitable2 (192.168.0.24)  
**Exploit:** CVE-2007-2447 (Samba usermap_script command execution)  
**Result:** ✅ Root shell gained on Metasploitable2

**Note:** vsftpd backdoor (port 21) exploit failed - service not running on target.

#### Attack 4: File Integrity Monitoring
**Target:** Docker host (192.168.0.25)  
**Actions:**
- Modified `/etc/hosts` file
- Created `/tmp/.hidden_backdoor` file
**Result:** ✅ **Detected successfully**
- Rule 5402: Command execution detected
- Rule 5501: Login session opened
- Rule 5502: Privilege escalation (sudo to root)
- Dashboard showed `/usr/bin/touch /tmp/.hidden_backdoor` command execution

**Note:** FIM alerts for `/etc/hosts` delayed (scans run every 6 hours by default)

### Pending Lab Work
- [ ] Custom Wazuh rule creation
- [ ] OPNsense syslog forwarding to Wazuh
- [ ] Web-based attacks (SQL injection, XSS via DVWA)
- [ ] Fix Kali agent connectivity (Agent 001)
- [ ] Security+ portfolio documentation with screenshots

### Detection Capability Status
| Attack Type | Detection Status |
|---|---|
| SSH brute force | ✅ Working |
| Command execution | ✅ Working |
| Privilege escalation | ✅ Working |
| File integrity monitoring | ✅ Working (6hr delay) |
| Raw network scanning | ❌ Not monitored by default |
| Web attacks (SQLi, XSS) | ⏳ Pending testing |
