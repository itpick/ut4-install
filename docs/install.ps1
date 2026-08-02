<#
  UT4 on Unreal Engine 5.8 - Windows (Win64) installer

  Works either way:
    irm https://itpick.github.io/ut4-install/install.ps1 | iex
    powershell -ExecutionPolicy Bypass -File .\install.ps1     # after downloading

  Downloads the Windows client (single tarball or split <2 GB parts) + the full
  map set, verifies, extracts with bsdtar (ships in Win10/11), and launches it.
  Safe to re-run.

  When more than one client build is published, the installer lists them and lets
  you pick with the Up/Down arrows (Enter = latest). Parts download in parallel.

  This script is pipe-safe: it takes no positional args and does not rely on its
  own path. When piped through `iex`, set options via environment variables:
    $env:UT_NO_MAPS       = "1"                # skip the ~40 map paks
    $env:UT_DIR           = "D:\Games\UT"      # custom install dir
    $env:UT_DOWNLOAD_BASE = "https://.../tag"  # pin a specific release, skip the picker
  When run as a file you can instead pass -NoMaps / -InstallDir / -DownloadBase.
#>

[CmdletBinding()]
param(
  # Empty by default: the installer discovers published client builds (release
  # tags starting with $ClientPrefix) and lets you pick. Set this (or
  # $env:UT_DOWNLOAD_BASE) to a release-download URL to pin one and skip the picker.
  # Expected asset names at the chosen tag:
  #   ut4-client-win64.tar.zst            (single file, if not split)
  #   ut4-client-win64.tar.zst.part-aa    ut4-client-win64.tar.zst.part-ab  ...
  [string]$DownloadBase = $(if ($env:UT_DOWNLOAD_BASE) { $env:UT_DOWNLOAD_BASE } else { "" }),
  [string]$InstallDir   = $(if ($env:UT_DIR) { $env:UT_DIR } else { Join-Path $env:USERPROFILE "UnrealTournament58" }),
  # Release channel: "stable" (default, pinned + tested) or "nightly" (latest dev build).
  # The client tag is client-win64-<channel>; the shared block store is client-win64-store.
  [string]$Channel      = $(if ($env:UT_CHANNEL) { $env:UT_CHANNEL } else { "stable" }),
  # Optional self-hosted mirror (CDN/origin) tried before GitHub - GitHub remains the
  # backup / source of truth (#23). Off by default: empty = zero behavior change. Its
  # layout must mirror GitHub Releases exactly: $MirrorBase/<tag>/<asset>.
  [string]$MirrorBase  = $(if ($env:UT_MIRROR_BASE) { $env:UT_MIRROR_BASE } else { "" }),
  [switch]$Nightly,
  [switch]$Stable,
  [switch]$NoMaps,
  [switch]$Details,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
# Belt-and-suspenders: Windows PowerShell 5.1's default console codepage isn't
# UTF-8, so nudge output to UTF-8. All printed strings are plain ASCII anyway.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Archive      = "ut4-client-win64.tar.zst"
$Exe          = "UnrealTournament.exe"
$MapsTag      = "maps-win-v1"           # existing release with the per-map paks
$Repo         = "itpick/ut4-install"
$ClientPrefix = "client-win64-"         # release tags for Win64 client builds
if ($env:UT_NO_MAPS -eq "1") { $NoMaps = $true }
$WantMaps = -not $NoMaps
if ($Nightly) { $Channel = "nightly" }
if ($Stable)  { $Channel = "stable" }

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "OK  $m"  -ForegroundColor Green }
function Warn ($m) { Write-Host "!   $m"  -ForegroundColor Yellow }
function Die  ($m) { try { Write-Progress -Activity $script:Phase -Completed } catch {}; Write-Host "X   $m"  -ForegroundColor Red; if ([Environment]::UserInteractive) { try { Read-Host "Press Enter to close" } catch {} }; exit 1 }

