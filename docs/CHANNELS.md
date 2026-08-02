# Release channels: stable & nightly

The installer serves two channels per platform. Both reference the **same shared
content-addressed block store** (`client-<plat>-store`) and the same map paks
(`maps-<plat>-v1`); only the per-build manifest + bulk tarball differ.

| Channel   | Release tag              | Who gets it                                   |
|-----------|--------------------------|-----------------------------------------------|
| `stable`  | `client-<plat>-stable`   | **installer default** — tested, promoted builds |
| `nightly` | `client-<plat>-nightly`  | opt-in (`--nightly` / `-Nightly` / `UT_CHANNEL=nightly`) — latest dev build |

`<plat>` is `mac`, `linux`, or `win64`.

## Users

```bash
# stable (default)
curl -fsSL https://itpick.github.io/ut4-install/install.command | bash
# nightly
curl -fsSL https://itpick.github.io/ut4-install/install.command | bash -s -- --nightly
```
```powershell
irm https://itpick.github.io/ut4-install/install.ps1 | iex                                   # stable
& ([scriptblock]::Create((irm https://itpick.github.io/ut4-install/install.ps1))) -Nightly    # nightly
```

Switching channels re-runs incrementally: only files whose hash changed download,
because the block store is shared. `DOWNLOAD_BASE` / `-DownloadBase` (or
`UT_DOWNLOAD_BASE`) still pins an explicit release tag and overrides the channel.

## Maintainers — publishing flow

1. **Publish a new build to nightly.** Point the ship scripts at the nightly tag:
   - store/incremental: `make-store-manifest.sh <staged_dir> <plat> nightly [PREFIX]`
     (uploads only new blocks to `client-<plat>-store`, writes the manifest to
     `client-<plat>-nightly`). Prefix: none for mac, `LinuxNoEditor` for linux, `""` for win64.
   - bulk tarball: split + upload `ut4-client-<plat>.tar.zst.part-*` to `client-<plat>-nightly`.
   The nixtop reship scripts (`linux-reship-full.sh`, `win-reship2.sh`, …) already target nightly.

2. **Test the nightly build.** At minimum, confirm the pak carries a complete global
   shader library (a truncated one crashes at launch — "Could not load section 0 of N
   of the global shadermap"):
   `UnrealPak <client>.pak -List | grep -i GlobalShaderCache` → present at full size (~32 MB).

3. **Promote to stable** once verified:
   ```bash
   scripts/promote-to-stable.sh <mac|linux|win64>      # mirrors nightly -> stable
   ```
   This mirrors the nightly manifest + tar parts onto `client-<plat>-stable`. The block
   store is untouched (shared), so promotion never re-uploads blocks.

The one-time initial pin (2026-08-01) renamed the legacy `client-<plat>-5.8` releases to
`client-<plat>-stable`; those `-5.8` tags are retired.
