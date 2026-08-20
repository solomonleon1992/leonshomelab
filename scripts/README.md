# Backup Scripts

**Status:** Operational · **Last verified:** 2026-08-14

`Backup-Tier1.ps1` is the only thing that puts any of this lab on hardware other than the single 4 TB disk every VM lives on. See `ARCHITECTURE.md` §7.10 for the two-tier strategy and R-01 for why it exists.

---

## 1. What It Does

Pulls the small, irreplaceable set of configuration and data off-host to the MSI Katana laptop, packs it into a **7-Zip AES-256 archive with encrypted headers**, verifies the archive opens, and only then deletes the plaintext staging directory.

| | |
|---|---|
| Coverage | **All six lab hosts** |
| Size | ~12 MB staged → ~1.2 MB encrypted (32 items) |
| Schedule | Daily 09:00, Windows Task Scheduler → *Homelab Tier1 Backup* |
| Retention | 14 runs |
| Destination | `%USERPROFILE%\homelab-backups` — refuses to run if this is inside the git repo |

**It fails closed.** Missing 7-Zip or a missing password file causes a non-zero exit and **no backup at all**, rather than a fallback to plaintext. A recurring job needs its security control inside the job, not applied afterwards by hand.

---

## 2. ⚠️ The Archive Contains Live Credentials

This is not a "config backup" in the harmless sense. Every archive holds:

| Secret | Source | Why it is captured |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | n8n compose file | Without it the n8n database is undecryptable — the dump alone restores nothing |
| PostgreSQL credentials | n8n compose file | Inline in compose; unavoidable until secrets move to `.env` |
| **Wazuh `client.keys`** | `/var/ossec/etc/` | **Agent authentication material.** Anyone holding it can impersonate an agent to the manager |
| OPNsense `config.xml` | `/conf/` | The complete firewall, including user password hashes |
| Proxmox guest configs | `/etc/pve/` | May carry cloud-init passwords and SSH keys |

### The `client.keys` trade, stated plainly

Capturing agent authentication material is a **deliberate choice, not an oversight.**

Without `client.keys`, a Wazuh restore means re-enrolling every agent by hand. With it, the manager comes back knowing its agents. That is the difference between a recovery procedure and a rebuild project — and it is exactly the bar `IaC-MIGRATION.md` §8 sets for Wazuh, which is excluded from IaC precisely *because* its recovery is expected to come from Tier 1.

**The control is the encryption, not omission.** AES-256 with encrypted headers, and the password held in **Bitwarden — outside the lab's failure domain**.

> **The archive password must never move to Vaultwarden.** Vaultwarden would run on the lab. If the lab is lost you need this archive to rebuild it, and its password would be locked inside the thing being rebuilt. See `ARCHITECTURE.md` §7.11.

**Never commit an archive.** `.gitignore` blocks `*.7z`, and the script refuses to write into the repository, but neither is a substitute for knowing what is in the file.

---

## 3. Setup

One time, before the scheduled task can succeed:

```powershell
.\Backup-Tier1.ps1 -SetPassword     # store the password in Bitwarden FIRST
```

Stored DPAPI-protected at `%USERPROFILE%\.homelab-backup.cred` — decryptable only by this Windows user on this machine. **If the Windows profile is lost, that file is unrecoverable**, which is why the master copy belongs in Bitwarden.

Requires **7-Zip** and six SSH aliases: `proxmox`, `vm102`, `n8n`, `pihole`, `opnsense`, `wazuh`.

---

## 4. The Wazuh Sudoers Dependency

Wazuh's config files are root-only. Access comes from an **argument-pinned** rule at `/etc/sudoers.d/wazuh-backup` on `192.168.0.27`:

```
leon ALL=(root) NOPASSWD: /usr/bin/cat /var/ossec/etc/ossec.conf, /usr/bin/cat /var/ossec/etc/client.keys
```