# ---- progress UI: a single Write-Progress band (phase title + bar) by default; press 'd'
# any time during downloads (or pass -Details / UT_DETAILS=1) to toggle the verbose log.
# $global:UTDetailed is shared with sync-client.ps1 so the toggle is sticky across both. ----
$global:UTDetailed = [bool]$Details -or ($env:UT_DETAILS -eq '1')
$script:Phase = ""
function Poll-Toggle {
  try {
    while ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      if ("$($k.KeyChar)" -match '[dD]') {
        $global:UTDetailed = -not $global:UTDetailed
        if ($global:UTDetailed) { try { Write-Progress -Activity $script:Phase -Completed } catch {}; Write-Host "  -- details ON (press d to hide) --" -ForegroundColor DarkGray }
        else { Write-Host "  -- details OFF --" -ForegroundColor DarkGray }
      }
    }
  } catch {}
}
function Phase($t) {
  $script:Phase = $t
  if ($global:UTDetailed) { Write-Host ""; Say $t }
  else { Write-Progress -Activity $t -Status "working ... (press d for details)" -PercentComplete 0 }
}
function Prog([int]$p, [string]$s) {
  Poll-Toggle
  if ($p -lt 0) { $p = 0 } elseif ($p -gt 100) { $p = 100 }
  if (-not $global:UTDetailed) { Write-Progress -Activity $script:Phase -Status $s -PercentComplete $p }
}
function Detail($m) { if ($global:UTDetailed) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor DarkGray } }
function End-Phase { if ($script:Phase) { try { Write-Progress -Activity $script:Phase -Completed } catch {}; $script:Phase = "" } }

# Arrow-key selector. Up/Down to move, Enter to choose. Returns the selected item.
# Falls back to the first item (the latest build) when there's no interactive
# console - e.g. under automation or a host without ReadKey/cursor support.
function Menu-Pick {
  param([string[]]$Options)
  $n = $Options.Count
  if ($n -le 1) { return $(if ($n -eq 1) { $Options[0] } else { "" }) }
  try {
    if ([Console]::IsInputRedirected) { return $Options[0] }
    $sel = 0
    $render = {
      for ($i = 0; $i -lt $n; $i++) {
        $line = if ($i -eq $sel) { "  > $($Options[$i])" } else { "    $($Options[$i])" }
        $pad  = ' ' * [Math]::Max(0, [Console]::WindowWidth - 1 - $line.Length)
        if ($i -eq $sel) { Write-Host ($line + $pad) -ForegroundColor Cyan }
        else             { Write-Host ($line + $pad) }
      }
    }
    & $render
    while ($true) {
      $key = [Console]::ReadKey($true)
      if     ($key.Key -eq 'UpArrow')   { $sel = ($sel - 1 + $n) % $n }
      elseif ($key.Key -eq 'DownArrow') { $sel = ($sel + 1) % $n }
      elseif ($key.Key -eq 'Enter')     { break }
      else   { continue }
      [Console]::SetCursorPosition(0, [Console]::CursorTop - $n)
      & $render
    }
    return $Options[$sel]
  } catch { return $Options[0] }
}

# Resolve the release-download base: an explicit -DownloadBase / env override wins;
# otherwise pin to the selected channel tag (client-win64-stable by default,
# client-win64-nightly with -Nightly).
function Resolve-DownloadBase {
  if ($DownloadBase) { return $DownloadBase }
  return "https://github.com/$Repo/releases/download/${ClientPrefix}${Channel}"
}

$tar = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tar) { Die "tar was not found. Windows 10 (1803+) and Windows 11 ship bsdtar; update Windows, or extract with 7-Zip." }

$DownloadBase = Resolve-DownloadBase
if (-not $DownloadBase) { $DownloadBase = "https://github.com/$Repo/releases/download/${ClientPrefix}stable" }

# Content-addressed store wiring (incremental updates). $Plat from the client prefix;
# $BuildTag is the resolved release tag. When the build publishes a manifest.json we
# sync only changed files from client-<plat>-store; otherwise fall back to the tarball.
$BuildTag = ($DownloadBase -split '/')[-1]
$Plat     = ($ClientPrefix -replace '^client-','') -replace '-$',''

