# UT4 client — incremental update system (design)

## Decisions (locked 2026-07-29)
- **Chunking: A1 (chunked cook paks), A2 (CDC) kept in reserve** — build A1; add A2 only
  if A1's per-chunk content updates prove still too big.
- **Phase 0 (drop PDB): do now.** Shipped as part of this work.

## Measured impact of dropping the 2.6 GB PDB (Windows)
- Extracted install: 9.08 GB → ~6.5 GB (**−2.6 GB, ~29% less disk**).
- Download (tar.zst): 6.52 GB → **5.92 GB** (−0.6 GB, ~9%) — the PDB compresses ~4× in
  zstd, so the disk-footprint win is the real prize; bandwidth win is modest.
- The big download lever is **incremental sync** (Phases 1–2), not the PDB.

## Goal
Client updates download only what changed, on all 3 OSes, distributed via GitHub
Releases + the existing bash/PowerShell installers.

## Core idea: everything is a hash-synced file
Replace the single ~7 GB `tar.zst` with a **per-build manifest** + many individual
release assets. One unified mechanism covers both "per-file sync" and "chunked pak":
a pak chunk is just another file in the manifest.

**Manifest** (`manifest-<plat>.json`, a release asset per build):
```json
{ "build": "55116800", "platform": "win64",
  "files": [ { "path": "UnrealTournament/Content/Paks/pakchunk10-...pak",
               "sha256": "…", "size": 12345, "asset": "pakchunk10__...pak" } ] }
```
- `path` = install-relative path. `asset` = flattened GH asset name (`/`→`__`, GH
  assets can't contain slashes). Files >1.9 GB are split into `.part-aa…` (existing logic).

**Installer sync algorithm:**
1. Resolve build (existing picker) → fetch its `manifest-<plat>.json`.
2. Read local `.installed-manifest.json` (kept in the install dir).
3. For each manifest entry: if local file missing OR local manifest hash differs →
   mark for download. Files only in the local manifest → delete (clean update).
4. Download the marked assets in parallel (existing parallel + self-heal path).
5. Verify each downloaded file's sha256 == manifest; place it; write the new local manifest.
- Fresh install = every file marked (same as today, just many files). Re-hash only on
  first install / when local manifest is missing; thereafter trust the stored manifest.

## Two payoff dimensions
1. **Code patch** (C++ fix): only `UnrealTournament.exe` (+ maybe a DLL) changes →
   ~350 MB instead of ~7 GB. Handled by per-file sync alone.
2. **Content recook**: the content pak changes → must be **chunked** or the whole pak
   re-downloads. See "chunking the pak" below.

## Chunking the content pak — DECISION NEEDED
### Option A1 (RECOMMENDED): chunked cook paks (UE-native)
Configure the cook to emit multiple paks grouped by asset (per-map + a shared/core pak),
via AssetManager chunk IDs / PrimaryAssetLabels / `-manifests`. A recook of one map
rewrites only that map's pak; the installer hash-syncs paks like any other file.
- Pro: UE loads them natively; **we already do this for the 40 add-on maps** (maps-win-v1).
- Pro: no extra client-side tooling — folds into the manifest sync.
- Con: needs cook/packaging config; granularity = asset grouping (a shared-asset change
  rewrites the core pak, but core rarely changes).

### Option A2: content-defined chunking of the final pak (casync/desync/zsync)
Keep one pak; split its bytes into content-defined chunks, ship a chunk store + index;
installer downloads changed chunks and reassembles the 5.9 GB pak locally.
- Pro: no cook change; byte-level dedup.
- Con: needs a cross-platform chunker/reassembler binary bundled in the installer;
  rewrites a 5.9 GB file on every content update; Oodle re-compression shifts bytes so
  dedup gains are uncertain. More moving parts for uncertain benefit.

**Recommendation: A1.** Native, reuses the maps pattern, zero extra client tooling.
Layer A2 later only if per-chunk content updates are still too big.

## Compression note
The big assets (paks, DLLs) are already compressed (Oodle / PE) — per-file zstd gains
~nothing and adds decompress cost. Ship big files as-is; only the tiny text/data files
and the manifest are worth compressing (optional). So "many files" ≠ "recompress each".

## Free win, independent of all the above
**Stop staging the 2.6 GB `UnrealTournament.pdb`** (debug symbols players never use):
`-nodebuginfo` on BuildCookRun (or delete before packaging). Every download −2.6 GB.
Archive PDBs separately for crash symbolication.

## Publish-side ("only upload what changed")
A packaging script (runs where the build is staged): exclude PDB → (cook chunked paks) →
sha256 every file → generate manifest → **diff against the previous release's manifest →
upload only changed/new assets, delete removed ones.** Mirrors the installer's logic on
the upload side, so a code-only patch uploads ~350 MB, not 7 GB.

## Phased delivery
- **Phase 0 (free, now):** drop the PDB from staging; re-ship. −2.6 GB for everyone.
- **Phase 1:** manifest + per-file hash-sync installer (paks still whole, but per-file
  sync ⇒ cheap code patches). Publish-side manifest+diff-upload script.
- **Phase 2:** chunk the content pak (A1 cook config) ⇒ content recooks incremental too.
- **Phase 3 (optional):** CDC (A2) if Phase 2 chunks are still too coarse.

## Open questions
1. Chunking approach: A1 (chunked cook paks) vs A2 (CDC)? — recommend A1.
2. Start Phase 0 (PDB drop) immediately, in parallel with designing Phase 1?
3. Clean-update deletes (remove local files not in the manifest) — yes/no? (recommend yes,
   with the install dir treated as installer-owned.)
```
