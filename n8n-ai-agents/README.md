# n8n AI Agents

**Documentation status:** Deploy ✅ · Config ✅ · Creds ✅ · Backup ✅ · Restore ✅ · Restore tested **n8n 2026-08-12 · `jobtracker` 2026-08-16**

> **Verified 2026-08-16.** Four job-finder workflows were added on 08-15/16 and are **active** — this host now runs unattended, which it did not before. That invalidated the restore procedure's safety precondition (§7), the credential list (§5), and the workflow inventory (§9). All three are corrected below. The n8n dump format also changed (execution history excluded) and has **not** been re-verified since — see §7.

> Self-hosted n8n workflow automation running the lab's AI agents, backed by PostgreSQL with a local Ollama LLM alongside the Anthropic API.

Follows [`SERVICE-TEMPLATE.md`](../SERVICE-TEMPLATE.md). Verified against the live host on 2026-08-12.

---

## 1. Placement

| Field | Value |
|---|---|
| VMID / Host | **105** on Proxmox VE 9.1 |
| Proxmox name | `n8n-ai-stack` |
| IP / FQDN | `192.168.0.28` · `n8n.leonshomelab.internal` |
| Resources | 4 vCPU / 8 GB RAM / 64 GB disk |
| OS | Ubuntu Server 22.04 LTS (minimized) |
| Root filesystem | 62 GB LV, 41% used, 35 GB free *(extended 2026-08-12)* |

> **Correction (2026-08-12):** this service was previously documented as "Bare metal / Separate machine." That was wrong. It is a Proxmox VM on the same `/dev/sda` as every other VM in the lab, which matters for backup planning — see §6.

Placement rationale is in [`ARCHITECTURE.md`](../ARCHITECTURE.md) §4.1. That document is authoritative.

---

## 2. Dependencies

**Requires:**
- Proxmox host and `/dev/sda` — total loss on disk failure
- Consumer router `192.168.0.1` for outbound internet
- Pi-hole `192.168.0.50` for `.internal` name resolution
- External SaaS at execution time: Anthropic API, SerpAPI, Telegram

**Required by:**
- Terry, Angie, Harry — all agent workflows
- Caddy on VM 102 proxies `n8n.leonshomelab.internal` → `192.168.0.28:5678`

**Internal:** n8n depends on `n8n-postgres`. If Postgres stops, n8n cannot start.

Full blast-radius analysis: [`ARCHITECTURE.md`](../ARCHITECTURE.md) §6.

---

## 3. Deployment

From a fresh Ubuntu Server 22.04 install.

### 3.1 Expand the logical volume — do this first

The Ubuntu installer allocates roughly half the disk by default. Skipping this produces a filesystem that fills silently.

```bash
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h /                      # expect ~62 GB, not ~31 GB
```

Safe to run online — no unmount, no reboot, no container restart.

### 3.2 Install Docker

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker
```

### 3.3 Deploy the stack

```bash
mkdir ~/n8n-stack && cd ~/n8n-stack
# Copy docker-compose.example.yml from this repo, then fill in real values.
# N8N_ENCRYPTION_KEY must match the one in Bitwarden if restoring existing data.
docker compose up -d
```

### 3.4 Pull the Ollama model

```bash
docker exec -it ollama ollama pull nemotron-mini
docker exec -it ollama ollama list
```

### 3.5 Configure n8n

1. Open `https://n8n.leonshomelab.internal` (or `http://192.168.0.28:5678` directly)
2. Create the admin account
3. Add credentials — Anthropic, SerpAPI, Telegram, Ollama (see §5)
4. Import workflows, or restore the database instead (§7)

---

## 4. Configuration

### 4.1 Files

| Path | Purpose | In repo |
|---|---|---|
| `~/n8n-stack/docker-compose.yml` | Live stack definition — **contains secrets inline** | ❌ blocked by `.gitignore` |
| `docker-compose.example.yml` | Sanitized template | ✅ |

### 4.2 Containers — verified 2026-08-12

| Container | Image | Version | Port | Image size |
|---|---|---|---|---:|
| `n8n` | `n8nio/n8n:latest` | **2.31.4** | 5678 | 2.53 GB |
| `n8n-postgres` | `postgres:15` | 15.18 | 5432 | 633 MB |
| `ollama` | `ollama/ollama:latest` | — | 11434 | 10.6 GB |