Write-Host ""
Say "UT4 on Unreal Engine 5.8 - Windows installer"
Write-Host "    Install dir: $InstallDir" -ForegroundColor DarkGray
Write-Host "    Channel:     $Channel$(if ($Channel -eq 'nightly') { '  (latest dev build - may be unstable)' })" -ForegroundColor DarkGray
Write-Host "    Client src:  $DownloadBase" -ForegroundColor DarkGray
Write-Host "    Maps:        $(if ($WantMaps) { "full set ($MapsTag)" } else { 'skipped (-NoMaps)' })" -ForegroundColor DarkGray
Write-Host "    $(if ($global:UTDetailed) { 'Showing detailed log (press d to hide).' } else { 'Tip: press d during download to show/hide the detailed log.' })" -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exePath = Join-Path $InstallDir $Exe

function Url-Exists([string]$url) {
  try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null; return $true } catch { return $false }
}
function Fetch([string]$url, [string]$dest) {
  Say "Downloading $(Split-Path $dest -Leaf) ..."
  Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}
# Resolve-AssetUrl <asset> - prefer the mirror (quick HEAD probe, short timeout) if configured
# and it actually has this asset; otherwise use GitHub. Existence discovery of which parts exist
# at all still runs against GitHub above; this only picks where the bytes come from.
function Resolve-AssetUrl([string]$asset) {
  if ($MirrorBase) {
    $murl = "$MirrorBase/$BuildTag/$asset"
    try { Invoke-WebRequest -Uri $murl -Method Head -UseBasicParsing -TimeoutSec 4 | Out-Null; return $murl } catch {}
  }
  return "$DownloadBase/$asset"
}