Verified 2026-08-14 with the credential cache cleared: both pinned reads succeed with no prompt; `/etc/shadow` is refused; and appending a second path to a pinned command is refused, confirming the pinning holds.

The script uses **`sudo -n`** specifically so that if this rule is ever removed, an unattended run **fails loudly** instead of hanging forever on a password prompt.

### ⚠️ Condition: custom rules and decoders are NOT covered

`/var/ossec/etc/rules/local_rules.xml` and `/var/ossec/etc/decoders/local_decoder.xml` are stock and unmodified since the September 2025 install, so they are **deliberately excluded** from the pin list.

**The moment you write a custom rule or decoder, extend the sudoers rule and the script.** Otherwise the backup will silently omit exactly the work you most want to keep, and nothing will report an error — the run will show all-OK while missing them.

---

## 5. Validation

A backup that looks fine and is empty is worse than no backup: it stops you looking. A 0-byte `pg_dump` on VM 102 went unnoticed for ten days in August 2026 for exactly this reason. Each fragile artifact is therefore checked, not just fetched:

| Artifact | Check |
|---|---|
| n8n `pg_dump` | Size floor **and** the `PostgreSQL database dump complete` trailer |
| `jobtracker` `pg_dump` | Size floor **and** the completion trailer |
| OPNsense `config.xml` | Size floor **and** an XML parse |
| Wazuh `ossec.conf` | Size floor **and** a *wrapped* XML parse — see below |
| Wazuh `client.keys` | Size floor, plus a count of agent entries |

**Why `ossec.conf` is wrapped.** Wazuh permits **multiple root-level `<ossec_config>` blocks**, and this install has two. A strict XML parse fails on a perfectly healthy file, which would mark every nightly run as failed. Wrapping the content in a synthetic root validates element structure while tolerating the multiple roots — and it still rejects truncation, verified by chopping the tail off the real file.

### ⚠️ The counter that hid failures

Until 2026-08-20 this script could report **success while an item failed**.

```powershell
$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
```

PowerShell 5.1 returns a **bare object** when exactly one item matches, and `.Count` on that is `$null`. So `$failCount -gt 0` evaluated `False`, the script printed *"All N items captured and encrypted"* and exited **0**.

Two or more failures counted correctly. **Exactly one was invisible** — which is the worst possible arrangement, because one flaky item is the common case and a total outage is the rare one.

It was latent from 2026-08-12 and surfaced only because the Pi-hole adlist query failed while the run still claimed success. Both counts are now wrapped in `@()` to force an array. **Do not remove those wrappers.**

The lesson generalises past PowerShell: a backup script's own success reporting is as much a correctness surface as the data it copies, and nothing was verifying it.

---

## 6. Restore

Per-artifact steps are in the `MANIFEST.txt` inside each archive. Summary:

| Service | Notes |
|---|---|
| **n8n** | `n8n-ai-agents/README.md` §7. Requires `N8N_ENCRYPTION_KEY` from Bitwarden — the dump alone is **not** sufficient. Verified end to end 2026-08-12. The restored instance starts with an **empty execution history**, by design |
| **job-finder** | Restore `jobtracker-*.sql` into a `jobtracker` database on the same PostgreSQL instance, then unpack `job-finder-source.tar.gz` to `~/n8n-stack/job-finder/` and redeploy via its `deploy.sh`. **The workflows inside n8n are build output** — that directory is the source they are generated from, and it exists nowhere else |
| **OPNsense** | `config.xml` rebuilds the entire firewall. Read `ARCHITECTURE.md` §3.4 first — the **WAN/LAN roles are inverted** on this box |
| **Wazuh** | Reinstall via the all-in-one installer, restore `ossec.conf` and `client.keys` to `/var/ossec/etc/`, restart the manager. `client.keys` is what avoids re-enrolling agents |
| **Pi-hole** | Files drop back into `/etc/pihole/`, restart `pihole-FTL`. Adlist URLs are in `adlists.txt`; re-add them, then `pihole -g` rebuilds the blocklists from those URLs |
| **Proxmox** | Guest configs are **reference material, not bootable images** — they rebuild the definition, not the disk contents |

