# Infrastructure as Code — Migration Roadmap

**Status:** Plan · **Created:** 2026-08-14 · **Maintainer:** Leon

This document defines *what* gets converted to code, *in what order*, and *how you know a service is done*. It is a plan, not a record — nothing described here is implemented unless a change-log entry in §11 says so.

`ARCHITECTURE.md` remains authoritative for topology and risk. This document is subordinate to it.

---

## 1. Why This Exists

This is not a portfolio exercise. Per `ARCHITECTURE.md` §7.10, the IaC migration **is** the lab's disaster-recovery strategy:

> Tier 2 requires storage hardware that does not exist. But a VM image backup exists to answer "how do I get this service back?" If every service can be rebuilt from this repository plus 0.42 MB of Tier 1 data, that question is already answered — without 127 GB of images.

So completeness is measured by exactly one question:

> **How much of this lab could be rebuilt from the repository alone?**

### 1.1 Current score — 2026-08-14

| Service | Documented | Reproducible | Rebuild tested |
|---|---|---|---|
| n8n stack | ✅ | ❌ — `:latest` | ❌ *(restore ≠ rebuild, see below)* |
| Caddy | ⚠️ Caddyfile recorded | ❌ | ❌ |
| Jellyfin | ⚠️ | ❌ | ❌ |
| `secplus-drill` | ⚠️ | ❌ | ❌ |
| DVWA | ❌ no compose (R-13) | ❌ | ❌ |
| Portainer | ❌ no compose (R-13) | ❌ | ❌ |
| Pi-hole | ⚠️ | ❌ | ❌ |
| Wazuh | ⚠️ | — out of scope (§8) | — |
| OPNsense | ⚠️ | — out of scope (§8) | — |

**Honest score: zero services are reproducible today.** Including n8n.

That contradicts §7.10's claim that n8n is "the only service with a demonstrated recovery path" — and both statements are true, because they measure different things:

- **Restore** = bring back *this* instance from *its* data. n8n passes; verified 2026-08-12.
- **Rebuild** = construct a working instance from the repository, on hardware that need not match. n8n fails.

n8n fails the rebuild test for one reason: `image: n8nio/n8n:latest`. Rebuilding tomorrow yields whatever `latest` resolves to, not 2.31.4. See §4.2.

---

## 2. Tooling Decision — Ansible First, Terraform Later

**Decision (2026-08-14): adopt Ansible for configuration. Defer Terraform.**

### 2.1 Why not Terraform first

Terraform's value is *provisioning* — creating VMs that do not yet exist. Every VM in this lab already exists and changes rarely. Adopting Terraform against running infrastructure requires `terraform import` for six guests, after which a malformed plan can destroy them.

**There is no Tier 2 backup** (`ARCHITECTURE.md` R-01). Importing Terry into a Terraform state file, with no VM image to restore from, is the single highest-consequence action available in this project. The reward — declarative management of VMs that are not being created or destroyed — does not justify it.

### 2.2 Why Ansible

| | Terraform | Ansible |
|---|---|---|
| State file | Yes — drift and corruption are failure modes | **None** |
| Destroy verb | Yes | **No** |
| Onboarding existing hosts | `import`, high risk | **Runs against them as-is** |
| Answers "rebuild service X" | Indirectly | **Directly — it is a playbook run** |
| Failure mode | Can delete a VM | Converges wrong config; recoverable |

Ansible is additive and idempotent against hosts that already exist. That matches the actual problem.

### 2.3 The portfolio tension, stated plainly

`README.md` lists portfolio value as an explicit goal, and Terraform is the stronger résumé line. This is a genuine trade-off, not one to pretend away.

**Resolution:** adopt Terraform later on a *greenfield* target — a throwaway VM created from scratch, where nothing is imported and destroy risk is zero. The skill is demonstrated; Terry is never wagered on it. Sequenced at §7.

---

## 3. Control Node

**Decision (2026-08-14): Ansible runs from the MSI Katana laptop under WSL.**

WSL is **not currently installed** (verified 2026-08-14, `wsl --status` → 50). Installing it is a prerequisite, not a blocker: `wsl --install` plus one reboot.

