# Performance & FPS

UT4 on UE5.8 targets high, stable frame rates (competitive shooters want 100+ FPS). This
page covers how to see your frame rate, what we've fixed, how to squeeze out more FPS on
weaker GPUs, and driver guidance.

> **Status:** a set of performance fixes is landing (see *What we've fixed* below). The
> biggest — re-enabling occlusion culling on Windows/macOS — ships in the next client
> build. If you're on an older build and CPU/GPU-bound, updating is the first step.

## See your frame rate & where time goes

Two ways:

- **In-game toggle:** *Settings → System → General → **Show Performance Stats*** (FPS + ping
  overlay). Persists across sessions.
- **Console** (press **`~`**, the tilde/backtick key):
  - `stat fps` — frame rate
  - `stat unit` — the important one: **Frame / Game (CPU) / Draw / GPU** milliseconds. If
    **GPU** ≈ Frame time, you're **GPU-bound** (lower graphics settings / resolution). If
    **Game** ≈ Frame time, you're **CPU-bound**.
  - `stat gpu` — detailed per-pass GPU cost
  - Type the same command again to turn it off.

## Typical performance by OS

Rough, community-reported numbers — **help us fill these in** (see *Report your numbers*).

| OS | GPU class | Typical FPS | Notes |
|----|-----------|-------------|-------|
| **Windows** (Win64) | Mid/high dGPU | _TBD_ | Uses D3D12 — keep GPU drivers current. |
| **Windows** (Win64) | Low-end / older laptop dGPU (e.g. RX 5500M) | _TBD (targeting 100+ after the occlusion fix)_ | GPU-bound; see tuning below. |
| **macOS** (Apple Silicon) | M1/M2/M3 | _TBD_ | Metal; integrated GPU scales with settings. |
| **macOS** (Intel) | AMD dGPU | _TBD_ | — |
| **Linux** | Mesa/RADV or NVIDIA | _TBD_ | Vulkan; if you see a hang on startup, launch with `-onethread`. |

*(Numbers are placeholders until we collect data — please report yours.)*

## Get more FPS

In-game, **Settings → Graphics**:

1. **Screen Percentage** — the single biggest GPU lever. Drop to **75–85%** for roughly
   **25–40 % more GPU headroom**; the image stays crisp on a fast-paced game.
2. **Overall quality / scalability** — pick a lower preset (Low/Medium). The scalability
   table is already conservative; Low is genuinely low.
3. **Anti-aliasing** — set to **FXAA** (cheap) or **Off** instead of TAA if you're
   GPU-bound. Saves ~0.5–1.5 ms/frame at 1080p.
4. **Frame Rate Cap** — raise it (or set unlimited) if your monitor is >120 Hz.

If you're **GPU-bound** (per `stat unit`), these help most. If you're **CPU-bound**, lower
resolution won't help — cap effects/view distance instead.

## GPU drivers

**Keep your GPU drivers current.** This is UE **5.8**, which uses **D3D12 on Windows** (and
Vulkan on Linux, Metal on macOS) and depends on modern driver PSO/barrier paths.

> ⚠️ If you remember *"new drivers made UT4 laggy"* — that was the **old UE4.15** UT4 on
> D3D11. This UE5.8 build is the opposite: **old (2019–2020-era) drivers cause hitching,
> long shader/PSO stalls, and D3D12 instability.** Update to the latest **AMD Adrenalin** /
> **NVIDIA Game Ready** / current Mesa. RDNA1 cards (RX 5500M etc.) still get current WHQL
> drivers.
>
> One-time note: the **first launch after a driver update** re-runs the shader/PSO warm-up
> (a few minutes of compiling) — that's expected and happens once.

## What we've fixed

- **Occlusion culling re-enabled on Windows/macOS.** A Linux-only Vulkan workaround
  (`r.AllowOcclusionQueries=0` / `r.HZBOcclusion=0`) had been applied cross-platform, so the
  client was drawing everything behind walls every frame — a large, map-dependent GPU cost,
  especially on 4 GB GPUs. Now scoped to Linux only.
- **Anti-aliasing selector fixed.** It previously wrote a removed CVar (a no-op), silently
  locking everyone to TAA; it now drives `r.AntiAliasingMethod` (Off / FXAA / TAA).
- **"Show Performance Stats" toggle** added to System settings.

Already off (good) for a competitive game on baked-lighting maps: Lumen, Nanite, virtual
shadow maps, motion blur, killcam/instant-replay.

**Planned:** dynamic resolution, a shipped PSO cache (kills first-run hitching), and a
low-spec auto-preset.

## Report your numbers

Hit a low frame rate? Use the in-game **"Report a Bug"** button (Main Menu or ESC) — it
uploads your log (with GPU/CPU/RAM + settings) so we can tune for your hardware. Include
your GPU, resolution, and the `stat unit` readout if you can.