> **`:latest` is a known risk (R-09).** An unattended `docker compose pull` can move n8n off 2.31.4 without warning. Pin these tags before any automated update process is introduced.

### 4.3 Volumes

| Volume | Contents |
|---|---|
| `n8n-stack_n8n_data` | n8n instance data |
| `n8n-stack_postgres_data` | **The database — workflows and encrypted credentials** |
| `n8n-stack_ollama_data` | Downloaded models |

Names carry the `n8n-stack_` compose project prefix. Total volume footprint 2.8 GB.

### 4.4 Environment variables — names only

| Variable | Purpose | Required |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | Encrypts stored credentials. **Loss is unrecoverable** | ✅ |
| `DB_TYPE` | `postgresdb` | ✅ |
| `DB_POSTGRESDB_HOST` · `_DATABASE` · `_USER` · `_PASSWORD` | Database connection | ✅ |
| `N8N_HOST` · `N8N_PORT` · `N8N_PROTOCOL` | Instance addressing | ✅ |
| `N8N_PROXY_HOPS` | Trusted proxy hops behind Caddy | ✅ |
| `N8N_SECURE_COOKIE` | Set `false` for HTTP access | ⚠️ likely removable — §7.7 of `ARCHITECTURE.md` |
| `WEBHOOK_URL` | External webhook base | ⚠️ deprecation review pending |
| `N8N_EDITOR_BASE_URL` | Editor base URL | **Not set** — review alongside `WEBHOOK_URL` |

### 4.5 Models

| Model | Where | Size | Purpose |
|---|---|---|---|
| Claude (Anthropic API) | External | — | Listing analysis and filtering in Terry |
| `nemotron-mini:latest` | Ollama, local | 2.7 GB | Fast local inference for simple tasks |

> Ollama is **deliberately retained** even though no currently-active workflow routes to it — see `ARCHITECTURE.md` §4.1. Do not reclaim it during cleanup.

> The Anthropic model configured in the credential predates the current Claude model generation. Worth reviewing when convenient; changing it alters Terry's output quality and cost, so treat it as a deliberate change rather than housekeeping.

---

## 5. Credentials

| Credential | Bitwarden item |
|---|---|
| n8n encryption key | `n8n encryption key — VM 105` |
| PostgreSQL user/password | n8n stack — Bitwarden |
| Anthropic API key | Stored in n8n; master copy in Bitwarden |
| SerpAPI key | Stored in n8n; master copy in Bitwarden |
| Telegram bot token (Terry) | Stored in n8n; master copy in Bitwarden |
| Google Gemini (PaLM) API key | Stored in n8n; master copy in Bitwarden |
| n8n account | `leonshomelab.updates@gmail.com` — password in Bitwarden |

**No values in this repository.** Credentials inside n8n are encrypted at rest in PostgreSQL using `N8N_ENCRYPTION_KEY`.

**Ten credentials** are stored in the database, verified 2026-08-16 — up from five on 08-12:

| Type | Count | Added |
|---|---|---|
| `anthropicApi`, `serpApi`, `ollamaApi`, `googlePalmApi` | 4 | pre-existing |
| `telegramApi` | **2** | one pre-existing, one for the job-finder bot |
| `googleDocsOAuth2Api`, `googleDriveOAuth2Api`, `googleSheetsOAuth2Api` | 3 | 2026-08-15/16, job-finder |
| `httpHeaderAuth`, `postgres` | 2 | 2026-08-15/16, job-finder |

The Gemini (`googlePalmApi`) credential was undocumented until the 2026-08-12 restore test surfaced it — a reminder that this list is only as good as its last verification.

**The Google OAuth2 credentials do not depend on the lab hostname.** Google rejects `.local` redirect URIs, so authorization runs against `http://localhost:5678/rest/oauth2-credential/callback` through an SSH tunnel. The `.internal` migration does not require re-authorizing them (`ARCHITECTURE.md` §7.8).

---

## 6. Backup

### What must be captured — all three, or none of it works