### 3.1 Why the Katana

| | **MSI Katana + WSL** ✅ | Kali laptop (.31) | LXC on Proxmox |
|---|---|---|---|
| Survives `/dev/sda` loss | ✅ | ✅ | ❌ **dies with the lab** |
| Holds Tier 1 archives | ✅ | ❌ | ❌ |
| Reliably powered on | ✅ daily driver | ❌ intermittent | ✅ |
| Setup cost | WSL install + reboot | `apt install ansible` | container build |
| Role separation | clean | mixes red-team with infra admin | clean |

**The deciding argument:** the machine that holds the backups should be the machine that can rebuild from them. Splitting recovery data and recovery tooling across two laptops means a real recovery needs both to be working, which doubles the number of things that must survive.

An LXC on Proxmox is disqualified outright — a control node inside the failure domain it exists to recover is not a recovery tool.

### 3.2 The SSH key problem this creates — read before Phase 1

Ansible requires SSH access to every managed host, typically with `become` privileges. That concentrates **lab-wide root access into one private key**, and that key would live on a laptop where **BitLocker is confirmed off** (`ARCHITECTURE.md` R-14).

This is a new risk created by this migration, not an existing one. Mandatory controls before any key is distributed:

1. **The Ansible SSH key must have a passphrase.** A bare key on an unencrypted disk is equivalent to leaving root credentials for the entire lab in a plaintext file.
2. **Use `ssh-agent`** so the passphrase is entered once per session, not stored.
3. **Passphrase master copy in Bitwarden**, subject to the same Vaultwarden exclusion as the backup password (`ARCHITECTURE.md` §7.11).
4. **This key must be distinct** from any key already used for interactive admin, so it can be rotated independently.

Tracked as **R-15** in `ARCHITECTURE.md`.

---

## 4. Phase 0 — Blockers

**No IaC is written until these are closed.** Each one makes downstream work either impossible or wrong.

### 4.1 SSH key access — Pi-hole, Wazuh, OPNsense

Ansible is SSH-based. Without keys, these three hosts cannot be managed, verified, or backed up.

Already blocking: 3 Tier 1 backup sources (§7.10), Wazuh credential rotation (§7.6), the `.local` → `.internal` cutover (§7.8), and three "not yet verified" items in §9 — all references to `ARCHITECTURE.md`.

**This is the highest-leverage item in the entire roadmap** — it is the only one that unblocks work in four other places.

*OPNsense caveat:* FreeBSD with a locked-down default shell. Enable SSH with key auth from the Proxmox console (`ARCHITECTURE.md` §3.3 — it is not reachable over the network from the workstation).

### 4.2 Pin every image tag — R-09

Currently every image in the lab is `:latest`. **A repository that specifies `:latest` cannot reproduce anything**, which makes the §1 measure of done unachievable for every service simultaneously.

This is why R-09 is promoted from *Medium / Open* to **High / Phase-0 prerequisite**. It was previously framed as "an unattended `docker compose pull` could move n8n off 2.31.4." The real problem is larger: the repo cannot state what it builds.

Procedure per image — record the running version, then pin it:

```bash
docker inspect --format '{{.Config.Image}} {{index .Config.Labels "org.opencontainers.image.version"}}' <container>
docker image inspect --format '{{index .RepoDigests 0}}' <image>
```

Tag pinning (`n8nio/n8n:2.31.4`) is the working minimum. Digest pinning (`@sha256:…`) is stricter and immutable; use it for anything where a re-tagged upstream would be a security concern.

**Known today:** n8n is **2.31.4** (verified 2026-08-12). `postgres:15` and `ollama/ollama:latest` exact versions are **not yet recorded** — do not guess them; read them from the host.

### 4.3 Reconstruct DVWA and Portainer compose files — R-13

Both were started with `docker run`; their configuration exists only as Docker daemon state. Source material is the `docker inspect` output already captured in every Tier 1 archive.

Convert to `docker-compose.example.yml` per `SERVICE-TEMPLATE.md`, then **redeploy from the compose file** to prove the reconstruction is accurate. A compose file that has never been used to start the container is a guess.

