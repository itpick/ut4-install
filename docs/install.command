#!/usr/bin/env bash
#
# UT4 on Unreal Engine 5.8 - macOS installer  (Universal: Intel + Apple Silicon)
#
# Works either way:
#   Double-click this file in Finder.
#   curl -fsSL https://itpick.github.io/ut4-install/install.command | bash
#
# Downloads the macOS client (single tarball or split <2 GB parts) + the full
# map set, clears quarantine, re-signs the app UNSANDBOXED (the sandbox breaks
# mouse-look - see below), and launches it. Safe to re-run.
#
# Flags:  --no-maps      skip the ~40 downloadable map paks
#         --dir <path>   install location (default: ~/UnrealTournament58)
#
set -euo pipefail

# -- config -----------------------------------------------------------------
# TODO(url): point DOWNLOAD_BASE at the GitHub Release that hosts the CLIENT.
# Once the macOS client is split + uploaded, this should be the release asset
# base, e.g.  https://github.com/itpick/ut4-install/releases/download/client-mac-5.8
# Expected asset names:
#     ut4-client-mac.tar.zst              (single file, if not split)
#     ut4-client-mac.tar.zst.part-aa      ut4-client-mac.tar.zst.part-ab  ...
# If DOWNLOAD_BASE is set in the environment it forces a specific release; otherwise
# the installer lists the available client builds and lets you pick (default = latest).
DOWNLOAD_BASE="${DOWNLOAD_BASE:-}"
CLIENT_PREFIX="client-mac-"       # release tags for macOS client builds
ARCHIVE="ut4-client-mac.tar.zst"
MAPS_TAG="maps-mac-v1"            # map paks are shared across channels
REPO="itpick/ut4-install"
INSTALL_DIR="${INSTALL_DIR:-$HOME/UnrealTournament58}"
APP="UnrealTournament.app"
# CRITICAL: the client MUST be signed WITHOUT the app sandbox. A sandboxed build
# cannot hold the permanent cursor capture UE needs, so mouse-look dies in
# matches (you can move + fire but the view won't turn). No entitlements.
BUNDLE_ID="com.itpick.UnrealTournament58"
WANT_MAPS=1
# Release channel: "stable" (default, pinned + tested) or "nightly" (latest dev build).
# The client tag is client-mac-<channel>; the shared block store is client-mac-store.
CHANNEL="${UT_CHANNEL:-stable}"
# ----------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --no-maps) WANT_MAPS=0 ;;
    --nightly) CHANNEL="nightly" ;;
    --stable)  CHANNEL="stable" ;;
    --channel) shift; CHANNEL="${1:?--channel needs a name}" ;;
    --dir) shift; INSTALL_DIR="${1:?--dir needs a path}" ;;
    -h|--help) echo "usage: install.command [--no-maps] [--nightly|--stable|--channel <name>] [--dir <path>]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; NC=$'\033[0m'
say()  { printf '%s==>%s %s\n'  "$BLUE"  "$NC" "$*"; }
ok()   { printf '%sOK%s %s\n'    "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n'    "$YELLOW" "$NC" "$*"; }
die()  { printf '%sX %s%s\n'    "$RED" "$*" "$NC" >&2; [ -e /dev/tty ] && { printf 'Press Return to close.' >/dev/tty; read -r _ </dev/tty || true; }; exit 1; }
ask()  { local p="$1" d="$2" a=""; if [ -e /dev/tty ]; then printf '%s' "$p" >/dev/tty; IFS= read -r a </dev/tty || a=""; fi; printf '%s' "${a:-$d}"; }
md5of(){ if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | awk '{print $1}'; fi; }

# Arrow-key selector over /dev/tty. Up/Down to move, Enter to choose. Echoes the
# selected item; falls back to the first item when there's no controlling terminal.
menu_pick() {
  local opts=("$@") n=$# sel=0 k rest i
  [ -e /dev/tty ] || { printf '%s' "${opts[0]}"; return; }
  printf '\033[?25l' >/dev/tty
  for ((i=0;i<n;i++)); do
    if [ "$i" -eq "$sel" ]; then printf '  \033[1;36m> %s\033[0m\n' "${opts[$i]}" >/dev/tty
    else printf '    %s\n' "${opts[$i]}" >/dev/tty; fi
  done
  while IFS= read -rsn1 k </dev/tty; do
    [ -z "$k" ] && break
    if [ "$k" = $'\033' ]; then IFS= read -rsn2 -t 0.2 rest </dev/tty || rest=""
      case "$rest" in '[A') sel=$(((sel-1+n)%n));; '[B') sel=$(((sel+1)%n));; esac; fi
    printf '\033[%dA' "$n" >/dev/tty
    for ((i=0;i<n;i++)); do
      if [ "$i" -eq "$sel" ]; then printf '\033[2K  \033[1;36m> %s\033[0m\n' "${opts[$i]}" >/dev/tty
      else printf '\033[2K    %s\n' "${opts[$i]}" >/dev/tty; fi
    done
  done
  printf '\033[?25h' >/dev/tty
  printf '%s' "${opts[$sel]}"
}

