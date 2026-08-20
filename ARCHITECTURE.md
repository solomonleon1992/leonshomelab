# Homelab Architecture

**Last verified:** 2026-08-12 · **Maintainer:** Leon · **Status:** Authoritative

This document is the single source of truth for topology, placement, and dependencies. Service READMEs describe *how to operate* a service; this describes *how the system fits together and why*. Where they conflict, this document wins.

> **Reading note:** §8 (Target State) describes changes that are **not implemented**. Everything in §1–§7 describes the lab as it actually is, verified against the live hosts on 2026-08-11 (see §9).

---

## 1. Physical Layer

| Component | Detail |
|---|---|
| Host | Dell OptiPlex 9020 SFF (refurbished) |
| CPU | Intel Core i5-4590 — **4 cores / 4 threads** (no HT) |
| RAM | 32 GB DDR3 (31 GiB usable) |
| Storage | 1 × 4 TB HDD (HGST HUS726T4, `/dev/sda`) — **no RAID, no SSD** |
| NIC | Onboard Intel + H!Fiber dual-port Intel I350 (low-profile PCIe) |
| Hypervisor | Proxmox VE 9.1, kernel 6.17.2-1-pve, ext4 + LVM-thin |

**Off-hypervisor hardware:**

| Device | Address | Role |
|---|---|---|
| Raspberry Pi 4 (4 GB, 32 GB microSD) | 192.168.0.50 | Pi-hole DNS — **deliberately not on Proxmox** (§4.1) |
| ASUS E410K laptop | 192.168.0.31 | Kali Linux, native install — attacker workstation |

### 1.1 Capacity — verified 2026-08-11

| Resource | Allocated | Physical | Notes |
|---|---:|---:|---|
| vCPU | 12 (+1 stopped) | 4 threads | **3 : 1 oversubscribed** |
| RAM | 24 GiB used | 31 GiB | **6.6 GiB available**; swap 8 GiB, 0 B used |
| Proxmox root fs | 12 GB used | 94 GB | 14% |

RAM figures are with **Metasploitable2 stopped**. Booting it adds 512 MB.

No memory pressure today (swap untouched), but headroom is thin. Wazuh (4 vCPU) and n8n (4 vCPU) alone request 8 vCPU against 4 threads — fine while both idle, contended during a concurrent OpenVAS scan and Ollama inference.

### 1.2 Storage Reality — the backup problem

| Storage | Type | Size | Used | Free |
|---|---|---:|---:|---:|
| `local` (ISOs, templates, **backups**) | dir | 94 GB | 12 GB | **77 GB** |
| `local-lvm` (VM disks) | lvmthin | 3.5 TB | 127 GB | 3.5 TB |

`local` is the documented backup target and holds **77 GB free against 127 GB of live VM data**. A full `vzdump` set does not fit — not one copy, let alone retention.

`local-lvm` has 3.5 TB idle, but **relocating backups there does not mitigate R-01**: both storages live on the same physical `/dev/sda`. A disk failure takes the VMs and the backups together. R-01 requires an *external* target.

---

## 2. Naming & Addressing

**Internal DNS zone: `leonshomelab.internal`** (migrated from `.local` — see §2.2)

### 2.1 Address Plan

| Range | Purpose | Managed by |
|---|---|---|
| `192.168.0.0/24` | Core segment — all lab hosts, workstations, household | Consumer router (`192.168.0.1`) |
| `192.168.1.0/24` | OPNsense LAN — **allocated, zero hosts attached** | OPNsense (inactive) |

| Host | IP | FQDN |
|---|---|---|
| Proxmox | 192.168.0.2 | `pve.leonshomelab.internal` |
| OPNsense (WAN) | 192.168.0.22 | `opnsense.leonshomelab.internal` |
| Metasploitable2 | 192.168.0.24 | *(none — intentional)* |
| Docker host | 192.168.0.25 | `docker.leonshomelab.internal` |
| Twingate connector | 192.168.0.26 | `twingate.leonshomelab.internal` |
| Wazuh | 192.168.0.27 | `wazuh.leonshomelab.internal` |
| n8n stack | 192.168.0.28 | `n8n.leonshomelab.internal` |
| Kali | 192.168.0.31 | *(none)* |
| Pi-hole | 192.168.0.50 | `pihole.leonshomelab.internal` |

### 2.2 Why `.internal` and not `.local`

`.local` is reserved by **RFC 6762 for multicast DNS**. Using it as a unicast DNS zone breaks or behaves unpredictably on any host running Avahi/Bonjour — macOS, iOS, Android, most desktop Linux. Windows tolerates it, which is why the original setup appeared to work.

`.internal` was **formally reserved by ICANN for private use** and will never be delegated in the global DNS root, so it can never collide with a real domain. Chosen over `home.arpa` (RFC 8375), which is scoped to residential CPE and carries DNSSEC insecure-delegation quirks.

**Trade-off accepted:** `.internal` can never obtain a publicly-trusted certificate. All TLS here is signed by the internal Caddy CA (§5.1). Moving to an owned domain would enable Let's Encrypt via DNS-01 and retire the internal CA; deferred (§7.3).

---

## 3. Network Topology

```
                        Internet
                            │
                  ┌─────────┴─────────┐
                  │  Consumer Router  │  192.168.0.1
                  │  gateway + DHCP   │  ← actual perimeter
                  └─────────┬─────────┘
                            │
        ════════════════════╪════════════════════  192.168.0.0/24  (flat, unsegmented)
          │      │      │   │    │      │      │
        ┌─┴──┐ ┌─┴──┐ ┌─┴─┐ │  ┌─┴───┐ ┌─┴──┐ ┌─┴────┐
        │Pi- │ │Kali│ │PVE│ │  │ .24 │ │ .25│ │ .27  │ ...
        │hole│ │ .31│ │ .2│ │  │ MS2 │ │Dckr│ │Wazuh │
        │ .50│ └────┘ └───┘ │  │(off)│ │Cddy│ └──────┘
        └────┘              │  └─────┘ └────┘
                            │
                       ┌────┴─────┐
                       │ OPNsense │  WAN em1 .0.22
                       │  VM 100  │
                       └────┬─────┘
                            │ LAN em0  192.168.1.1/24
                            │
                        ( no hosts )
```

### 3.1 Proxmox NIC Mapping

| Interface | Assignment |
|---|---|
| Onboard NIC | Proxmox management, bridged to `vmbr0` (192.168.0.2) |
| I350 Port 1 | Passed through to OPNsense — WAN |
| I350 Port 2 | Passed through to OPNsense — LAN (no downstream devices) |
| `vmbr0` | Bridge carrying all VM/CT traffic onto `192.168.0.0/24` |

### 3.2 Traffic Paths

All lab-to-lab traffic is **direct Layer 2 over `vmbr0`** — same subnet, no routing hop. All lab-to-internet traffic goes to the consumer router at `192.168.0.1`. **No lab traffic traverses OPNsense in either direction.**

### 3.3 OPNsense: Current Reality

> Nothing is on `192.168.1.0/24`. OPNsense's LAN interface is configured with that subnet but has no devices attached. All homelab traffic uses `192.168.0.0/24` via OPNsense's WAN interface at `192.168.0.22`. OPNsense is currently not in any traffic path — it's a VM on the same network as everything it would theoretically protect.

**Consequences, stated plainly:**

1. **OPNsense enforces nothing.** Its rules apply to traffic that never arrives. The three documented rules (block RFC1918, block bogons, allow LAN→any) are a default install guarding an empty segment.
2. **The consumer router is the actual perimeter.** Its configuration is undocumented and outside this repo (R-11).
3. **Metasploitable2 is attached to `vmbr0` with no isolation.** It is currently *stopped*, so the exposure is latent rather than active — but it rejoins the flat segment the moment it boots, alongside Proxmox management, Pi-hole, and personal workstations (R-02).
4. **No OPNsense rule can filter traffic between two `192.168.0.0/24` hosts.** Any such control must be host-level (R-05).

OPNsense is currently a **learning appliance, not a security control.** It is documented as such so no one mistakes it for enforcement.

### 3.4 OPNsense management access — corrected 2026-08-14

> **This document previously recorded the wrong cause.** It stated the web UI was unreachable because "the UI binds to LAN (`192.168.1.1`) and blocks WAN by default." That is **incorrect — OPNsense binds the GUI to all interfaces.** The claim is preserved here rather than deleted, because a plausible-sounding wrong diagnosis is exactly what sends the next person down the same dead end.

**The actual cause:** **"Block private networks" was enabled on the WAN interface.** That setting generates an implicit block rule **above every user-defined rule**, dropping all `192.168.0.0/24` traffic — ICMP included — before any pass rule was evaluated.

**The topology is inverted, and this is the key to reading this firewall's configuration.** `em1` — which OPNsense calls **WAN** — sits at `192.168.0.22/24` and faces the *trusted* home network. `em0` (**LAN**) is `192.168.1.1/24`, the isolated lab segment. The names mean the opposite of what they normally do here.

