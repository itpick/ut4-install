# UT4 on Unreal Engine 5.8 — install guide

Unofficial port of **Unreal Tournament (2017)** from Unreal Engine 4.15 to **Unreal Engine 5.8**.

| | |
|---|---|
| Engine | Unreal Engine 5.8.0 |
| Build | `55116800` |
| Built | 2026-07-22 |
| Platforms | Linux ✅ · macOS (Apple Silicon) ✅ · Windows 🚧 |

> **Builds are not published yet.** This repo currently documents how to install and run;
> download links land here once the first release is cut. Source lives in
> [itpick/UnrealTournament](https://github.com/itpick/UnrealTournament) on the `ue5.8-port` branch.

---

## Important: you cannot mix versions

A UE5.8 client can only join a UE5.8 server, and a 4.x client can only join a 4.x server.
The engine network protocol and map serialization both changed, so the two populations are
mutually unreachable by design — servers advertise their network version and clients filter
on it.

Maps are also **cooked per platform**. The lighting bake is shared, but Linux, macOS and
Windows each need their own pak set. A single universal map pak is not possible.

---

## Requirements

- A 64-bit machine with a GPU supporting **Vulkan** (Linux), **Metal** (macOS) or **D3D12** (Windows)
- ~16 GB free disk for the client
- An account on the master server you intend to play on

---

## Linux

```bash
tar xf UT4-UE58-Linux.tar.gz
cd UT4-UE58-Linux
./UnrealTournament.sh
```

If you get a black screen or a hang on startup, try forcing single-threaded rendering:

```bash
./UnrealTournament.sh -onethread
```

Some Mesa/RADV driver combinations deadlock in the Vulkan RHI without it.

---

## macOS (Apple Silicon)

```bash
xattr -dr com.apple.quarantine UnrealTournament.app   # if downloaded via a browser
open UnrealTournament.app
```

### Grant Local Network access — required for LAN play

From **macOS 15 onward**, macOS blocks apps from reaching other machines on your network
until you approve it. On first launch you should get a prompt; approve it.

If you miss the prompt, enable it manually:

**System Settings → Privacy & Security → Local Network → Unreal Tournament**

Without this permission the symptoms are confusing rather than obvious:

- Login to a master server on your LAN fails instantly with *"The Internet connection appears to be offline"*
- Servers appear in the browser but never respond to pings, so hubs look empty
- Joining a game silently times out

A master server reached over the public internet works without it; only LAN addresses are gated.

---

## Windows

Not yet available. This section lands with the first Windows build.

---

## Signing in

The game needs a master server for login and the server browser.

1. Launch the game
2. On the login screen, set **Login Server** to the master server URL, e.g. `https://ut4.example.com`
3. Enter your username and password, then **Sign In**

**Play Offline** skips login entirely and works for single-player and bot matches.

---

## Joining a game

**Hubs** host multiple matches; you join the hub, then join or start a match inside it.
**Servers** are a single ongoing match you join directly.

`PLAY → Join a Hub` lists both, split across the **Hubs** and **Servers** tabs. Empty hubs
are shown, but a server only appears once it answers a ping — if the list is empty, the
servers either are not running or are unreachable from your network.

You can also connect directly from the console:

```
open <address>:7777
```

---

## Running your own server or hub

```bash
# Hub — hosts a lobby and spawns match instances on demand
./UnrealTournamentServer "UT-Entry?Game=LOBBY" -log -port=7777

# Single dedicated match
./UnrealTournamentServer "DM-Outpost23?Game=DM?BotFill=6" -log -port=7777
```

### Ports to open (UDP)

| Port | Purpose |
|---|---|
| `7777` | game traffic |
| `7787` | query beacon — **required**, a hub with this closed is invisible in the browser |
| `8000`–`8150` | match instances a hub spawns (`StartingInstancePort` + `InstancePortStep` × `MaxInstances`) |

Port `14000` is the hub↔instance channel and stays on loopback — do **not** expose it.

If your server shares a host with the master server, it may register the wrong address
(a container bridge IP rather than its real one). Set the address it should advertise:

```ini
[OnlineSubsystemUT]
ServerAddressOverride=203.0.113.10
```

Or on the command line for an existing packaged build:

```
-ini:Engine:[OnlineSubsystemUT]:ServerAddressOverride=203.0.113.10
```

---

## Known issues

- **DM-Underland** crashes on load (`ULandscapeSplineSegment::Serialize`) and is excluded from all builds
- **Quick Play** is unavailable — it depends on Epic services that no longer exist
- **Remember-me / auto-login** is not implemented; you sign in each launch
- Player stats and MMR are unavailable (`McpUtils` is an Epic service)

---

## Credits

Unreal Tournament and Unreal Engine are trademarks of Epic Games, Inc. This is a
community port of Epic's open-sourced UT4 code, unaffiliated with and unendorsed by Epic.

Master server: [timiimit/UT4MasterServer](https://github.com/timiimit/UT4MasterServer).