# Resolve DOWNLOAD_BASE: explicit env override wins; otherwise pin to the selected
# channel tag (client-mac-stable by default, client-mac-nightly with --nightly).
resolve_download_base() {
  [ -n "$DOWNLOAD_BASE" ] && { echo "$DOWNLOAD_BASE"; return; }
  echo "https://github.com/$REPO/releases/download/${CLIENT_PREFIX}${CHANNEL}"
}

command -v curl >/dev/null || die "curl is required but not found."
command -v tar  >/dev/null || die "tar is required but not found."

DOWNLOAD_BASE="$(resolve_download_base)"
[ -n "$DOWNLOAD_BASE" ] || DOWNLOAD_BASE="https://github.com/$REPO/releases/download/${CLIENT_PREFIX}stable"

# Content-addressed store wiring (incremental updates). PLAT from the client prefix;
# BUILD_TAG is the resolved release tag. When the build publishes a manifest.tsv we
# sync only changed files from client-<plat>-store; otherwise fall back to the tarball.
# (The app is re-signed unsandboxed after install regardless - see the codesign step -
# so a synced .app gets a fresh signature too.)
BUILD_TAG="${DOWNLOAD_BASE##*/}"
PLAT="${CLIENT_PREFIX#client-}"; PLAT="${PLAT%-}"

echo
say "UT4 on Unreal Engine 5.8 - macOS installer (Universal)"
echo "${DIM}    Install dir: ${INSTALL_DIR}${NC}"
echo "${DIM}    Channel:     ${CHANNEL}$([ "$CHANNEL" = nightly ] && echo "  (latest dev build - may be unstable)")${NC}"
echo "${DIM}    Client src:  ${DOWNLOAD_BASE}${NC}"
echo "${DIM}    Maps:        $([ "$WANT_MAPS" = 1 ] && echo "full set ($MAPS_TAG)" || echo "skipped (--no-maps)")${NC}"
echo

mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"

http_ok() { curl -fsSL -I -o /dev/null "$1" 2>/dev/null; }
fetch()   { say "Downloading $(basename "$2") ..."; curl -fL --retry 3 --retry-delay 2 -C - -o "$2" "$1" || die "Download failed: $1"; }