Consequently **a WAN rule permitting management access is correct in this deployment**, though it would read as a serious misconfiguration anywhere else. Anyone auditing this config without the inversion in mind will flag it as a finding. **Do not "fix" it without re-reading this section.**

**Resolved 2026-08-14:**

- "Block private networks" disabled on WAN
- Two WAN pass rules added — source `192.168.0.0/24`, destination *WAN address*, **TCP 443** and **TCP 22**
- *Permit root user login* enabled under System → Settings → Administration, then *Permit password login* disabled after key deployment — **root SSH is now key-only**
- GUI admin/root password changed and stored in Bitwarden

The Proxmox console is no longer the only administration path. Lockout recovery, and a significant gotcha about how OPNsense manages `authorized_keys`, are in §7.6.

**Management reachability is not enforcement.** §3.3 still holds — OPNsense remains outside every traffic path. This section changed how it is *administered*, not what it *protects*.

---

## 4. Service Placement

Verified against `qm list` and `docker ps` on 2026-08-11. **Proxmox VM names are given exactly as configured** — these are the identifiers any Terraform/Ansible will key on.

| VMID | Proxmox name | Services | vCPU | RAM | Disk | State |
|---|---|---|---:|---:|---:|---|
| 100 | `OPNsense` | Firewall/router — *not in path* | 2 | 2 GB | 20 GB | Running |
| 101 | `Metasploitable2` | Intentionally vulnerable target | 1 | 512 MB | 8 GB | **Stopped** |
| 102 | `Docker-Host` | See below | 2 | 4 GB | 60 GB | Running |
| 103 | `twingate-connector` (LXC) | Twingate connector | 1 | 1 GB | 3 GB | Running |
| 104 | `Wazuh-SIEM` | Manager, Indexer, Dashboard, Filebeat (4.13) | 4 | 8 GB | 50 GB | Running |
| 105 | `n8n-ai-stack` | See below | 4 | 8 GB | 64 GB | Running |

VM 101 network: `net0: e1000, bridge=vmbr0`.
CT 103 is an LXC container, so it is not returned by `qm list` (QEMU only). Confirmed running as `twingate-connector` via `pct list` on 2026-08-12.

**VM 102 — `Docker-Host` containers:**

| Container | Image | Published ports | Defined by |
|---|---|---|---|
| `caddy` | `caddy:2-alpine` | 80, 443 | `~/docker/caddy/docker-compose.yml` |
| `portainer` | `portainer/portainer-ce:latest` | **9443** (9000 exposed, *not* published) | ✅ `docker/portainer.example.yml` — **deployed from this file 2026-08-14** |
| `jellyfin` | `jellyfin/jellyfin:latest` | `network_mode: host` — binds host interfaces directly (8096 and DLNA/discovery ports). Docker reports no mappings by design; 8096 is reachable | `~/docker/jellyfin/docker-compose.yml` |
| `DVWA` | `vulnerables/web-dvwa:latest` | 8080 | ✅ `docker/dvwa.example.yml` — **deployed from this file 2026-08-14** |
| `secplus-drill` | `nginx:alpine` | 8088 | `~/secplus-drill/docker-compose.yml` |

**Two containers were started with `docker run`** and had no declarative definition. Reconstructed from `docker inspect` on 2026-08-14, then **both were recreated from those exact files** — the repo files were copied to VM 102 and md5-verified byte-identical before use, so what runs is what is committed. **R-13 resolved.**

Three things this surfaced:

- **Portainer bind-mounts `/var/run/docker.sock` read-write** — root-equivalent access to VM 102, by design. Its credentials are effectively host-root credentials (R-06).
- **DVWA has no volumes at all.** Its MySQL data lives inside the container, so `--force-recreate` is a full reset. That made adopting compose risk-free there — no data for a project-name mismatch to orphan. Portainer was the opposite case: `portainer_data` had to be declared `external: true`, and after deployment only `portainer_data` exists (no `portainer_portainer_data`), with the admin user and InstanceID retained.
- **Compose changed DVWA's network.** It now sits on `dvwa_default` (172.21.x) rather than the default bridge, which drops *direct* container-to-container access to Portainer. **This is not containment** — DVWA still reaches Portainer through the host's published port, confirmed on both `172.17.0.1:9443` and `192.168.0.25:9443`. The R-06 adjacency is narrowed, not removed; real isolation remains §7.1 / §8.

**Image versions — verified 2026-08-14.** Every image runs a floating tag (R-09); these are the versions that resolved today, not pinned guarantees.

| Container | Configured tag | Running version |
|---|---|---|
| `caddy` | `caddy:2-alpine` | **v2.11.4** |
| `jellyfin` | `jellyfin/jellyfin:latest` | **10.11.6** |
| `secplus-drill` | `nginx:alpine` | **nginx/1.31.2** |
| `portainer` | `portainer/portainer-ce:latest` | **2.39.1** — *not from an image label; read from `GET /api/status`* |
| `DVWA` | `vulnerables/web-dvwa:latest` | *no version published anywhere* |

`portainer` and `DVWA` publish no `org.opencontainers.image.version` label, so **digest pinning is the only option for both** — recorded in `docker/portainer.example.yml` and `docker/dvwa.example.yml`.

Portainer is a partial exception worth noting: the *image* carries no version, but the running service reports **2.39.1** via its unauthenticated `/api/status` endpoint. Absence of an image label does not always mean the version is undiscoverable — check the application before concluding it is.

Volumes: `caddy_caddy_data`, `caddy_caddy_config`, `portainer_data`.
Configs: `~/docker/{caddy,jellyfin,pihole}/`, `~/secplus-drill/`.
Root fs: 59 GB, 25% used.

**Caddy currently proxies exactly one service.** `~/docker/caddy/Caddyfile` in full:

```
n8n.leonshomelab.local {
    tls internal
    reverse_proxy 192.168.0.28:5678
}
```

The upstream is addressed **by IP**, so the `.internal` migration changes only the site address (§7.8). Portainer, Jellyfin, DVWA and secplus-drill are reached directly by `IP:port` and are not proxied.

`~/docker/pihole/` retains data directories from before the 2026-04-15 migration. Dead data, and it contains stale credential material — this directory must not be copied into the repo wholesale during migration.

**VM 105 — `n8n-ai-stack` containers:**

| Container | Image (as configured) | Running version | Port exposure |
|---|---|---|---|
| `n8n` | `n8nio/n8n:latest` | **2.31.4** | **5678 published on `0.0.0.0` + `[::]`** — authenticated (R-05) |
| `n8n-postgres` | `postgres:15` | **15.18** | 5432 — *not published*; compose network only |
| `ollama` | `ollama/ollama` *(no tag — defaults to `:latest`)* | **0.24.0** | 11434 — *not published* since 2026-08-14; compose network only (**R-16 mitigated**) |

Versions verified 2026-08-14; image digests recorded in `n8n-ai-agents/docker-compose.example.yml`. **All three run floating tags in production (R-09)** — these are the versions that resolved today, not guarantees.

**PostgreSQL 15.18 is restore-relevant.** The Tier 1 dump carries `\restrict` / `\unrestrict` markers that require `psql` ≥ 15.18 to load; an older 15.x fails. `postgres:15` floats *forward*, so it will not regress below 15.18 on its own — the value of pinning here is not preventing a likely failure but **recording the dump/server pairing that is known to work**, which is exactly what a rebuild on unfamiliar hardware has no other way to learn.

Stack dir: `~/n8n-stack/`. Root fs: **62 GB, 41% used, 35 GB free** — extended 2026-08-12, R-04 resolved.

Disk consumption is Docker images (13.8 GB — `ollama/ollama` 10.6 GB, `n8nio/n8n` 2.53 GB, `postgres:15` 633 MB) plus volumes (2.8 GB).

> **Superseded 2026-08-16.** This section previously read *"the PostgreSQL database is 15 MB — execution history is not a growth risk"* and *"all four workflows are `active = false`"*. **Both are now false.** The old text is quoted rather than deleted because several downstream decisions — the restore test's safety, §7.8's risk assessment — rested on them.

| | 2026-08-12 | 2026-08-16 |
|---|---|---|
| Workflows | 4, **all inactive** | **8, four active** |
| PostgreSQL | 15 MB | **35 MB** |
| Credentials | 5 | **10** |
| Executions | effectively none | **~1,200/day** |

Four **job-finder** workflows were added 2026-08-15/16 and are **active** — the first thing in this lab running unattended. `job-finder-approval` polls Telegram `getUpdates` on a 60-second schedule; that is the correct design given there is no public ingress for a Telegram webhook, and it is the source of essentially all the load.

**Execution history is a growth risk — bounded 2026-08-20.** It reached **85 MB and 7,146 executions in five days** before `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=168` and `EXECUTIONS_DATA_PRUNE_MAX_COUNT=5000` were applied. `MAX_COUNT` is the binding constraint: at ~1,400 executions/day it caps history at roughly 3.5 days, well inside the 7-day age limit. It is also excluded from the Tier 1 dump (§7.10).

