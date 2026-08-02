#!/bin/bash
# sync-client.sh <platform> <build_tag> <install_dir>
#
# Incrementally sync a UT4 client from the content-addressed store to <install_dir>:
# download ONLY files whose sha256 differs from the installed manifest, pull their
# blocks from release client-<platform>-store, assemble + sha256-verify each file.
#
# jq-free (stock macOS ships none) and bash-3.2 safe (macOS /bin/bash): parses the
# tab-separated manifest.tsv, no associative arrays / mapfile / wait -n / export -f.
# Needs: curl, awk, sort, comm, and sha256sum OR shasum.
set -u
PLAT="${1:?platform}"; BUILD_TAG="${2:?build_tag}"; DEST="${3:?install_dir}"
REPO="${UT_REPO:-itpick/ut4-install}"
STORE_TAG="client-${PLAT}-store"
DLBASE="https://github.com/$REPO/releases/download"
PAR="${UT_PAR:-6}"
# Optional self-hosted mirror (CDN/origin) tried first for the manifest + every block, with
# GitHub as the backup/source of truth (ut4-install#23). Off by default: empty = zero behavior
# change. Layout must mirror GitHub Releases exactly: $UT_MIRROR_BASE/<tag>/<asset>.
MIRROR_BASE="${UT_MIRROR_BASE:-}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CACHE="$DEST/.blockcache"
LOCAL="$DEST/.installed-manifest.tsv"
TAB=$(printf '\t')

# ---- progress UI: a phase title + bar by default; the verbose per-step log is hidden
# unless UT_DETAILS/the shared $UT_STATEF says otherwise. The installer's key-watcher
# flips $UT_STATEF live (press 'd'); we just read it, so the toggle is sticky here too. ----
BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; DIM=$'\033[2m'; NC=$'\033[0m'
UT_STATEF="${UT_STATEF:-$DEST/.ut-details}"
[ -f "$UT_STATEF" ] || printf '%s' "${UT_DETAILS:-0}" > "$UT_STATEF" 2>/dev/null || true
UT_PHASE=""; _BARW=30
is_detail(){ [ "$(cat "$UT_STATEF" 2>/dev/null)" = 1 ]; }
phase(){ UT_PHASE="$1"
  if is_detail; then printf '\n%s==>%s %s\n' "$BLUE" "$NC" "$1"
  else printf '\n%s%s%s  %spress d for details%s\n' "$BLUE" "$1" "$NC" "$DIM" "$NC"; fi; }
prog(){ is_detail && return 0
  local pct="${1:-0}" f i bar=""
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0; [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  f=$(( pct * _BARW / 100 ))
  for ((i=0;i<_BARW;i++)); do if [ "$i" -lt "$f" ]; then bar="${bar}#"; else bar="${bar}."; fi; done
  printf '\r  %s[%s]%s %3d%%  %s\033[K' "$GREEN" "$bar" "$NC" "$pct" "${2:-}"; }
detail(){ is_detail && printf '%s[%s] %s%s\n' "$DIM" "$(date +%T)" "$*" "$NC"; return 0; }

sha256of(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
# A cached block is valid iff it hashes to its own name (blocks are content-addressed). Split
# parts are named <filesha>.part-xx (not verifiable by name) -> accept if non-empty; the
# assembled file's sha256 (step 5) is the backstop for those. This catches truncated/corrupt
# downloads that are non-empty but short, which would otherwise assemble into a bad file.
block_valid(){ [ -s "$1" ] || return 1; case "$2" in *.part-*) return 0;; *) [ "$(sha256of "$1")" = "$2" ];; esac; }

command -v curl >/dev/null 2>&1 || { echo "X curl is required"; exit 1; }
mkdir -p "$DEST" "$CACHE"

