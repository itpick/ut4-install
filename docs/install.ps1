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
  [switch]$NoMaps,
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

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "OK  $m"  -ForegroundColor Green }
function Warn ($m) { Write-Host "!   $m"  -ForegroundColor Yellow }
function Die  ($m) { Write-Host "X   $m"  -ForegroundColor Red; if ([Environment]::UserInteractive) { try { Read-Host "Press Enter to close" } catch {} }; exit 1 }

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
# otherwise list published client builds (tags starting with $ClientPrefix, newest
# first) and let the user pick. Default (and the <2-builds case) is the latest.
function Resolve-DownloadBase {
  if ($DownloadBase) { return $DownloadBase }
  $tags = @()
  try {
    $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers @{ "User-Agent" = "ut4-install" } -UseBasicParsing
    # the content-addressed store (client-<plat>-store) is not a selectable build
    $tags = @($rels | Where-Object { $_.tag_name -like "$ClientPrefix*" -and $_.tag_name -notmatch '-store$' } | ForEach-Object { $_.tag_name })
  } catch { }
  if ($tags.Count -eq 0) { return "" }
  $chosen = $tags[0]
  if ($tags.Count -gt 1) {
    Write-Host "Select a build (Up/Down, Enter for latest):" -ForegroundColor Blue
    $labels = for ($i = 0; $i -lt $tags.Count; $i++) { if ($i -eq 0) { "$($tags[$i])  (latest)" } else { $tags[$i] } }
    $picked = Menu-Pick -Options @($labels)
    $chosen = ($picked -replace '  \(latest\)$','')
  }
  return "https://github.com/$Repo/releases/download/$chosen"
}

$tar = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tar) { Die "tar was not found. Windows 10 (1803+) and Windows 11 ship bsdtar; update Windows, or extract with 7-Zip." }

$DownloadBase = Resolve-DownloadBase
if (-not $DownloadBase) { $DownloadBase = "https://github.com/$Repo/releases/download/${ClientPrefix}5.8" }

# Content-addressed store wiring (incremental updates). $Plat from the client prefix;
# $BuildTag is the resolved release tag. When the build publishes a manifest.json we
# sync only changed files from client-<plat>-store; otherwise fall back to the tarball.
$BuildTag = ($DownloadBase -split '/')[-1]
$Plat     = ($ClientPrefix -replace '^client-','') -replace '-$',''

Write-Host ""
Say "UT4 on Unreal Engine 5.8 - Windows installer"
Write-Host "    Install dir: $InstallDir" -ForegroundColor DarkGray
Write-Host "    Client src:  $DownloadBase" -ForegroundColor DarkGray
Write-Host "    Maps:        $(if ($WantMaps) { "full set ($MapsTag)" } else { 'skipped (-NoMaps)' })" -ForegroundColor DarkGray
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