> **Configured, not yet demonstrated.** As of the change, 0 executions were soft-deleted and nothing appeared in the log — n8n's pruning service starts on a delay. Confirm with `SELECT count(*) FROM execution_entity;` falling toward 5,000; until it does, this is a setting, not a result.

**Do not use `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`** (or the per-workflow `saveDataSuccessExecution: 'none'`) as a shortcut here — it leaves zombie `running` executions accumulating instead of cleaning up.

**Application state lives in a separate `jobtracker` database** on the same PostgreSQL instance (`job_matches`, `bot_state`). The source of truth for the workflows is `~/n8n-stack/job-finder/`; the workflows inside n8n's database are **build output** generated from it.

Environment variables set: `DB_TYPE`, `DB_POSTGRESDB_{HOST,DATABASE,USER,PASSWORD}`, `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`, `N8N_PROXY_HOPS`, `N8N_SECURE_COOKIE`, `WEBHOOK_URL`. **`N8N_EDITOR_BASE_URL` is not set.**

### 4.1 Why Things Run Where They Run

Each row carries a **provenance tag** recording where the rationale came from. A future maintainer needs to know which decisions were deliberate, which followed vendor defaults, and which were never really choices at all.

| Tag | Meaning |
|---|---|
| **Verified** | Confirmed against the live hosts or git history |
| **Stated** | Already recorded in a service README |
| **Confirmed** | Explicitly confirmed by the maintainer (date given in the row or change log) |
| **Consulted** | Decided after discussing tradeoffs with Claude in prior sessions; options were presented and the maintainer chose |
| **Vendor-default** | Followed the vendor's official installer or documentation |
| **Constraint** | Not a choice — imposed by how the software is distributed |

Rows tagged **Consulted** reflect decisions made after discussing tradeoffs with Claude in prior sessions. The reasoning is captured here so future maintainers understand the design rationale, not merely that a choice was made. This is deliberate documentation of a collaborative process, not a gap — an undocumented decision is far more expensive to revisit than one whose reasoning was written down.

Chat logs of the original design discussions exist and can be retrieved if any rationale needs deeper archaeology than this table provides.

| Decision | Rationale | Provenance |
|---|---|---|
| **Pi-hole on a dedicated Pi, not Docker** | DNS must survive Proxmox reboots, upgrades, and host failure. Moved off VM 102 on 2026-04-15. **The single best placement decision in this lab** — it is the only service with no dependency on `/dev/sda`. | **Verified** |
| **Kali native on a laptop, not a VM** | Full hardware access (Wi-Fi monitor mode, USB adapters) and performance during testing. | Stated |
| **OPNsense gets passed-through physical NICs** | Isolates the firewall data plane from Proxmox management, so a firewall misconfiguration cannot lock out the hypervisor. Technically sound, and it follows common Proxmox + OPNsense guidance rather than having been derived independently. Undermined only by the fact that nothing sits behind the firewall (§3.3). | Consulted |
| **Twingate as LXC, not a VM** | Followed Twingate's official install documentation. The resource argument holds regardless: 1 vCPU / 1 GB / 3 GB for a single outbound daemon, where a full VM kernel would be waste on a 4-thread host. | Consulted |
| **n8n on its own VM, not the Docker host** | Ollama's memory footprint and the AI stack's blast radius stay isolated from Jellyfin/Portainer/DVWA. Protects Terry from unrelated container churn. | Consulted |
| **Ollama retained on VM 105** | Kept deliberately (2026-08-12) despite a 10.6 GB image footprint and no currently-active workflow routing to it. **Not to be reclaimed during cleanup or IaC migration** — its presence is intentional, not orphaned. | **Confirmed** |
| **Wazuh on its own VM** | Deployed with Wazuh's official all-in-one installer, which effectively assumes ownership of the host. The 4 vCPU / 8 GB allocation comes from Wazuh's documented recommendations, not from local tuning. | Vendor-default |
| **Caddy on VM 102, not its own host** | Co-located with the existing web services. **Accepted as questionable** — it makes VM 102 a SPOF for all HTTPS access and places the TLS terminator on the same host as DVWA, an intentionally vulnerable web app. Deferred work tracked at §7.1 and §7.2. | **Confirmed** |
| **Metasploitable2 virtualized** | Distributed as a VM appliance; Proxmox snapshots enable clean state restore after exploitation exercises. | Constraint |

---

## 5. Trust, Identity & Data Flow

### 5.1 TLS / Certificate Authority

Caddy on VM 102 terminates HTTPS using its **built-in internal CA**. The root CA is generated once and persisted in the `caddy_caddy_data` volume; its root certificate is manually installed in the Windows trust store on the workstation. An exported copy of the root *certificate* is kept in the operator's home directory on VM 102 (627 B).

- Leaf certs are auto-issued and auto-renewed per hostname. **Adding or changing a hostname reuses the same root** — no trust-store re-import needed. This is what makes the `.internal` migration cheap.
- **If `caddy_caddy_data` is destroyed, a new root CA is generated and every client must re-trust it.** That volume holds a Tier-0 secret and is **not backed up** (R-03).
- The root *certificate* (not the key) is safe to publish and should be committed so other machines can trust it. It must not be placed in a directory named `certs/`, `ca/`, or `pki/` — `.gitignore` blocks those as directories, and a per-file negation cannot rescue a file inside an ignored directory.

### 5.2 DNS Resolution

Clients → Pi-hole (192.168.0.50) → Cloudflare (DNSSEC) for public names. Pi-hole holds the local A records for the `leonshomelab.internal` zone.

Proxmox and OPNsense are configured with `8.8.8.8` directly, bypassing Pi-hole — intentional, so host updates keep working when Pi-hole is down.

### 5.3 Secrets

| Secret | Location | Status |
|---|---|---|
| Service credentials | Bitwarden (cloud) | Vaultwarden self-host migration planned (§7.5) |
| `N8N_ENCRYPTION_KEY` | Compose file on VM 105; **copy in Bitwarden (2026-08-12)** | ✅ Backed up. The n8n dump is now genuinely restorable |
| PostgreSQL credentials | Set inline in the same compose file | ⚠️ Blocked from this repo by `.gitignore` policy |
| Caddy root CA key | Docker volume on VM 102 | ⚠️ Not backed up |
| Twingate access token | Consumed at connector install | — |
| Wazuh admin credentials | Bitwarden | Rotation pending (§7.6) |
| OPNsense GUI / root | Bitwarden | ✅ Changed 2026-08-14. Root SSH is **key-only** — password login disabled (§3.4) |
| SSH keys for `pihole`, `wazuh`, `opnsense` | MSI Katana | ⚠️ On a disk without full-disk encryption (R-14). Not the future Ansible key, which is separate (R-15) |

**No secret, key, token, or password belongs in this repository. Ever.**

`.gitignore` blocks compose files by default because this lab stores secrets inline in them. Commit `docker-compose.example.yml` with `${VAR}` placeholders instead.

### 5.4 Remote Access

The Twingate connector (CT 103) maintains an outbound-only tunnel; no inbound ports are opened. Resources are defined per-service in the Twingate admin panel.

**Two of six defined resources are confirmed broken** (R-07):

| Resource | Configured address | Reality |
|---|---|---|
| Pi-hole | `192.168.0.25/admin` | No Pi-hole on .25 since 2026-04-15 |
| Portainer | `192.168.0.25:9000` | Port 9000 is not published; Portainer listens on 9443 |

A `192.168.0.0/24` **full-subnet resource** is also defined, granting remote clients the entire flat segment and rendering the per-resource entries decorative.

---

## 6. Dependency Map

**"If this fails, what stops working?"**

| Component | Blast radius on failure |
|---|---|
| **`/dev/sda` (4 TB HDD)** | **Total lab loss** — all six VMs *and* the backup storage. Pi-hole and Kali survive. The only n8n dump also lives on `/dev/sda` (inside VM 105), so **no off-host backup exists → unrecoverable** |
| **Raspberry Pi / microSD** | All `.internal` resolution fails; IP access still works. **If clients have no secondary DNS, the entire household loses name resolution** |
| **Consumer router** | Internet and all inter-host connectivity |
| **VM 102 (`Docker-Host`)** | Caddy, Portainer, Jellyfin, DVWA, secplus-drill. Grows worse per service proxied (§7.2) |
| **Caddy** | HTTPS access to all proxied services; direct `IP:port` still works |
| **PostgreSQL (VM 105)** | n8n → **Terry** |
| **`N8N_ENCRYPTION_KEY`** | Terry unrecoverable — not resettable |
| **Twingate (CT 103)** | Remote access only; local access unaffected |
| **Wazuh (VM 104)** | Detection blind; no service impact |
| **OPNsense (VM 100)** | **Nothing. Zero dependents** — §3.3 restated as a graph property |
| Anthropic API / SerpAPI / Telegram | Terry — external SaaS, outside our control |