function Install-Client {
  # Prefer incremental content-addressed sync when the build publishes a manifest.
  # Downloads only files whose hash changed vs the installed manifest (fresh install
  # pulls everything; an update pulls just the delta). Falls back to the full tarball
  # if the manifest or the sync helper isn't reachable.
  if (Url-Exists "$DownloadBase/manifest.tsv") {
    Detail "Incremental update available - syncing only changed files ..."
    try {
      # Propagate -MirrorBase into the in-process sync script even when it was passed as a
      # parameter rather than $env:UT_MIRROR_BASE (the script reads the env var directly).
      if ($MirrorBase) { $env:UT_MIRROR_BASE = $MirrorBase }
      $sctext = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/main/scripts/sync-client.ps1" -UseBasicParsing).Content
      if ($sctext -is [byte[]]) { $sctext = [Text.Encoding]::UTF8.GetString($sctext) }
      $sb = [ScriptBlock]::Create($sctext)
      & $sb $Plat $BuildTag $InstallDir    # drives its own progress phases; shares $global:UTDetailed
      End-Phase
      Ok "Client up to date (incremental)."
      return
    } catch {
      End-Phase
      Warn "Incremental sync failed ($($_.Exception.Message)) - falling back to the full archive."
    }
  }

  if ((Test-Path $exePath) -and -not $Force) {
    Ok "Client already present at $InstallDir"
    $ans = Read-Host "Re-download and reinstall the client? [y/N]"
    if ($ans -notmatch '^[yY]') { return }
  }
  $work = Join-Path $InstallDir ".download"
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $final = Join-Path $work $Archive
  $curl  = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source

  # Locate -> download (parallel) -> join -> integrity-check, with one clean-retry.
  # A stale/partial cached part (curl -C - resumes a full-size stale file and never
  # refreshes it, e.g. after a re-upload) is purged and re-fetched fresh, once.
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    Phase "Downloading UT4"
    Detail "Locating client parts ..."
    $suffixes = @()
    if (Url-Exists "$DownloadBase/$Archive") {
      $suffixes = @("")
    } else {
      $letters = [char[]](97..122)
      foreach ($c1 in $letters) {
        $gap = $false
        foreach ($c2 in $letters) {
          if (Url-Exists "$DownloadBase/$Archive.part-$c1$c2") { $suffixes += "part-$c1$c2" }
          else { $gap = $true; break }
        }
        if ($gap) { break }
      }
    }
    if ($suffixes.Count -eq 0) { Die "No client found at $DownloadBase (checked single file and part-aa). The client release may not be uploaded yet - see the README for the manual (oras) install." }

    # total download size (sum of part Content-Lengths) so the bar can show GB progress.
    # Size is probed from GitHub (source of truth); the bytes come from the mirror-first
    # Resolve-AssetUrl below when a mirror is configured.
    $totalBytes = 0
    foreach ($s in $suffixes) {
      $u = if ($s -eq "") { "$DownloadBase/$Archive" } else { "$DownloadBase/$Archive.$s" }
      try { $totalBytes += [int64]((Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing).Headers['Content-Length']) } catch {}
    }
    Detail ("Downloading {0} part(s) in parallel ...{1}" -f $suffixes.Count, $(if ($MirrorBase) { " (mirror first, GitHub backup)" } else { "" }))
    $parts = @()
    if ($curl) {
      $procs = @()
      foreach ($s in $suffixes) {
        if ($s -eq "") { $out = $final; $asset = $Archive }
        else           { $out = Join-Path $work "$Archive.$s"; $asset = "$Archive.$s" }
        $url = Resolve-AssetUrl $asset
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $curl
        $psi.Arguments       = "-fL --retry 3 --retry-delay 2 -C - -o `"$out`" `"$url`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $procs += [System.Diagnostics.Process]::Start($psi)
        $parts += $out
      }
      # poll for a live byte-level progress bar instead of a blocking WaitForExit
      while ($procs | Where-Object { -not $_.HasExited }) {
        Start-Sleep -Milliseconds 300
        $have = 0; foreach ($pp in $parts) { if (Test-Path $pp) { $have += (Get-Item $pp).Length } }
        if ($totalBytes -gt 0) { Prog ([int](100 * $have / $totalBytes)) ("{0:N1} / {1:N1} GB" -f ($have/1GB), ($totalBytes/1GB)) }
        else { Prog 50 ("{0:N1} GB" -f ($have/1GB)) }
      }
      $dlfail = $false
      foreach ($p in $procs) { if ($p.ExitCode -ne 0) { $dlfail = $true } }
      if ($dlfail) { Die "One or more parts failed to download - re-run to resume." }
    } else {
      $i = 0
      foreach ($s in $suffixes) {
        $i++; Prog ([int](100 * $i / $suffixes.Count)) ("part $i / $($suffixes.Count)")
        if ($s -eq "") { $out = $final; $asset = $Archive }
        else           { $out = Join-Path $work "$Archive.$s"; $asset = "$Archive.$s" }
        Detail "Downloading $(Split-Path $out -Leaf) ..."; Invoke-WebRequest -Uri (Resolve-AssetUrl $asset) -OutFile $out -UseBasicParsing; $parts += $out
      }
    }
    Prog 100 "download complete"
    Detail "Fetched $($parts.Count) file(s)."

    Phase "Verifying files"
    if ($parts.Count -gt 1) {
      Detail "Joining $($parts.Count) parts ..."
      $sorted = $parts | Sort-Object
      $out = [System.IO.File]::Create("$final.joined")
      try { foreach ($p in $sorted) { $in = [System.IO.File]::OpenRead($p); try { $in.CopyTo($out) } finally { $in.Close() } } }
      finally { $out.Close() }
      Move-Item -Force "$final.joined" $final
    }

    Prog 50 "checking archive integrity"
    if ((Get-Item $final).Length -lt 1MB) { $bad = $true }
    else { & tar --zstd -tf $final > $null 2>&1; $bad = ($LASTEXITCODE -ne 0) }
    if (-not $bad) { Prog 100 "archive OK"; Detail ("Archive looks good ({0} GB)." -f [math]::Round((Get-Item $final).Length/1GB,1)); break }

    if ($attempt -eq 1) {
      Warn "Archive failed integrity check - purging cached parts and re-downloading fresh ..."
      Remove-Item -Force -ErrorAction SilentlyContinue $final, "$final.joined"
      Get-ChildItem -Path $work -Filter "$Archive.part-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
      Die "Archive still failed integrity check after a clean re-download. Please try again later, or use the manual (oras) install in the README."
    }
  }

  Phase "Extracting"
  Prog 0 "unpacking ~10 GB (give it a minute)"
  & tar --zstd -xf $final -C $InstallDir
  if ($LASTEXITCODE -ne 0) { Die "Extraction failed (tar exit $LASTEXITCODE)." }
  if (-not (Test-Path $exePath)) { Die "Extraction finished but $Exe is missing." }
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  End-Phase
  Ok "Client installed."
}

