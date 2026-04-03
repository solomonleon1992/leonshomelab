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
sudo bash wazuh-passwords-tool.sh -u admin -p YourNewPassword1!
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
