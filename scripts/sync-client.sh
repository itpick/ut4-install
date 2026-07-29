#!/bin/bash
# sync-client.sh <platform> <build_tag> <install_dir>
#
# Incrementally sync a UT4 client from the content-addressed store to <install_dir>.
# Downloads ONLY files whose sha256 differs from the locally-installed manifest, pulling
# their blocks from release `client-<platform>-store` and assembling + verifying each file.
#
# bash-3.2 safe (macOS default shell): no associative arrays, no mapfile. Needs curl, jq,
# and sha256sum OR shasum. Public store => no auth needed for downloads.
set -u
PLAT="${1:?platform}"; BUILD_TAG="${2:?build_tag}"; DEST="${3:?install_dir}"
REPO="${UT_REPO:-itpick/ut4-install}"
STORE_TAG="client-${PLAT}-store"
DLBASE="https://github.com/$REPO/releases/download"
PAR="${UT_PAR:-6}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CACHE="$DEST/.blockcache"
LOCAL="$DEST/.installed-manifest.json"
say(){ echo "[$(date +%T)] $*"; }
sha256of(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

command -v jq   >/dev/null 2>&1 || { echo "X jq is required";   exit 1; }
command -v curl >/dev/null 2>&1 || { echo "X curl is required"; exit 1; }
mkdir -p "$DEST" "$CACHE"

# 1) fetch the chosen build's manifest
say "fetching manifest for $BUILD_TAG ..."
curl -fsSL "$DLBASE/$BUILD_TAG/manifest.json" -o "$TMP/manifest.json" || { echo "X no manifest.json at $BUILD_TAG"; exit 1; }
NF=$(jq '.files|length' "$TMP/manifest.json"); say "manifest lists $NF files"

# 2) diff vs the installed manifest -> need.tsv (path \t sha \t blocks-csv)
if [ -f "$LOCAL" ]; then jq -r '.files[]|"\(.path)\t\(.sha256)"' "$LOCAL" > "$TMP/old.tsv"; else : > "$TMP/old.tsv"; fi
jq -r '.files[]|"\(.path)\t\(.sha256)\t\(.blocks|join(","))"' "$TMP/manifest.json" > "$TMP/new.tsv"
: > "$TMP/need.tsv"
while IFS="$(printf '\t')" read -r path sha blocks; do
  osha=$(awk -F"$(printf '\t')" -v p="$path" '$1==p{print $2; exit}' "$TMP/old.tsv")
  if [ "$osha" = "$sha" ] && [ -f "$DEST/$path" ]; then continue; fi
  printf '%s\t%s\t%s\n' "$path" "$sha" "$blocks" >> "$TMP/need.tsv"
done < "$TMP/new.tsv"
NEED=$(wc -l < "$TMP/need.tsv" | tr -d ' ')
say "need to update $NEED/$NF files"

if [ "$NEED" -gt 0 ]; then
  # 3) unique blocks needed
  awk -F"$(printf '\t')" '{n=split($3,a,","); for(i=1;i<=n;i++) print a[i]}' "$TMP/need.tsv" | sort -u > "$TMP/blocks.txt"
  NB=$(wc -l < "$TMP/blocks.txt" | tr -d ' ')
  say "fetching $NB unique blocks (parallel x$PAR) ..."

  # 4) parallel block download (resume + retry, skip already-cached)
  fetch_block(){ local b="$1" out="$CACHE/$1"; [ -s "$out" ] && return 0
    curl -fL --retry 3 --retry-delay 2 -C - -o "$out" "$DLBASE/$STORE_TAG/$b" >/dev/null 2>&1; }
  export -f fetch_block; export CACHE DLBASE STORE_TAG
  xargs -P "$PAR" -I{} bash -c 'fetch_block "$@"' _ {} < "$TMP/blocks.txt"
  # verify all present
  miss=0; while IFS= read -r b; do [ -s "$CACHE/$b" ] || { echo "X block missing: $b"; miss=1; }; done < "$TMP/blocks.txt"
  [ "$miss" = 0 ] || { echo "X some blocks failed to download - re-run to resume"; exit 1; }

  # 5) assemble each needed file, verify sha256
  while IFS="$(printf '\t')" read -r path sha blocks; do
    mkdir -p "$DEST/$(dirname "$path")"
    set --; oldIFS="$IFS"; IFS=','; for b in $blocks; do set -- "$@" "$CACHE/$b"; done; IFS="$oldIFS"
    cat "$@" > "$DEST/$path.tmp"
    got=$(sha256of "$DEST/$path.tmp")
    if [ "$got" != "$sha" ]; then echo "X sha mismatch: $path (got ${got:0:12} want ${sha:0:12})"; rm -f "$DEST/$path.tmp"; exit 1; fi
    mv -f "$DEST/$path.tmp" "$DEST/$path"
  done < "$TMP/need.tsv"
  say "assembled + verified $NEED files"
fi

# 6) clean update: remove files in old manifest but not in the new one
if [ -f "$LOCAL" ]; then
  jq -r '.files[].path' "$TMP/manifest.json" | sort > "$TMP/newpaths.txt"
  jq -r '.files[].path' "$LOCAL"             | sort > "$TMP/oldpaths.txt"
  comm -23 "$TMP/oldpaths.txt" "$TMP/newpaths.txt" | while IFS= read -r p; do
    [ -n "$p" ] && { rm -f "$DEST/$p"; echo "  - removed $p"; }
  done
fi

# 7) record installed manifest, drop the block cache
cp -f "$TMP/manifest.json" "$LOCAL"
rm -rf "$CACHE"
say "SYNC-OK $BUILD_TAG -> $DEST ($NEED files updated)"
