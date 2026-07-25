# Changelog

Notable bugs fixed and features added to Unreal Tournament (2017) since the port from
Unreal Engine 4.15 to **Unreal Engine 5.8**. The whole game — client, dedicated server,
and editor — was migrated to UE5.8 (C++20), then hardened with the changes below.

## Platforms

- **Linux**, **macOS** (Universal — native Intel *and* Apple Silicon), and **Windows (Win64)** clients, plus a Linux dedicated server / hub — all on the same UE5.8 codebase, joining the same hubs.

## Features & improvements

- **Auto-login / remember-me** — remembers your account per login server and signs you back in automatically.
- **Hubs & matchmaking** — lobby hubs spawn match instances on demand; custom rulesets (Blitz 10v10, the full FlagRun map list, plus DM/CTF); QuickPlay matchmaking.
- **Automatic map downloads** — missing community map paks download over an HTTPS redirect (per-platform paks, no extra ports to open).
- **All three modes verified end-to-end** — Deathmatch, Capture the Flag, and Blitz (FlagRun) — with full HUD, teams, bots, and objectives.
- **Server browser** — servers list reliably (master-server heartbeat), hubs land in the Hubs tab, and players show their display name instead of an account id.
- **Servers behind NAT / tunnels** (playit.gg, Cloudflare, home/CGNAT) can advertise the public address players actually connect to.
- Team chat tinted red/blue in the menu & lobby; build/engine/date shown on the home panel.
- Headless **GPU Lightmass** map baking (new `UTGPUBake` commandlet).
- Crash-report and telemetry uploads to Epic disabled.

## Bug fixes

### Input
- **Mouse-look was dead in matches** on macOS (you could move and shoot, but the view wouldn't turn) — the macOS **app sandbox** was silently revoking the game's mouse capture. The Mac client now ships **unsandboxed**, restoring look.
- Map-picker selection now visibly highlights the chosen map.

### Stability & memory
- **~80 GB memory spike and the crash when exiting a match to the menu** — fixed the killcam replay-driver teardown and a runaway home-panel LAN-ping beacon leak that spawned (and never freed) hundreds of net drivers.
- macOS **code-signing / startup crashes** — the correct bundle identity is now baked into the build.
- Profile values (FOV, HUD scale/opacity) are sanitized, fixing a flat-grey "frozen" screen on match start.
- Numerous editor/startup asserts fixed (world settings, missing CVars, HTTP timeout).

### Maps & content
- Fixed load crashes on **DM-Underland**, **FR-Fort**, and **FR-Loh** (CoreRedirects for renamed classes).
- Fixed a client crash the instant a map-redirect download started.
- Only the running platform's map pak is downloaded (not every platform's).

### Online & hubs
- Hub instance joins fixed (publish/filter by instance GUID); instance-ready notify retries until the lobby beacon connects.
- Correct beacon-port advertisement and instance/stats port allocation; hubs can run in as few as 2 exposed ports.
- LAN play on macOS works (declares the Local Network permission).

### Rendering
- Maps that previously showed a flat/blank screen now render fully (occlusion-query deadlock fixed; driver workarounds retired).

---

*This is a living document; see the [git history](https://github.com/itpick/UnrealTournament) for the full commit-level detail.*
