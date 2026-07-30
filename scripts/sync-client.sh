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
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CACHE="$DEST/.blockcache"
LOCAL="$DEST/.installed-manifest.tsv"
TAB=$(printf '\t')
say(){ echo "[$(date +%T)] $*"; }
sha256of(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

command -v curl >/dev/null 2>&1 || { echo "X curl is required"; exit 1; }
mkdir -p "$DEST" "$CACHE"

# 1) fetch the chosen build's manifest (tab-separated: path \t sha256 \t size \t blocks-csv)
say "fetching manifest for $BUILD_TAG ..."
curl -fsSL "$DLBASE/$BUILD_TAG/manifest.tsv" -o "$TMP/manifest.tsv" || { echo "X no manifest.tsv at $BUILD_TAG"; exit 1; }
NF=$(grep -c . "$TMP/manifest.tsv" | tr -d ' ')
say "manifest lists $NF files"

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
say "need to update $NEED/$NF files"

if [ "$NEED" -gt 0 ]; then
  # 3) unique blocks to fetch (blocks field is comma-separated)
  awk -F"$TAB" '{n=split($3,a,","); for(i=1;i<=n;i++) if(a[i]!="" && a[i]!="-") print a[i]}' "$TMP/need.tsv" | sort -u > "$TMP/blocks.txt"
  NB=$(grep -c . "$TMP/blocks.txt" | tr -d ' ')
  say "fetching $NB unique blocks (parallel x$PAR) ..."

  # 4) parallel download in bounded batches (bash-3.2 safe: no wait -n)
  count=0; pids=""
  while IFS= read -r b; do
    out="$CACHE/$b"
    [ -s "$out" ] && continue
    ( curl -fL --retry 3 --retry-delay 2 -C - -o "$out" "$DLBASE/$STORE_TAG/$b" >/dev/null 2>&1 ) &
    pids="$pids $!"; count=$((count+1))
    if [ "$count" -ge "$PAR" ]; then for p in $pids; do wait "$p"; done; pids=""; count=0; fi
  done < "$TMP/blocks.txt"
  for p in $pids; do wait "$p"; done

  miss=0; while IFS= read -r b; do [ -s "$CACHE/$b" ] || { echo "X block missing: $b"; miss=1; }; done < "$TMP/blocks.txt"
  [ "$miss" = 0 ] || { echo "X some blocks failed to download - re-run to resume"; exit 1; }

  # 5) assemble each file from its blocks (in order), verify sha256, restore +x
  while IFS="$TAB" read -r path sha blocks xbit; do
    [ -n "$path" ] || continue
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
  say "assembled + verified $NEED files"
fi

# 6) clean update: remove files in the old manifest but not the new one
if [ -f "$LOCAL" ]; then
  awk -F"$TAB" '{print $1}' "$TMP/manifest.tsv" | sort > "$TMP/newpaths.txt"
  awk -F"$TAB" '{print $1}' "$LOCAL"            | sort > "$TMP/oldpaths.txt"
  comm -23 "$TMP/oldpaths.txt" "$TMP/newpaths.txt" | while IFS= read -r p; do
    [ -n "$p" ] && { rm -f "$DEST/$p"; echo "  - removed $p"; }
  done
fi

# 7) record installed manifest, drop the block cache
cp -f "$TMP/manifest.tsv" "$LOCAL"
rm -rf "$CACHE"
say "SYNC-OK $BUILD_TAG -> $DEST ($NEED files updated)"
