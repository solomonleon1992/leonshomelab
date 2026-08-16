<#
.SYNOPSIS
    Pulls Tier 1 homelab configuration and data off-host, as an encrypted archive.

.DESCRIPTION
    Tier 1 is the small, irreplaceable set: the n8n database, compose files,
    the Caddyfile, and Proxmox guest definitions. Total is well under 50 MB.

    Everything in the lab otherwise lives on a single 4 TB disk (/dev/sda)
    with no RAID. This script is the only thing that puts any of it on
    different physical hardware. See ARCHITECTURE.md R-01.

    The captured data contains REAL SECRETS - N8N_ENCRYPTION_KEY, database
    credentials, and Proxmox guest configs that may carry cloud-init
    passwords. BitLocker is off on this machine (R-14), so every run is
    packed into a 7-Zip AES-256 archive with encrypted headers and the
    plaintext staging directory is deleted. See ARCHITECTURE.md 7.11.

    Tier 2 - full VM images, ~127 GB - is NOT covered here and needs storage
    hardware that does not currently exist.

.PARAMETER Destination
    Where the encrypted .7z archives are written. MUST live outside the git
    repository.

.PARAMETER PasswordFile
    DPAPI-protected file holding the archive password. Created once with
    -SetPassword. Only this Windows user on this machine can decrypt it.

.PARAMETER KeepRuns
    Number of archives to retain. Older ones are deleted.

.PARAMETER SetPassword
    One-time interactive setup: prompts for the archive password and stores
    it DPAPI-protected, then exits.

.EXAMPLE
    .\Backup-Tier1.ps1 -SetPassword      # run once, interactively
    .\Backup-Tier1.ps1                   # normal run (unattended)

.NOTES
    Requires 7-Zip and SSH aliases: proxmox, vm102, n8n, pihole, opnsense,
    wazuh. All six lab hosts are covered.

    Wazuh additionally depends on a narrowly scoped, argument-pinned sudoers
    rule at /etc/sudoers.d/wazuh-backup (see the Wazuh section below). If that
    rule is removed, the Wazuh items fail loudly - `sudo -n` never prompts.

    THIS ARCHIVE CARRIES AGENT AUTHENTICATION MATERIAL (Wazuh client.keys)
    as well as N8N_ENCRYPTION_KEY, database credentials, and the full
    OPNsense configuration. That is the intended trade - it is what makes
    restore without re-enrollment possible - and AES-256 with the password
    held in Bitwarden, outside the lab's failure domain, is the control.
    See scripts/README.md.
#>

[CmdletBinding()]
param(
    [string]$Destination  = "$env:USERPROFILE\homelab-backups",
    [string]$PasswordFile = "$env:USERPROFILE\.homelab-backup.cred",
    [int]$KeepRuns        = 14,
    [switch]$SetPassword
)

$ErrorActionPreference = 'Continue'

# --- Locate 7-Zip -----------------------------------------------------------
$sevenZip = $null
foreach ($p in @("C:\Program Files\7-Zip\7z.exe", "C:\Program Files (x86)\7-Zip\7z.exe")) {
    if (Test-Path $p) { $sevenZip = $p; break }
}
if (-not $sevenZip) {
    try { $sevenZip = (Get-Command 7z -ErrorAction Stop).Source } catch { }
}

# --- One-time password setup ------------------------------------------------
if ($SetPassword) {
    $secure = Read-Host "Archive password (store this in Bitwarden FIRST)" -AsSecureString
    if ($secure.Length -eq 0) { Write-Error "Empty password rejected."; exit 1 }
    $secure | ConvertFrom-SecureString | Set-Content -Path $PasswordFile -Encoding utf8
    Write-Host "Password stored DPAPI-protected at $PasswordFile" -ForegroundColor Green
    Write-Host "Only '$env:USERNAME' on '$env:COMPUTERNAME' can decrypt it." -ForegroundColor Green
    Write-Host "`nIf you lose the Windows profile, this file is unrecoverable." -ForegroundColor Yellow
    Write-Host "The password MUST also be in Bitwarden - not in Vaultwarden." -ForegroundColor Yellow
    exit 0
}