function Install-Maps {
  if (-not $WantMaps) { Detail "Skipping map paks (-NoMaps)."; return }
  $pakdir = Get-ChildItem -Path $InstallDir -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Content\\Paks$' } | Select-Object -First 1
  if (-not $pakdir) { Warn "Couldn't find the client's Content\Paks dir - skipping maps."; return }

  Phase "Downloading maps"
  Detail "Fetching the full map set ($MapsTag) ..."
  try { $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$MapsTag" -Headers @{ "User-Agent" = "ut4-install" } -UseBasicParsing }
  catch { Warn "Couldn't reach the maps release - skipping."; return }

  # Optional checksum manifest.
  $sums = $null
  $sumAsset = $rel.assets | Where-Object { $_.name -match '(checksums|md5)' } | Select-Object -First 1
  if ($sumAsset) { try { $sums = (Invoke-WebRequest -Uri $sumAsset.browser_download_url -UseBasicParsing).Content } catch {} }

  $paks = $rel.assets | Where-Object { $_.name -like '*.pak' }
  if (-not $paks) { Warn "No .pak assets found in $MapsTag - skipping."; return }

  $total = $paks.Count
  $par = if ($env:UT_MAP_PAR) { [int]$env:UT_MAP_PAR } else { 6 }
  Detail ("Downloading {0} map pak(s) (parallel x{1}) ..." -f $total, $par)
  $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
  # queue only the paks we don't already have
  $done = 0
  $todo = New-Object System.Collections.Queue
  foreach ($a in $paks) {
    $dest = Join-Path $pakdir.FullName $a.name
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { $done++; Detail ("{0} (have it)" -f $a.name) }
    else { $todo.Enqueue($a) }
  }
  Prog ([int](100 * $done / [Math]::Max($total,1))) ("$done / $total maps")
  # bounded-parallel download (curl.exe procs); Invoke-WebRequest fallback stays sequential
  $active = @()
  while ($todo.Count -gt 0 -or $active.Count -gt 0) {
    while ($active.Count -lt $par -and $todo.Count -gt 0) {
      $a = $todo.Dequeue(); $dest = Join-Path $pakdir.FullName $a.name; $url = $a.browser_download_url
      Remove-Item $dest -Force -ErrorAction SilentlyContinue
      if ($curl) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $curl
        $psi.Arguments       = "-fL --retry 3 --retry-delay 2 -o `"$dest`" `"$url`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $active += @{ proc = [System.Diagnostics.Process]::Start($psi); name = $a.name; dest = $dest }
      } else {
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing; $done++; Detail ("+ {0}" -f $a.name); Prog ([int](100 * $done / [Math]::Max($total,1))) ("$done / $total maps") }
        catch { Warn "Failed: $($a.name) (skipping)"; Remove-Item $dest -Force -ErrorAction SilentlyContinue }
      }
    }
    if ($active.Count -gt 0) {
      Start-Sleep -Milliseconds 200
      foreach ($d in @($active | Where-Object { $_.proc.HasExited })) {
        if ($d.proc.ExitCode -ne 0) { Warn "Failed: $($d.name) (skipping)"; Remove-Item $d.dest -Force -ErrorAction SilentlyContinue }
        else { $done++; Detail ("+ {0}" -f $d.name) }
      }
      $active = @($active | Where-Object { -not $_.proc.HasExited })
      Prog ([int](100 * $done / [Math]::Max($total,1))) ("$done / $total maps")
    }
  }
  # md5 verify (sequential, local hashing); drop a bad file so a re-run re-fetches it
  if ($sums) {
    foreach ($a in $paks) {
      $dest = Join-Path $pakdir.FullName $a.name
      if (-not (Test-Path $dest)) { continue }
      $line = ($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($a.name) } | Select-Object -First 1
      if ($line) {
        $want = ($line -split '\s+')[0]
        $got  = (Get-FileHash -Algorithm MD5 -Path $dest).Hash.ToLower()
        if ($want.ToLower() -ne $got) { Warn "md5 mismatch on $($a.name) - removing"; Remove-Item $dest -Force -ErrorAction SilentlyContinue }
      }
    }
  }
  End-Phase
  Ok "Map set installed to $($pakdir.FullName)"
}

