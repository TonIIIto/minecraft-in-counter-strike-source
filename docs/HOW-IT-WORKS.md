# How it works

```
Counter-Strike: Source (64-bit, -insecure)                         Minecraft 26.3 + Fabric (mc/, own game folder)
┌───────────────────────────────────────────────┐                  ┌───────────────────────────────────────┐
│ SourceMod plugin  (plugin/  mcbridge.sp)      │                  │ Passthrough mod (adapted from the     │
│   camera, map scan, stand-ins, damage, flight │                  │ universal-modder GTA V example)       │
│        │ natives                              │                  │                                       │
│ SourceMod extension (ext/  mcbridge.ext.dll)  │  WebSocket       │  HostLink  127.0.0.1:25599            │
│   WinHTTP WebSocket client ───────────────────┼─────────────────►│  camera, ground, commands, input      │
│   keyboard hook (F7/F10), mouse polling       │◄─────────────────┼─  blocks, projectiles, explosions...  │
│        │ shared memory "Local\MCCssPose"       │                  │                                       │
│ ReShade add-on (addon/  MCCss.addon64 + .fx)  │  shared memory   │  FrameExporter                        │
│   draws Minecraft's picture over CS:S  ◄──────┼──────────────────┼─  "Local\MCPassthroughFrame"          │
└───────────────────────────────────────────────┘  (colour, depth, └───────────────────────────────────────┘
                                                    hand/HUD)
```

1. **Camera.** Every server frame the plugin reads your eye position and angles and the extension sends them to Minecraft (converted: 40 CS:S units = 1 block, `x, z-up, y` → `x, y-up, -z`). Minecraft renders from that exact camera.
2. **Picture.** Minecraft writes its colour, depth and HUD layers into a shared-memory ring. The ReShade add-on (running inside the CS:S process) uploads the newest frame and the effect `MCCss.fx` composites it over CS:S. Because Minecraft's frame is a few milliseconds old, the effect **re-projects** it to the camera CS:S actually rendered with (rotation *and* movement, using Minecraft's depth), so blocks stay glued to the world.
3. **Exact camera.** The add-on reads the *real* per-frame camera from the engine's `VEngineClient014` interface: `WorldToViewMatrix()` and `WorldToScreenMatrix()` (vtable indexes **37** and **36** in the 64-bit CS:S build). The server-side camera the plugin knows is a tick old and made blocks "swim".
4. **The map as ground.** The plugin voxelizes CS:S's brushes around you with `TR_TraceHullFilter` (a small hull per 1-metre cell, in time slices), takes the *shell* of solid cells, and asks Minecraft to place `magenta_concrete` there. That gives Minecraft real collision for blocks, mobs, arrows and pearls, **and** a depth buffer entry that hides Minecraft blocks behind walls. The shader then makes magenta transparent (a chroma key), so the shell is invisible. Minecraft's world is fully bright (the mod overrides the overworld dimension type with `ambient_light: 1`), otherwise the shell is black inside enclosed rooms.
5. **Blocks → CS:S.** Every solid Minecraft block becomes an invisible solid box entity in CS:S (`prop_dynamic_override`, `SOLID_BBOX`, capped at 600) so bullets and players stop at it.
6. **Weapons.** Arrows in flight are reported by Minecraft each tick; the plugin traces their path through the CS:S map and players and answers with `projhit`. Sword swings, explosions (TNT, creepers) and mob hits arrive as events and become `SDKHooks_TakeDamage` plus knockback. Bots get invisible villager stand-ins in Minecraft so hostile mobs hunt them.
7. **Input.** CS:S reads the mouse with raw input, so window-message hooks never see clicks: while Minecraft mode is on, the extension polls the mouse buttons with `GetAsyncKeyState` and hooks the keyboard/wheel with a `WH_GETMESSAGE` hook. F7/F10 are function keys so they never type into the console.
8. **Flight.** Done entirely on the CS:S side (`MOVETYPE_FLY` plus velocity steering each frame; passes through the sky roof by switching to noclip). Minecraft's own elytra physics fought the CS:S player and was dropped.

## Things we learned (so you don't have to)

- **CS:S's depth buffer can't be read.** The 64-bit CS:S uses Direct3D 9 with a plain `D24S8` depth surface created at device creation, which ReShade cannot sample. The GTA V original composites against the game's depth; here that is impossible, which is why the map is mirrored into Minecraft as occluder blocks instead.
- **Metamod 2.0 + SourceMod 1.13 do not work together on 64-bit CS:S.** Metamod 2.0 looks for an export named `CreateInterface` in plugins; SourceMod's x64 loader only exports `CreateInterface_MMS`. Use **Metamod 1.12**, and point `addons/metamod/sourcemod.vdf` at `sourcemod_mm.x64.dll`.
- **Metamod only activates after a map change** after the game starts.
- **Minecraft's new launcher ignores custom profiles** (Microsoft Store build) and rewrites `launcher_profiles.json`, so the mod runs as a Fabric developer client (`gradlew runClient`) instead.
- **Minecraft 26.3 changed blocks to collections**: `Blocks.CONCRETE.magenta()`, not `Blocks.MAGENTA_CONCRETE`.
- Stale blocks from an old session (the ground is saved in the world as blocks) caused phantom collision, so the scratch world is recreated at every launch.
- Writing Java files from Windows PowerShell with `-Encoding utf8` adds a BOM that breaks `javac`.

## Wire protocol (short)

JSON text frames over `ws://127.0.0.1:25599`.

Plugin → Minecraft: `cam` (position, rotation, fov, feet), `ground` (`[x,z,yBottom,yTop,…]` columns), `clear`, `cmd` (server command), `key` / `slot` / `scroll` (input), `view` (window size), `blocksync`, `projhit`, `peds` (bot stand-ins).
Minecraft → plugin: `blocks` (`set`/`clear` lists), `proj` (arrows/fireworks in flight), `explosion`, `melee`, `mobhit`, `pteleport` (ender pearl landed).
Shared memory `Local\MCPassthroughFrame`: header, three slots of (colour RGBA8, depth R32F, overlay RGBA8); layout documented in `mc/src/client/java/dev/rehan/passthrough/client/FrameExporter.java`.
Shared memory `Local\MCCssPose`: the plugin's camera, the grid height offset, CS:S's picture size and the Minecraft-mode flag (`ext/extension.cpp`, `addon/mccss_addon.cpp`).

## Ideas for improvement

- Draw the exact map geometry (parse the BSP) into the occluder instead of 1-metre blocks.
- Merge collision boxes (greedy meshing) to lift the 600-box cap.
- Real multiplayer: send blocks to other clients, show the Minecraft picture for each.
- Lower latency: smaller exported frames (16-bit depth), skip layers that aren't needed.
- A proper Minecraft launcher profile instead of the developer client.
