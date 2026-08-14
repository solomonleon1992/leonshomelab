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
    Requires 7-Zip and SSH aliases: proxmox, vm102, n8n, pihole, opnsense.

    Wazuh is deliberately NOT covered. SSH key access works, but every Wazuh
    config path - /var/ossec/etc/*, the indexer and dashboard configs - is
    root-only, and the backup account has no passwordless sudo. Verified
    2026-08-14. Closing that gap is a privilege decision (ARCHITECTURE.md
    7.6), not something this script should quietly work around.
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
foreach ($sub in 'vm105-n8n', 'vm102-docker', 'proxmox', 'pihole', 'opnsense') {
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

$dumpRemote = "/tmp/n8n-backup-$stamp.sql"
& ssh -o BatchMode=yes -o ConnectTimeout=10 n8n "docker exec n8n-postgres pg_dump -U n8n n8n > $dumpRemote"
if ($LASTEXITCODE -eq 0) {
    $dumpLocal = Join-Path $n8nDir "n8n-database-$stamp.sql"
    Get-RemoteFile 'n8n' $dumpRemote $dumpLocal 'n8n PostgreSQL dump'

    # A 0-byte dump is indistinguishable from a real one in `ls`. That exact
    # failure produced a fake backup on VM 102 that went unnoticed for 10 days.
    if (Test-Path $dumpLocal) {
        $len  = (Get-Item $dumpLocal).Length
        $tail = Get-Content $dumpLocal -Tail 5 | Out-String
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
Encrypted with 7-Zip AES-256 and encrypted headers. Never commit it.

CONTENTS
$($results | Format-Table -AutoSize | Out-String)

GAPS - not covered by this run
  - Wazuh (192.168.0.27)        SSH key access WORKS, but /var/ossec/etc/*
                                and the indexer/dashboard configs are all
                                root-only and this account has no
                                passwordless sudo. Verified 2026-08-14.
                                Pending a privilege decision - see
                                ARCHITECTURE.md 7.6.
  - Pi-hole adlist URLs         live in gravity.db (63 MB). Not extracted:
                                sqlite3 is absent on the Pi and the native
                                teleporter export needs sudo. The rest of
                                the Pi-hole configuration IS captured.
  - Full VM images (Tier 2)     ~127 GB, requires storage hardware

RESTORE
  n8n:      see n8n-ai-agents/README.md section 7. Requires
            N8N_ENCRYPTION_KEY from Bitwarden - the dump alone is NOT
            sufficient. Verified working 2026-08-12.
  Proxmox:  guest configs are reference material, not bootable images.
            They rebuild the definition, not the disk contents.
  OPNsense: config.xml rebuilds the ENTIRE firewall. Restore via
            System > Configuration > Backups > Restore, or copy to
            /conf/config.xml and reboot. Note the WAN/LAN inversion
            documented in ARCHITECTURE.md 3.4 before editing rules.
  Pi-hole:  pihole.toml and dnsmasq.conf drop back into /etc/pihole/,
            then restart pihole-FTL. Adlists must be re-added by hand.
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