if (-not $sevenZip) {
    Write-Error "7-Zip not found. Install it, or the archive cannot be encrypted. Refusing to write plaintext backups."
    exit 1
}
if (-not (Test-Path $PasswordFile)) {
    Write-Error "No password file at $PasswordFile. Run: .\Backup-Tier1.ps1 -SetPassword`nRefusing to write plaintext backups."
    exit 1
}

# --- Safety: never write backups inside the repository ----------------------
$repoRoot = & git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $repoRoot) {
    $repoFull   = (Resolve-Path ($repoRoot -replace '/', '\')).Path
    $destParent = Split-Path -Parent $Destination
    if (-not (Test-Path $destParent)) { $destParent = $env:USERPROFILE }
    $destFull = (Resolve-Path $destParent).Path
    if ($destFull.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "REFUSING TO RUN: destination '$Destination' is inside the git repo at '$repoFull'."
        exit 1
    }
}

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
# Plaintext lands in a transient staging directory, never in $Destination.
$stageDir = Join-Path $env:TEMP "homelab-tier1-$stamp"
$results  = New-Object System.Collections.ArrayList

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path $stageDir    | Out-Null
foreach ($sub in 'vm105-n8n', 'vm102-docker', 'proxmox', 'pihole', 'opnsense', 'wazuh') {
    New-Item -ItemType Directory -Force -Path (Join-Path $stageDir $sub) | Out-Null
}

function Add-Result {
    param($Item, $Status, $Detail)
    [void]$results.Add([PSCustomObject]@{ Item = $Item; Status = $Status; Detail = $Detail })
}

function Get-RemoteFile {
    param($Alias, $RemotePath, $LocalPath, $Label)
    & scp -o BatchMode=yes -o ConnectTimeout=10 -q "${Alias}:${RemotePath}" $LocalPath
    if ($LASTEXITCODE -eq 0 -and (Test-Path $LocalPath)) {
        Add-Result $Label 'OK' "$((Get-Item $LocalPath).Length) bytes"
    } else {
        Add-Result $Label 'FAIL' "scp exit $LASTEXITCODE"
    }
}

function Save-RemoteOutput {
    param($Alias, $Command, $LocalPath, $Label)
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=10 $Alias $Command
    if ($LASTEXITCODE -eq 0) {
        $out | Out-File -FilePath $LocalPath -Encoding utf8
        Add-Result $Label 'OK' "$((Get-Item $LocalPath).Length) bytes"
    } else {
        Add-Result $Label 'FAIL' "ssh exit $LASTEXITCODE"
    }
}

Write-Host "`n=== Tier 1 backup (staging -> $stageDir) ===`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# VM 105 - n8n stack
# ---------------------------------------------------------------------------
Write-Host "[VM 105] n8n stack..." -ForegroundColor Yellow
$n8nDir = Join-Path $stageDir 'vm105-n8n'

# Execution HISTORY is excluded, execution SCHEMA is not.
#
# job-finder-approval polls Telegram on a 60s schedule, which produced ~1,200
# executions/day and pushed this dump from 406 KB to 39 MB in two days - 97%
# of it execution_data. That is operational noise: a restore needs workflows,
# credentials and settings, not a log of past runs. Measured 2026-08-16:
# 39.1 MB full vs 928 KB with these exclusions.
#
# --exclude-table-data keeps the CREATE TABLE and drops only the rows, so a
# restored instance comes up with an empty execution history and works.
$dumpRemote = "/tmp/n8n-backup-$stamp.sql"
$pgExclude  = '--exclude-table-data=execution_data --exclude-table-data=execution_entity --exclude-table-data=execution_metadata --exclude-table-data=execution_annotations'
& ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "docker exec n8n-postgres pg_dump -U n8n n8n $pgExclude > $dumpRemote"
if ($LASTEXITCODE -eq 0) {
    $dumpLocal = Join-Path $n8nDir "n8n-database-$stamp.sql"
    Get-RemoteFile 'n8n' $dumpRemote $dumpLocal 'n8n PostgreSQL dump'

    # A 0-byte dump is indistinguishable from a real one in `ls`. That exact
    # failure produced a fake backup on VM 102 that went unnoticed for 10 days.
    if (Test-Path $dumpLocal) {
        $len  = (Get-Item $dumpLocal).Length
        # -Tail 20, not 5. The completion marker sits at line 552 of 556 in a
        # real dump - EXACTLY 5 from the end - because pg_dump 15.18 emits a
        # trailing `\unrestrict` line and blanks after it. One more trailing
        # line from any future pg_dump and a -Tail 5 check would report FAIL on
        # a perfectly healthy dump, failing the whole run every night. Found by
        # the 2026-08-16 jobtracker restore test.
        $tail = Get-Content $dumpLocal -Tail 20 | Out-String
        if ($len -lt 1024) {
            Add-Result 'n8n dump validation' 'FAIL' "only $len bytes - empty or truncated"
        } elseif ($tail -notmatch 'PostgreSQL database dump complete') {
            Add-Result 'n8n dump validation' 'FAIL' 'missing completion marker - truncated'
        } else {
            Add-Result 'n8n dump validation' 'OK' "$len bytes, completion marker present"
        }
    }
    & ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "rm -f $dumpRemote" | Out-Null
} else {
    Add-Result 'n8n PostgreSQL dump' 'FAIL' "pg_dump failed (ssh exit $LASTEXITCODE)"
}

# ---------------------------------------------------------------------------
# jobtracker database - the job-finder's actual application state
#
# The job-finder agents (added 2026-08-15/16) keep their state in a SEPARATE
# `jobtracker` database on the same PostgreSQL instance: job_matches, bot_state.
# Keeping it out of n8n's schema is good design, but it means `pg_dump n8n`
# does NOT include it - it went unbacked-up from creation until 2026-08-16.
#
# Execution history is excluded above because it is noise. This is the
# opposite: it is the irreplaceable output of the system.
# ---------------------------------------------------------------------------
$jtRemote = "/tmp/jobtracker-$stamp.sql"
& ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "docker exec n8n-postgres pg_dump -U n8n jobtracker > $jtRemote"
if ($LASTEXITCODE -eq 0) {
    $jtLocal = Join-Path $n8nDir "jobtracker-$stamp.sql"
    Get-RemoteFile 'n8n' $jtRemote $jtLocal 'jobtracker PostgreSQL dump'
    if (Test-Path $jtLocal) {
        $jtLen  = (Get-Item $jtLocal).Length
        $jtTail = Get-Content $jtLocal -Tail 20 | Out-String   # see the note on -Tail 20 above
        if ($jtLen -lt 1024) {
            Add-Result 'jobtracker dump validation' 'FAIL' "only $jtLen bytes - empty or truncated"
        } elseif ($jtTail -notmatch 'PostgreSQL database dump complete') {
            Add-Result 'jobtracker dump validation' 'FAIL' 'missing completion marker - truncated'
        } else {
            Add-Result 'jobtracker dump validation' 'OK' "$jtLen bytes, completion marker present"
        }
    }
    & ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "rm -f $jtRemote" | Out-Null
} else {
    Add-Result 'jobtracker PostgreSQL dump' 'FAIL' "pg_dump failed (ssh exit $LASTEXITCODE)"
}

# ---------------------------------------------------------------------------
# job-finder source of truth
#
# ~/n8n-stack/job-finder/ holds build.js, codenodes.js, deploy.sh, the workflow
# JSON, the scoring system prompt and the cover-letter template. The workflows
# in n8n's database are BUILD OUTPUT; this directory is the source they are
# generated from, and it exists nowhere else - not in git, not in the n8n DB.
# 216 KB, 13 files.
# ---------------------------------------------------------------------------
$jfRemote = "/tmp/job-finder-$stamp.tar.gz"
& ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "tar czf $jfRemote -C ~/n8n-stack job-finder"
if ($LASTEXITCODE -eq 0) {
    Get-RemoteFile 'n8n' $jfRemote (Join-Path $n8nDir 'job-finder-source.tar.gz') 'job-finder source (build.js, deploy.sh, workflow JSON)'
    & ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "rm -f $jfRemote" | Out-Null
} else {
    Add-Result 'job-finder source' 'FAIL' "tar failed (ssh exit $LASTEXITCODE)"
}

Get-RemoteFile 'n8n' '~/n8n-stack/docker-compose.yml' (Join-Path $n8nDir 'docker-compose.yml') 'n8n compose file'
Get-RemoteFile 'n8n' '~/n8n-stack/scripts/restore-verification.sh' (Join-Path $n8nDir 'restore-verification.sh') 'n8n restore harness'
Save-RemoteOutput 'n8n' 'docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}"; echo; docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}"; echo; docker volume ls' (Join-Path $n8nDir 'docker-state.txt') 'n8n docker state'

# ---------------------------------------------------------------------------
# VM 102 - Docker host
# ---------------------------------------------------------------------------
Write-Host "[VM 102] Docker host..." -ForegroundColor Yellow
$dockerDir = Join-Path $stageDir 'vm102-docker'

Get-RemoteFile 'vm102' '~/docker/caddy/Caddyfile'             (Join-Path $dockerDir 'Caddyfile')                   'Caddyfile'
Get-RemoteFile 'vm102' '~/docker/caddy/docker-compose.yml'    (Join-Path $dockerDir 'caddy-docker-compose.yml')    'caddy compose'
Get-RemoteFile 'vm102' '~/docker/jellyfin/docker-compose.yml' (Join-Path $dockerDir 'jellyfin-docker-compose.yml') 'jellyfin compose'
Get-RemoteFile 'vm102' '~/secplus-drill/docker-compose.yml'   (Join-Path $dockerDir 'secplus-drill-compose.yml')   'secplus-drill compose'

# Caddy internal root CA *certificate* (public, safe). The root KEY is
# deliberately NOT backed up - see ARCHITECTURE.md 7.9.
Get-RemoteFile 'vm102' '~/caddy-root-ca.crt' (Join-Path $dockerDir 'caddy-root-ca.crt') 'Caddy root CA cert (public)'

# DVWA and portainer were started with `docker run` and have NO compose file
# (R-13). `docker inspect` is the only record of their configuration.
Save-RemoteOutput 'vm102' 'docker inspect DVWA portainer' (Join-Path $dockerDir 'no-compose-containers-inspect.json') 'DVWA/portainer inspect (R-13)'
Save-RemoteOutput 'vm102' 'docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}"; echo; docker volume ls' (Join-Path $dockerDir 'docker-state.txt') 'vm102 docker state'

# ---------------------------------------------------------------------------
# Proxmox - guest definitions
# ---------------------------------------------------------------------------
Write-Host "[Proxmox] guest definitions..." -ForegroundColor Yellow
$pveDir = Join-Path $stageDir 'proxmox'

Save-RemoteOutput 'proxmox' 'for f in /etc/pve/qemu-server/*.conf; do echo "===== $f ====="; cat "$f"; echo; done' (Join-Path $pveDir 'qemu-server-configs.txt') 'Proxmox VM configs'
Save-RemoteOutput 'proxmox' 'for f in /etc/pve/lxc/*.conf; do echo "===== $f ====="; cat "$f"; echo; done'         (Join-Path $pveDir 'lxc-configs.txt')         'Proxmox LXC configs'
Save-RemoteOutput 'proxmox' 'echo "=== qm list ==="; qm list; echo; echo "=== pct list ==="; pct list; echo; echo "=== pvesm status ==="; pvesm status; echo; echo "=== pveversion ==="; pveversion' (Join-Path $pveDir 'inventory.txt') 'Proxmox inventory'
Save-RemoteOutput 'proxmox' 'cat /etc/network/interfaces' (Join-Path $pveDir 'network-interfaces.txt') 'Proxmox network config'

# ---------------------------------------------------------------------------
# Pi-hole - DNS configuration
#
# pihole.toml holds the local DNS A records and CNAMEs that the .internal
# migration depends on (ARCHITECTURE.md 7.8). The Pi is the one lab host with
# no dependency on /dev/sda, but a microSD card is its own failure mode (R-08),
# so this is captured regardless.
# ---------------------------------------------------------------------------
Write-Host "[Pi-hole] DNS configuration..." -ForegroundColor Yellow
$piDir = Join-Path $stageDir 'pihole'

Get-RemoteFile 'pihole' '/etc/pihole/pihole.toml'  (Join-Path $piDir 'pihole.toml')  'Pi-hole config (pihole.toml)'
Get-RemoteFile 'pihole' '/etc/pihole/dnsmasq.conf' (Join-Path $piDir 'dnsmasq.conf') 'Pi-hole dnsmasq.conf'
Save-RemoteOutput 'pihole' 'pihole -v; echo; ls -la /etc/pihole/' (Join-Path $piDir 'pihole-state.txt') 'Pi-hole version/state'

# NOT captured: gravity.db (63 MB, overwhelmingly downloaded blocklist content
# that `pihole -g` regenerates). The adlist URLs inside it are genuinely not
# regenerable, but extracting them needs sqlite3 - absent on the Pi - and
# `pihole-FTL --teleporter` needs sudo to read pihole-FTL.db. Recorded in the
# manifest as a gap rather than silently dropped.

# ---------------------------------------------------------------------------
# OPNsense - entire configuration
#
# /conf/config.xml IS the firewall: interfaces, rules, users, NAT, and the WAN
# pass rules that make management reachable at all (ARCHITECTURE.md 3.4).
# Nothing else on that box needs capturing.
#
# Connects as root, whose login shell is tcsh. scp is unaffected, but any
# `ssh` command must be wrapped in /bin/sh -c - Bourne syntax sent directly
# fails with "Illegal variable name".
# ---------------------------------------------------------------------------
Write-Host "[OPNsense] firewall configuration..." -ForegroundColor Yellow
$opnDir  = Join-Path $stageDir 'opnsense'
$opnFile = Join-Path $opnDir 'config.xml'

Get-RemoteFile 'opnsense' '/conf/config.xml' $opnFile 'OPNsense config.xml'
Save-RemoteOutput 'opnsense' '/bin/sh -c "opnsense-version; echo; ifconfig -a"' (Join-Path $opnDir 'opnsense-state.txt') 'OPNsense version/interfaces'

# A truncated config.xml is as useless as a 0-byte database dump and just as
# invisible in `ls` - the same failure the n8n dump validation above exists to
# catch. Parsing it is the cheapest proof it is whole.
if (Test-Path $opnFile) {
    $opnLen = (Get-Item $opnFile).Length
    if ($opnLen -lt 4096) {
        Add-Result 'OPNsense config validation' 'FAIL' "only $opnLen bytes - truncated"
    } else {
        try {
            $null = [xml](Get-Content $opnFile -Raw)
            Add-Result 'OPNsense config validation' 'OK' "$opnLen bytes, parses as XML"
        } catch {
            Add-Result 'OPNsense config validation' 'FAIL' 'does not parse as XML - truncated or corrupt'
        }
    }
}

# ---------------------------------------------------------------------------
# Wazuh - SIEM configuration and agent roster
#
# Both files are root-only. Access comes from a narrowly scoped sudoers rule
# at /etc/sudoers.d/wazuh-backup on 192.168.0.27, added 2026-08-14:
#
#   leon ALL=(root) NOPASSWD: /usr/bin/cat /var/ossec/etc/ossec.conf,
#                             /usr/bin/cat /var/ossec/etc/client.keys
#
# The rule is ARGUMENT-PINNED. Verified 2026-08-14 that `sudo -n cat` on an
# unpinned path is refused, and that appending a second path to a pinned
# command is also refused.
#
# `sudo -n` is deliberate: if that rule is ever removed, an unattended run
# fails loudly instead of hanging forever on a password prompt.
#
# *** SCOPE CONDITION - READ BEFORE WRITING CUSTOM WAZUH RULES ***
# The pin list covers exactly two files. /var/ossec/etc/rules/local_rules.xml
# and /var/ossec/etc/decoders/local_decoder.xml are stock and unmodified since
# the September 2025 install, so they are excluded ON PURPOSE. The moment
# custom rules or decoders are written, the sudoers rule must be extended and
# this section updated - otherwise the backup silently omits them and nothing
# here will complain.
#
# client.keys holds AGENT AUTHENTICATION MATERIAL. Capturing it is what makes
# restore-without-re-enrollment possible. See scripts/README.md.
# ---------------------------------------------------------------------------
Write-Host "[Wazuh] SIEM configuration..." -ForegroundColor Yellow
$wzDir = Join-Path $stageDir 'wazuh'

# Read via sudo into a temp file, then scp. This preserves the file bytes
# exactly, where piping ssh stdout through PowerShell would re-encode it
# (BOM + CRLF). The redirect runs as the SSH user, so it sits outside the
# sudo pin and is allowed. `umask 077` keeps the transient copy private.
foreach ($wf in @(
    @{ Remote = '/var/ossec/etc/ossec.conf';  Local = 'ossec.conf';  Label = 'Wazuh ossec.conf' },
    @{ Remote = '/var/ossec/etc/client.keys'; Local = 'client.keys'; Label = 'Wazuh client.keys (agent roster)' }
)) {
    $wzTmp = "/tmp/wz-$stamp-$($wf.Local)"
    & ssh -o BatchMode=yes -o ConnectTimeout=10 wazuh "(umask 077; sudo -n cat $($wf.Remote) > $wzTmp)"
    if ($LASTEXITCODE -eq 0) {
        Get-RemoteFile 'wazuh' $wzTmp (Join-Path $wzDir $wf.Local) $wf.Label
        & ssh -o BatchMode=yes -o ConnectTimeout=10 wazuh "rm -f $wzTmp" | Out-Null
    } else {
        Add-Result $wf.Label 'FAIL' "sudo -n refused (exit $LASTEXITCODE) - is /etc/sudoers.d/wazuh-backup still present?"
    }
}

# ossec.conf is validated by a WRAPPED parse, not a plain one.
#
# Wazuh permits MULTIPLE root-level <ossec_config> blocks - this install has
# two - which is not well-formed XML. A strict [xml] cast fails on a perfectly
# healthy file, which would mark every nightly run as failed. Wrapping in a
# synthetic root validates element structure and still rejects truncation;
# verified 2026-08-14 that chopping the tail off the real file is caught.
$wzConf = Join-Path $wzDir 'ossec.conf'
if (Test-Path $wzConf) {
    $wzLen = (Get-Item $wzConf).Length
    if ($wzLen -lt 1024) {
        Add-Result 'Wazuh ossec.conf validation' 'FAIL' "only $wzLen bytes - truncated"
    } else {
        try {
            $null = [xml]("<validation-root>" + (Get-Content $wzConf -Raw) + "</validation-root>")
            Add-Result 'Wazuh ossec.conf validation' 'OK' "$wzLen bytes, XML structure valid"
        } catch {
            Add-Result 'Wazuh ossec.conf validation' 'FAIL' 'malformed XML - truncated or corrupt'
        }
    }
}

# client.keys is one agent per line: id name ip key
$wzKeys = Join-Path $wzDir 'client.keys'
if (Test-Path $wzKeys) {
    $wzkLen = (Get-Item $wzKeys).Length
    if ($wzkLen -lt 16) {
        Add-Result 'Wazuh client.keys validation' 'FAIL' "only $wzkLen bytes - empty or truncated"
    } else {
        $agentCount = @(Get-Content $wzKeys | Where-Object { $_.Trim() -ne '' }).Count
        Add-Result 'Wazuh client.keys validation' 'OK' "$wzkLen bytes, $agentCount agent entries"
    }
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
$stagedBytes = (Get-ChildItem $stageDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$okCount     = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$failCount   = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count

$manifest = @"
HOMELAB TIER 1 BACKUP
=====================
Run:      $stamp
Host:     $env:COMPUTERNAME
Staged:   $([math]::Round($stagedBytes/1MB, 2)) MB
Result:   $okCount OK, $failCount FAILED

*** THIS ARCHIVE CONTAINS REAL SECRETS ***
Compose files carry N8N_ENCRYPTION_KEY and database credentials inline.
Proxmox guest configs may carry cloud-init passwords and SSH keys.
OPNsense config.xml is the complete firewall, including user hashes.
Wazuh client.keys is AGENT AUTHENTICATION MATERIAL - anyone holding it can
impersonate a Wazuh agent to the manager. Capturing it is deliberate: it is
what makes restore without re-enrolling every agent possible.
Encrypted with 7-Zip AES-256 and encrypted headers. Never commit it.

CONTENTS
$($results | Format-Table -AutoSize | Out-String)

GAPS - not covered by this run
  - Wazuh custom rules          /var/ossec/etc/rules/local_rules.xml and
    and decoders                decoders/local_decoder.xml are NOT in the
                                sudoers pin list. They are stock and
                                unmodified, so this is deliberate. IF YOU
                                EVER WRITE CUSTOM RULES OR DECODERS, extend
                                /etc/sudoers.d/wazuh-backup and this script
                                or they will be silently omitted.
  - Wazuh indexer/dashboard     configs are root-only and not pinned. The
                                manager config and agent roster ARE captured.
  - n8n execution HISTORY       deliberately excluded from the dump (schema
                                is kept, rows are not). ~1,200 executions/day
                                from the 60s Telegram poll made it 97% of a
                                39 MB dump. A restore needs workflows and
                                credentials, not a log of past runs.
  - Pi-hole adlist URLs         live in gravity.db (63 MB). Not extracted:
                                sqlite3 is absent on the Pi and the native
                                teleporter export needs sudo. The rest of
                                the Pi-hole configuration IS captured.
  - Full VM images (Tier 2)     ~127 GB, requires storage hardware

RESTORE
  n8n:      see n8n-ai-agents/README.md section 7. Requires
            N8N_ENCRYPTION_KEY from Bitwarden - the dump alone is NOT
            sufficient. Verified working 2026-08-12. The restored instance
            comes up with an EMPTY execution history, by design.
  job-      restore jobtracker-*.sql into a `jobtracker` database on the
  finder:   same PostgreSQL instance, then unpack job-finder-source.tar.gz
            to ~/n8n-stack/job-finder/ and redeploy per its deploy.sh.
            The workflows inside n8n are BUILD OUTPUT - that directory is
            the source they come from.
  Proxmox:  guest configs are reference material, not bootable images.
            They rebuild the definition, not the disk contents.
  OPNsense: config.xml rebuilds the ENTIRE firewall. Restore via
            System > Configuration > Backups > Restore, or copy to
            /conf/config.xml and reboot. Note the WAN/LAN inversion
            documented in ARCHITECTURE.md 3.4 before editing rules.
  Pi-hole:  pihole.toml and dnsmasq.conf drop back into /etc/pihole/,
            then restart pihole-FTL. Adlists must be re-added by hand.
  Wazuh:    reinstall via the official all-in-one installer, then restore
            ossec.conf and client.keys to /var/ossec/etc/ (root:wazuh,
            client.keys 0640) and restart wazuh-manager. Restoring
            client.keys is what avoids re-enrolling every agent - without
            it, each agent must be registered again by hand.
"@
$manifest | Out-File -FilePath (Join-Path $stageDir 'MANIFEST.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# Encrypt, verify, then destroy the plaintext
# ---------------------------------------------------------------------------
Write-Host "`n[Encrypt] packing archive..." -ForegroundColor Yellow

$secure = Get-Content $PasswordFile | ConvertTo-SecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

$archive = Join-Path $Destination "tier1-$stamp.7z"

# -mhe=on encrypts the file NAMES too, not just contents.
& $sevenZip a -t7z "-p$plain" -mhe=on -mx=9 $archive "$stageDir\*" | Out-Null
$packRc = $LASTEXITCODE

$verified = $false
if ($packRc -eq 0 -and (Test-Path $archive)) {
    # Prove it opens with the stored password before deleting the plaintext.
    & $sevenZip t "-p$plain" $archive | Out-Null
    if ($LASTEXITCODE -eq 0) { $verified = $true }
}
$plain = $null
[System.GC]::Collect()

if ($verified) {
    Remove-Item $stageDir -Recurse -Force
    $archiveSize = (Get-Item $archive).Length
    Write-Host "  archive verified, plaintext staging deleted" -ForegroundColor Green
    Add-Result 'Encrypted archive' 'OK' "$archiveSize bytes, AES-256 + encrypted headers"
} else {
    Write-Host "  ENCRYPTION OR VERIFICATION FAILED - staging left at $stageDir" -ForegroundColor Red
    Write-Host "  That directory contains PLAINTEXT SECRETS. Handle it." -ForegroundColor Red
    Add-Result 'Encrypted archive' 'FAIL' "7z pack=$packRc verify failed"
    $failCount++
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
$allRuns = Get-ChildItem $Destination -Filter 'tier1-*.7z' -File | Sort-Object Name -Descending
if ($allRuns.Count -gt $KeepRuns) {
    $allRuns | Select-Object -Skip $KeepRuns | ForEach-Object {
        Write-Host "  pruning: $($_.Name)" -ForegroundColor DarkGray
        Remove-Item $_.FullName -Force
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
$results | Format-Table -AutoSize
if ($verified) { Write-Host "Archive: $archive" }

if ($failCount -gt 0) {
    Write-Host "`n$failCount item(s) FAILED - backup is incomplete." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll $okCount items captured and encrypted." -ForegroundColor Green
    exit 0
}
