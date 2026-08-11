# Homelab Architecture

**Last verified:** 2026-08-11 · **Maintainer:** Leon · **Status:** Authoritative

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

**A practical symptom:** the OPNsense web UI is unreachable from the workstation. That is not a fault — the UI binds to LAN (`192.168.1.1`) and blocks WAN by default, and the workstation sits on the WAN side. Administer it via **Proxmox → VM 100 → Console**. Do not use `pfctl -d`.

OPNsense is currently a **learning appliance, not a security control.** It is documented as such so no one mistakes it for enforcement.

---

## 4. Service Placement

Verified against `qm list` and `docker ps` on 2026-08-11. **Proxmox VM names are given exactly as configured** — these are the identifiers any Terraform/Ansible will key on.

| VMID | Proxmox name | Services | vCPU | RAM | Disk | State |
|---|---|---|---:|---:|---:|---|
| 100 | `OPNsense` | Firewall/router — *not in path* | 2 | 2 GB | 20 GB | Running |
| 101 | `Metasploitable2` | Intentionally vulnerable target | 1 | 512 MB | 8 GB | **Stopped** |
| 102 | `Docker-Host` | See below | 2 | 4 GB | 60 GB | Running |
| 103 | *(LXC — unconfirmed)* | Twingate connector | 1 | 1 GB | 3 GB | Assumed running |
| 104 | `Wazuh-SIEM` | Manager, Indexer, Dashboard, Filebeat (4.13) | 4 | 8 GB | 50 GB | Running |
| 105 | `n8n-ai-stack` | See below | 4 | 8 GB | 64 GB | Running |

VM 101 network: `net0: e1000, bridge=vmbr0`.
CT 103 was not returned by `qm list` (QEMU only) — confirm with `pct list`.

**VM 102 — `Docker-Host` containers:**

| Container | Image | Published ports |
|---|---|---|
| `caddy` | `caddy:2-alpine` | 80, 443 |
| `portainer` | `portainer/portainer-ce:latest` | **9443** (9000 exposed, *not* published) |
| `jellyfin` | `jellyfin/jellyfin:latest` | `network_mode: host` — binds host interfaces directly (8096 and DLNA/discovery ports). Docker reports no mappings by design; 8096 is reachable |
| `DVWA` | `vulnerables/web-dvwa:latest` | 8080 |
| `secplus-drill` | `nginx:alpine` | 8088 |

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

| Container | Image | Port |
|---|---|---|
| `n8n` | `n8nio/n8n:latest` — **running 2.31.4** | 5678 |
| `n8n-postgres` | `postgres:15` | 5432 |
| `ollama` | `ollama/ollama` | 11434 |

Stack dir: `~/n8n-stack/`. Root fs: **31 GB, 82% used, 5.5 GB free (R-04)**.

Environment variables set: `DB_TYPE`, `DB_POSTGRESDB_{HOST,DATABASE,USER,PASSWORD}`, `N8N_ENCRYPTION_KEY`, `N8N_HOST`, `N8N_PORT`, `N8N_PROTOCOL`, `N8N_PROXY_HOPS`, `N8N_SECURE_COOKIE`, `WEBHOOK_URL`. **`N8N_EDITOR_BASE_URL` is not set.**

### 4.1 Why Things Run Where They Run

Each row carries a **provenance tag** recording where the rationale came from. A future maintainer needs to know which decisions were deliberate, which followed vendor defaults, and which were never really choices at all.

