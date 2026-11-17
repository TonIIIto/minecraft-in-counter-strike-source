# Dev log (condensed)

What was tried, in order, and what it taught us. Dates 2026-10.

## Setup
- Windows 11, Visual Studio 2026 Community + C++ workload, Git, JDK 25 (Corretto), CS:S (64-bit, build 25338318), Minecraft Java 26.3 + Fabric 0.19.5.
- No WSL needed (Git Bash/PowerShell instead of the example's bash scripts).

## Step 0 – can SourceMod run on 64-bit CS:S?
- Metamod 2.0.0.1473 + SourceMod 1.13.0.7477: `[META] Failed to load plugin … Function CreateInterface not found`.
- Metamod **1.12.0.1227** + SourceMod 1.13.0.7477: `Loaded 1 plugin`. Works on dedicated and listen servers, with `-insecure`.

## Step 1 – the link and the picture
- ReShade 6.8.0 loads in 64-bit CS:S as `d3d9.dll`. Spike add-on: CS:S's main depth buffer is a non-readable `D24S8`; only a 1024×1024 shadow buffer is visible. → GTA-style depth compositing impossible; use occluder blocks + chroma key instead.
- First visible result: stone/gold/wool test tower fixed in the dust2 map.
- "Blocks swim when you move": the camera we sent was the server's (66 Hz, a tick old). Fix: read `WorldToViewMatrix` from `VEngineClient014` (vtable 37) every frame and re-project with Minecraft's depth; verified against the server camera (within 0.01–0.07 blocks).

## Input
- Wheel / number keys / F7 work through a `WH_GETMESSAGE` hook; mouse clicks don't (raw input) → poll `GetAsyncKeyState`.
- Minecraft mode hides the viewmodel (`EF_NODRAW`), delays weapons' next attack, strips attack buttons, and makes the player invincible.

## The map as ground
- First version: a flat plane of barrier blocks at the player's floor → couldn't place blocks on other levels; arrows/pearls flew through the map.
- Now: hull-trace voxelization of the real map (41×41×19 cells, 1500 tests per frame), shell → `magenta_concrete`, keyed out in the shader.
- Bug: enclosed rooms → pitch-black shell and blocks (no skylight). Fix: dimension type with `ambient_light: 1`.
- Bug: leftover barrier blocks from the first version were saved in the scratch world and became 600 phantom collision boxes. Fix: fresh world on every launch; ignore barriers.

## Combat and flight
- Arrows traced through the CS:S map (`proj`/`projhit`), sword (`melee`), explosions, mob stand-ins for bots (`peds`/`mobhit`), pearls (`pteleport`).
- Elytra: Minecraft's physics (drive mode) kept ending immediately → rewritten as CS:S-side flight on F10, with sky-roof pass-through.
- Damage values were raised to 70 per arrow and 45 per sword hit; a kill-the-other-team report is still being investigated.

## Packaging
- `build.ps1`, `install.ps1` (checksummed downloads, backups, manifest), `uninstall.ps1`, launcher scripts.
- Bugs found only by testing the installer: git progress text on stderr treated as failure; reinstall backed up our own files as "originals".