function Test-VCRedistInstalled {
  # The VC++ 2015-2022 x64 runtime records itself under this key.
  foreach ($k in @(
      "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64",
      "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64")) {
    try { if ((Get-ItemProperty -Path $k -ErrorAction Stop).Installed -eq 1) { return $true } } catch {}
  }
  return $false
}

function Install-Prereqs {
  # The game needs the Visual C++ x64 redistributable. Without it the top-level
  # UnrealTournament.exe (UE's launcher/prereq stub) errors asking for the
  # "VC++ redist 2018-2022". Install it so the game just launches.
  if (Test-VCRedistInstalled) { Detail "Visual C++ x64 runtime already installed." ; return }
  Phase "Installing prerequisites"
  Prog 30 "Visual C++ x64 runtime"
  Detail "Installing the Visual C++ x64 runtime the game needs ..."

  # 1) Prefer the prerequisite installer bundled in the staged build.
  $bundled = Get-ChildItem -Path $InstallDir -Recurse -Filter "UEPrereqSetup_x64.exe" -ErrorAction SilentlyContinue |
             Select-Object -First 1
  if ($bundled) {
    Detail "Running bundled UE prerequisites ($($bundled.Name)) ..."
    try {
      $p = Start-Process -FilePath $bundled.FullName -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
      if ($p.ExitCode -in 0,1638,3010,5100) { Ok "Prerequisites installed."; return }
      Warn "UE prereq setup returned exit $($p.ExitCode); falling back to Microsoft's redist ..."
    } catch { Warn "Couldn't run the bundled prereq setup; falling back to Microsoft's redist ..." }
  }

  # 2) Fall back to Microsoft's standalone VC++ x64 redistributable.
  $vc = Join-Path $env:TEMP "vc_redist.x64.exe"
  try {
    Detail "Downloading Microsoft VC++ x64 redistributable ..."
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vc -UseBasicParsing
    $p = Start-Process -FilePath $vc -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
    Remove-Item $vc -ErrorAction SilentlyContinue
    # 1638 = a newer version is already installed; 3010 = ok, reboot pending.
    if ($p.ExitCode -in 0,1638,3010,5100) { Ok "Visual C++ x64 runtime installed." }
    else { Warn "VC++ redist installer exit $($p.ExitCode). If the game won't start, install it from https://aka.ms/vs/17/release/vc_redist.x64.exe" }
  } catch {
    Warn "Couldn't auto-install the VC++ redist. If the game won't start, install it from https://aka.ms/vs/17/release/vc_redist.x64.exe"
  }
}

function Find-GameExe {
  # The top-level UnrealTournament.exe is UE's launcher/prereq stub; the real
  # game binary lives under Binaries\Win64. Prefer that so launching doesn't
  # re-trigger the prereq stub (which is what errored for players).
  $bin = Get-ChildItem -Path $InstallDir -Recurse -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match 'Binaries\\Win64$' } | Select-Object -First 1
  if ($bin) {
    foreach ($pat in @("UnrealTournament-Win64-Shipping.exe","UnrealTournament-Win64-Development.exe","UnrealTournament.exe")) {
      $c = Join-Path $bin.FullName $pat
      if (Test-Path $c) { return $c }
    }
    $any = Get-ChildItem -Path $bin.FullName -Filter "UnrealTournament*.exe" -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($any) { return $any.FullName }
  }
  if (Test-Path $exePath) { return $exePath }
  return $null
}

Install-Client
Install-Maps
Install-Prereqs
End-Phase

$gameExe = Find-GameExe
if (-not $gameExe) { $gameExe = $exePath }

Write-Host ""
Ok "Installed to $InstallDir"
Write-Host ""
Say "To play, run:"
Write-Host "    & `"$gameExe`""
Write-Host "    (needs a D3D11/D3D12-capable GPU)" -ForegroundColor DarkGray
if ($gameExe -ne $exePath) {
  Write-Host "    Note: this is the real game exe under Binaries\Win64 - the top-level" -ForegroundColor DarkGray
  Write-Host "    UnrealTournament.exe is UE's prerequisite/launcher stub." -ForegroundColor DarkGray
}
Write-Host ""
$go = Read-Host "Launch the game now? [Y/n]"
if ($go -notmatch '^[nN]') { Start-Process -FilePath $gameExe }
