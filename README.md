# Minecraft inside Counter-Strike: Source

Real **Minecraft: Java Edition** running next to **Counter-Strike: Source** and drawn *into* it. Build with Minecraft blocks on CS:S maps, blow things up with TNT and creepers, shoot a bow, swing a sword, fly with elytra-style flight, and fight CS:S bots – all on **your own local server**.

> ## ⚠️ Early build – it has bugs and rough edges
> This is a hobby experiment that we got working end to end and wanted to share. It is **playable, but buggy**: see [Known problems](#known-problems) below.
> It has only been tested on one Windows 11 laptop. Expect to hit things we haven't. Bug reports and pull requests are very welcome.

**Own server only.** The mod injects code into the CS:S client. The start scripts always launch CS:S with `-insecure` (VAC off). **Never join public or VAC-secured servers with this installed.** See [Safety](#safety).

---

## What works (more or less)

| | |
|---|---|
| 🧱 **Build** | Place and break Minecraft blocks in CS:S maps. Blocks block bullets and players. |
| 🗺️ **The CS:S map is the ground** | The plugin scans the real map around you and builds a hidden block copy of the floors and walls in Minecraft, so blocks, arrows, pearls and mobs land on real surfaces – on any level, not just one flat floor. |
| 💥 **TNT and creepers** | Minecraft explosions also hurt and throw CS:S players and bots. |
| 🗡️ **Sword, bow, crossbow, ender pearls** | Arrows are traced through the real CS:S map and players; sword swings hit what is in front of you; a landed pearl moves your CS:S player. |
| 🪽 **Flight** | Press **F10** for elytra-style flight (CS:S-side physics): look to steer, dive to speed up, right-click to boost, fly up through the sky roof. |
| 🧟 **Mobs vs bots** | Bots get invisible stand-ins in Minecraft so hostile mobs (creepers!) hunt them. *Largely untested.* |
| 🛡️ **Minecraft mode** | **F7** gives the mouse wheel, number keys and mouse buttons to Minecraft, puts your CS:S gun away and makes you invincible. |

## How it works (short version)

Two games run at once. Minecraft renders the world from **your CS:S camera**; that picture is laid on top of CS:S frame by frame. The CS:S map is invisible collision (and hides Minecraft blocks behind walls) inside Minecraft, and everything that happens in Minecraft is sent back as CS:S entities and damage. Details: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

---

## Requirements

- **Windows 10 or 11**, 64-bit
- **Counter-Strike: Source** from Steam, the current **64-bit** version (`cstrike_win64.exe` must exist in its folder)
- **Minecraft: Java Edition** – you must own it. The mod runs a Fabric developer client (offline account) in its own folder; it downloads Minecraft's game files from Mojang on first start. Your normal worlds and launcher are not touched.
- **Java (JDK) 25** – the installer offers to install it for you (Amazon Corretto via `winget`)
- A reasonably modern GPU. Minecraft and CS:S both render at once. (See the tip about the integrated GPU in [Known problems](#known-problems).)
- Internet for the first install (the installer downloads Metamod:Source, SourceMod and ReShade from their official pages and checks their SHA-256)

## Install (about 5 minutes)

1. Download **`css-minecraft-passthrough-*.zip`** from the [**Releases**](../../releases) page and **unzip it** somewhere (for example `C:\css-minecraft`).
2. **Close CS:S** if it is running.
3. Right-click **`install.ps1`** → **Run with PowerShell**. (If Windows blocks it: open PowerShell in that folder and run `powershell -ExecutionPolicy Bypass -File .\install.ps1`.)
4. Answer the questions (`y`). When it says *Done*, you're set.

The installer backs up every file it replaces and writes a list of everything it adds. To remove it all again, run **`uninstall.ps1`**.

> Only have the source code (git clone)? Then there is no `bin\` folder yet: run `powershell -ExecutionPolicy Bypass -File .\build.ps1` first (needs Visual Studio with *Desktop development with C++*, Git and JDK 25), or download the release zip instead.

## Play

1. Double-click **`START-EVERYTHING.bat`**. It starts Minecraft (the first time it downloads files and takes several minutes), waits until it is ready, then starts CS:S in insecure mode.
2. In CS:S open the console with the **`~`** key and type:
   ```
   map de_dust2
   bot_add
   bot_add
   ```
   (Metamod only switches on after a map change, so the `map` command matters.)
3. Wait about **10 seconds** – the plugin is scanning the map and building its hidden copy in Minecraft.
4. Press **F7** for Minecraft mode, **F10** to fly. Have fun!

Leave the Minecraft window open (don't minimize it); it can sit behind CS:S.

### Controls

| Key | What it does |
|---|---|
| **F7** | Minecraft mode on/off. While on: your CS:S gun is hidden, you take no damage, and the keys below go to Minecraft |
| Mouse wheel, **1–9** | Minecraft hotbar |
| Left / right / middle click | Break or attack / place or use / pick block |
| **Q**, **E**, **F** | Drop item / Minecraft inventory / swap hands |
| **~** or **Esc** | Leave Minecraft mode (so the console and menus work) |
| **F10** | Take off / stop flying (works any time). Look to steer, **dive** to gain speed, **climb** to lose it, **right-click** for a firework boost. Landing ends it |

Hotbar: `1` ender pearls · `2` diamond sword · `3` crossbow · `4` bow · `5` TNT · `6` flint and steel · `7` creeper eggs · `8` grass blocks · `9` fireworks.

Console commands: `mc_test` (builds a small test tower), `mc_level` (re-level and re-scan the map), `mc_mode` (same as F7), `mc_debug 0|1` (logging to the SourceMod log), `bot_add` (CS:S's own command).

---

## Known problems

Please read this before filing a bug – a lot of this is already known.

- **A little laggy.** Placing and seeing blocks has some delay (the picture goes through two games and shared memory). If Minecraft runs on your integrated GPU while CS:S uses the dedicated one, it is much worse: in Windows *Settings → System → Display → Graphics*, add Java's `java.exe` and set it to **High performance**.
- **Blocky world.** CS:S's map is approximated with 1-metre blocks (1 block = 40 CS:S units). Blocks can float or sink up to **half a block** relative to the real floor, and walls only hide Minecraft blocks approximately (blocky edges, slopes and diagonals aren't exact).
- **Combat is lightly tested.** Arrows, sword, TNT and creeper damage reach CS:S, but the numbers were tuned blind and kills are not 100% reliable. Creepers hunting bots is largely untested.
- **Flight is rough.** It is simulated on the CS:S side; there is no elytra model and it can feel floaty or stick on geometry.
- **Single local player.** Friends joining your server is **untested** – they won't see the Minecraft picture unless they also install it, and the invisible collision boxes will still be there for them.
- **Builds are not saved.** Minecraft's scratch world starts fresh on every launch on purpose (stale ground blocks from an old session break things).
- **At most ~600 collision boxes.** Very large builds beyond that stop blocking bullets and players (they still exist in Minecraft).
- **The map is re-scanned on every spawn**, which takes a few seconds.
- **Fragile versions.** It needs exactly: Metamod:Source **1.12**, SourceMod **1.13.0.7477**, ReShade **6.8.0**, Minecraft **26.3**. A Valve or Mojang update can break it. (The newest Metamod 2.0 does **not** work with SourceMod on 64-bit CS:S.)
- **Windows only**, 64-bit CS:S only, tested on Windows 11 with an NVIDIA RTX 4060 laptop.

Found something new? [Open an issue](../../issues) and attach `cstrike\console.log` and `cstrike\addons\sourcemod\logs\*.log` (check them for personal info first).

## Safety

- It loads a **ReShade add-on and a SourceMod extension into the CS:S client**. VAC would flag this on a protected server, so **the start scripts always use `-insecure`** and you must never join public/VAC servers while it is installed. If in doubt, run `uninstall.ps1`.
- The Minecraft link listens on `127.0.0.1:25599` only (this computer), without a password, so any program on your PC could send it commands. Close Minecraft when you're done.
- Nothing here changes Minecraft's or CS:S's own game files except as listed in the manifest the installer writes. Everything it adds is backed up/removable.

## Build from source

```
powershell -ExecutionPolicy Bypass -File .\build.ps1     # extension, ReShade add-on, plugin, mod jar -> bin\
powershell -ExecutionPolicy Bypass -File .\install.ps1   # installs from bin\
```

Layout: [`mc/`](mc) Fabric mod (Java) · [`ext/`](ext) SourceMod extension (C++) · [`addon/`](addon) ReShade add-on + shader · [`plugin/`](plugin) SourceMod plugin (SourcePawn) · [`tools/`](tools) small diagnostic scripts · [`docs/`](docs).

## Credits and licenses

- The Minecraft side is adapted from the **Minecraft × GTA V passthrough example** of [universal-modder](https://github.com/rehan-remade/universal-modder) by Rehan and contributors (MIT). Its idea, protocol and most of the Fabric mod come from there.
- [Metamod:Source](https://www.sourcemm.net/) and [SourceMod](https://www.sourcemod.net/) by AlliedModders (GPL v3, downloaded by the installer); [ReShade](https://reshade.me) by crosire (BSD-3, downloaded by the installer); [Fabric](https://fabricmc.net); [Java-WebSocket](https://github.com/TooTallNate/Java-WebSocket).
- Full details in [NOTICE.md](NOTICE.md). Our own code is MIT, except [`ext/`](ext) and [`plugin/`](plugin) which are GPL v3 (they build on SourceMod's SDK).
- **Built with Claude Code** (AI-assisted) – debugging, design and most of the code were written together with an AI assistant, so treat it accordingly.
- Counter-Strike: Source belongs to Valve; Minecraft belongs to Mojang Studios and Microsoft. This is an unofficial fan project and is not affiliated with or endorsed by Valve, Mojang or Microsoft. No game files are included.