| Component | Why | Where it is |
|---|---|---|
| **n8n PostgreSQL dump** | Workflows and encrypted credentials | `pg_dump`, below |
| **`N8N_ENCRYPTION_KEY`** | Without it the dump's credentials are undecryptable | ✅ Bitwarden (2026-08-12) |
| **`docker-compose.yml`** | Reproduces the environment the key belongs to | Host only |
| **`jobtracker` database** | The job-finder's actual state — 359 job matches, bot state. **A separate database; `pg_dump n8n` does not include it** | ✅ added 2026-08-16 |
| **`~/n8n-stack/job-finder/`** | The workflows in n8n are build output; this is the source they come from, and it is in no other place | ✅ added 2026-08-16 |

> **A dump alone will not restore this service.** Restored without the original encryption key, every workflow comes back intact, correctly wired, and completely non-functional — each credential decrypts to garbage. The key is not in the dump.

> **`jobtracker` was unprotected from creation until 2026-08-16.** It was created on 08-15 and `pg_dump n8n` never touched it. If you add another database to this PostgreSQL instance, it is **not** backed up until `Backup-Tier1.ps1` is told about it explicitly.

### Command

```bash
# n8n — execution HISTORY excluded, execution SCHEMA retained
docker exec n8n-postgres pg_dump -U n8n n8n \
  --exclude-table-data=execution_data --exclude-table-data=execution_entity \
  --exclude-table-data=execution_metadata --exclude-table-data=execution_annotations \
  > ~/n8n-backup-$(date +%Y%m%d).sql

# job-finder state — a SEPARATE database
docker exec n8n-postgres pg_dump -U n8n jobtracker > ~/jobtracker-$(date +%Y%m%d).sql
```

**Why execution history is excluded.** The 60-second Telegram poll drove the n8n dump from 406 KB to **39 MB in two days, 97% of it execution logs**. A restore needs workflows, credentials and settings — not a record of past runs. `--exclude-table-data` keeps the `CREATE TABLE`, so a restored instance works and simply starts with an empty history. Measured 2026-08-16: 39.1 MB full versus 928 KB excluded.

### Current state — honest

| Aspect | Status |
|---|---|
| Schedule | ✅ Daily 09:00 via Windows Task Scheduler on the MSI Katana |
| Mechanism | ✅ `scripts/Backup-Tier1.ps1` — pulls over SSH, validates the dump, writes a manifest, retains 14 runs |
| Off-host | ✅ Replicated to the MSI Katana laptop — separate physical hardware from `/dev/sda` |
| Encrypted at rest | ✅ 7-Zip AES-256 with encrypted headers; plaintext staging deleted after each run (`ARCHITECTURE.md` §7.11) |
| Validation | ✅ Size plus `PostgreSQL database dump complete` marker on every run — **`-Tail 20`, not 5** (see below) |
| `jobtracker` covered | ✅ Since 2026-08-16 — **restore-verified the same day** |
| `job-finder/` source | ✅ Since 2026-08-16 |
| Covers the VM image | ❌ Database and configuration only — Tier 2 remains open (`ARCHITECTURE.md` §7.10) |

Current sizes (2026-08-16): the n8n database is **35 MB** but dumps to **928 KB** with execution history excluded; `jobtracker` dumps to **3.2 MB**; the `job-finder/` tree is 216 KB. **The irreplaceable data here is still small** — getting it off-host was never a storage-capacity problem.

> **The marker check must stay at `-Tail 20`.** In a real dump the `PostgreSQL database dump complete` line sits at line **552 of 556** — exactly five from the end, because `pg_dump` 15.18 writes a trailing `\unrestrict` line after it. A `-Tail 5` check was one future `pg_dump` line away from reporting FAIL on healthy dumps and failing every nightly run. Found by the 2026-08-16 `jobtracker` restore test; do not narrow it again.

> A stale copy also lives at `~/n8n-backup-20260802.sql` on VM 105. It is a valid dump, superseded by the automated backups. A 0-byte file of the same name on VM 102 was a failed attempt from the wrong host and was deleted 2026-08-12 — **verify dump size after every backup; an empty file looks exactly like a real one in `ls`.**

> A 0-byte file named `n8n-backup-20260802.sql` also existed on VM 102 — a failed first attempt from the wrong host. Deleted 2026-08-12. Verify dump size after every backup; an empty file looks exactly like a real one in `ls`.

---

## 7. Restore