function Install-Client {
  # Prefer incremental content-addressed sync when the build publishes a manifest.
  # Downloads only files whose hash changed vs the installed manifest (fresh install
  # pulls everything; an update pulls just the delta). Falls back to the full tarball
  # if the manifest or the sync helper isn't reachable.
  if (Url-Exists "$DownloadBase/manifest.tsv") {
    Say "Incremental update available - syncing only changed files ..."
    try {
      $sctext = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/main/scripts/sync-client.ps1" -UseBasicParsing).Content
      if ($sctext -is [byte[]]) { $sctext = [Text.Encoding]::UTF8.GetString($sctext) }
      $sb = [ScriptBlock]::Create($sctext)
      & $sb $Plat $BuildTag $InstallDir
      Ok "Client up to date (incremental)."
      return
    } catch {
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
    Say "Locating client parts ..."
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

    Say "Downloading $($suffixes.Count) part(s) in parallel ..."
    $parts = @()
    if ($curl) {
      $procs = @()
      foreach ($s in $suffixes) {
        if ($s -eq "") { $out = $final; $url = "$DownloadBase/$Archive" }
        else           { $out = Join-Path $work "$Archive.$s"; $url = "$DownloadBase/$Archive.$s" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $curl
        $psi.Arguments       = "-fL --retry 3 --retry-delay 2 -C - -o `"$out`" `"$url`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $procs += [System.Diagnostics.Process]::Start($psi)
        $parts += $out
      }
      $dlfail = $false
      foreach ($p in $procs) { $p.WaitForExit(); if ($p.ExitCode -ne 0) { $dlfail = $true } }
      if ($dlfail) { Die "One or more parts failed to download - re-run to resume." }
    } else {
      foreach ($s in $suffixes) {
        if ($s -eq "") { $out = $final; $url = "$DownloadBase/$Archive" }
        else           { $out = Join-Path $work "$Archive.$s"; $url = "$DownloadBase/$Archive.$s" }
        Fetch $url $out; $parts += $out
      }
    }
    Ok "Fetched $($parts.Count) file(s)."

    if ($parts.Count -gt 1) {
      Say "Joining $($parts.Count) parts ..."
      $sorted = $parts | Sort-Object
      $out = [System.IO.File]::Create("$final.joined")
      try { foreach ($p in $sorted) { $in = [System.IO.File]::OpenRead($p); try { $in.CopyTo($out) } finally { $in.Close() } } }
      finally { $out.Close() }
      Move-Item -Force "$final.joined" $final
    }

    Say "Verifying archive (integrity) ..."
    if ((Get-Item $final).Length -lt 1MB) { $bad = $true }
    else { & tar --zstd -tf $final > $null 2>&1; $bad = ($LASTEXITCODE -ne 0) }
    if (-not $bad) { Ok "Archive looks good ($([math]::Round((Get-Item $final).Length/1GB,1)) GB)."; break }

    if ($attempt -eq 1) {
      Warn "Archive failed integrity check - purging cached parts and re-downloading fresh ..."
      Remove-Item -Force -ErrorAction SilentlyContinue $final, "$final.joined"
      Get-ChildItem -Path $work -Filter "$Archive.part-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
      Die "Archive still failed integrity check after a clean re-download. Please try again later, or use the manual (oras) install in the README."
    }
  }

  Say "Extracting (~10 GB, give it a minute) ..."
  & tar --zstd -xf $final -C $InstallDir
  if ($LASTEXITCODE -ne 0) { Die "Extraction failed (tar exit $LASTEXITCODE)." }
  if (-not (Test-Path $exePath)) { Die "Extraction finished but $Exe is missing." }
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  Ok "Client installed."
}

function Install-Maps {
  if (-not $WantMaps) { Say "Skipping map paks (-NoMaps)."; return }
  $pakdir = Get-ChildItem -Path $InstallDir -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Content\\Paks$' } | Select-Object -First 1
  if (-not $pakdir) { Warn "Couldn't find the client's Content\Paks dir - skipping maps."; return }

  Say "Fetching the full map set ($MapsTag) ..."
  try { $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$MapsTag" -Headers @{ "User-Agent" = "ut4-install" } -UseBasicParsing }
  catch { Warn "Couldn't reach the maps release - skipping."; return }

  # Optional checksum manifest.
  $sums = $null
  $sumAsset = $rel.assets | Where-Object { $_.name -match '(checksums|md5)' } | Select-Object -First 1
  if ($sumAsset) { try { $sums = (Invoke-WebRequest -Uri $sumAsset.browser_download_url -UseBasicParsing).Content } catch {} }

  $paks = $rel.assets | Where-Object { $_.name -like '*.pak' }
  if (-not $paks) { Warn "No .pak assets found in $MapsTag - skipping."; return }

  $i = 0; $total = $paks.Count
  foreach ($a in $paks) {
    $i++
    $dest = Join-Path $pakdir.FullName $a.name
    if ((Test-Path $dest) -and (Get-Item $dest).Length -gt 0) { Write-Host ("  [{0}/{1}] {2} (have it)" -f $i,$total,$a.name) -ForegroundColor DarkGray; continue }
    Write-Host ("  [{0}/{1}] {2}" -f $i,$total,$a.name)
    try { Invoke-WebRequest -Uri $a.browser_download_url -OutFile $dest -UseBasicParsing }
    catch { Warn "Failed: $($a.name) (skipping)"; Remove-Item $dest -ErrorAction SilentlyContinue; continue }
    if ($sums) {
      $line = ($sums -split "`n") | Where-Object { $_ -match [regex]::Escape($a.name) } | Select-Object -First 1
      if ($line) {
        $want = ($line -split '\s+')[0]
        $got  = (Get-FileHash -Algorithm MD5 -Path $dest).Hash.ToLower()
        if ($want.ToLower() -ne $got) { Warn "md5 mismatch on $($a.name)" }
      }
    }
  }
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
  if (Test-VCRedistInstalled) { Ok "Visual C++ x64 runtime already installed." ; return }
  Say "Installing the Visual C++ x64 runtime the game needs ..."

  # 1) Prefer the prerequisite installer bundled in the staged build.
  $bundled = Get-ChildItem -Path $InstallDir -Recurse -Filter "UEPrereqSetup_x64.exe" -ErrorAction SilentlyContinue |
             Select-Object -First 1
  if ($bundled) {
    Say "Running bundled UE prerequisites ($($bundled.Name)) ..."
    try {
      $p = Start-Process -FilePath $bundled.FullName -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru
      if ($p.ExitCode -in 0,1638,3010,5100) { Ok "Prerequisites installed."; return }
      Warn "UE prereq setup returned exit $($p.ExitCode); falling back to Microsoft's redist ..."
    } catch { Warn "Couldn't run the bundled prereq setup; falling back to Microsoft's redist ..." }
  }

  # 2) Fall back to Microsoft's standalone VC++ x64 redistributable.
  $vc = Join-Path $env:TEMP "vc_redist.x64.exe"
  try {
    Say "Downloading Microsoft VC++ x64 redistributable ..."
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