### 4.4 Accept the patching obligation this creates

Pinning versions means images stop updating on their own. That is the point — but it converts a silent-drift risk into a **silent-staleness** risk, which is not automatically better.

Pinning is only complete when paired with a deliberate update cadence: monthly, review upstream releases, bump the pin in the repo, redeploy. **Do not close R-09 without recording that cadence** — otherwise the lab trades unpredictable updates for no updates, and DVWA aside, nothing here should run indefinitely unpatched.

---

## 5. Phase 1 — Control Node and Inventory

1. `wsl --install` on the Katana; reboot; install Ansible in the distro.
2. Generate the dedicated, **passphrase-protected** Ansible key (§3.2). Distribute public keys to all managed hosts.
3. Create `ansible/inventory.yml` keyed on the **exact Proxmox guest names** in `ARCHITECTURE.md` §4 — `OPNsense`, `Metasploitable2`, `Docker-Host`, `twingate-connector`, `Wazuh-SIEM`, `n8n-ai-stack`. Do not invent new names; the architecture document is authoritative and any automation must key on the same identifiers.
4. Verify with a read-only fact-gathering run against every host before writing a single task:
   ```bash
   ansible all -m ansible.builtin.setup --tree /tmp/facts
   ```
   This proves connectivity and privilege without changing anything.
5. Commit `ansible/inventory.example.yml` — sanitized, per the `.example` convention.

**Exit criterion:** every in-scope host answers a fact-gathering run. No configuration has been changed yet.

---

## 6. Phase 2 — Conversion Order

Ordered by blast radius, cheapest first. The point of the early entries is to be *wrong* somewhere harmless.

| # | Service | Host | Why in this position |
|---|---|---|---|
| 1 | `secplus-drill` | VM 102 | `nginx:alpine`, one port, zero dependents. Proves the whole pattern where failure costs nothing |
| 2 | DVWA + Portainer | VM 102 | Closes R-13; both need compose files regardless. DVWA has no dependents |
| 3 | Jellyfin | VM 102 | `network_mode: host` and media paths add real complexity. Failure means no TV, not data loss |
| 4 | Caddy | VM 102 | Holds the internal root CA volume and fronts n8n. **`caddy_caddy_data` must survive** — see §6.1 |
| 5 | Pi-hole | Pi (.50) | Household DNS. An outage affects people who did not opt into this lab |
| 6 | n8n stack | VM 105 | Already restore-tested, so codifying is comparatively low-risk — but it is Terry, so it goes last |

### 6.1 Standing constraints during conversion

- **Never `docker compose down -v` on a production stack.** The `-v` flag destroys named volumes. This is how `caddy_caddy_data` (root CA private key) or `n8n-stack_postgres_data` (Terry) would be lost, and neither has a Tier 2 backup.
- **Compose project names are load-bearing.** Volumes are prefixed by project name. Renaming a directory silently creates *new empty volumes* and the stack returns with no data — documented in `n8n-ai-agents/docker-compose.example.yml`.
- **Run a Tier 1 backup before touching any service**, and confirm the archive was written.
- **Terry must not break.** n8n's workflows are `active = false` by design (`ARCHITECTURE.md` §4). Convert with the stack deactivated, and confirm a manual Terry execution delivers a Telegram message before calling it done.

---

## 7. Phase 3 — Terraform, Greenfield Only

After Phase 2, provision **one new VM from nothing** with the `bpg/proxmox` provider. No `import`, no existing guest under management. This demonstrates the skill against a target whose destruction costs nothing.

Reconsider Terraform for existing guests only once Tier 2 backups exist (R-01 fully resolved).

---

## 8. Scope Boundary — What Stays Manual

**Not everything should be IaC. Knowing where to stop is part of the design.**

