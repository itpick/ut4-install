#!/usr/bin/env bash
#
# UT4 on Unreal Engine 5.8 - Linux installer
#
# Works either way:
#   curl -fsSL https://itpick.github.io/ut4-install/install.sh | bash
#   bash install.sh                       # after downloading it
#
# Downloads the Linux client (single tarball or split <2 GB parts), the full
# map-pak set, verifies, extracts, and prints how to run it. Safe to re-run.
#
# Flags:  --no-maps      skip the ~40 downloadable map paks
#         --dir <path>   install location (default: ~/UnrealTournament58)
#
set -euo pipefail

# -- config -----------------------------------------------------------------
# TODO(url): point DOWNLOAD_BASE at the GitHub Release that hosts the CLIENT.
# Once the Linux client is split + uploaded, this should be the release asset
# base, e.g.  https://github.com/itpick/ut4-install/releases/download/client-linux-5.8
# Expected asset names:
#     ut4-client-linux.tar.zst              (single file, if not split)
#     ut4-client-linux.tar.zst.part-aa      ut4-client-linux.tar.zst.part-ab  ...
# If DOWNLOAD_BASE is set in the environment it forces a specific release; otherwise
# the installer lists the available client builds and lets you pick (default = latest).
DOWNLOAD_BASE="${DOWNLOAD_BASE:-}"
CLIENT_PREFIX="client-linux-"     # release tags for Linux client builds
ARCHIVE="ut4-client-linux.tar.zst"
MAPS_TAG="maps-linux-v1"          # map paks are shared across channels
REPO="itpick/ut4-install"
# Optional self-hosted mirror (CDN/origin), tried before GitHub - GitHub remains the
# backup / source of truth (#23). Off by default: empty = zero behavior change. Its
# layout must mirror GitHub Releases exactly: $UT_MIRROR_BASE/<tag>/<asset>, e.g. a
# rsync/rclone mirror of https://github.com/itpick/ut4-install/releases/download/.
MIRROR_BASE="${UT_MIRROR_BASE:-}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/UnrealTournament58}"
RUN_DIR="LinuxNoEditor"
RUN_CMD="./UnrealTournament.sh"
WANT_MAPS=1
# Release channel: "stable" (default, pinned + tested) or "nightly" (latest dev build).
# The client tag is client-linux-<channel>; the shared block store is client-linux-store.
CHANNEL="${UT_CHANNEL:-stable}"
# ----------------------------------------------------------------------------

# -- args (optional - pipe-safe: pass via `bash -s -- --no-maps`) ------------
while [ $# -gt 0 ]; do
  case "$1" in
    --no-maps) WANT_MAPS=0 ;;
    --nightly) CHANNEL="nightly" ;;
    --stable)  CHANNEL="stable" ;;
    --channel) shift; CHANNEL="${1:?--channel needs a name}" ;;
    --details|--verbose) UT_DETAILS=1 ;;
    --dir) shift; INSTALL_DIR="${1:?--dir needs a path}" ;;
    -h|--help) echo "usage: install.sh [--no-maps] [--nightly|--stable|--channel <name>] [--details] [--dir <path>]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; NC=$'\033[0m'
say()  { printf '%s==>%s %s\n'  "$BLUE"  "$NC" "$*"; }
ok()   { printf '%sOK%s %s\n'    "$GREEN" "$NC" "$*"; }
warn() { printf '%s!%s %s\n'    "$YELLOW" "$NC" "$*"; }
die()  { stop_key_watcher 2>/dev/null; is_detail || printf '\n'; printf '%sX %s%s\n'    "$RED" "$*" "$NC" >&2; exit 1; }

