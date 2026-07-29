param([string]$Platform, [string]$BuildTag, [string]$InstallDir)
#
# sync-client.ps1 - PowerShell port of scripts/sync-client.sh (Windows installer).
# Incrementally sync a UT4 client from the content-addressed store to $InstallDir:
# download ONLY files whose sha256 differs from the installed manifest, pull their
# blocks from release client-<platform>-store, assemble + SHA-256 verify each file.
# Runs in-process (invoked by install.ps1 via ScriptBlock) or standalone.
$ErrorActionPreference = "Stop"
$Repo     = if ($env:UT_REPO) { $env:UT_REPO } else { "itpick/ut4-install" }
$StoreTag = "client-$Platform-store"
$DlBase   = "https://github.com/$Repo/releases/download"
$Par      = if ($env:UT_PAR) { [int]$env:UT_PAR } else { 6 }
$Cache    = Join-Path $InstallDir ".blockcache"
$Local    = Join-Path $InstallDir ".installed-manifest.json"
function Say($m){ Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

# 1) fetch the chosen build's manifest. NB: download to a file, not .Content -
# GitHub serves release assets as octet-stream, so .Content is a byte[] that
# ConvertFrom-Json silently misparses; reading the file as text avoids that.
Say "fetching manifest for $BuildTag ..."
$mfile = Join-Path $Cache "manifest.json"
try { Invoke-WebRequest -Uri "$DlBase/$BuildTag/manifest.json" -OutFile $mfile -UseBasicParsing }
catch { throw "no manifest.json at $BuildTag" }
$mtext = Get-Content $mfile -Raw
$man = $mtext | ConvertFrom-Json
$nf  = @($man.files).Count
Say "manifest lists $nf files"

# 2) installed shas
$lsha = @{}
if (Test-Path $Local) {
  try { $lman = (Get-Content $Local -Raw) | ConvertFrom-Json; foreach ($f in $lman.files) { $lsha[$f.path] = $f.sha256 } } catch {}
}

# 3) which files changed?
$need = @()
foreach ($f in $man.files) {
  $target = Join-Path $InstallDir ($f.path -replace '/','\')
  if ($lsha[$f.path] -eq $f.sha256 -and (Test-Path $target)) { continue }
  $need += $f
}
Say ("need to update {0}/{1} files" -f $need.Count, $nf)

if ($need.Count -gt 0) {
  # 4) unique blocks to fetch
  $blockset = @{}
  foreach ($f in $need) { foreach ($b in $f.blocks) { $blockset[$b] = 1 } }
  $blist = @($blockset.Keys)
  Say ("fetching {0} unique blocks (parallel x{1}) ..." -f $blist.Count, $Par)

  $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  $queue = New-Object System.Collections.Queue
  foreach ($b in $blist) {
    $bp = Join-Path $Cache $b
    if (-not (Test-Path $bp) -or (Get-Item $bp).Length -eq 0) { $queue.Enqueue($b) }
  }
  $active = @()
  while ($queue.Count -gt 0 -or $active.Count -gt 0) {
    while ($active.Count -lt $Par -and $queue.Count -gt 0) {
      $b = $queue.Dequeue(); $out = Join-Path $Cache $b; $url = "$DlBase/$StoreTag/$b"
      if ($curl) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $curl
        $psi.Arguments       = "-fL --retry 3 --retry-delay 2 -C - -o `"$out`" `"$url`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $active += [System.Diagnostics.Process]::Start($psi)
      } else {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
      }
    }
    if ($active.Count -gt 0) { Start-Sleep -Milliseconds 200; $active = @($active | Where-Object { -not $_.HasExited }) }
  }
  # every block present + non-empty (a partial/failed block will fail the sha check below and can be resumed)
  foreach ($b in $blist) { $bp = Join-Path $Cache $b; if (-not (Test-Path $bp) -or (Get-Item $bp).Length -eq 0) { throw "block missing: $b (re-run to resume)" } }

  # 5) assemble each file from its blocks (in order) and verify sha256
  foreach ($f in $need) {
    $target = Join-Path $InstallDir ($f.path -replace '/','\')
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    $tmp = "$target.uttmp"
    $out = [System.IO.File]::Create($tmp)
    try { foreach ($b in $f.blocks) { $in = [System.IO.File]::OpenRead((Join-Path $Cache $b)); try { $in.CopyTo($out) } finally { $in.Close() } } }
    finally { $out.Close() }
    $got = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLower()
    if ($got -ne $f.sha256.ToLower()) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; throw ("sha mismatch: {0}" -f $f.path) }
    Move-Item -Force $tmp $target
  }
  Say ("assembled + verified {0} files" -f $need.Count)
}

# 6) clean update: remove files in the old manifest but not the new one
if (Test-Path $Local) {
  $newpaths = @{}; foreach ($f in $man.files) { $newpaths[$f.path] = 1 }
  $lman = (Get-Content $Local -Raw) | ConvertFrom-Json
  foreach ($f in $lman.files) {
    if (-not $newpaths[$f.path]) { $t = Join-Path $InstallDir ($f.path -replace '/','\'); Remove-Item $t -Force -ErrorAction SilentlyContinue; Write-Host "  - removed $($f.path)" }
  }
}

# 7) record installed manifest, drop the block cache
Set-Content -Path $Local -Value $mtext -Encoding UTF8
Remove-Item -Recurse -Force $Cache -ErrorAction SilentlyContinue
Say ("SYNC-OK {0} -> {1} ({2} files updated)" -f $BuildTag, $InstallDir, $need.Count)
