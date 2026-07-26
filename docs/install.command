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
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/itpick/ut4-install/releases/latest/download}"  # TODO(url)

ARCHIVE="ut4-client-mac.tar.zst"
MAPS_TAG="maps-mac-v1"            # existing release with the per-map paks
REPO="itpick/ut4-install"
INSTALL_DIR="${INSTALL_DIR:-$HOME/UnrealTournament58}"
APP="UnrealTournament.app"
# CRITICAL: the client MUST be signed WITHOUT the app sandbox. A sandboxed build
# cannot hold the permanent cursor capture UE needs, so mouse-look dies in
# matches (you can move + fire but the view won't turn). No entitlements.
BUNDLE_ID="com.itpick.UnrealTournament58"
WANT_MAPS=1
# ----------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --no-maps) WANT_MAPS=0 ;;
    --dir) shift; INSTALL_DIR="${1:?--dir needs a path}" ;;
    -h|--help) echo "usage: install.command [--no-maps] [--dir <path>]"; exit 0 ;;
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

command -v curl >/dev/null || die "curl is required but not found."
command -v tar  >/dev/null || die "tar is required but not found."

echo
say "UT4 on Unreal Engine 5.8 - macOS installer (Universal)"
echo "${DIM}    Install dir: ${INSTALL_DIR}${NC}"
echo "${DIM}    Client src:  ${DOWNLOAD_BASE}${NC}"
echo "${DIM}    Maps:        $([ "$WANT_MAPS" = 1 ] && echo "full set ($MAPS_TAG)" || echo "skipped (--no-maps)")${NC}"
echo

mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"

http_ok() { curl -fsSL -I -o /dev/null "$1" 2>/dev/null; }
fetch()   { say "Downloading $(basename "$2") ..."; curl -fL --retry 3 --retry-delay 2 -C - -o "$2" "$1" || die "Download failed: $1"; }

install_client() {
  if [ -d "$INSTALL_DIR/$APP" ]; then
    ok "Client already present at $INSTALL_DIR/$APP"
    case "$(ask "Re-download and reinstall the client? [y/N] " "n")" in
      [yY]*) rm -rf "$INSTALL_DIR/$APP" ;;
      *) return 0 ;;
    esac
  fi

  local work="$INSTALL_DIR/.download"; mkdir -p "$work"
  say "Locating client parts ..."
  local parts=()
  if http_ok "$DOWNLOAD_BASE/$ARCHIVE"; then
    fetch "$DOWNLOAD_BASE/$ARCHIVE" "$work/$ARCHIVE"; parts=("$work/$ARCHIVE")
  else
    local c1 c2
    for c1 in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
      for c2 in a b c d e f g h i j k l m n o p q r s t u v w x y z; do
        local suffix="part-${c1}${c2}" url="$DOWNLOAD_BASE/$ARCHIVE.part-${c1}${c2}"
        if http_ok "$url"; then fetch "$url" "$work/$ARCHIVE.$suffix"; parts+=("$work/$ARCHIVE.$suffix"); else break 2; fi
      done
    done
  fi
  [ ${#parts[@]} -gt 0 ] || die "No client found at $DOWNLOAD_BASE (checked single file and part-aa).
The client release may not be uploaded yet - see the README for the manual (oras) install."
  ok "Fetched ${#parts[@]} file(s)."

  local final="$work/$ARCHIVE"
  if [ ${#parts[@]} -gt 1 ]; then say "Joining ${#parts[@]} parts ..."; cat "${parts[@]}" > "$final.joined"; mv "$final.joined" "$final"; fi

  say "Verifying archive ..."
  command -v zstd >/dev/null && { zstd -t "$final" >/dev/null 2>&1 || die "Archive failed integrity check. Re-run to re-download."; }
  ok "Archive looks good."

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

  local total i=0; total=$(printf '%s\n' "$urls" | grep -c . || true)
  while IFS= read -r u; do
    [ -n "$u" ] || continue; i=$((i+1))
    local name dest; name=$(basename "$u"); dest="$pakdir/$name"
    if [ -s "$dest" ]; then printf '  %s[%d/%d] %s (have it)%s\n' "$DIM" "$i" "$total" "$name" "$NC"; continue; fi
    printf '  [%d/%d] %s\n' "$i" "$total" "$name"
    curl -fL --retry 3 -C - -o "$dest" "$u" || { warn "Failed: $name (skipping)"; rm -f "$dest"; continue; }
    if [ -n "$sums" ]; then
      local want; want=$(printf '%s\n' "$sums" | grep -F "$name" | awk '{print $1}' | head -1)
      [ -n "$want" ] && { local got; got=$(md5of "$dest"); [ "$want" = "$got" ] || warn "md5 mismatch on $name"; }
    fi
  done <<EOF
$urls
EOF
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