### 6.1 Risk Register

| ID | Risk | Severity | Status |
|---|---|---|---|
| R-01 | **No Tier 2 (full VM image) backups.** `local` has 77 GB free against 127 GB of VM data, and both storages share one physical disk with ~44,800 power-on hours. A disk failure loses every VM. **Tier 1 resolved 2026-08-12, extended 2026-08-14** — configuration and the n8n database (0.56 MB) replicate off-host to the MSI Katana via `scripts/Backup-Tier1.ps1`, now covering **five of six hosts** including the full OPNsense firewall config and Pi-hole's DNS records. Wazuh remains uncovered pending a sudo decision. See §7.10 | **High** | **Partially resolved 2026-08-12** — Tier 1 done, Tier 2 blocked on hardware |
| R-02 | Metasploitable2 attached to `vmbr0` with no isolation, alongside management, DNS, and workstations. Currently **stopped** — latent, not active | **Critical (latent)** | Open |
| R-03 | Caddy internal root CA **private key** is unbacked-up (Docker volume, VM 102, `/dev/sda`). Loss forces a new root CA and a trust-store re-import on every client. `N8N_ENCRYPTION_KEY` **resolved 2026-08-12** — copy stored in Bitwarden | Medium | **Downgraded 2026-08-12** — deliberately accepted, see §7.9 |
| R-04 | VM 105 root fs 82% full (5.5 GB free) on a 64 GB disk — LVM never extended past 31 GB. Disk exhaustion stops n8n and Terry | **High** | **Resolved 2026-08-12** — `lvextend`/`resize2fs` online to 62 GB; now 41% used, 35 GB free |
| R-05 | n8n `:5678` reachable from any host on the segment; **cannot be fixed by an OPNsense rule** (§3.2) — requires a host-level control | High | Open |
| R-06 | VM 102 concentrates TLS termination, media, container management, and a vulnerable web app. **Made concrete 2026-08-14:** Portainer bind-mounts `/var/run/docker.sock` **read-write**. That is by design — it is how Portainer manages containers — but write access to the Docker socket is equivalent to root on the host, so Portainer credentials are effectively VM 102 root credentials, including control of Caddy and the internal root CA private key (§5.1). DVWA sits on the same host and the same default bridge network | High | Deferred → §7.1, §7.2 |
| R-07 | Twingate full-subnet resource contradicts the per-resource model; 2 of 6 resources point at dead endpoints | High | Open |
| R-08 | Pi-hole is a single point of failure for household DNS, on a microSD card | Medium | Open |
| R-09 | **All images are `:latest`.** An unattended `docker compose pull` can move n8n off 2.31.4 without warning — but the larger problem is that a repository specifying `:latest` **cannot reproduce anything**, so no service can satisfy the §7.10 rebuild test, including n8n. **Phase-0 prerequisite for the IaC migration** (`IaC-MIGRATION.md` §4.2). Closing it requires a recorded update cadence, or unpredictable updates simply become no updates | **High** | **Partially resolved 2026-08-20** — VM 105's three images pinned **by digest** in the live stack (versions unchanged: n8n 2.31.4, PostgreSQL 15.18, Ollama 0.24.0). **Still open:** VM 102's five containers, and no update cadence recorded |
| R-10 | Stale `~/docker/pihole/docker-compose.yml` on VM 102. If started, a second DNS server would contend with the Pi | Medium | **Resolved 2026-08-11** — renamed to `.disabled` |
| R-11 | The consumer router is the real perimeter and is entirely undocumented | Medium | Open |
| R-12 | 12 vCPU allocated against 4 threads; 6.6 GiB RAM headroom | Low | Accepted |
| R-13 | **`DVWA` and `portainer` on VM 102 have no compose file** — started with `docker run`, so their configuration exists only as Docker daemon state. Nothing describes how to recreate them. Direct blocker for IaC conversion; `docker inspect` output was captured in Tier 1 backups as a stopgap | Medium | **Resolved 2026-08-14** — reconstructed into `docker/dvwa.example.yml` and `docker/portainer.example.yml`, then **both containers recreated from those exact files** (byte-identical, md5-verified). Portainer's data survived: admin-check 204, InstanceID persisted, no project-prefixed volume created |
| R-14 | Tier 1 archives hold secrets (`N8N_ENCRYPTION_KEY`, database credentials, Proxmox guest configs that may carry cloud-init passwords) on a laptop where **BitLocker is confirmed OFF** (2026-08-12: `Protection Off`, no key protectors, 931 GB decrypted). **Mitigated 2026-08-12** — archives are 7-Zip AES-256 with encrypted headers, and the backup script encrypts every run and deletes plaintext staging. Residual risk is the DPAPI-stored password and a brief staging window (§7.11) | Medium | **Mitigated 2026-08-12** |
| R-15 | **Anticipated, not yet real.** The planned Ansible control node concentrates **lab-wide root access into a single SSH key**, held on the MSI Katana where BitLocker is off (R-14). A passphrase-less key on an unencrypted disk is equivalent to storing root credentials for every host in plaintext. Logged now so the controls are in place *before* the key is created, not after | Medium | **Anticipated 2026-08-14** — Ansible not yet deployed; mandatory controls defined in `IaC-MIGRATION.md` §3.2 |
| R-16 | **Ollama API published on `0.0.0.0:11434` and `[::]:11434` with no authentication.** Verified 2026-08-14 from VM 102: TCP open, `GET /api/tags` returns **HTTP 200 in 1.5 ms** with the full model inventory, no credentials presented. Reachable from every host on the flat segment (§3.3) and from any Twingate client while the full-subnet grant stands (R-07). **The entire API is unauthenticated, not only reads** — `/api/pull` writes arbitrary models to a disk with 35 GB free, `/api/delete` removes them, `/api/generate` is unmetered inference on a 4-thread host. Same family as R-05 and fixed in the same place (§7.4), but materially worse: n8n at least authenticates. **Closed the same day** — the `ports:` mapping was removed after confirming the `ollamaApi` credential addresses the service by name | **High** | **Mitigated 2026-08-14** — refused from VM 102, still reachable from the n8n container; n8n and PostgreSQL never restarted |

---

## 7. Known Issues / Deferred Work

Tracked decisions that are understood, accepted for now, and scheduled.

### 7.1 Move DVWA off VM 102 to an isolated lab VM/container
Removes co-location of an intentionally vulnerable web application with the TLS terminator that fronts every other service. DVWA belongs with Metasploitable2 in the lab segment, not on the production Docker host. **Trigger: before the OPNsense lab segment is built (§8), so both vulnerable hosts move together.**

### 7.2 Evaluate moving Caddy to its own dedicated VM
Once **more than three services** sit behind the reverse proxy, its concentration risk outweighs the convenience of co-location. Addresses both the VM 102 SPOF and blast radius — a compromise of any other container on VM 102 currently sits on the same host as the internal CA's private key. **Trigger: 4th proxied service. Currently at 1** (n8n only), so this is not near-term.

### 7.3 Retire the internal CA in favour of an owned domain
Would enable publicly-trusted Let's Encrypt certificates via DNS-01 and eliminate the trust-store distribution problem entirely. Deferred; `.internal` is the correct choice until then (§2.2).

### 7.4 Host-level control for published ports on VM 105

Two services publish to `0.0.0.0` **and `[::]`** on the flat segment. Neither can be solved at OPNsense (§3.2) — both require a host-level control.

| Port | Service | Authenticated | Risk | State |
|---|---|---|---|---|
| `5678` | n8n editor / API | ✅ yes | R-05 | **Open** |
| `11434` | Ollama API | ❌ no | R-16 | ✅ **Closed 2026-08-14** |

#### Ollama — done

The `ports:` mapping was removed from `~/n8n-stack/docker-compose.yml` on 2026-08-14 after confirming the `ollamaApi` credential addresses the service as `http://ollama:11434` rather than by host IP. That check was the gate: one workflow references Ollama, so the mapping could not be assumed unused.

Verified after `docker compose up -d ollama`: TCP refused and HTTP `000` from VM 102, `GET http://ollama:11434/api/tags` still returning the model inventory from inside the `n8n` container, the 2.7 GB model volume intact, and `n8n` / `n8n-postgres` uptime unbroken at 2 and 3 weeks. A backup of the pre-change file is at `~/n8n-stack/docker-compose.yml.bak-20260814` on VM 105.

**Do not re-add a published port for Ollama.** Nothing outside the compose network needs to reach it.

#### n8n `:5678` — still open

**This one cannot simply be unpublished.** Caddy on VM 102 proxies to it across hosts (§4), so the port must remain reachable from `192.168.0.25`. Restrict it with `ufw` on VM 105 rather than unbinding it — allow `192.168.0.25`, deny the rest of the segment.

### 7.5 Vaultwarden self-host migration
Move off Bitwarden cloud. **Prerequisite: R-01 must be resolved first** — self-hosting a password manager without working backups converts a cloud dependency into an unrecoverable one.

