# Building the UT4 (UE5.8) Editor from source

This is the **advanced, build-it-yourself** guide for mappers and modders who want the
**Unreal Editor** for the UE5.8 port of Unreal Tournament — the tool you open maps and
assets in, not the game client. It is a from-source build of our engine fork plus the UT
project. Expect a long first build (hours) and a lot of disk.

> **Just want to *play*?** You don't need any of this — use the
> [one-click installer](https://itpick.github.io/ut4-install/). The editor is only for
> people who want to open, edit, or make maps and content.
>
> **Prefer not to compile?** Pre-built editor packages are planned (see the bottom of this
> page). Until those ship, building from source is the only route.

---

## ⚠️ Read this first: the content problem

The editor is only useful if it has **uncooked** `.uasset`/`.umap` content to open. UT4's
uncooked source content is **not freely obtainable anymore**:

- The UT repo ships **no `Content/` directory in git**. Historically it was fetched by the
  engine's GitDependencies step from Epic's CDN — and **every UT content pack on
  `cdn.unrealengine.com/dependencies` now returns `403 AccessDenied`** (Epic pulled UT's
  content when they delisted the game). Engine dependencies still download fine; only UT's
  game content is gone.
- Public archives only contain **cooked** builds. Cooked paks cannot be opened or edited in
  the editor — cooking is one-way.

**What this means for a from-source editor:**

1. `Setup.sh`/`Setup.bat` will fetch the **engine** binaries/content fine. It will **not**
   get you UT's game content.
2. You must supply `UnrealTournament/Content/` yourself. If you have our uncooked content
   tree (33 GB — see the maintainers), drop it (or symlink it) at
   `<Engine>/UnrealTournament/Content`. Without it the editor opens but the UT maps/assets
   won't be there to edit.
3. Even with our tree, be aware some original stock assets were lost with the CDN. Meshes,
   textures, sounds and most animations survive; some Blueprints, Cascade particle systems,
   UMG, material graphs and level layouts from the very earliest content do not. What ships
   in our content tree is what survived. See
   [the content-availability note](https://github.com/itpick/ut4-install) for the full story.

If you don't have the content tree, you can still build and run the editor against an empty
project — useful for engine/C++ work, not for map editing.

---

## What you're building

| | |
|---|---|
| Engine fork | [`itpick/UnrealEngine`](https://github.com/itpick/UnrealEngine) branch **`5.8`** |
| Game project | [`itpick/UnrealTournament`](https://github.com/itpick/UnrealTournament) branch **`main`** |
| Target | **`UnrealTournamentEditor`**, configuration **Development Editor** |
| Output | The Unreal Editor, launched by opening `UnrealTournament.uproject` |

The UT project lives **inside** the engine tree at `<Engine>/UnrealTournament/` (this is a
source-tree layout, not an out-of-tree game project).

---

## Prerequisites (all platforms)

- **Disk: ~200 GB free.** A full engine + editor build tree is ~120 GB on its own; add
  uncooked content (33 GB), the derived-data cache the editor builds on first open (several
  GB), and headroom.
- **RAM: 32 GB strongly recommended** (16 GB will thrash and can OOM-kill the final monolithic
  link — see the Linux note). A fast multi-core CPU and an SSD make a large difference; the
  first build is hours.
- **A GitHub account with access** to both `itpick/UnrealEngine` and `itpick/UnrealTournament`.
- **git** (and `git-lfs` if you plan to pull LFS content; the engine fork itself does not
  require LFS for the source build).
- **The UT uncooked content tree** (see the content problem above) if you want to edit maps.

---

## Common steps (do this on every OS)

```bash
# 1. Clone the engine fork (the 5.8 branch) — this is the repo ROOT
git clone --branch 5.8 https://github.com/itpick/UnrealEngine.git
cd UnrealEngine

# 2. Clone the UT project INTO the engine tree, at ./UnrealTournament
git clone --branch main https://github.com/itpick/UnrealTournament.git UnrealTournament

# 3. Supply uncooked content (only if you have our content tree). Either copy it
#    into ./UnrealTournament/Content, or symlink it:
#      ln -s /path/to/ut4-content/Content UnrealTournament/Content   (macOS/Linux)
#    (Skip if you only want an empty-project / engine build.)
```

Then run the engine setup + project-file generation for your OS (below), **build the
`UnrealTournamentEditor` target in Development configuration**, and finally open
`UnrealTournament/UnrealTournament.uproject`.

`Setup` downloads Epic's prebuilt engine binaries/dependencies (large, one-time).
`GenerateProjectFiles` writes the IDE/build project files. Neither fetches UT game content
(see the content problem).

---

## macOS (Apple Silicon or Intel)

**Toolchain**

- **Xcode** (full app from the App Store, not just Command Line Tools) with the macOS SDK;
  run it once to accept the license and let it install components. Metal is included with
  the OS — no separate SDK.
- Confirm the active developer dir points at Xcode:
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

**Build**

```bash
# from the engine root, after the Common steps
./Setup.sh
./GenerateProjectFiles.sh          # or GenerateProjectFiles.command

# build the editor target (Development). This is the ~hours first build.
./Engine/Build/BatchFiles/Mac/Build.sh \
    UnrealTournamentEditor Mac Development \
    -project="$PWD/UnrealTournament/UnrealTournament.uproject" -waitmutex

# then open the project (this launches the editor you just built)
open UnrealTournament/UnrealTournament.uproject
```

**macOS gotchas**

- **GPU Lightmass bake commandlet fails to compile — this is expected and non-fatal.**
  `UnrealTournament/Source/UnrealTournamentEditor/Private/UTGPUBakeCommandlet.cpp` includes
  `GPULightmassSettings.h`, which is not on the include path for the plain editor target, so
  that one commandlet errors with `'GPULightmassSettings.h' file not found`. The **editor
  itself and all the game/HUD modules still build and link** — only the offline GPU-bake
  commandlet is affected, and you don't need it to open/edit maps. If a strict build fails
  *only* on that file, you can exclude the commandlet from the module or add the GPULightmass
  plugin's `Source/Public` to the include path; it does not block editor use.
- **Apple Silicon:** build native `arm64`. If you hit a plugin that dynamically loads a
  dylib and crashes on missing symbols, it is the known `dlopen` needing `RTLD_GLOBAL`
  visibility — load it globally rather than locally. (This does not affect a stock editor
  build; it only surfaces with certain third-party plugin dylibs.)
- The **app-sandbox / codesign** rules that matter for the *shipped client* (must be signed
  **unsandboxed** or mouse-look dies) do **not** apply to a locally-built editor you launch
  yourself via `open …uproject` — the editor is not re-signed/sandboxed. Just don't wrap it
  in an app-sandbox entitlement if you package it.

---

## Linux

**Toolchain**

- **clang** via the bundled **UE Linux toolchain** — `Setup.sh` downloads the exact clang
  toolchain UE5.8 expects (`v25`-era; it self-installs under
  `Engine/Extras/ThirdPartyNotUE/SDKs`). You do **not** need to match your distro's system
  clang; let Setup fetch the UE one.
- **Vulkan**: install your distro's Vulkan loader + headers and a working ICD
  (`vulkan-tools`, `libvulkan-dev`/`vulkan-loader`, Mesa RADV or your vendor driver).
- Standard build deps: `mono`/`dotnet` are bundled by the engine; also `clang`, `lld`,
  `python3`, and the usual `build-essential`-style packages.

**Build**

```bash
# from the engine root, after the Common steps
./Setup.sh
./GenerateProjectFiles.sh

./Engine/Build/BatchFiles/Linux/Build.sh \
    UnrealTournamentEditor Linux Development \
    "$PWD/UnrealTournament/UnrealTournament.uproject"

# launch the editor
./Engine/Binaries/Linux/UnrealEditor UnrealTournament/UnrealTournament.uproject
```

**Linux gotchas**

- **The final monolithic link can OOM-kill on <32 GB RAM / no swap.** On a 30 GB box with
  ~7–8 GB free, the single `clang++ -fuse-ld` link of a monolithic target gets `Killed`
  (often after `UbaSessionServer - Process timed out`). The compile phase fits; only the one
  giant link blows the budget. Fixes: free RAM first, add swap, or pass **`-NoDebugInfo`** to
  `Build.sh` (strips the DWARF that dominates linker memory). Note `-NoDebugInfo` changes the
  build config, so it forces a full recompile the first time you add it.
- **Mesa/RADV Vulkan deadlock in the editor:** some Mesa versions deadlock the Vulkan RHI.
  We run the editor/client with **Mesa 25.2.8**; newer kisak Mesa (26.x) caused GPU hangs on
  our hardware. If the editor hangs on a black viewport, try launching with **`-onethread`**
  (single-threaded rendering) — the multithreaded RHI can deadlock in
  `FVulkanContextCommon::FlushCommands` on RADV.
- **Cooking maps on a RAM-limited box:** a default cook does a full delete of `Saved/Cooked`
  then can silently OOM-kill mid-cook while UAT still exits 0 and stages a broken pak. If you
  cook from this editor on a tight box, bound cook memory:
  `-ini:Engine:[CookSettings]:MemoryMaxUsedPhysical=4500`
  `-ini:Engine:[CookSettings]:MemoryMinFreePhysical=1800`
  `-ini:Engine:[CookSettings]:CookProcessCount=1`, and always sanity-check the resulting pak
  is GB-sized (not ~90 MB) and free of `WorldGridMaterial`/`Corrupt data` errors.

---

## Windows (Win64)

**Toolchain**

- **Visual Studio 2022** with:
  - *Desktop development with C++* workload
  - **MSVC v143** build tools (x64/x86)
  - **Windows 10/11 SDK**
  - *Game development with C++* (pulls the Unreal-friendly components) is convenient but not
    strictly required.
- **.NET** SDK is bundled by the engine (UBT/UAT). D3D12-capable GPU + recent drivers.

**Build**

```bat
:: from the engine root, after the Common steps (use a normal cmd/PowerShell)
Setup.bat
GenerateProjectFiles.bat

:: build the editor target (Development). You can also open UE5.sln in VS2022 and build
:: the "UnrealTournamentEditor" target in the "Development Editor" configuration.
Engine\Build\BatchFiles\Build.bat ^
    UnrealTournamentEditor Win64 Development ^
    -project="%CD%\UnrealTournament\UnrealTournament.uproject" -waitmutex

:: launch
Engine\Binaries\Win64\UnrealEditor.exe UnrealTournament\UnrealTournament.uproject
```

**Windows gotchas**

- The **GPU Lightmass bake commandlet** caveat from macOS applies here too if you build the
  full editor target strictly — the `UTGPUBakeCommandlet.cpp` / `GPULightmassSettings.h`
  include only affects that offline commandlet, not the editor itself.
- **Restricted folder names in content** can trip *staging* (not editing): an asset under a
  folder literally named `Windows` (e.g. `RestrictedAssets/.../Industrial/Windows/…`) is
  treated as a restricted platform name and fails a later cook/stage. This only matters if
  you cook/package from the editor; add
  `+AllowedDirectories=UnrealTournament/Content/RestrictedAssets/Environments/Industrial/Windows`
  under `[Staging]` in `UnrealTournament/Config/DefaultGame.ini` if you hit it.
- Long paths: keep the engine tree near a drive root (e.g. `C:\UE58\`) to avoid
  `MAX_PATH` issues during the build.

---

## After it builds

- First editor launch compiles shaders and builds the derived-data cache — this is slow the
  first time (many minutes) and much faster afterward.
- If maps show a flat/grey viewport on load, it's usually a runtime navmesh rebuild (UT maps
  ship without saved navmesh); let it finish, or open **Build → Build Paths** and re-save.
- To produce a **playable client** from your edits you cook/stage the project — see the
  maintainer build recipe; that path is separate from just running the editor.

---

## Pre-built editor packages (planned)

Compiling from source is heavy. Redistributable pre-built editor packages
(macOS / Linux / Windows) are planned, distributed like the client
(`ghcr.io/itpick/ut4-install`, tag scheme `editor-<plat>-5.8`) with a "For mappers" section
on the [download site](https://itpick.github.io/ut4-install/). They will be considerably
larger than the game client (tens of GB) because they carry the editor binaries, full engine
content, and the uncooked UT content needed to edit maps. This page will link them once they
exist.