**Two legs have been executed: n8n (2026-08-12) and `jobtracker` (2026-08-16).** Everything else is a written procedure, which `SERVICE-TEMPLATE.md` correctly calls a hypothesis. Re-verify quarterly — **next due 2026-11-12**.

The `jobtracker` test restored from the **actual encrypted archive** into a throwaway database: `psql` exit 0, 0 errors, 359/359 rows, 7/7 approved with letters, and an identical md5 across every `cover_letter_doc_id`.

**Why the marker check is `-Tail 20` and not `-Tail 5`.** That test found the completion marker sits at line **552 of 556** in a real dump — exactly 5 from the end, because `pg_dump` 15.18 writes a trailing `\unrestrict` line after it. A `-Tail 5` check was one future `pg_dump` line away from failing every run on healthy data. Do not narrow it again.

---

## 7. Known Gaps

- **n8n execution history** — deliberately excluded. Schema is kept, rows are not. The 60-second Telegram poll in `job-finder-approval` produces ~1,200 executions/day, which made execution data **97% of a 39 MB dump**. A restore needs workflows, credentials and settings, not a log of past runs. **This is excluded from the backup but not bounded on the host** — no `EXECUTIONS_DATA_PRUNE` variables are set, so the live database keeps growing. Note: do **not** reach for `saveDataSuccessExecution: 'none'` to solve this; it leaves zombie `running` executions accumulating instead
- **Tier 2 (full VM images, ~127 GB)** — no storage hardware. `IaC-MIGRATION.md` argues this is what the IaC migration makes optional
- **Pi-hole `gravity.db`** — 63 MB of downloaded blocklist content that `pihole -g` regenerates. The **adlist URLs** inside it *are* captured since 2026-08-20 via `pihole-FTL sqlite3`, which bundles sqlite3 (a standalone binary is absent — an earlier note here wrongly concluded the URLs were unextractable)
- **Wazuh custom rules/decoders** — see §4
- **Wazuh indexer and dashboard configs** — root-only, not pinned. The manager config and agent roster *are* captured

---

## 8. Change Log

| Date | Change |
|---|---|
| 2026-08-16 | **`jobtracker` restore verified** — restored from the actual encrypted archive into a throwaway database: exit 0, 0 errors, 359/359 rows, identical md5 across every `cover_letter_doc_id`. The test **found a latent bug**: the dump's completion marker sits exactly 5 lines from the end, so the `-Tail 5` validation was one future `pg_dump` line away from failing every run on healthy data. Widened to `-Tail 20`. |
| 2026-08-16 | **`jobtracker` database and the `job-finder/` source tree added; n8n execution history excluded.** The job-finder agents keep their state in a separate database that `pg_dump n8n` never touched — 359 job matches were unbacked-up from creation. At the same time the 60-second Telegram poll had driven the n8n dump to 39 MB, 97% of it execution history. Both fixed together: **29 items, 860 KB → 670 KB, carrying 3.3 MB more real content**. Restore has not been re-verified against the new dump format — folded into the 2026-11-12 quarterly check. |
| 2026-08-14 | **Wazuh added** via an argument-pinned sudoers rule — Tier 1 now covers all six hosts, 26/26 items. `client.keys` capture documented as a deliberate trade (§2). Wrapped-XML validation adopted after a strict parse was found to fail on healthy multi-root `ossec.conf`. This README created. |
| 2026-08-14 | **OPNsense and Pi-hole added** (three hosts → five). `config.xml` XML-parse validated. Scheduled task's battery restrictions removed after runs were silently skipped. |
| 2026-08-12 | Script created; encryption made unconditional and fail-closed after a manual 7-Zip step would have been silently reverted by the next scheduled run. |