# ---- progress UI: a phase title + an updating bar by default; the verbose per-step log
# is hidden unless --details/UT_DETAILS=1 or you press 'd' during a download. A background
# key-watcher flips a shared state file, so the 'd' toggle is live AND sticky across this
# script and the sync helper (which reads the same $UT_STATEF). ----
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
UT_STATEF="${UT_STATEF:-$INSTALL_DIR/.ut-details}"
printf '%s' "${UT_DETAILS:-0}" > "$UT_STATEF" 2>/dev/null || true
export UT_STATEF
UT_PHASE=""; UT_WATCHER=""; _BARW=30
is_detail(){ [ "$(cat "$UT_STATEF" 2>/dev/null)" = 1 ]; }
_fsize(){ stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
_gb(){ awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1073741824}'; }
phase(){ UT_PHASE="$1"
  if is_detail; then printf '\n%s==>%s %s\n' "$BLUE" "$NC" "$1"
  else printf '\n%s%s%s  %spress d for details%s\n' "$BLUE" "$1" "$NC" "$DIM" "$NC"; fi; }
prog(){ # <pct> <status>
  is_detail && return 0
  local pct="${1:-0}" f i bar=""
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0; [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  f=$(( pct * _BARW / 100 ))
  for ((i=0;i<_BARW;i++)); do if [ "$i" -lt "$f" ]; then bar="${bar}#"; else bar="${bar}."; fi; done
  printf '\r  %s[%s]%s %3d%%  %s\033[K' "$GREEN" "$bar" "$NC" "$pct" "${2:-}"; }
detail(){ is_detail && printf '%s[%s] %s%s\n' "$DIM" "$(date +%T)" "$*" "$NC"; return 0; }
end_phase(){ is_detail || printf '\r\033[K'; }
# background key-watcher: 'd' flips the state file. Blocking single-char read (-n1) works on
# bash 3.2 (macOS). Only run it around downloads so it never races the y/N prompts.
start_key_watcher(){ [ -e /dev/tty ] || return 0; [ -n "$UT_WATCHER" ] && return 0
  ( while IFS= read -rsn1 _k </dev/tty 2>/dev/null; do
      case "$_k" in
        d|D) if [ "$(cat "$UT_STATEF" 2>/dev/null)" = 1 ]; then printf '0' > "$UT_STATEF"; printf '\n  %s-- details off --%s\n' "$DIM" "$NC"
             else printf '1' > "$UT_STATEF"; printf '\n  %s-- details on (press d to hide) --%s\n' "$DIM" "$NC"; fi ;;
      esac
    done ) & UT_WATCHER=$!; }
stop_key_watcher(){ [ -n "$UT_WATCHER" ] && kill "$UT_WATCHER" 2>/dev/null; UT_WATCHER=""; }
trap 'stop_key_watcher' EXIT

# Pipe-safe prompt: read from the controlling terminal, not stdin (which is the
# script itself when piped from curl). Falls back to the default with no TTY.
ask()  { local p="$1" d="$2" a=""; if [ -e /dev/tty ]; then printf '%s' "$p" >/dev/tty; IFS= read -r a </dev/tty || a=""; fi; printf '%s' "${a:-$d}"; }
md5of(){ if command -v md5sum >/dev/null; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi; }

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
# channel tag (client-linux-stable by default, client-linux-nightly with --nightly).
resolve_download_base() {
  [ -n "$DOWNLOAD_BASE" ] && { echo "$DOWNLOAD_BASE"; return; }
  echo "https://github.com/$REPO/releases/download/${CLIENT_PREFIX}${CHANNEL}"
}

# Guard against a macOS user piping the Linux script by mistake.
if [ "$(uname -s)" = "Darwin" ]; then
  die "This is the Linux installer. On macOS use:
    curl -fsSL https://itpick.github.io/ut4-install/install.command | bash"
fi

command -v curl >/dev/null || die "curl is required but not found. Install it and re-run."
command -v tar  >/dev/null || die "tar is required but not found."
if ! tar --help 2>/dev/null | grep -q -- '-I' && ! command -v zstd >/dev/null; then
  die "Need GNU tar (for 'tar -I zstd') or the 'zstd' tool. Install zstd and re-run."
fi

DOWNLOAD_BASE="$(resolve_download_base)"
[ -n "$DOWNLOAD_BASE" ] || DOWNLOAD_BASE="https://github.com/$REPO/releases/download/${CLIENT_PREFIX}stable"

# Content-addressed store wiring (incremental updates). PLAT comes from the client
# prefix; BUILD_TAG is the resolved release tag. When the build publishes a
# manifest.json we sync only changed files from client-<plat>-store; otherwise we
# fall back to the full tarball below.
BUILD_TAG="${DOWNLOAD_BASE##*/}"
PLAT="${CLIENT_PREFIX#client-}"; PLAT="${PLAT%-}"

echo
say "UT4 on Unreal Engine 5.8 - Linux installer"
echo "${DIM}    Install dir: ${INSTALL_DIR}${NC}"
echo "${DIM}    Channel:     ${CHANNEL}$([ "$CHANNEL" = nightly ] && echo "  (latest dev build - may be unstable)")${NC}"
echo "${DIM}    Client src:  ${DOWNLOAD_BASE}${NC}"
echo "${DIM}    Maps:        $([ "$WANT_MAPS" = 1 ] && echo "full set ($MAPS_TAG)" || echo "skipped (--no-maps)")${NC}"
echo "${DIM}    $(is_detail && echo "Showing detailed log (press d to hide)." || echo "Tip: press d during download to show/hide the detailed log.")${NC}"
echo

mkdir -p "$INSTALL_DIR"; cd "$INSTALL_DIR"

http_ok() { curl -fsSL -I -o /dev/null "$1" 2>/dev/null; }
fetch()   { say "Downloading $(basename "$2") ..."; curl -fL --retry 3 --retry-delay 2 -C - -o "$2" "$1" || die "Download failed: $1"; }

# fetch_part <asset_name> <dest>  - try the mirror first (short timeout, no resume: a stale
# partial from a different origin must not be resumed into), fall back to GitHub on any miss.
# Existence discovery (which parts exist) stays on GitHub above; this only picks where the
# bytes come from once a part is known to exist.
fetch_part() {
  local asset="$1" dest="$2"
  if [ -n "$MIRROR_BASE" ]; then
    if curl -fL --retry 1 --connect-timeout 4 -o "$dest" "$MIRROR_BASE/$BUILD_TAG/$asset" >/dev/null 2>&1 && [ -s "$dest" ]; then
      return 0
    fi
    rm -f "$dest"
  fi
  curl -fL --retry 3 --retry-delay 2 -C - -o "$dest" "$DOWNLOAD_BASE/$asset" >/dev/null 2>&1
}

install_client() {
  # Prefer incremental content-addressed sync when the build publishes a manifest.
  # It downloads only files whose hash changed vs the installed manifest; a fresh
  # install pulls everything, an update pulls just the delta. Falls back to the full
  # tarball if the manifest or the sync helper isn't reachable.
  if http_ok "$DOWNLOAD_BASE/manifest.tsv"; then
    detail "Incremental update available - syncing only changed files ..."
    local sc="$INSTALL_DIR/.sync-client.sh"
    if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/sync-client.sh" -o "$sc" 2>/dev/null; then
      start_key_watcher   # sync helper drives its own progress phases; reads the same $UT_STATEF
      if UT_PAR="${UT_PAR:-6}" UT_MIRROR_BASE="$MIRROR_BASE" bash "$sc" "$PLAT" "$BUILD_TAG" "$INSTALL_DIR"; then
        stop_key_watcher; end_phase; rm -f "$sc"; ok "Client up to date (incremental)."; return 0
      fi
      stop_key_watcher; end_phase
      warn "Incremental sync failed - falling back to the full archive."
    else
      warn "Couldn't fetch the sync helper - falling back to the full archive."
    fi
    rm -f "$sc"
  fi

  if [ -x "$INSTALL_DIR/$RUN_DIR/UnrealTournament.sh" ]; then
    ok "Client already present at $INSTALL_DIR/$RUN_DIR"
    case "$(ask "Re-download and reinstall the client? [y/N] " "n")" in
      [yY]*) rm -rf "$INSTALL_DIR/$RUN_DIR" ;;
      *) return 0 ;;
    esac
  fi

  local work="$INSTALL_DIR/.download"; mkdir -p "$work"
  local final="$work/$ARCHIVE"
  local attempt parts
  for attempt in 1 2; do
    phase "Downloading UT4"; detail "Locating client parts ..."
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
    # total download size (sum of part Content-Lengths) so the bar can show GB progress.
    # Size is probed from GitHub (source of truth); the bytes themselves come from the
    # mirror-first fetch_part below when a mirror is configured.
    local total_bytes=0 cl s out asset url
    for s in "${suffixes[@]}"; do
      if [ -z "$s" ]; then url="$DOWNLOAD_BASE/$ARCHIVE"; else url="$DOWNLOAD_BASE/$ARCHIVE.$s"; fi
      cl=$(curl -fsSLI "$url" 2>/dev/null | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/\r/,"",v); print v+0}')
      total_bytes=$(( total_bytes + ${cl:-0} ))
    done
    detail "Downloading ${#suffixes[@]} part(s) in parallel ...$([ -n "$MIRROR_BASE" ] && echo " (mirror first, GitHub backup)")"
    local dlpids=()
    for s in "${suffixes[@]}"; do
      if [ -z "$s" ]; then out="$work/$ARCHIVE"; asset="$ARCHIVE"
      else out="$work/$ARCHIVE.$s"; asset="$ARCHIVE.$s"; fi
      fetch_part "$asset" "$out" &
      dlpids+=("$!"); parts+=("$out")
    done
    start_key_watcher
    # live byte-level progress bar while the parallel curls run
    local alive have f pid
    while :; do
      alive=0; for pid in "${dlpids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
      have=0; for f in "${parts[@]}"; do [ -f "$f" ] && have=$(( have + $(_fsize "$f") )); done
      if [ "$total_bytes" -gt 0 ]; then prog $(( have * 100 / total_bytes )) "$(_gb "$have") / $(_gb "$total_bytes") GB"
      else prog 50 "$(_gb "$have") GB"; fi
      [ "$alive" = 0 ] && break
      sleep 0.3
    done
    local dlfail=0
    for pid in "${dlpids[@]}"; do wait "$pid" || dlfail=1; done
    stop_key_watcher
    [ "$dlfail" = 0 ] || die "One or more parts failed to download - re-run to resume."
    prog 100 "download complete"; detail "Fetched ${#parts[@]} file(s)."

    phase "Verifying files"
    if [ ${#parts[@]} -gt 1 ]; then detail "Joining ${#parts[@]} parts ..."; cat "${parts[@]}" > "$final.joined"; mv "$final.joined" "$final"; fi
    prog 50 "checking archive integrity"
    if ! command -v zstd >/dev/null || zstd -t "$final" >/dev/null 2>&1; then prog 100 "archive OK"; detail "Archive looks good."; break; fi

    if [ "$attempt" = 1 ]; then
      warn "Archive failed integrity check - purging cached parts and re-downloading fresh ..."
      rm -f "$work/$ARCHIVE" "$work/$ARCHIVE".part-* "$final.joined"
    else
      die "Archive still failed integrity check after a clean re-download.
Please try again later, or use the manual (oras) install in the README."
    fi
  done

  phase "Extracting"; prog 0 "unpacking ~16 GB (give it a minute)"
  if tar --help 2>/dev/null | grep -q -- '-I'; then tar -I zstd -xf "$final" -C "$INSTALL_DIR"
  else zstd -dc "$final" | tar -xf - -C "$INSTALL_DIR"; fi
  [ -x "$INSTALL_DIR/$RUN_DIR/UnrealTournament.sh" ] || die "Extraction finished but $RUN_DIR/UnrealTournament.sh is missing."
  chmod +x "$INSTALL_DIR/$RUN_DIR/UnrealTournament.sh" 2>/dev/null || true
  rm -rf "$work"
  end_phase; ok "Client installed."
}

install_maps() {
  [ "$WANT_MAPS" = 1 ] || { detail "Skipping map paks (--no-maps)."; return 0; }
  local pakdir; pakdir=$(find "$INSTALL_DIR" -type d -path '*/Content/Paks' 2>/dev/null | head -1)
  [ -n "$pakdir" ] || { warn "Couldn't find the client's Content/Paks dir - skipping maps."; return 0; }

  phase "Downloading maps"; detail "Fetching the full map set ($MAPS_TAG) ..."
  local json; json=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$MAPS_TAG") \
    || { warn "Couldn't reach the maps release - skipping."; return 0; }

  # Optional checksum manifest (md5sum format), if the release ships one.
  local sums="" sums_url
  sums_url=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]*(checksums|md5)[^"]*"' | sed -E 's/.*"(https[^"]+)".*/\1/' | head -1)
  [ -n "$sums_url" ] && sums=$(curl -fsSL "$sums_url" 2>/dev/null || true)

  local urls; urls=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]*\.pak"' | sed -E 's/.*"(https[^"]+)".*/\1/')
  [ -n "$urls" ] || { warn "No .pak assets found in $MAPS_TAG - skipping."; return 0; }

  local total par="${UT_MAP_PAR:-6}"; total=$(printf '%s\n' "$urls" | grep -c . || true)
  detail "Downloading $total map pak(s) (parallel x$par) ..."
  # bounded-parallel: each worker fetches one pak, verifies md5, self-cleans a bad file so a
  # re-run re-fetches it. md5of + $sums/$pakdir/is_detail are inherited by the subshells.
  start_key_watcher
  local mpids=() cnt=0 p launched=0
  prog 0 "0 / $total maps"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    (
      m_name=$(basename "$u"); m_dest="$pakdir/$m_name"
      if [ -s "$m_dest" ]; then detail "$m_name (have it)"; exit 0; fi
      if ! curl -fL --retry 3 --retry-delay 2 -C - -o "$m_dest" "$u" >/dev/null 2>&1; then
        detail "failed: $m_name (skipping)"; rm -f "$m_dest"; exit 0; fi
      if [ -n "$sums" ]; then
        m_want=$(printf '%s\n' "$sums" | grep -F "$m_name" | awk '{print $1}' | head -1)
        if [ -n "$m_want" ]; then m_got=$(md5of "$m_dest")
          [ "$m_want" = "$m_got" ] || { detail "md5 mismatch: $m_name (skipping)"; rm -f "$m_dest"; exit 0; }
        fi
      fi
      detail "+ $m_name"
    ) &
    mpids+=("$!"); cnt=$((cnt+1)); launched=$((launched+1))
    if [ "$cnt" -ge "$par" ]; then for p in "${mpids[@]}"; do wait "$p"; done; mpids=(); cnt=0; prog $((launched*100/total)) "$launched / $total maps"; fi
  done <<EOF
$urls
EOF
  for p in "${mpids[@]}"; do wait "$p"; done
  stop_key_watcher
  prog 100 "$total / $total maps"; end_phase
  ok "Map set installed to $pakdir"
}

install_client
install_maps
end_phase

echo
ok "Installed to $INSTALL_DIR/$RUN_DIR"
echo
say "To play:"
echo "    cd \"$INSTALL_DIR/$RUN_DIR\" && $RUN_CMD"
echo
echo "${DIM}    Black screen or a hang on startup? Try:  $RUN_CMD -onethread${NC}"
echo "${DIM}    (some Mesa/RADV Vulkan combos deadlock without it)${NC}"
echo