### 7.6 Administrative access paths — SSH resolved 2026-08-14

All three previously "unreachable" hosts now have SSH key access. Verified by hand.

| Host | Alias | Prior belief | Verified reality |
|---|---|---|---|
| Pi-hole | `pihole` — `leon@192.168.0.50` | blocked | **Key auth already worked.** `ssh -v` confirms `publickey` with the existing ed25519 key. It was never blocked; no console or physical access was needed |
| Wazuh | `wazuh` — `leon@192.168.0.27` | blocked, console required | Password-only. Public key deployed **over SSH**, re-verified as `publickey`. No Proxmox console needed |
| OPNsense | `opnsense` — `root@192.168.0.22` | blocked | The only genuine blocker — and its recorded *cause* was also wrong (§3.4). Now key-only root SSH |

**Two of the three were never blocked in the way this document claimed.** The obstacle was assumed and never tested, and that assumption propagated into the backup design, the risk register, and the IaC roadmap, where it was promoted to "the highest-leverage item." Recorded plainly because the cost of an untested assumption is exactly the point this repository keeps making about restore procedures.

**SSH aliases on the MSI Katana** — `IaC-MIGRATION.md` Phase 1 keys its inventory against these:

```
proxmox · vm102 · n8n · pihole · wazuh · opnsense
```

**Backup access to Wazuh** is granted by an argument-pinned rule at `/etc/sudoers.d/wazuh-backup` (added 2026-08-14), covering read of `ossec.conf` and `client.keys` only. Details and the scope condition are in §7.10 and `scripts/README.md` §4.

**Still outstanding:** Wazuh admin credentials require rotation via the documented `wazuh-passwords-tool.sh` procedure; record the result in Bitwarden. The OPNsense GUI/root password was changed 2026-08-14 and is already in Bitwarden.

#### OPNsense `authorized_keys` is GUI-managed — operational gotcha

**Appending to `/root/.ssh/authorized_keys` over SSH does not persist.** Applying any change in the GUI re-runs the configuration scripts, which rewrite that file from `config.xml` and silently discard manual edits. Nothing errors; the key is simply gone.

The authoritative location is **System → Access → Users → root → Authorized keys**.

This is a hard constraint on automation. An Ansible task using `ansible.posix.authorized_key` against OPNsense will report success and then be reverted at the next GUI apply — the worst kind of failure, because it is silent and delayed. It reinforces excluding OPNsense from IaC entirely (`IaC-MIGRATION.md` §8): its state lives in one XML blob, and Ansible fights the platform instead of managing it.

#### Lockout recovery — OPNsense

If management access is lost again:

1. **Proxmox → VM 100 → Console → option 8** (Shell)
2. `pfctl -d` — disables the packet filter and reopens access
3. `configctl filter reload` — rebuilds the ruleset from saved config **and re-enables pf in one step**

**Do not use `pfctl -e`.** It re-enables pf with the previously loaded ruleset — which is the ruleset that caused the lockout.

**While pf is disabled, all filtering and NAT on that box are off.** Anything on `192.168.1.0/24` is unprotected and has no internet path, so treat this as a brief maintenance window, not a working state.

### 7.7 `WEBHOOK_URL` deprecation review
`WEBHOOK_URL` and `N8N_PROXY_HOPS` are set; `N8N_EDITOR_BASE_URL` is not. Confirm the correct configuration against the n8n 2.31.4 release notes before changing anything. `N8N_SECURE_COOKIE` can likely be removed now that access is HTTPS-only — it governs the editor session only and cannot affect Terry.

### 7.8 `.local` → `.internal` DNS migration
Decision recorded at §2.2; **not yet executed.** The hostnames in §2.1 are the target state, not the current one — live records still use `.local`.

Sequenced for zero Terry downtime. Steps 1–2 are additive and reversible:

1. Add `*.leonshomelab.internal` A records in Pi-hole **alongside** the existing `.local` records.
2. Serve both names from Caddy — a one-line change, since the upstream is addressed by IP:
   ```
   n8n.leonshomelab.internal, n8n.leonshomelab.local {
       tls internal
       reverse_proxy 192.168.0.28:5678
   }
   ```
   Caddy issues a new leaf from the same root CA; no trust-store re-import is needed.
3. Verify `https://n8n.leonshomelab.internal` loads with a trusted certificate.
4. Update `N8N_HOST` / `WEBHOOK_URL` on VM 105 and recreate the container.
5. **Execute Terry manually once and confirm the Telegram message arrives.**
6. Rename OS hostnames on `docker`, `twingate`, `opnsense`.
7. Soak two weeks, then drop the `.local` records and the second Caddy site address.

**Terry is not at risk.** It is schedule-triggered (`0 */6 * * *`, and currently deactivated — activated on demand) with entirely outbound nodes (SerpAPI, Anthropic API, Telegram send) and no webhook trigger.

> **⚠️ Revised 2026-08-16 — Terry is no longer the only thing on this host.** The safety argument above was written when four workflows existed and all were inactive. There are now **eight, four of them active**, and **`job-finder-daily` has a webhook trigger**.
>
> A webhook URL is derived from `WEBHOOK_URL` / `N8N_HOST`, so **steps 4–6 will change it.** Identify what calls that webhook and update it in the same window, or the cutover breaks it silently — the workflow stays "active" and simply stops being reached.
>
> **OAuth is *not* affected**, despite three Google OAuth2 credentials now existing (Docs, Drive, Sheets). Google rejects `.local` redirect URIs, so authorization is performed against `http://localhost:5678/rest/oauth2-credential/callback` through an SSH tunnel — which is hostname-independent. Existing refresh tokens are unaffected by a rename in any case, since a redirect URI only matters at authorization time. **Do not add OAuth re-authorization to the cutover plan; it is not needed.**

**Do not rename the Proxmox node.** Node renames touch `/etc/pve` node directories and are a known footgun. Change only its DNS record.

### 7.9 Caddy root CA key — risk accepted, not mitigated

The internal root CA private key is **deliberately not backed up** (decision 2026-08-12).

Backing up a private key means creating a second permanent copy of a Tier-0 secret — extracting it from the volume, moving it across a filesystem, storing it in a vault. That exposure is only worth paying for if the loss it prevents is expensive.

At present it is not. The root is trusted by **one client** (the Windows workstation) and fronts **one proxied service** (n8n). If the `caddy_caddy_data` volume is lost, Caddy regenerates a root automatically on next start and recovery is a single trust-store re-import — roughly five minutes of work.

**Revisit trigger:** 3 or more trusting clients, **or** 4 or more proxied services. The second condition deliberately coincides with the §7.2 trigger for relocating Caddy to its own VM — both should be reconsidered in the same pass, since a dedicated Caddy host changes where the key lives anyway.

Until then this is an accepted risk, not an outstanding task. **Do not "fix" it without re-reading this section.**

### 7.10 Backup strategy — two tiers

Backup is split by what is *irreplaceable* versus what is merely *large*. Conflating the two is why this lab had no backups for months: 127 GB looked unsolvable without hardware, so nothing got done — while the part that actually mattered was under half a megabyte.

| | **Tier 1 — configuration & data** | **Tier 2 — full VM images** |
|---|---|---|
| Size | **0.56 MB** staged → 101 KB encrypted | ~127 GB |
| Contents | n8n PostgreSQL dump, compose files, Caddyfile, Caddy root CA *certificate*, Proxmox guest configs, network config, `docker inspect` for R-13 containers, **Pi-hole `pihole.toml`, OPNsense `config.xml`** | `vzdump` of all six guests |
| Destination | **MSI Katana laptop** — genuinely separate hardware | None available |
| Mechanism | `scripts/Backup-Tier1.ps1`, scheduled daily, **7-Zip AES-256 encrypted** (§7.11) | — |
| Status | ✅ **Implemented 2026-08-12** | ❌ Blocked on hardware |

**Tier 1 mechanism.** The script pulls over SSH, validates the PostgreSQL dump (size plus the `PostgreSQL database dump complete` marker — a 0-byte dump is indistinguishable from a real one in `ls`, which is exactly how a fake backup went unnoticed from 2026-08-02 to 2026-08-12), writes a manifest recording what was captured and what was missed, and retains the last 14 runs. It refuses to run if its destination is inside the git repository.

**Tier 1 coverage — extended 2026-08-14.**

| Host | Captured |
|---|---|
| VM 105 | n8n database (**execution history excluded**, dump validated), **`jobtracker` database**, **`job-finder/` source tree**, compose file, restore harness, docker state |
| VM 102 | Caddyfile, three compose files, Caddy root CA *certificate*, `docker inspect` for the R-13 containers, docker state |
| Proxmox | qemu-server + LXC guest configs, inventory, network config |
| **Pi-hole** | **`pihole.toml`** — the local DNS A records and CNAMEs the §7.8 migration depends on — plus `dnsmasq.conf` and version/state |
| **OPNsense** | **`/conf/config.xml`** — the entire firewall in one file, XML-parse validated |
| **Wazuh** | **`ossec.conf` (manager config) and `client.keys` (agent roster)** — via a scoped sudoers rule, see below |