**Prerequisites not contained in the backup:**
1. `N8N_ENCRYPTION_KEY` from Bitwarden — must match the value in use when the dump was taken
2. A working `docker-compose.yml`
3. A `psql` client at 15.18 or newer — the dump uses `\restrict` / `\unrestrict`, which older clients reject

```bash
# 1. Bring the stack up with the ORIGINAL encryption key in place
cd ~/n8n-stack && docker compose up -d

# 2. Stop n8n, leave Postgres running
docker compose stop n8n

# 3. Recreate the database
docker exec -i n8n-postgres psql -U n8n -d postgres -c "DROP DATABASE n8n;"
docker exec -i n8n-postgres psql -U n8n -d postgres -c "CREATE DATABASE n8n OWNER n8n;"

# 4. Load the dump
docker exec -i n8n-postgres psql -U n8n -d n8n < ~/n8n-backup-YYYYMMDD.sql

# 5. Start n8n
docker compose start n8n
```

**Then verify (§8) — and specifically open a credential in the n8n UI.** If credentials fail to decrypt, the encryption key does not match. Stop and correct the key; do not proceed.

**Last tested: 2026-08-12** · **Next due: 2026-11-12** (quarterly)

### Verification results — 2026-08-12

Tested end to end using the **actual off-host backup artifact**, not a fresh dump: VM 105 → MSI Katana → back to VM 105 → restored → decrypted. Byte-identical at 406,418 bytes throughout.

Restored into an isolated stack (compose project `n8n-restoretest`, separate volumes, port 5679). **Production was never touched** — `n8n` and `n8n-postgres` showed unbroken uptime of 2 and 3 weeks across the entire test.

| Check | Result |
|---|---|
| `psql` restore exit code | **0** |
| SQL error lines | **0** |
| n8n startup | 10s, clean |
| Decryption errors in log | **0** |
| Workflows restored | **4 of 4** |
| Credentials restored | **5 of 5** |
| Users restored | 1 |
| `export:credentials --decrypted` | **exit 0**, 1683 bytes |

The final row is the one that matters. It forces n8n to run every stored credential through the real decryption path; a wrong or missing `N8N_ENCRYPTION_KEY` fails there. Workflows restore from plaintext JSON and look correct even with a wrong key — **credentials are the only thing that proves the key survived.** The decrypted output was never read and was deleted from the throwaway container immediately.

### Re-running it

```bash
~/n8n-stack/scripts/restore-verification.sh
```

Reads the encryption key directly from the running production container into a `0600` `.env` — the value is never printed. Expects the dump at `~/restore-test.sql`; copy the newest artifact from the laptop first.

**Teardown is not automatic.** The stack is left running for manual inspection:

```bash
cd ~/n8n-restore-test && docker compose ls   # confirm you are on n8n-restoretest
docker compose down -v
cd ~ && rm -rf ~/n8n-restore-test            # also removes the .env holding the key
```

> ⚠️ `docker compose down -v` destroys volumes. The same command run from `~/n8n-stack` would delete the production database. Check `docker compose ls` first.

> ### ⚠️ STOP — this precondition changed on 2026-08-16
>
> This procedure was written when **every** workflow was inactive. That is what made it safe. **Four are now active**, including `job-finder-approval`, which polls Telegram every 60 seconds.
>
> A restored instance carries the *same credentials* — the same Telegram bot token, the same Google OAuth tokens. Restoring with those workflows active means a second instance polling the same bot, consuming the same approval replies, and writing to the same Google Sheet and Drive folder as production. **The harness isolates the database, the network and the port. It does not isolate external side effects.**
>
> **Deactivate them in the restored database before starting n8n** — between step 4 (restore) and step 5 (start n8n):
>
> ```bash
> docker exec n8n-restore-postgres psql -U n8n -d n8n \
>   -c "UPDATE workflow_entity SET active = false;"
> ```
>
> Run that against `n8n-restore-postgres`, the throwaway container — **never** against production. Deactivating in the *restored* copy is safer than deactivating production, because it leaves your live job search untouched.

---

## 8. Verification

