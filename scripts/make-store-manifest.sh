#!/bin/bash
# make-store-manifest.sh <staged_dir> <platform> <build_label>
#
# Content-addressed publish (Model B). For every file under <staged_dir> (except
# *.pdb): hash it, split into <=1.9 GB blocks named by the file's sha256, and
# upload ONLY blocks not already in the append-only store release
# `client-<platform>-store`. Then write a tiny per-build manifest to release
# `client-<platform>-<build_label>` (manifest.json) listing path -> sha -> blocks.
#
# Re-runnable + incremental: unchanged files upload nothing (their blocks already
# exist in the store). Requires: bash, jq, curl, sha256sum, split. Token in ~/.ghcr_token
set -u
STAGE="${1:?staged_dir}"; PLAT="${2:?platform}"; BUILD="${3:?build_label}"
# Optional 4th arg: a path prefix prepended to every manifest path (files are still
# read from STAGE). Use it so manifest paths match where the installer writes them -
# e.g. Linux wraps the client in LinuxNoEditor/, so pass PREFIX=LinuxNoEditor.
PREFIX="${4:-}"
REPO=itpick/ut4-install
TOKEN="${UT_GH_TOKEN:-$(cat ~/.ghcr_token 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "X no token (set UT_GH_TOKEN or ~/.ghcr_token)"; exit 1; }
STORE_TAG="client-${PLAT}-store"
BUILD_TAG="client-${PLAT}-${BUILD}"
SPLIT=${UT_SPLIT:-1992294400}   # 1900 MiB, < GitHub's 2 GB asset cap (override for tests)
API="https://api.github.com/repos/$REPO"
UP="https://uploads.github.com/repos/$REPO"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

GH()  { curl -s -H "Authorization: token $TOKEN" "$@"; }
say() { echo "[$(date +%T)] $*"; }
# portable helpers (works on Linux GNU coreutils AND macOS BSD tools)
fsize()    { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }
sha256of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

[ -d "$STAGE" ] || { echo "X no staged dir: $STAGE"; exit 1; }
command -v jq >/dev/null || { echo "X jq required"; exit 1; }

ensure_release() {  # <tag> [prerelease] -> echoes release id
  local tag="$1" pre="${2:-false}" rid
  rid=$(GH "$API/releases/tags/$tag" | jq -r '.id // empty')
  [ -n "$rid" ] || rid=$(GH -X POST "$API/releases" \
        -d "{\"tag_name\":\"$tag\",\"name\":\"$tag\",\"prerelease\":$pre}" | jq -r '.id // empty')
  echo "$rid"
}

# All asset names on a release (paginated - the store can exceed 100).
list_asset_names() {  # <release_id>
  local rid="$1" page=1 names
  while :; do
    names=$(GH "$API/releases/$rid/assets?per_page=100&page=$page" | jq -r '.[].name')
    [ -z "$names" ] && break
    printf '%s\n' "$names"
    page=$((page+1))
  done
}

upload_asset() {  # <release_id> <name> <filepath>
  local rid="$1" name="$2" fp="$3" code
  code=$(curl -s -o "$TMP/up.out" -w '%{http_code}' -X POST \
    -H "Authorization: token $TOKEN" -H "Content-Type: application/octet-stream" \
    --data-binary @"$fp" "$UP/releases/$rid/assets?name=$name")
  [ "$code" = "201" ]
}

say "publish: staged=$STAGE plat=$PLAT build=$BUILD"
STORE_ID=$(ensure_release "$STORE_TAG"); [ -n "$STORE_ID" ] || { echo "X could not ensure store release"; exit 1; }
say "store release $STORE_TAG id=$STORE_ID"

# Set of blocks already in the store (skip re-upload = incremental).
declare -A HAVE
while IFS= read -r n; do [ -n "$n" ] && HAVE["$n"]=1; done < <(list_asset_names "$STORE_ID")
say "store already holds ${#HAVE[@]} blocks"

MANIFEST="$TMP/manifest.json"
: > "$TMP/files.ndjson"
NEW=0; SKIP=0; NFILES=0