**All six hosts are now covered (2026-08-14).** Wazuh's config is root-only, so access comes from an **argument-pinned** sudoers rule at `/etc/sudoers.d/wazuh-backup`, granting read of exactly two files and nothing else. Verified with the credential cache cleared: both pinned reads succeed unprompted, `/etc/shadow` is refused, and appending a second path to a pinned command is refused. The script uses `sudo -n`, so removing that rule makes an unattended run **fail loudly** rather than hang on a prompt.

> **The archive now carries agent authentication material.** `client.keys` lets its holder impersonate a Wazuh agent to the manager. This is deliberate: without it, a Wazuh restore means re-enrolling every agent by hand, and §8 of `IaC-MIGRATION.md` excludes Wazuh from IaC *precisely because* its recovery is expected to come from Tier 1. **The control is the encryption, not omission** — AES-256 with the password in Bitwarden, outside the lab's failure domain. Stated in full at `scripts/README.md` §2.

**Condition attached to that scope.** `/var/ossec/etc/rules/local_rules.xml` and `decoders/local_decoder.xml` are stock and unmodified since the September 2025 install, so they are excluded on purpose. **If custom rules or decoders are ever written, the sudoers rule and the script must both be extended** — otherwise the backup silently omits exactly the work most worth keeping, and reports all-OK while doing so.

**`ossec.conf` is validated by a *wrapped* XML parse, not a plain one.** Wazuh permits multiple root-level `<ossec_config>` blocks and this install has two, so a strict parse fails on a perfectly healthy file — which would have marked every nightly run as failed. Wrapping in a synthetic root tolerates the multiple roots and still rejects truncation, verified against the real file.

**`config.xml` gets the same validation as the n8n dump** — a size floor plus an XML parse. A truncated firewall config is exactly as useless as a 0-byte database dump, and exactly as invisible in `ls`.

**Two gaps recorded rather than hidden.** Pi-hole's adlist URLs live inside `gravity.db` (63 MB, overwhelmingly regenerable blocklist content); extracting just the URLs needs `sqlite3`, absent on the Pi, and the native teleporter export needs sudo. Full VM images remain Tier 2.

**Two corrections on 2026-08-16, in opposite directions.**

The job-finder agents added 2026-08-15/16 exposed a real gap and a real waste at the same time. Their application state lives in a **separate `jobtracker` database**, which `pg_dump n8n` never touched — 359 job matches were **unbacked-up from creation**. Meanwhile the 60-second Telegram poll drove n8n's own dump from 406 KB to **39 MB in two days, 97% of it execution history** — data with no restore value at all.

So the backup was capturing 38 MB of noise daily while missing the 3.2 MB that mattered. Both were fixed together: execution *rows* are excluded (the *schema* is kept, so a restored instance works and simply starts with an empty history), and `jobtracker` plus the `job-finder/` source tree are now captured.

`~/n8n-stack/job-finder/` matters because **the workflows in n8n's database are build output** — `build.js`, `deploy.sh`, the workflow JSON and the scoring prompt exist only in that directory, not in git and not in the database.

| Run | Items | Archive |
|---|---:|---:|
| 2026-08-14 | 26 | 104 KB |
| 2026-08-16, before fix | 26 | 860 KB |
| **2026-08-16, after fix** | **29** | **670 KB** |

Verified: staging deleted, transient copies removed from both the n8n and Wazuh hosts, archive unlistable without the password.

**`jobtracker` restore verified 2026-08-16 — first test, not a re-test.** The dump was extracted from the **actual encrypted archive**, shipped to VM 105, and restored into a throwaway `jobtracker_restoretest` database. `psql` exit 0, **0 errors**, and every field matched production:

| | Production | Restored |
|---|---:|---:|
| `job_matches` rows | 359 | 359 |
| approved | 7 | 7 |
| with cover letter | 7 | 7 |
| sheet-synced | 7 | 7 |
| `bot_state` rows | 2 | 2 |
| md5 of all `cover_letter_doc_id` | `254d1a4c…` | `254d1a4c…` |

The fingerprint is the meaningful line: content identity of the field that would be most expensive to reconstruct, not merely matching row counts. Test database dropped, temp files removed from both machines, production untouched at 359 rows with `n8n-postgres` uptime unbroken at 3 weeks.

**The test found a latent bug.** In a real dump the `PostgreSQL database dump complete` marker sits at line **552 of 556** — *exactly* 5 lines from the end, because `pg_dump` 15.18 emits a trailing `\unrestrict` line after it. Both dump validations used `-Tail 5`, so **one additional trailing line from any future `pg_dump` would have reported FAIL on a healthy dump and failed the entire run, nightly**. Widened to `-Tail 20`. This is precisely the class of fault a restore test exists to surface and a passing backup never would.

**The n8n dump format change has still not been re-verified.** The 2026-08-12 test used a full dump; the current one excludes execution rows. `--exclude-table-data` preserves DDL so the risk is low, but it remains an untested assumption — folded into the quarterly re-verification due **2026-11-12**.

**Why Tier 2 is deferred, and why that is defensible.** Tier 2 requires storage hardware that does not exist, and relocating backups to `local-lvm` would not help — both storages sit on the same `/dev/sda` (§1.2).

More importantly: **the IaC migration is what makes Tier 2 optional.** A VM image backup exists to answer "how do I get this service back?" If every service can be rebuilt from this repository plus 0.42 MB of Tier 1 data, that question is already answered — without 127 GB of images. Tier 2 restores a machine; Tier 1 plus IaC restores a *system*, and does it on hardware that need not match.

That reframes the IaC work from a portfolio exercise into the lab's actual disaster-recovery strategy. Its completeness is measured by one question: **how much of this lab could be rebuilt from the repository alone?** Today that is one service — n8n — and only once its restore procedure has been executed rather than merely written.

**Recovery caveat, stated plainly.** Proxmox guest configs are reference material, not bootable images. They rebuild the *definition* of a VM, not its disk contents. Everything except n8n currently depends on documentation quality for recovery, not on captured data.

**Tier 1 is verified, not assumed (2026-08-12).** The n8n leg was tested end to end using the actual off-host artifact — VM 105 → laptop → back to VM 105 → restored into an isolated stack → credentials decrypted. `psql` exit 0, zero errors, 4 workflows, 5 credentials, and `n8n export:credentials --decrypted` exit 0. Production was untouched throughout. Procedure and results: `n8n-ai-agents/README.md` §7; harness at `~/n8n-stack/scripts/restore-verification.sh` on VM 105. **Re-verify quarterly — next due 2026-11-12.**

This makes n8n the only service in the lab with a *demonstrated* recovery path. Every other service is recoverable in theory, on the strength of documentation nobody has tested. Closing that gap is what the IaC roadmap is for.

### 7.11 Tier 1 archive encryption (R-14) — implemented

Tier 1 archives contain `N8N_ENCRYPTION_KEY`, database credentials, and Proxmox guest configs. BitLocker is **confirmed off** on the MSI Katana, and the machine runs Windows 11 Home, which does not include full BitLocker; Device Encryption depends on hardware support that gaming laptops frequently lack.

**Decision: encrypt the archive, not the disk.** This is a 0.42 MB problem, not a 931 GB one — a Windows Pro upgrade to protect half a megabyte is the wrong trade.

**Implemented 2026-08-12:**

| | |
|---|---|
| Cipher | 7-Zip AES-256, `-mhe=on` (**headers encrypted — filenames hidden, not just contents**) |
| Verified | `7z l` with a wrong password cannot even list the archive |
| Automation | `scripts/Backup-Tier1.ps1` stages to `%TEMP%`, packs, **verifies the archive opens**, then deletes the plaintext staging |
| Password | DPAPI-protected file, decryptable only by this Windows user on this machine. Master copy in Bitwarden |
| Fail-safe | The script **refuses to run** if 7-Zip or the password file is missing. It never falls back to writing plaintext |

**Why the script had to change, not just the folder.** Encrypting the existing archive by hand fixed one artifact. The scheduled task would have recreated a plaintext directory at 09:00 the next morning and every morning after — the mitigation would have silently reverted while the documentation claimed the risk was closed. **A recurring job needs the control inside the job.**

**Residual risk, stated honestly:**

1. **The password is reachable by anyone who compromises the Windows account.** DPAPI ties it to the user profile, so an offline disk thief cannot read it without the account credentials — a real improvement over plaintext — but it is not equivalent to a password that exists only in your head. Unattended automation and maximum secrecy are genuinely in tension here; this trade buys daily backups.
2. **There is a brief plaintext window** in `%TEMP%` during each run, roughly ten seconds. Unavoidable — `scp` must land files somewhere before they can be packed.
3. **7-Zip takes the password as a command-line argument**, so it is briefly visible in the process list to a local user.