# 1) fetch the chosen build's manifest (tab-separated: path \t sha256 \t size \t blocks-csv).
# Mirror first (short timeout) if configured, falling back to GitHub.
phase "Checking for updates"
detail "fetching manifest for $BUILD_TAG ..."
got_manifest=0
if [ -n "$MIRROR_BASE" ] && curl -fsSL --connect-timeout 4 -o "$TMP/manifest.tsv" "$MIRROR_BASE/$BUILD_TAG/manifest.tsv" 2>/dev/null && [ -s "$TMP/manifest.tsv" ]; then
  got_manifest=1
fi
[ "$got_manifest" = 1 ] || curl -fsSL "$DLBASE/$BUILD_TAG/manifest.tsv" -o "$TMP/manifest.tsv" || { echo "X no manifest.tsv at $BUILD_TAG"; exit 1; }
NF=$(grep -c . "$TMP/manifest.tsv" | tr -d ' ')
detail "manifest lists $NF files"
prog 5 "$NF files in manifest"

# 2) diff vs the installed manifest -> need.tsv (path \t sha \t blocks-csv)
: > "$TMP/need.tsv"
while IFS="$TAB" read -r path sha size blocks xbit; do
  [ -n "$path" ] || continue
  osha=""
  [ -f "$LOCAL" ] && osha=$(awk -F"$TAB" -v p="$path" '$1==p{print $2; exit}' "$LOCAL")
  # Bootstrap: no recorded manifest entry but the file is already on disk (e.g. the user
  # installed via the bulk tarball, or a prior sync was interrupted). Hash the on-disk file
  # so unchanged files are skipped instead of fully re-downloaded.
  if [ -z "$osha" ] && [ -f "$DEST/$path" ]; then osha=$(sha256of "$DEST/$path"); fi
  if [ "$osha" = "$sha" ] && [ -e "$DEST/$path" ]; then continue; fi
  printf '%s\t%s\t%s\t%s\n' "$path" "$sha" "$blocks" "${xbit:-0}" >> "$TMP/need.tsv"
done < "$TMP/manifest.tsv"
NEED=$(grep -c . "$TMP/need.tsv" 2>/dev/null | tr -d ' '); [ -n "$NEED" ] || NEED=0
detail "need to update $NEED/$NF files"