install_client() {
  # Prefer incremental content-addressed sync when the build publishes a manifest.
  # Downloads only files whose hash changed vs the installed manifest. The app is
  # re-signed unsandboxed afterwards in the main flow, so a synced .app is sealed too.
  # Falls back to the full tarball if the manifest or the sync helper isn't reachable.
  if http_ok "$DOWNLOAD_BASE/manifest.tsv"; then
    say "Incremental update available - syncing only changed files ..."
    mkdir -p "$INSTALL_DIR"
    local sc="$INSTALL_DIR/.sync-client.sh"
    if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/sync-client.sh" -o "$sc" 2>/dev/null; then
      if UT_PAR="${UT_PAR:-6}" /bin/bash "$sc" "$PLAT" "$BUILD_TAG" "$INSTALL_DIR"; then
        rm -f "$sc"; ok "Client up to date (incremental)."; return 0
      fi
      warn "Incremental sync failed - falling back to the full archive."
    else
      warn "Couldn't fetch the sync helper - falling back to the full archive."
    fi
    rm -f "$sc"
  fi

  if [ -d "$INSTALL_DIR/$APP" ]; then
    ok "Client already present at $INSTALL_DIR/$APP"
    case "$(ask "Re-download and reinstall the client? [y/N] " "n")" in
      [yY]*) rm -rf "$INSTALL_DIR/$APP" ;;
      *) return 0 ;;
    esac
  fi

  local work="$INSTALL_DIR/.download"; mkdir -p "$work"
  local final="$work/$ARCHIVE"
  local attempt parts
  for attempt in 1 2; do
    say "Locating client parts ..."
    parts=(); local suffixes=() c1 c2 stop
    if http_ok "$DOWNLOAD_BASE/$ARCHIVE"; then
      suffixes=("")
    else
      for c1 in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
        stop=0
        for c2 in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
          if http_ok "$DOWNLOAD_BASE/$ARCHIVE.part-${c1}${c2}"; then suffixes+=("part-${c1}${c2}"); else stop=1; break; fi
        done
        [ "$stop" = 1 ] && break
      done
    fi
    [ ${#suffixes[@]} -gt 0 ] || die "No client found at $DOWNLOAD_BASE (checked single file and part-aa).
The client release may not be uploaded yet - see the README for the manual (oras) install."
    say "Downloading ${#suffixes[@]} part(s) in parallel ..."
    local dlpids=() s out url
    for s in "${suffixes[@]}"; do
      if [ -z "$s" ]; then out="$work/$ARCHIVE"; url="$DOWNLOAD_BASE/$ARCHIVE"
      else out="$work/$ARCHIVE.$s"; url="$DOWNLOAD_BASE/$ARCHIVE.$s"; fi
      curl -fL --retry 3 --retry-delay 2 -C - -o "$out" "$url" >/dev/null 2>&1 &
      dlpids+=("$!"); parts+=("$out")
    done
    local dlfail=0
    for s in "${dlpids[@]}"; do wait "$s" || dlfail=1; done
    [ "$dlfail" = 0 ] || die "One or more parts failed to download - re-run to resume."
    ok "Fetched ${#parts[@]} file(s)."

    if [ ${#parts[@]} -gt 1 ]; then say "Joining ${#parts[@]} parts ..."; cat "${parts[@]}" > "$final.joined"; mv "$final.joined" "$final"; fi

    say "Verifying archive ..."
    if ! command -v zstd >/dev/null || zstd -t "$final" >/dev/null 2>&1; then ok "Archive looks good."; break; fi

    # Integrity failed - almost always stale/partial cached parts from an earlier
    # run: curl -C - resumes a full-size stale file and never refreshes it (e.g. after
    # the release was re-uploaded). Purge everything and re-download fresh, once.
    if [ "$attempt" = 1 ]; then
      warn "Archive failed integrity check - purging cached parts and re-downloading fresh ..."
      rm -f "$work/$ARCHIVE" "$work/$ARCHIVE".part-* "$final.joined"
    else
      die "Archive still failed integrity check after a clean re-download.
Please try again later, or use the manual (oras) install in the README."
    fi
  done

  say "Extracting (~16 GB, give it a minute) ..."
  if ! tar -I zstd -xf "$final" -C "$INSTALL_DIR" 2>/dev/null; then
    if command -v zstd >/dev/null; then zstd -dc "$final" | tar -xf - -C "$INSTALL_DIR"
    else tar --zstd -xf "$final" -C "$INSTALL_DIR" || die "Could not extract the archive."; fi
  fi
  [ -d "$INSTALL_DIR/$APP" ] || die "Extraction finished but $APP is missing."
  rm -rf "$work"
  ok "Client installed."
}

install_maps() {
  [ "$WANT_MAPS" = 1 ] || { say "Skipping map paks (--no-maps)."; return 0; }
  local pakdir; pakdir=$(find "$INSTALL_DIR/$APP" -type d -path '*/Content/Paks' 2>/dev/null | head -1)
  [ -n "$pakdir" ] || pakdir=$(find "$INSTALL_DIR" -type d -path '*/Content/Paks' 2>/dev/null | head -1)
  [ -n "$pakdir" ] || { warn "Couldn't find the app's Content/Paks dir - skipping maps."; return 0; }

  say "Fetching the full map set ($MAPS_TAG) ..."
  local json; json=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$MAPS_TAG") \
    || { warn "Couldn't reach the maps release - skipping."; return 0; }

  local sums="" sums_url
  sums_url=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]*(checksums|md5)[^"]*"' | sed -E 's/.*"(https[^"]+)".*/\1/' | head -1)
  [ -n "$sums_url" ] && sums=$(curl -fsSL "$sums_url" 2>/dev/null || true)

  local urls; urls=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]*\.pak"' | sed -E 's/.*"(https[^"]+)".*/\1/')
  [ -n "$urls" ] || { warn "No .pak assets found in $MAPS_TAG - skipping."; return 0; }

  local total par="${UT_MAP_PAR:-6}"; total=$(printf '%s\n' "$urls" | grep -c . || true)
  say "Downloading $total map pak(s) (parallel x$par) ..."
  # bounded-parallel: each worker fetches one pak, verifies md5, self-cleans a bad file so a
  # re-run re-fetches it. md5of + $sums/$pakdir are inherited by the subshells.
  local mpids=() cnt=0 p
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    (
      m_name=$(basename "$u"); m_dest="$pakdir/$m_name"
      if [ -s "$m_dest" ]; then printf '  %s%s (have it)%s\n' "$DIM" "$m_name" "$NC"; exit 0; fi
      if ! curl -fL --retry 3 --retry-delay 2 -C - -o "$m_dest" "$u" >/dev/null 2>&1; then
        printf '  ! failed: %s (skipping)\n' "$m_name"; rm -f "$m_dest"; exit 0; fi
      if [ -n "$sums" ]; then
        m_want=$(printf '%s\n' "$sums" | grep -F "$m_name" | awk '{print $1}' | head -1)
        if [ -n "$m_want" ]; then m_got=$(md5of "$m_dest")
          [ "$m_want" = "$m_got" ] || { printf '  ! md5 mismatch: %s (skipping)\n' "$m_name"; rm -f "$m_dest"; exit 0; }
        fi
      fi
      printf '  + %s\n' "$m_name"
    ) &
    mpids+=("$!"); cnt=$((cnt+1))
    if [ "$cnt" -ge "$par" ]; then for p in "${mpids[@]}"; do wait "$p"; done; mpids=(); cnt=0; fi
  done <<EOF
$urls
EOF
  for p in "${mpids[@]}"; do wait "$p"; done
  ok "Map set installed to $pakdir"
}

install_client
install_maps   # add maps BEFORE signing so the signature seals them in

# Clear the download quarantine so Gatekeeper won't block it.
say "Clearing quarantine ..."
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP" 2>/dev/null || true

# Re-sign UNSANDBOXED - this is the fix for dead mouse-look. No entitlements.
say "Re-signing the app (unsandboxed) ..."
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$INSTALL_DIR/$APP" \
  || warn "codesign failed - if mouse-look is dead in a match, re-run this installer."
if codesign -d --entitlements - "$INSTALL_DIR/$APP" 2>/dev/null | grep -q app-sandbox; then
  warn "The app is STILL sandboxed - mouse-look will be broken."
else
  ok "App is unsandboxed (mouse-look will work)."
fi

echo
ok "Installed to $INSTALL_DIR/$APP"
echo
echo "${DIM}    LAN play needs Local Network access: approve the first-launch prompt, or${NC}"
echo "${DIM}    System Settings -> Privacy & Security -> Local Network -> Unreal Tournament${NC}"
echo
say "Launching ..."
open "$INSTALL_DIR/$APP"
echo
[ -e /dev/tty ] && { printf 'Done. Press Return to close this window.' >/dev/tty; read -r _ </dev/tty || true; }
