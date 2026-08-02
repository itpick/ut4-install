param([string]$Platform, [string]$BuildTag, [string]$InstallDir)
#
# sync-client.ps1 - PowerShell port of scripts/sync-client.sh (Windows installer).
# Incrementally sync a UT4 client from the content-addressed store to $InstallDir:
# download ONLY files whose sha256 differs from the installed manifest, pull their
# blocks from release client-<platform>-store, assemble + SHA-256 verify each file.
# Parses the tab-separated manifest.tsv (no ConvertFrom-Json). Runs in-process
# (invoked by install.ps1 via ScriptBlock) or standalone.
$ErrorActionPreference = "Stop"
$Repo     = if ($env:UT_REPO) { $env:UT_REPO } else { "itpick/ut4-install" }
$StoreTag = "client-$Platform-store"
$DlBase   = "https://github.com/$Repo/releases/download"
$Par      = if ($env:UT_PAR) { [int]$env:UT_PAR } else { 6 }
# Optional self-hosted mirror (CDN/origin) tried first for the manifest + every block, with
# GitHub as the backup/source of truth (ut4-install#23). Off by default: empty = zero behavior
# change. Layout must mirror GitHub Releases exactly: $MirrorBase/<tag>/<asset>.
$MirrorBase = if ($env:UT_MIRROR_BASE) { $env:UT_MIRROR_BASE } else { "" }
$Cache    = Join-Path $InstallDir ".blockcache"
$Local    = Join-Path $InstallDir ".installed-manifest.tsv"
function Say($m){ Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) }
# A cached block is valid iff it hashes to its own name (blocks are content-addressed). Split
# parts are named <filesha>.part-xx (not name-verifiable) -> accept if non-empty; the assembled
# file's sha256 (step 5) is the backstop. Catches truncated/corrupt but non-empty downloads.
function Block-Valid($path, $name) {
  if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { return $false }
  if ($name -like '*.part-*') { return $true }
  return ((Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() -eq $name.ToLower())
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

# 1) fetch manifest.tsv. NB: download to a file, not .Content - GitHub serves release
# assets as octet-stream so .Content is a byte[]. tab-separated: path sha256 size blocks-csv
Say "fetching manifest for $BuildTag ..."
$mfile = Join-Path $Cache "manifest.tsv"
$gotManifest = $false
if ($MirrorBase) {
  try { Invoke-WebRequest -Uri "$MirrorBase/$BuildTag/manifest.tsv" -OutFile $mfile -UseBasicParsing -TimeoutSec 5; $gotManifest = $true } catch {}
}
if (-not $gotManifest) {
  try { Invoke-WebRequest -Uri "$DlBase/$BuildTag/manifest.tsv" -OutFile $mfile -UseBasicParsing }
  catch { throw "no manifest.tsv at $BuildTag" }
}
$files = @()
foreach ($ln in (Get-Content $mfile)) {
  if ($ln -eq "") { continue }
  $p = $ln -split "`t"
  $files += [pscustomobject]@{ path=$p[0]; sha256=$p[1]; size=$p[2]; blocks=@($p[3] -split ',') }
}
$nf = $files.Count
Say "manifest lists $nf files"

# 2) installed shas
$lsha = @{}
if (Test-Path $Local) { foreach ($ln in (Get-Content $Local)) { if ($ln -ne "") { $q = $ln -split "`t"; $lsha[$q[0]] = $q[1] } } }

# 3) which files changed?
$need = @()
foreach ($f in $files) {
  $target = Join-Path $InstallDir ($f.path -replace '/','\')
  # Bootstrap: no recorded manifest entry but the file is already on disk (bulk-tarball
  # install or interrupted sync) -> hash it so unchanged files are skipped, not re-downloaded.
  $osha = $lsha[$f.path]
  if (-not $osha -and (Test-Path $target)) { $osha = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLower() }
  if ($osha -eq $f.sha256 -and (Test-Path $target)) { continue }
  $need += $f
}
Say ("need to update {0}/{1} files" -f $need.Count, $nf)

if ($need.Count -gt 0) {
  # 4) unique blocks to fetch
  $blockset = @{}
  foreach ($f in $need) { foreach ($b in $f.blocks) { if ($b -ne "" -and $b -ne "-") { $blockset[$b] = 1 } } }
  $blist = @($blockset.Keys)
  Say ("fetching {0} unique blocks (parallel x{1}) ..." -f $blist.Count, $Par)

  # download with integrity verification: each single-sha block must hash to its name; corrupt or
  # truncated blocks are dropped and re-fetched (a non-empty but short block would otherwise
  # assemble into a bad file). No -C - resume: rm a bad partial and pull it fresh.
  function Fetch-Blocks($blocks, $base) {
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    $queue = New-Object System.Collections.Queue
    foreach ($b in $blocks) { $queue.Enqueue($b) }
    $active = @()
    while ($queue.Count -gt 0 -or $active.Count -gt 0) {
      while ($active.Count -lt $Par -and $queue.Count -gt 0) {
        $b = $queue.Dequeue(); $out = Join-Path $Cache $b; $url = "$base/$StoreTag/$b"
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        if ($curl) {
          $psi = New-Object System.Diagnostics.ProcessStartInfo
          $psi.FileName        = $curl
          $psi.Arguments       = "-fL --retry 3 --retry-delay 2 -o `"$out`" `"$url`""
          $psi.UseShellExecute = $false
          $psi.CreateNoWindow  = $true
          $active += [System.Diagnostics.Process]::Start($psi)
        } else {
          Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        }
      }
      if ($active.Count -gt 0) { Start-Sleep -Milliseconds 200; $active = @($active | Where-Object { -not $_.HasExited }) }
    }
  }
  # First pass: the mirror if configured (self-host - ut4-install#23), else GitHub directly.
  $firstBase = if ($MirrorBase) { $MirrorBase } else { $DlBase }
  if ($MirrorBase) { Say "trying self-hosted mirror first ($MirrorBase) ..." }
  Fetch-Blocks (@($blist | Where-Object { -not (Block-Valid (Join-Path $Cache $_) $_) })) $firstBase
  # Second pass: re-fetch anything incomplete/corrupt/missing - always from GitHub. This is both
  # the existing corrupt-download retry AND the mirror-miss fallback: a mirror missing some
  # blocks (lazy-seeded CDN, partial rsync, unreachable) degrades to plain GitHub for just the
  # blocks it didn't have, instead of failing the whole sync.
  $bad = @($blist | Where-Object { -not (Block-Valid (Join-Path $Cache $_) $_) })
  if ($bad.Count -gt 0) {
    if ($firstBase -ne $DlBase) { Say "some blocks missing on the mirror - falling back to GitHub ..." }
    else { Say "re-fetching incomplete/corrupt blocks ..." }
    Fetch-Blocks $bad $DlBase
  }
  foreach ($b in $blist) { if (-not (Block-Valid (Join-Path $Cache $b) $b)) { throw "block bad/missing: $b (re-run to resume)" } }

  # 5) assemble each file from its blocks (in order) and verify sha256
  foreach ($f in $need) {
    $target = Join-Path $InstallDir ($f.path -replace '/','\')
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    $tmp = "$target.uttmp"
    $o = [System.IO.File]::Create($tmp)
    try { foreach ($b in $f.blocks) { if ($b -eq "" -or $b -eq "-") { continue }; $in = [System.IO.File]::OpenRead((Join-Path $Cache $b)); try { $in.CopyTo($o) } finally { $in.Close() } } }
    finally { $o.Close() }
    $got = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLower()
    if ($got -ne $f.sha256.ToLower()) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw ("sha mismatch: {0}" -f $f.path) }
    Move-Item -Force $tmp $target
  }
  Say ("assembled + verified {0} files" -f $need.Count)
}

# 6) clean update: remove files in the old manifest but not the new one
if (Test-Path $Local) {
  $newpaths = @{}; foreach ($f in $files) { $newpaths[$f.path] = 1 }
  foreach ($ln in (Get-Content $Local)) {
    if ($ln -ne "") { $q = $ln -split "`t"; if (-not $newpaths[$q[0]]) { $t = Join-Path $InstallDir ($q[0] -replace '/','\'); Remove-Item $t -Force -ErrorAction SilentlyContinue; Write-Host "  - removed $($q[0])" } }
  }
}

# 7) record installed manifest (copy out of cache before deleting it), drop the block cache
Copy-Item -Force $mfile $Local
Remove-Item -Recurse -Force $Cache -ErrorAction SilentlyContinue
Say ("SYNC-OK {0} -> {1} ({2} files updated)" -f $BuildTag, $InstallDir, $need.Count)