```bash
# Containers up
docker ps --format "table {{.Names}}\t{{.Status}}"
# expect: n8n, n8n-postgres, ollama — all Up

# Database reachable
docker exec n8n-postgres pg_isready -U n8n
# expect: /var/run/postgresql:5432 - accepting connections

# Workflows present
docker exec n8n-postgres psql -U n8n -d n8n -c "SELECT id, name, active FROM workflow_entity;"
# expect: 8 rows, 4 with active = true (see §9)

# Version
docker exec n8n n8n --version        # expect 2.31.4

# Disk
df -h /                              # expect ~41% used, not >80%
```

**UI check:** open `https://n8n.leonshomelab.internal`, then open any credential. It must decrypt and display without error — that is the only proof the encryption key is correct.

---

## 9. Workflows

**Eight workflows, four active** — verified 2026-08-16. This changed materially on 2026-08-15/16: until then nothing on this host ran unattended.

| ID | Name | Active | Belongs to |
|---|---|---|---|
| `jobFinderDaily01` | job-finder-daily | ✅ | job-finder |
| `jobFinderApprov1` | job-finder-approval | ✅ | job-finder |
| `jobFinderCovLtr1` | job-finder-cover-letter | ✅ | job-finder |
| `clBackfill00001` | cl-backfill | ✅ | job-finder |
| `w53g2XfgOCRmtErG` | **Terry — Laptop eBay Deal Finder** | ❌ | — |
| `fXKsIhcBdngSIvEZ` | Angie — personal AI assistant, Telegram voice and text | ❌ | — |
| `ZnmGRqszMk76GnaQ` | Harry — Headless YT Creator | ❌ | — |
| `xSzXTcw8pRWjGWY4` | My workflow | ❌ | — |

### The job-finder is documented elsewhere — deliberately not duplicated here

The four `job-finder*` workflows are **build output**. Their source of truth is `~/n8n-stack/job-finder/` on VM 105 — `build.js`, `codenodes.js`, `deploy.sh`, the workflow JSON and the scoring prompt — and their design documentation lives in a **different Claude Code project's memory**:

```
C:\Users\leons\.claude\projects\C--Users-leons-OneDrive-Desktop-resume\memory\
```

That covers the build → deploy → `publish:workflow` → `docker restart n8n` sequence, the Google Drive and Sheets resource IDs, deliberate design constraints that must **not** be "improved" away, and n8n 2.31.4 behaviours verified the hard way. **Read it before editing anything job-finder.**

Reproducing that content here would create a second source of truth that drifts within a week — `SERVICE-TEMPLATE.md` non-negotiable #4 ("link, do not duplicate"), applied one level out. This repository owns **where it runs** (§1), **what backs it up** (§6), **what breaks if it dies** (`ARCHITECTURE.md` §6), and **the restore safety rules** (§7). The resume project owns the rest.

**Execution volume.** `job-finder-approval` polls Telegram on a 60-second schedule, producing roughly 1,200 executions/day. `execution_entity` held **1,641 rows** on 2026-08-16 — this README previously said 0, which was true when nothing was active. See §6 for why execution history is now excluded from backups.

### Terry — Laptop Deal Finder

**Trigger:** Schedule, `0 */6 * * *` (every 6 hours) — currently deactivated.

1. **Schedule Trigger**
2. **SerpAPI eBay search** — query `laptop -parts -screen -battery -keyboard`, max $300, sorted price-descending, 50 results/page
3. **AI Agent (Anthropic)** — filters accessories, parts-only and broken listings, and obvious scams, then applies deal-evaluation criteria
4. **Telegram** — sends title, price, condition, link, and assessment via the Terry bot

**Running cost:** roughly $3.60/month — SerpAPI free tier (~120 searches), Anthropic API ~$0.03/search, Telegram free.

**Migration-safe:** every node is outbound. No webhook trigger, no OAuth, so no redirect URI depends on the hostname. The `.internal` migration cannot break it (`ARCHITECTURE.md` §7.8).

### Planned

Listing generator · Wazuh alert aggregation · Proxmox/Docker log analyzer · VM resource optimizer

---

## 10. Troubleshooting

### Secure cookie error — cannot reach the dashboard
**Symptom:** *"Your n8n server is configured to use a secure cookie, however you are either visiting this via an insecure URL, or using Safari."*
**Fix:** set `N8N_SECURE_COOKIE=false` in the compose environment, then `docker compose restart n8n`.
**Note:** now that Caddy fronts this over HTTPS, this variable is probably no longer needed. Review before removing.