if [ "$NEED" -gt 0 ]; then
  # 3) unique blocks to fetch (blocks field is comma-separated)
  awk -F"$TAB" '{n=split($3,a,","); for(i=1;i<=n;i++) if(a[i]!="" && a[i]!="-") print a[i]}' "$TMP/need.tsv" | sort -u > "$TMP/blocks.txt"
  NB=$(grep -c . "$TMP/blocks.txt" | tr -d ' '); [ "$NB" -ge 1 ] 2>/dev/null || NB=1
  phase "Downloading UT4"
  detail "fetching $NB unique blocks (parallel x$PAR) ..."

  # 4) parallel download in bounded batches (bash-3.2 safe: no wait -n). Each downloaded block
  # is verified against its content-address; a corrupt/truncated block is dropped and re-fetched
  # (a non-empty but short block would otherwise assemble into a bad file). No -C - resume: we
  # rm a bad partial and pull it fresh rather than risk compounding a corrupt cache entry.
  fetch_blocks(){  # <base_url>
    local base="$1"
    BDONE=0; count=0; pids=""
    while IFS= read -r b; do
      out="$CACHE/$b"
      if block_valid "$out" "$b"; then BDONE=$((BDONE+1)); prog $((BDONE*100/NB)) "$BDONE / $NB files"; continue; fi
      rm -f "$out"                             # drop any truncated/corrupt partial
      ( curl -fL --retry 3 --retry-delay 2 -o "$out" "$base/$STORE_TAG/$b" >/dev/null 2>&1 ) &
      pids="$pids $!"; count=$((count+1))
      if [ "$count" -ge "$PAR" ]; then for p in $pids; do wait "$p"; done; pids=""; BDONE=$((BDONE+count)); count=0; prog $((BDONE*100/NB)) "$BDONE / $NB files"; fi
    done < "$TMP/blocks.txt"
    for p in $pids; do wait "$p"; done; BDONE=$((BDONE+count)); prog $((BDONE*100/NB)) "$BDONE / $NB files"
  }
  # First pass: the mirror if configured (self-host - ut4-install#23), else GitHub directly.
  FIRST_BASE="$DLBASE"; [ -n "$MIRROR_BASE" ] && FIRST_BASE="$MIRROR_BASE"
  [ -n "$MIRROR_BASE" ] && detail "trying self-hosted mirror first ($MIRROR_BASE) ..."
  fetch_blocks "$FIRST_BASE"
  # Second pass: re-fetch anything incomplete/corrupt/missing - always from GitHub. This is both
  # the existing corrupt-download retry AND the mirror-miss fallback: a mirror that doesn't have
  # every block yet (lazy-seeded CDN, partial rsync, or unreachable) degrades to plain GitHub for
  # just the blocks it was missing, instead of failing the whole sync.
  bad=0; while IFS= read -r b; do block_valid "$CACHE/$b" "$b" || { bad=1; break; }; done < "$TMP/blocks.txt"
  if [ "$bad" = 1 ]; then
    if [ "$FIRST_BASE" != "$DLBASE" ]; then detail "some blocks missing on the mirror - falling back to GitHub ..."
    else detail "re-fetching incomplete/corrupt blocks ..."; fi
    fetch_blocks "$DLBASE"
  fi

  miss=0; while IFS= read -r b; do block_valid "$CACHE/$b" "$b" || { echo "X block bad/missing: $b"; miss=1; }; done < "$TMP/blocks.txt"
  [ "$miss" = 0 ] || { echo "X some blocks failed integrity - re-run to resume"; exit 1; }

  # 5) assemble each file from its blocks (in order), verify sha256, restore +x
  phase "Verifying files"
  AN=$NEED; AI=0
  while IFS="$TAB" read -r path sha blocks xbit; do
    [ -n "$path" ] || continue
    AI=$((AI+1)); prog $((AI*100/AN)) "$AI / $AN files"
    mkdir -p "$DEST/$(dirname "$path")"
    if [ -z "$blocks" ] || [ "$blocks" = "-" ]; then
      : > "$DEST/$path.uttmp"    # empty file: no blocks in the store, create it empty
    else
      set --; oldIFS="$IFS"; IFS=','; for b in $blocks; do set -- "$@" "$CACHE/$b"; done; IFS="$oldIFS"
      cat "$@" > "$DEST/$path.uttmp"
    fi
    got=$(sha256of "$DEST/$path.uttmp")
    if [ "$got" != "$sha" ]; then echo "X sha mismatch: $path"; rm -f "$DEST/$path.uttmp"; exit 1; fi
    mv -f "$DEST/$path.uttmp" "$DEST/$path"
    [ "$xbit" = 1 ] && chmod +x "$DEST/$path"   # store holds content only - restore exec bit
  done < "$TMP/need.tsv"
  detail "assembled + verified $NEED files"
fi

# 6) clean update: remove files in the old manifest but not the new one
if [ -f "$LOCAL" ]; then
  awk -F"$TAB" '{print $1}' "$TMP/manifest.tsv" | sort > "$TMP/newpaths.txt"
  awk -F"$TAB" '{print $1}' "$LOCAL"            | sort > "$TMP/oldpaths.txt"
  comm -23 "$TMP/oldpaths.txt" "$TMP/newpaths.txt" | while IFS= read -r p; do
    [ -n "$p" ] && { rm -f "$DEST/$p"; detail "removed $p"; }
  done
fi

# 7) record installed manifest, drop the block cache
cp -f "$TMP/manifest.tsv" "$LOCAL"
rm -rf "$CACHE"
is_detail || printf '\r\033[K'
detail "SYNC-OK $BUILD_TAG -> $DEST ($NEED files updated)"