| Excluded | Reason | What is required instead |
|---|---|---|
| **Wazuh (VM 104)** | Deployed via the official all-in-one installer, which assumes ownership of the host (`ARCHITECTURE.md` §4.1). Automating it means reverse-engineering a vendor installer for a single-instance service | Config + agent roster in Tier 1; a written, **tested** restore procedure |
| **OPNsense (VM 100)** | Configuration is a single XML blob with a native backup/restore path. Ansible adds nothing | Export `config.xml` into Tier 1; test the import path |
| **Proxmox host itself** | Bare-metal hypervisor install. Automating it requires PXE/Packer infrastructure that does not exist and cannot pay for itself at one host | Documented install + guest configs in Tier 1 |
| **Metasploitable2 (VM 101)** | Distributed as a fixed appliance image. Its value is being unpatched | Note the source image and checksum |

For every row above, the recovery bar is **a restore procedure that has been executed and dated** — the same standard as an IaC rebuild, met by a different mechanism.

---

## 9. Definition of Done

### 9.1 Per service

A service is **IaC complete** when all six hold:

1. `docker-compose.example.yml` (or playbook) exists, with **every image pinned**.
2. `.env.example` enumerates every variable by name, no values.
3. README §3 Deployment is reproducible from a bare OS — no step reads "then configure it in the UI" without saying exactly what to set.
4. README §6 Backup captures everything §4 Configuration lists. *Verify by comparing the two lists directly; a partial backup that looks complete is worse than none.*
5. README §7 Restore has been **executed**, not merely written.
6. **The acid test:** the service is rebuilt on a fresh VM from the repository and the Tier 1 archive alone — **without consulting the running instance** — and dated.

Criterion 6 is the only one that cannot be satisfied by confident writing. It is the same bar the n8n restore cleared on 2026-08-12, applied to rebuild rather than restore.

*Capacity note:* the host has ~6.6 GiB RAM headroom against 4 threads (`ARCHITECTURE.md` §1.1). Rebuild tests need a small, short-lived VM — build it, verify, destroy it. Do not leave test VMs running.

### 9.2 Status line

Extend the `SERVICE-TEMPLATE.md` status line with one field:

```
**Documentation status:** Deploy ✅ · Config ✅ · Creds ✅ · Backup ✅ · Restore ✅ · Restore tested 2026-08-12 · Rebuilt —
```

`Rebuilt` takes a **date**, never a checkmark — same rule as `Restore tested`, for the same reason.

### 9.3 Project level

The migration is complete when §1.1's table shows a **rebuild date** for every in-scope service, and §8's excluded services each carry a tested restore date.

At that point R-01's Tier 2 gap is genuinely mitigated rather than deferred, and `ARCHITECTURE.md` §7.10 can say so without qualification.

---

## 10. Risks Introduced by This Migration

An honest plan accounts for the harm it can do.

| ID | Risk | Mitigation |
|---|---|---|
| **R-15** | Ansible concentrates lab-wide root access into one SSH key, stored on a laptop with BitLocker off (R-14) | Passphrase-protected key + `ssh-agent`; dedicated key, independently rotatable; passphrase in Bitwarden (§3.2) |
| — | Pinning stops security updates | Monthly review-and-bump cadence, recorded before R-09 closes (§4.4) |
| — | A wrong playbook applies to many hosts at once — blast radius amplification vs. manual change | Always `--check --diff` first; `--limit` to one host before running against a group |
| — | Conversion touches running production services with no Tier 2 backup | Order by blast radius (§6); Tier 1 backup before each conversion; never `down -v` (§6.1) |

---

## 11. Change Log

| Date | Change |
|---|---|
| 2026-08-14 | Roadmap created. Ansible-first decision recorded (§2) with Terraform deferred to greenfield (§7). Control node set to MSI Katana + WSL (§3); WSL confirmed not installed. **R-09 promoted to High / Phase-0 prerequisite** — `:latest` makes the repository unable to reproduce any service, including n8n (§4.2). **R-15 identified** — Ansible SSH key concentration on an unencrypted laptop (§3.2). Scope boundary set: Wazuh, OPNsense, Proxmox host, and Metasploitable2 excluded from IaC with a tested-restore bar instead (§8). Rebuild-vs-restore distinction defined; honest current score is zero reproducible services (§1.1). |