### Container name conflict
**Symptom:** *"The container name '/ollama' is already in use"*
```bash
docker stop n8n n8n-postgres ollama
docker rm n8n n8n-postgres ollama
docker compose up -d
```

### Ollama unreachable from n8n
**Cause:** `localhost` inside the n8n container is the n8n container.
**Fix:** use the compose service name — base URL `http://ollama:11434`.

### Disk filling up
**Cause:** the LV was never extended past the installer default (§3.1).
**Check:** `df -h /`. **Fix:** §3.1. Resolved on this host 2026-08-12 (31 → 62 GB).
Postgres is only 15 MB and `docker system df` reports 0 B reclaimable — if the disk is filling, images are the cause, not execution history.

### Credentials fail after a restore
**Cause:** `N8N_ENCRYPTION_KEY` does not match the value used when the dump was taken.
**Fix:** correct the key from Bitwarden and restart. There is no recovery path without the original key.

---

## 11. Security Notes

- Access is HTTPS via Caddy (`n8n.leonshomelab.internal`), certificate issued by the lab's internal CA. **Port 5678 also remains reachable directly over HTTP from any host on `192.168.0.0/24`** — this is R-05, and it cannot be fixed with an OPNsense rule because Caddy and n8n are same-subnet L2 peers. A host-level control is required (`ARCHITECTURE.md` §7.4).
- Never expose 5678 to the internet.
- API keys are encrypted at rest in PostgreSQL via `N8N_ENCRYPTION_KEY`.
- The Telegram bot token permits sending messages as Terry — treat it as a live credential.
- `~/n8n-stack/docker-compose.yml` contains secrets inline and is blocked by `.gitignore`. Commit only `docker-compose.example.yml`.

---

## 12. Change Log

| Date | Change |
|---|---|
| 2026-08-12 | Rewritten against `SERVICE-TEMPLATE.md`. Corrected "bare metal" → Proxmox VM 105. Corrected volume names (compose prefix) and nemotron-mini size (4 GB → 2.7 GB). Added verified image sizes, backup/restore procedures, and verification commands. Recorded workflow inventory and `active = false` state. |
| 2026-08-12 | Root LV extended 31 → 62 GB online; R-04 resolved. `N8N_ENCRYPTION_KEY` copied to Bitwarden; R-03 partially resolved. |
| 2026-08-12 | **Restore verified end to end** against the off-host artifact — 4 workflows, 5 credentials, `export:credentials --decrypted` exit 0. Production untouched. Status line moved to `Restore ✅ / tested 2026-08-12`, quarterly re-verification set. Google Gemini credential discovered and documented. Test harness stored at `~/n8n-stack/scripts/restore-verification.sh` on VM 105. |
| 2026-08-16 | **Four job-finder workflows added (by the maintainer, 08-15/16) and left active** — this host now runs unattended, which it never had before. Three parts of this README were invalidated at once and are corrected here. **§7's safety precondition was the dangerous one:** "safe only while workflows are inactive" was written when all four workflows were inactive, and the quarterly re-verification is due 2026-11-12. A restored instance shares the *credentials* in the dump, so restoring with the job-finder active would mean a second instance polling the same Telegram bot and writing to the same Google Sheet and Drive folder — the harness isolates database, network and port, **not external side effects**. Replaced with an explicit `UPDATE workflow_entity SET active = false` against the *restored* database, which leaves production untouched. **§5:** credentials 5 → **10**, and recorded that the new Google OAuth2 credentials do **not** tie to the lab hostname (Google rejects `.local`; authorization runs against `localhost` via SSH tunnel), so the `.internal` migration needs no re-authorization. **§9:** inventory 4 → 8 workflows, rewritten as a **pointer** to the resume project's memory rather than a duplicated inventory — the job-finder workflows are build output from `~/n8n-stack/job-finder/`, and copying its design docs here would create a second source of truth that drifts. **§6:** `jobtracker` and the `job-finder/` source tree added to the backup after being unprotected since creation; n8n execution history excluded (39.1 MB → 928 KB); marker validation widened to `-Tail 20` after the `jobtracker` restore test found the completion marker sits exactly 5 lines from the end. **`jobtracker` restore verified 2026-08-16** — 359/359 rows, identical md5 across every `cover_letter_doc_id`. |