# Walk files (exclude *.pdb), deterministic order.
while IFS= read -r f; do
  rel="${f#"$STAGE"/}"
  [ -n "$PREFIX" ] && rel="$PREFIX/$rel"
  NFILES=$((NFILES+1))
  sha=$(sha256of "$f")
  size=$(fsize "$f")
  blocks=()
  if [ "$size" -gt "$SPLIT" ]; then
    # split into <sha>.part-aa ...; upload the missing ones.
    pref="$TMP/blk."
    rm -f "${pref}"*
    split -b "$SPLIT" -a 2 "$f" "$pref"
    for part in "${pref}"*; do
      # split -a 2 names blocks <pref>aa, <pref>ab, ...  -> suffix is the tail
      suf="part-${part#$pref}"    # e.g. part-aa
      bname="${sha}.${suf}"
      blocks+=("$bname")
      if [ -n "${HAVE[$bname]:-}" ]; then SKIP=$((SKIP+1)); else
        if upload_asset "$STORE_ID" "$bname" "$part"; then HAVE[$bname]=1; NEW=$((NEW+1)); say "  + $rel [$bname]"
        else echo "X upload failed: $bname"; exit 1; fi
      fi
    done
    rm -f "${pref}"*
  else
    bname="$sha"
    blocks+=("$bname")
    if [ -n "${HAVE[$bname]:-}" ]; then SKIP=$((SKIP+1)); else
      if upload_asset "$STORE_ID" "$bname" "$f"; then HAVE[$bname]=1; NEW=$((NEW+1)); say "  + $rel [$bname]"
      else echo "X upload failed: $bname"; exit 1; fi
    fi
  fi
  # emit one manifest file record (blocks as JSON array) - human/debug format
  jq -cn --arg p "$rel" --arg s "$sha" --argjson z "$size" \
     --argjson b "$(printf '%s\n' "${blocks[@]}" | jq -R . | jq -cs .)" \
     '{path:$p, sha256:$s, size:$z, blocks:$b}' >> "$TMP/files.ndjson"
  # and a jq-free TSV row (path \t sha256 \t size \t block1,block2,...) - this is what
  # the installers parse, so they need no jq (stock macOS ships none).
  printf '%s\t%s\t%s\t%s\n' "$rel" "$sha" "$size" "$(IFS=,; printf '%s' "${blocks[*]}")" >> "$TMP/files.tsv"
done < <(find "$STAGE" -type f ! -name '*.pdb' | LC_ALL=C sort)   # newline-delimited: portable (macOS sort lacks -z); UE paths have no newlines

say "files=$NFILES  new blocks uploaded=$NEW  reused=$SKIP"

# Assemble manifest.json (human/debug) and manifest.tsv (what installers parse)
jq -s --arg plat "$PLAT" --arg build "$BUILD" --arg store "$STORE_TAG" \
   '{schema:1, platform:$plat, build:$build, store_tag:$store, files:.}' \
   "$TMP/files.ndjson" > "$MANIFEST"
cp -f "$TMP/files.tsv" "$TMP/manifest.tsv"
MSIZE=$(fsize "$MANIFEST")
say "manifest.json = $MSIZE bytes; manifest.tsv = $(wc -l < "$TMP/manifest.tsv" | tr -d ' ') files"

# Publish both manifests to the per-build release (replace if present).
BUILD_ID=$(ensure_release "$BUILD_TAG"); [ -n "$BUILD_ID" ] || { echo "X could not ensure build release"; exit 1; }
for name in manifest.json manifest.tsv; do
  old=$(GH "$API/releases/$BUILD_ID/assets?per_page=100" | jq -r --arg n "$name" '.[]|select(.name==$n)|.id')
  [ -n "$old" ] && GH -X DELETE "$API/releases/assets/$old" >/dev/null
done
upload_asset "$BUILD_ID" "manifest.json" "$MANIFEST"          || { echo "X manifest.json upload failed"; exit 1; }
upload_asset "$BUILD_ID" "manifest.tsv"  "$TMP/manifest.tsv"  || { echo "X manifest.tsv upload failed";  exit 1; }
say "PUBLISH-OK $BUILD_TAG (manifest.json + manifest.tsv) -> store $STORE_TAG"