> **The password must not live in Vaultwarden after the §7.5 migration.** Vaultwarden would run on the lab; if the lab is lost you need the archive to rebuild it, and its password would be locked inside the thing being rebuilt. Bitwarden cloud breaks that circle today. Any future store for this password must sit outside the lab's failure domain.

**Setup, one time:** `.\Backup-Tier1.ps1 -SetPassword`. Until this runs, the scheduled task exits non-zero and produces no backup — deliberately failing closed rather than open.

---

## 8. Target State — **NOT IMPLEMENTED**

> Nothing in this section is built. It exists to give §3.3 a direction.

**Recommended next change: isolate the vulnerable hosts, not re-architect the network.**

Create `vmbr1` (no physical uplink) bound to OPNsense's LAN interface, and move **Metasploitable2 and DVWA** onto `192.168.1.0/24` behind it. Kali reaches them through an explicit OPNsense rule.

| | Option A: OPNsense as full gateway | **Option B: isolated lab segment** ✅ |
|---|---|---|
| Work | Re-IP every host, reconfigure DHCP/DNS | Add one bridge, move two hosts |
| Risk to Terry | High — n8n re-IP, Caddy, Pi-hole records | **None** |
| Fixes R-02 | Yes | **Yes** |
| New SPOF | OPNsense becomes critical path on a failing disk | None |
| Firewall becomes real | Fully | For the segment that actually needs it |

Option B resolves the critical risk with the smallest blast radius and no exposure to Terry. Option A is a rebuild and should wait until R-01 is solved.

**Note:** neither option enables an OPNsense rule for R-05 — Caddy (.25) and n8n (.28) remain same-subnet peers. That control stays host-level regardless (§7.4).

---

## 9. Verification Method & Change Log

State in §1.1, §1.2, §4, and §5 was verified by read-only SSH queries against `pve`, `vm102`, and `n8n` on 2026-08-11 (`qm list`, `qm config`, `pvesm status`, `free`, `df`, `docker ps`, `docker volume ls`). n8n environment variables were enumerated **by name only** — no values were read or recorded.

A second read-only pass on 2026-08-12 covered VM 105 (LVM, filesystem, Docker state, PostgreSQL size, workflow inventory), VM 102 (config file discovery), and Proxmox (`pct list`, guest config enumeration). n8n environment variables remain enumerated **by name only**.

**Not yet verified:** OPNsense NIC passthrough configuration, the Pi-hole record set, and the Wazuh agent roster. **No longer blocked** — SSH key access to all three hosts was established 2026-08-14 (§7.6). These are now simply unverified rather than unreachable, and nothing prevents verifying them in the next pass.

