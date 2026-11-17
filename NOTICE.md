# Third-party software and notices

This project does not contain any Counter-Strike: Source or Minecraft game files, and it does not redistribute Metamod:Source,
SourceMod or ReShade: the installer downloads those from their official pages and verifies their SHA-256 checksums.

| Component | Who | License | How it is used |
|---|---|---|---|
| Minecraft × GTA V passthrough example (`examples/minecraft-gta5-passthrough`) | Rehan and [universal-modder](https://github.com/rehan-remade/universal-modder) contributors | MIT (text in `mc/LICENSE-universal-modder-MIT.txt`) | The Fabric mod in `mc/` is adapted from it: the protocol, frame export, camera sync, mob/explosion bridge and most Java code. |
| Metamod:Source 1.12 | AlliedModders | GPL v3 | Downloaded by `install.ps1` into your game folder |
| SourceMod 1.13 | AlliedModders | GPL v3 (with exceptions) | Downloaded by `install.ps1`; its SDK headers are used to build `ext/`; its `spcomp64` compiles `plugin/` |
| ReShade 6.8.0 (add-on build) and `ReShade.fxh` / `ReShadeUI.fxh` | crosire / Patrick Mours | BSD-3-Clause | Downloaded by `install.ps1`; its add-on headers are used to build `addon/` |
| Fabric Loader, Fabric API, Loom | FabricMC | Apache-2.0 | Pulled by Gradle when building/running the mod |
| Java-WebSocket | TooTallNate | MIT | Pulled by Gradle (bundled into the mod for the link) |
| `mc/src/main/resources/data/minecraft/dimension_type/overworld.json` | Mojang Studios | Minecraft data | A copy of Minecraft's own overworld dimension definition with *ambient light* set to maximum (so Minecraft blocks are fully lit inside CS:S's enclosed rooms). Used under the [Minecraft Usage Guidelines](https://www.minecraft.net/en-us/usage-guidelines). |

## Our own code

- `mc/` (changes to the example), `addon/`, `build.ps1`, `install.ps1`, `uninstall.ps1`, `*.bat`, `tools/`, `docs/`: MIT, see `LICENSE`.
- `ext/` and `plugin/`: **GPL v3** (they are built on SourceMod's SDK / include files). Text in `ext/LICENSE-GPL-3.0.txt`.

## Trademarks

Counter-Strike and Source are trademarks of Valve Corporation. Minecraft is a trademark of Mojang Synergies AB / Microsoft.
This is an unofficial fan project, not affiliated with or endorsed by Valve, Mojang or Microsoft. You need to own both games.

## AI assistance

This project was developed together with an AI coding assistant (Claude Code). Review the code before trusting it with anything you care about.
