#!/usr/bin/env bash
# promote-to-stable.sh <platform> [source_channel]
#
# Promote a tested build to the STABLE channel that the installer pins to by default.
# Mirrors every release asset (manifest.tsv/json + bulk tar parts) from
# client-<platform>-<source_channel> (default: nightly) onto client-<platform>-stable,
# so both the incremental (manifest + shared client-<platform>-store) and bulk-tarball
# install paths serve the promoted build. The shared block store is never touched -
# stable and nightly reference the same content-addressed blocks.
#
# Idempotent: stale stable assets of the same name are deleted before re-upload.
# Requires: bash, jq, curl. Token in $UT_GH_TOKEN or ~/.ghcr_token.
#
#   platform       mac | linux | win64
#   source_channel any channel tag suffix (default nightly); e.g. `5.8` for the
#                  one-time initial pin from the legacy client-<plat>-5.8 releases.
set -u
PLAT="${1:?usage: promote-to-stable.sh <mac|linux|win64> [source_channel]}"
SRC_CH="${2:-nightly}"
REPO="${UT_REPO:-itpick/ut4-install}"
TOKEN="${UT_GH_TOKEN:-$(cat ~/.ghcr_token 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "X no token (set UT_GH_TOKEN or ~/.ghcr_token)"; exit 1; }

SRC_TAG="client-${PLAT}-${SRC_CH}"
DST_TAG="client-${PLAT}-stable"
API="https://api.github.com/repos/$REPO"
UP="https://uploads.github.com/repos/$REPO"
GH()  { curl -s -H "Authorization: token $TOKEN" "$@"; }
say() { echo "[$(date +%T)] $*"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

say "promote $SRC_TAG -> $DST_TAG"

src_rid=$(GH "$API/releases/tags/$SRC_TAG" | jq -r '.id // empty')
[ -n "$src_rid" ] || { echo "X source release $SRC_TAG not found"; exit 1; }

# ensure the destination stable release exists (create if missing)
dst_rid=$(GH "$API/releases/tags/$DST_TAG" | jq -r '.id // empty')
if [ -z "$dst_rid" ]; then
  say "creating $DST_TAG release"
  dst_rid=$(GH -X POST "$API/releases" -d "{\"tag_name\":\"$DST_TAG\",\"name\":\"UT4 client ($PLAT) - stable\",\"body\":\"Stable channel for $PLAT. Promoted from $SRC_TAG. The installer pins here by default.\"}" | jq -r '.id // empty')
  [ -n "$dst_rid" ] || { echo "X could not create $DST_TAG"; exit 1; }
fi

# assets to mirror: everything except .pdb (never shipped) and the split index noise
names=$(GH "$API/releases/$src_rid/assets?per_page=100" | jq -r '.[] | select(.name|test("\\.pdb$")|not) | .name')
[ -n "$names" ] || { echo "X source release has no assets"; exit 1; }

fail=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  url=$(GH "$API/releases/$src_rid/assets?per_page=100" | jq -r --arg n "$name" '.[]|select(.name==$n)|.url')
  say "  fetch $name"
  curl -sL -H "Authorization: token $TOKEN" -H "Accept: application/octet-stream" -o "$WORK/$name" "$url"
  [ -s "$WORK/$name" ] || { echo "  X download empty: $name"; fail=1; continue; }
  # delete stale destination asset of the same name
  old=$(GH "$API/releases/$dst_rid/assets?per_page=100" | jq -r --arg n "$name" '.[]|select(.name==$n)|.id')
  [ -n "$old" ] && GH -X DELETE "$API/releases/assets/$old" >/dev/null
  ok=0
  for att in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 30 --speed-limit 10240 --speed-time 180 --max-time 1800 \
      -H "Authorization: token $TOKEN" -H "Content-Type: application/octet-stream" \
      --data-binary @"$WORK/$name" "$UP/releases/$dst_rid/assets?name=$name")
    [ "$code" = 201 ] && { ok=1; break; }
    old=$(GH "$API/releases/$dst_rid/assets?per_page=100" | jq -r --arg n "$name" '.[]|select(.name==$n)|.id'); [ -n "$old" ] && GH -X DELETE "$API/releases/assets/$old" >/dev/null
    sleep 4
  done
  rm -f "$WORK/$name"
  if [ "$ok" = 1 ]; then say "  -> uploaded $name"; else echo "  X upload FAILED: $name"; fail=1; fi
done <<EOF
$names
EOF

if [ "$fail" = 0 ]; then
  say "DONE: $DST_TAG now serves the $SRC_CH build. Installer default (stable) will pick it up."
else
  echo "X promotion completed with errors - re-run to retry failed assets"; exit 1
fi