| Date | Change |
|---|---|
| 2026-08-11 | Document created. `.local` → `.internal` decision recorded (§7.8). OPNsense traffic-path reality documented per §3.3. Live-host verification pass. Provenance tagging added to §4.1. Deferred work §7.1/§7.2 added. |
| 2026-08-11 | VM 102 follow-up: R-10 resolved (stale Pi-hole compose disabled); Jellyfin confirmed `network_mode: host`; Caddyfile read and recorded — one proxied service. |
| 2026-08-12 | **n8n restore verified end to end (§7.10)** — the off-host artifact was restored into an isolated stack and all five credentials decrypted (`export:credentials --decrypted` exit 0); production untouched. n8n becomes the first service with a demonstrated recovery path; quarterly re-verification set for 2026-11-12. **R-14 mitigated** — BitLocker confirmed off on the MSI Katana, so Tier 1 archives are encrypted instead: existing archive packed with 7-Zip AES-256 and encrypted headers (verified unlistable without the password), and `Backup-Tier1.ps1` rewritten to encrypt every run, verify the archive opens, delete plaintext staging, and refuse to run rather than fall back to plaintext. **§7.11** records the residual risks and the Vaultwarden circular-dependency warning. Google Gemini credential discovered and documented. |
| 2026-08-12 | **Tier 1 backup implemented (§7.10)** — `scripts/Backup-Tier1.ps1` replicates 0.42 MB of configuration and the n8n database off-host to the MSI Katana laptop, scheduled daily, with dump validation and a per-run manifest. **R-01 downgraded to partially resolved.** CT 103 verified as `twingate-connector` via `pct list`. **R-13 added** — `DVWA` and `portainer` have no compose file and exist only as daemon state. **R-14 added** — backup archive holds plaintext secrets on a laptop of unverified encryption status. `SERVICE-TEMPLATE.md` adopted; `n8n-ai-agents/` converted as the reference implementation with a sanitized `docker-compose.example.yml` and `.env.example`. |
| 2026-08-12 | **R-04 resolved** — VM 105 logical volume extended 31 → 62 GB online (`lvextend -l +100%FREE` / `resize2fs`), no downtime, no container restarts. **R-01 corrected:** a valid 405 KB `pg_dump` exists on VM 105; the 0-byte file is a separate failed attempt on VM 102. Verified PostgreSQL at 15 MB (execution history is not a growth risk) and 0 B Docker-reclaimable. All four n8n workflows confirmed `active = false` by design. Ollama retention confirmed as deliberate (§4.1). |
| 2026-08-14 | **`IaC-MIGRATION.md` created** — Ansible-first tooling decision with Terraform deferred to a greenfield target (importing six existing guests with no Tier 2 backup was judged the highest-consequence action available); MSI Katana + WSL as control node; conversion ordered by blast radius; and a **rebuild**-based definition of done distinct from the **restore** test n8n already passed. Scope boundary set: Wazuh, OPNsense, the Proxmox host, and Metasploitable2 are **deliberately excluded** from IaC in favour of tested restore procedures. **R-09 re-severitied Medium → High** and made a Phase-0 prerequisite — `:latest` means *no* service currently satisfies the §7.10 rebuild test, n8n included, so the reference implementation's compose example is now pinned to 2.31.4 with the host unchanged. **R-15 added (anticipated)** — the planned Ansible key concentrates lab-wide root access on a laptop without full-disk encryption; logged before the key exists so the controls precede it. **Backup schedule corrected** — `DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` disabled after the 09:00 run was skipped; sleep/wake logs show the laptop was asleep through 09:00 on both 08-13 and 08-14, so §7.10's "scheduled daily" depended on `StartWhenAvailable` catch-up. Today's run re-executed manually and verified (encrypted, staging clean). |
| 2026-08-14 | **R-09 groundwork — every running image version recorded** (§4, read-only `docker inspect` across VM 102 and VM 105). n8n confirmed still **2.31.4** with no drift since 2026-08-12. Two findings: **PostgreSQL is 15.18**, which is restore-relevant because the Tier 1 dump's `\restrict` markers require psql ≥ 15.18 — `postgres:15` floats forward and so will not regress on its own, but it does not record the known-good dump/server pairing, which is what a rebuild needs; and **Ollama's `image.version` label reads `24.04`, which is the Ubuntu base version, not the Ollama version** (actually 0.24.0) — pinning from that label would have recorded the wrong thing entirely. `portainer` and `DVWA` publish no version label at all, so digest is their only pinning option. n8n's compose example now pins all three services **by digest**. **R-09 remains open** — production still runs floating tags, nothing on any host was changed, and closing it additionally requires the update cadence at `IaC-MIGRATION.md` §4.4. |
| 2026-08-14 | **R-16 identified — Ollama API exposed unauthenticated to the whole segment.** Verified from VM 102: `GET http://192.168.0.28:11434/api/tags` returns HTTP 200 in 1.5 ms with the full model inventory and no credentials, on `0.0.0.0:11434` **and** `[::]:11434`. The entire API is open, including `/api/pull`, `/api/delete` and `/api/generate` — not only reads. **This corrects an error in `docker-compose.example.yml`**, which omitted the `ollama` `ports:` block entirely and so understated the attack surface of the reference implementation; the block is now present and annotated. §7.4 retitled from "n8n `:5678`" to cover both published ports on VM 105, with a removal procedure gated on first checking the base URL in the encrypted `ollamaApi` credential — **one workflow references Ollama**, so the mapping cannot be assumed unused. §4's VM 105 table now distinguishes published from compose-network-only ports, which it previously conflated. |
| 2026-08-14 | **R-16 mitigated the same day it was found.** Maintainer confirmed the `ollamaApi` credential reads `http://ollama:11434`, so the published mapping was unused; `ports:` removed from `~/n8n-stack/docker-compose.yml` (backup kept at `docker-compose.yml.bak-20260814`), YAML validated, and only the `ollama` container recreated. **Verified both directions** — TCP refused and HTTP `000` from VM 102, model inventory still served to the `n8n` container over the compose network, 2.7 GB model volume intact, and `n8n` / `n8n-postgres` uptime unbroken at 2 and 3 weeks. The compose example was updated a second time: it had just been corrected to *document* the exposure, and now records its removal instead, with an explicit instruction not to re-add the mapping. §7.4 split into a closed Ollama subsection and an open n8n `:5678` subsection — the latter cannot be unpublished because Caddy proxies to it from VM 102, so it needs `ufw` scoped to `192.168.0.25` instead. |
| 2026-08-14 | **R-13 partially resolved** — `DVWA` and `portainer` reconstructed from `docker inspect` into `docker/dvwa.example.yml` and `docker/portainer.example.yml`, both **pinned by digest** since neither image publishes a version label. Verified with `git check-ignore -v` that `!**/*.example.yml` rescues both, rather than assuming it. **Neither has been deployed from its file, so R-13 is not closed** — an unexecuted reconstruction is a hypothesis (`IaC-MIGRATION.md` §4.3). Two findings recorded: **Portainer bind-mounts `/var/run/docker.sock` read-write**, making its credentials root-equivalent on VM 102 and putting Caddy's internal CA key within reach of whoever holds them — R-06 updated from an abstract "concentrates" to this concrete mechanism; and **DVWA has no volumes**, so adopting compose there is risk-free while Portainer's `portainer_data` requires `external: true` or Compose starts it empty. |
| 2026-08-14 | **R-13 resolved — both reconstructions proven by deployment.** The repo files were copied to VM 102, md5-verified byte-identical, and used to recreate both containers, so what runs is what is committed. DVWA first (no volumes, nothing to lose), then Portainer. **Portainer's data survived**: only `portainer_data` exists afterwards, `GET /api/users/admin/check` returned 204 and the InstanceID persisted. Note for future verification — `portainer.db`'s checksum **does** change across a restart (BoltDB rewrites its meta page on open), so a file hash is the wrong retention test; the admin-check endpoint is the right one. Two corrections to earlier claims: **Portainer's version is 2.39.1**, readable from `/api/status` even though the image carries no version label, so "no label" does not imply "undiscoverable"; and **compose moved DVWA onto its own network**, which blocks direct container-to-container access to Portainer but **is not containment** — the published-port path remains open from `172.17.0.1:9443` and `192.168.0.25:9443`, both confirmed. Caddy, Jellyfin and secplus-drill were untouched throughout. |
| 2026-08-14 | **SSH access established to all three previously "blocked" hosts, and a recorded root cause corrected.** Verified by hand by the maintainer. **Pi-hole key auth already worked** — `ssh -v` authenticates via `publickey` with the existing ed25519 key; it was never blocked, the obstacle was assumed and never tested. **Wazuh** was password-only; the public key was deployed over SSH and re-verified, with no Proxmox console needed. **OPNsense was the only genuine blocker — and §3.3's stated cause was wrong.** The GUI does not bind only to LAN; OPNsense binds it to all interfaces. The real cause was **"Block private networks" on WAN**, which generates an implicit block rule above all user-defined rules and dropped every `192.168.0.0/24` packet, ICMP included. Fixed by disabling that setting and adding two WAN pass rules (source `192.168.0.0/24`, destination WAN address, TCP 443 and 22); root login enabled then restricted to **key-only**; GUI password changed into Bitwarden. New **§3.4** documents the **WAN/LAN inversion** — `em1`/WAN faces the trusted home network while `em0`/LAN is the isolated lab segment — because a WAN rule permitting management reads as a misconfiguration without that context. §7.6 rewritten with the access matrix, the six SSH aliases, the **GUI-managed `authorized_keys` gotcha** (manual edits are silently overwritten from `config.xml` on any GUI apply, so `ansible.posix.authorized_key` will be reverted), and a **lockout recovery procedure** (`pfctl -d`, then `configctl filter reload`; never `pfctl -e`). The prior "do not use `pfctl -d`" instruction was wrong and is reversed. Downstream claims corrected in §7.10 and §9. |
| 2026-08-14 | **Tier 1 backup extended from three hosts to five** (§7.10). `scripts/Backup-Tier1.ps1` now captures **OPNsense `/conf/config.xml`** — the entire firewall, including the WAN rules fixed earlier today, which previously existed nowhere but that VM — and **Pi-hole `pihole.toml`**, which holds the local DNS A records and CNAMEs the §7.8 migration depends on. `config.xml` is validated by size floor **and XML parse**, mirroring the n8n dump's completion-marker check: a truncated firewall config fails silently in exactly the same way. Verified run: **22/22 items, 0.56 MB staged → 101 KB encrypted**, staging deleted, archive unlistable without the password. Three implementation facts found by probing rather than assumption — OPNsense's root shell is **tcsh**, so `ssh` commands need a `/bin/sh -c` wrapper (`scp` is unaffected); Pi-hole's native `pihole-FTL --teleporter` **fails without sudo** because it must read `pihole-FTL.db`; and `sqlite3` is **not installed** on the Pi, so adlist URLs cannot be extracted from `gravity.db` without shipping 63 MB. **Wazuh remains uncovered** — SSH works but every config path is root-only with no passwordless sudo, recorded as a privilege decision (§7.6) rather than worked around. The script's stale "no SSH key access" text is gone from both its header and the per-run manifest. |
| 2026-08-14 | **Wazuh added — Tier 1 now covers all six hosts** (§7.10). Access via an **argument-pinned** sudoers rule at `/etc/sudoers.d/wazuh-backup`, granting read of `ossec.conf` and `client.keys` and nothing else; verified with the credential cache cleared that unpinned paths and appended second paths are both refused. `sudo -n` is used so removal of the rule fails the run loudly rather than hanging on a prompt. **The archive now carries agent authentication material** — `client.keys` — which is the deliberate price of restoring Wazuh without re-enrolling every agent, and the reason `IaC-MIGRATION.md` §8 can exclude Wazuh from IaC at all; the control is AES-256 plus a password held outside the lab's failure domain, stated in full in the new `scripts/README.md`. **Implementation correction:** a strict XML parse **fails on a healthy `ossec.conf`**, because Wazuh permits multiple root-level `<ossec_config>` blocks and this install has two — it would have marked every nightly run failed. Validation wraps the content in a synthetic root instead, which tolerates multiple roots and still rejects truncation (verified by chopping the real file). **Scope condition recorded:** `local_rules.xml` and `local_decoder.xml` are stock and deliberately unpinned; writing custom rules or decoders requires extending both the sudoers rule and the script, or they are omitted silently. Verified run: **26/26 items, 0.57 MB staged → 104 KB encrypted**, 2 agent entries, transient sudo copies cleaned from the Wazuh host. |
| 2026-08-20 | **VM 105 maintenance window — images pinned and execution retention bounded, in one container recreate.** Both changes had been deferred for the same reason (downtime on four active workflows), so they were spent together. All three images pinned **by digest**, verified beforehand to match what was already running — n8n 2.31.4, PostgreSQL 15.18, Ollama 0.24.0 — so this is a freeze, not a version change. Checking first mattered: pinning to a stale digest would have **downgraded n8n**, and n8n does not reverse its database migrations. Retention set to `PRUNE=true` / `MAX_AGE=168` / `PRUNE_MAX_COUNT=5000`, after execution history reached **85 MB and 7,146 rows in five days**; `MAX_COUNT` binds first at ~1,400/day. **`EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` was deliberately avoided** — it leaves zombie `running` executions. Verified after recreate: all three containers up, versions unchanged, **4 active / 4 inactive workflows intact**, `jobtracker` intact at 810 rows / 53 approved, zero errors in the n8n startup log, and the 60-second Telegram poll resumed cleanly (executions at 16:25:03 and 16:26:03, 10/10 success). **Pruning is configured but not yet demonstrated** — 0 soft-deleted at the time of the change; n8n's pruning service starts on a delay. **R-09 partially resolved:** VM 102's five containers still float and no update cadence is recorded. The repo's compose example was also corrected — it had drifted on `N8N_PROTOCOL` (`http` → `https`) and `N8N_SECURE_COOKIE` (`false` → `true`). |
| 2026-08-16 | **Four job-finder workflows added to VM 105 (by the maintainer, 08-15/16) — the first thing in this lab running unattended.** Review found one data-loss gap and one waste, fixed together (§7.10). **`jobtracker`, a separate database holding the system's actual state (359 job matches), was never backed up** — `pg_dump n8n` does not include it. Simultaneously the 60-second Telegram poll drove n8n's dump from 406 KB to **39 MB in two days, 97% execution history**, so the backup was storing 38 MB of noise daily while missing the 3.2 MB that mattered. Execution *rows* are now excluded (schema retained), and `jobtracker` plus the `~/n8n-stack/job-finder/` **source tree** — the workflows in the database are build output — are captured. Net: **29 items, 860 KB → 670 KB**, with 3.3 MB more real content. **§4 superseded** — "the database is 15 MB, execution history is not a growth risk" and "all four workflows are `active = false`" are both now false (8 workflows, 4 active, 35 MB, 10 credentials). **§7.8 revised** — `job-finder-daily` **has a webhook trigger**, so the `.internal` cutover will change its URL; a claimed-obvious OAuth risk was investigated and **found not to apply**, because Google rejects `.local` redirect URIs and authorization already runs against `localhost` through an SSH tunnel. Execution growth is excluded from backups but **still unbounded on the host** — no prune variables set. |
