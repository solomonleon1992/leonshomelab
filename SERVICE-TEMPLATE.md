# Service Documentation Template

**Status:** Authoritative convention · **Adopted:** 2026-08-12 · **Reference implementation:** [`n8n-ai-agents/README.md`](./n8n-ai-agents/README.md)

Every service folder in this repository follows the structure below. This exists so that any service can be **rebuilt from this repository alone**, and so that gaps in that ability are visible rather than assumed away.

`ARCHITECTURE.md` describes *how the system fits together and why*. A service README describes *how to operate one piece of it*. Where they conflict, `ARCHITECTURE.md` wins — do not duplicate topology, blast radius, or placement rationale into a service README. Link to it.

---

## 1. Folder Layout

**Flat by default.** Do not create empty scaffolding.

```
<service>/
├── README.md                       # required, always
├── docker-compose.example.yml      # if containerized
├── .env.example                    # if env-driven
└── <name>.example                  # Caddyfile.example, ossec.conf.example, …
```

**Promote to subdirectories only when a service earns it:**

| Add | When |
|---|---|
| `config/` | More than three configuration files |
| `terraform/` · `ansible/` | Real code exists — never as a placeholder |
| `scripts/` | More than one operational script |

A nested tree of near-empty directories makes a repository harder to navigate, not more professional. Structure should follow content, not anticipate it.

### The `.example` convention is a security control

Every sanitized file ends in `.example`. This is not cosmetic — `.gitignore` blocks the real files and its allow-list explicitly rescues the `.example` ones:

```
docker-compose.yml           ← blocked (this lab stores secrets inline)
docker-compose.example.yml   ← allowed
```

Sanitize by replacing every value with a `${VAR}` placeholder or an obvious dummy. **Never** commit a real file and plan to clean it later — git history is permanent, and a leaked secret must be rotated, not deleted.

---

## 2. README Structure

Twelve sections, in this order. Sections that genuinely do not apply are marked *N/A* with a one-line reason — never silently omitted, because an absent section is indistinguishable from an overlooked one.

````markdown
# <Service Name>

**Documentation status:** Deploy — · Config — · Creds — · Backup — · Restore — · Restore tested —

> One sentence: what this is and why it exists in this lab.

## 1. Placement

| Field | Value |
|---|---|
| VMID / Host | |
| Proxmox name | |
| IP / FQDN | |
| Resources | vCPU / RAM / disk |
| OS | |

Placement rationale lives in `ARCHITECTURE.md` §4.1. That document is authoritative.

## 2. Dependencies

**Requires:** what must be running for this to work.
**Required by:** what breaks if this stops.

Full blast-radius analysis is in `ARCHITECTURE.md` §6 — link, do not duplicate.

## 3. Deployment

Reproducible from a bare OS install. Numbered and copy-pasteable.
No step may read "then configure it in the UI" without saying exactly what to set.

## 4. Configuration

Files in this folder and what each does. Every environment variable **by name**,
with its purpose and whether it is required.

**Never a value.** Not even a "harmless" one.

## 5. Credentials

Bitwarden item names only.

| Credential | Bitwarden item |
|---|---|

No values. No filesystem paths to values. No hints about format or length.

## 6. Backup

- **What must be captured** — enumerate every component; a partial backup that
  looks complete is worse than none
- **Command** — exact and copy-pasteable
- **Destination** — and whether it is genuinely off-host
- **Schedule** — or "manual", stated honestly

## 7. Restore

Numbered steps from nothing to working, including prerequisites that are not
in the backup itself (encryption keys, compose files, matching versions).

**Last tested: YYYY-MM-DD**

An untested restore procedure is a hypothesis, not a capability.

## 8. Verification

Commands that prove it works, with expected output. How you know deployment or
restore actually succeeded — not merely that it exited zero.

## 9. Troubleshooting

Symptom → cause → fix. Real problems encountered, not imagined ones.

## 10. Change Log

| Date | Change |
|---|---|
````

---

## 3. The Status Line

```
**Documentation status:** Deploy ✅ · Config ✅ · Creds ✅ · Backup ⚠️ · Restore ❌ · Restore tested —
```

| Symbol | Meaning |
|---|---|
| ✅ | Complete and verified |
| ⚠️ | Present but incomplete, unverified, or with known caveats |
| ❌ | Missing |
| — | Not applicable, or not yet attempted (for *Restore tested*, a date) |

This makes documentation debt visible at a glance. A README carrying `Restore ❌` is honest. A README with a confident-looking restore section nobody has executed is worse than one with no section at all, because it will be trusted during an incident.

**Rules:**
- `Restore tested` takes a **date**, never a checkmark. If it is blank, you do not have a tested restore procedure.
- Downgrade a flag the moment reality changes. A status line that lags reality is a lie with a timestamp.
- Never mark ✅ on the strength of a procedure being *written*. ✅ means *executed and observed*.

---

## 4. Non-Negotiables

1. **No secrets. Ever.** Not values, not paths to values, not partial values. The repository records *where* a credential lives, never *what* it is.
2. **Sanitized files end in `.example`.** This is what `.gitignore` allows through.
3. **Verified facts only.** If something has not been checked against the live host, mark it unverified. Confident-sounding documentation that is wrong costs more than an admitted gap — it gets trusted.
4. **`ARCHITECTURE.md` wins.** Do not restate topology or rationale; link to it.
5. **Date every claim that can go stale.** Versions, capacities, host state, agent rosters.
6. **A restore procedure is not real until it has been run.** Write it, then execute it, then date it.

---

## 5. Migration Order

When converting an existing service folder to this template:

1. **Verify against the live host first.** Do not carry forward existing claims — this repository already contained a service documented as "bare metal" that is a Proxmox VM, and a container port that was wrong. Assume every unverified statement is suspect.
2. **Write the status line honestly**, with most flags at ❌. That is the starting point, not a failure.
3. **Fill Placement, Dependencies, Configuration** — these come straight from verification.
4. **Write Backup and Restore last.** They are the sections most likely to be fiction, and they deserve the most care.
5. **Preserve real troubleshooting entries.** Problems that were actually hit and solved are the highest-value content in these files and cannot be reconstructed.

---

## 6. Change Log

| Date | Change |
|---|---|
| 2026-08-12 | Template created. Flat-by-default layout, 12-section README structure, status-line convention, and `.example`/`.gitignore` interlock defined. `n8n-ai-agents/README.md` written as the reference implementation. |