| Tag | Meaning |
|---|---|
| **Verified** | Confirmed against the live hosts or git history |
| **Stated** | Already recorded in a service README |
| **Confirmed** | Explicitly confirmed by the maintainer on 2026-08-11 |
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
| `N8N_ENCRYPTION_KEY` | Set inline in the stack's compose file on VM 105 | ⚠️ **Not backed up.** Loss = every n8n credential unrecoverable |
| PostgreSQL credentials | Set inline in the same compose file | ⚠️ Blocked from this repo by `.gitignore` policy |
| Caddy root CA key | Docker volume on VM 102 | ⚠️ Not backed up |
| Twingate access token | Consumed at connector install | — |
| Wazuh admin credentials | Bitwarden | Rotation pending (§7.6) |

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
| **`/dev/sda` (4 TB HDD)** | **Total lab loss** — all six VMs *and* the backup storage. Pi-hole and Kali survive. No working backups exist → unrecoverable |
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
| R-01 | **No working backups.** No job configured; the one attempt (`n8n-backup-20260802.sql`, VM 102) is **0 bytes**; the documented target `local` has 77 GB free vs 127 GB of VM data; both storages share one physical disk with ~44,800 power-on hours | **Critical** | Open |
| R-02 | Metasploitable2 attached to `vmbr0` with no isolation, alongside management, DNS, and workstations. Currently **stopped** — latent, not active | **Critical (latent)** | Open |
| R-03 | `N8N_ENCRYPTION_KEY` and the Caddy root CA key are unbacked-up; loss of either is unrecoverable | **Critical** | Open |
| R-04 | **VM 105 root fs 82% full (5.5 GB free) on a 64 GB disk** — LVM never extended past 31 GB. Disk exhaustion stops n8n and Terry | **High** | Open |
| R-05 | n8n `:5678` reachable from any host on the segment; **cannot be fixed by an OPNsense rule** (§3.2) — requires a host-level control | High | Open |
| R-06 | VM 102 concentrates TLS termination, media, container management, and a vulnerable web app | High | Deferred → §7.1, §7.2 |
| R-07 | Twingate full-subnet resource contradicts the per-resource model; 2 of 6 resources point at dead endpoints | High | Open |
| R-08 | Pi-hole is a single point of failure for household DNS, on a microSD card | Medium | Open |
| R-09 | All images pinned to `:latest` — an unattended `docker compose pull` can move n8n off 2.31.4 without warning | Medium | Open |
| R-10 | Stale `~/docker/pihole/docker-compose.yml` on VM 102. If started, a second DNS server would contend with the Pi | Medium | **Resolved 2026-08-11** — renamed to `.disabled` |
| R-11 | The consumer router is the real perimeter and is entirely undocumented | Medium | Open |
| R-12 | 12 vCPU allocated against 4 threads; 6.6 GiB RAM headroom | Low | Accepted |

---

## 7. Known Issues / Deferred Work

Tracked decisions that are understood, accepted for now, and scheduled.

### 7.1 Move DVWA off VM 102 to an isolated lab VM/container
Removes co-location of an intentionally vulnerable web application with the TLS terminator that fronts every other service. DVWA belongs with Metasploitable2 in the lab segment, not on the production Docker host. **Trigger: before the OPNsense lab segment is built (§8), so both vulnerable hosts move together.**

### 7.2 Evaluate moving Caddy to its own dedicated VM
Once **more than three services** sit behind the reverse proxy, its concentration risk outweighs the convenience of co-location. Addresses both the VM 102 SPOF and blast radius — a compromise of any other container on VM 102 currently sits on the same host as the internal CA's private key. **Trigger: 4th proxied service. Currently at 1** (n8n only), so this is not near-term.

### 7.3 Retire the internal CA in favour of an owned domain
Would enable publicly-trusted Let's Encrypt certificates via DNS-01 and eliminate the trust-store distribution problem entirely. Deferred; `.internal` is the correct choice until then (§2.2).

### 7.4 Host-level control for n8n `:5678`
Bind the published port to the Docker bridge or restrict with `ufw` on VM 105. Cannot be solved at OPNsense (§3.2, R-05).

### 7.5 Vaultwarden self-host migration
Move off Bitwarden cloud. **Prerequisite: R-01 must be resolved first** — self-hosting a password manager without working backups converts a cloud dependency into an unrecoverable one.

### 7.6 Administrative access paths for Wazuh and OPNsense
Wazuh admin credentials require rotation — use the documented `wazuh-passwords-tool.sh` procedure, run from the Proxmox console. OPNsense is administered from the Proxmox console rather than over the network, which is a direct consequence of §3.3. Both are console-first by design; record the resulting credentials in Bitwarden.

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

**Terry is not at risk.** It is schedule-triggered (`0 */6 * * *`) with entirely outbound nodes (SerpAPI, Anthropic API, Telegram send), has no webhook trigger, and uses no OAuth credentials — so no redirect URI depends on the hostname. Only editor access is affected.

**Do not rename the Proxmox node.** Node renames touch `/etc/pve` node directories and are a known footgun. Change only its DNS record.

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

**Not yet verified:** CT 103 (needs `pct list`), OPNsense NIC passthrough configuration, the Pi-hole record set, and the Wazuh agent roster.

| Date | Change |
|---|---|
| 2026-08-11 | Document created. `.local` → `.internal` decision recorded (§7.8). OPNsense traffic-path reality documented per §3.3. Live-host verification pass. Provenance tagging added to §4.1. Deferred work §7.1/§7.2 added. |
| 2026-08-11 | VM 102 follow-up: R-10 resolved (stale Pi-hole compose disabled); Jellyfin confirmed `network_mode: host`; Caddyfile read and recorded — one proxied service. |
