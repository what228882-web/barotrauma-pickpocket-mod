# Barotrauma Pickpocket Mod

A pickpocketing mod for Barotrauma.

A [Barotrauma](https://barotraumagame.com/) mod built on
[LuaForBarotrauma (LuaCs)](https://github.com/evilfactory/LuaCsForBarotrauma)
that adds a pickpocketing mechanic against outpost vendor NPCs.

## Installation

1. Make sure you have the LuaForBarotrauma (LuaCs) patch installed.
2. Copy the `barotrauma-pickpocket-mod` folder into your `LocalMods` folder
   (on Windows: `%LocalAppData%\Daedalic Entertainment GmbH\Barotrauma\LocalMods`).
3. Enable the "Pickpocket Mod" package in the game's Mods list - on the
   client and, for multiplayer, on the server as well (all the actual game
   logic is authoritative on the server side).

## How it works

- Walk up to an outpost vendor NPC (a character with `CampaignInteractionType
  == Store`) within `Pickpocket.INTERACT_RANGE` (200 units by default,
  configurable in `Lua/PickpocketShared.lua`).
- A `[G] Steal` prompt appears at the bottom of the screen.
- Pressing `G` opens a custom window listing that vendor's current stock,
  read directly from `Location.StoreInfo.Stock` - not the vanilla store
  screen.
- Clicking "Steal" on an item rolls a chance check. Success chances for
  consecutive attempts within one open session: 90% / 70% / 50% / 30% / 10% /
  5% / 2% / 1% (8th attempt onward stays at 1%).
- **Success**: the item is spawned into the player's inventory and the
  vendor's stock quantity drops by 1.
- **Failure**: every item stolen during this session vanishes from the
  player's inventory, the menu is force-closed, the vendor shouts a line,
  the outpost's reputation drops, and outpost security NPCs
  (`securityofficer`) get a combat objective targeting the player.
- The attempt counter (and the whole chance ladder) resets when the menu is
  closed (button, click-away, walking off), or when the outpost changes /
  a new leg of the journey starts.

## Project structure

```
barotrauma-pickpocket-mod/
  filelist.xml                    - content package manifest
  Lua/
    Autorun/PickpocketMod.lua     - entry point, loads the other modules
    PickpocketShared.lua          - constants, chances, shared checks
    PickpocketServer.lua          - authoritative server-side logic
    PickpocketClient.lua          - GUI, input, network requests
```

## Assumptions worth double-checking against your game version

The API calls here were cross-checked against the live LuaForBarotrauma
documentation and the Barotrauma source, but a few details are
version-specific:

- **`gameversion` in `filelist.xml`** is set to `1.9.5.0` - adjust it if the
  game refuses to load the package.
- **Security job identifier** - `securityofficer`
  (`Pickpocket.SECURITY_JOB_IDS` in `PickpocketShared.lua`). If your job list
  is modded, add the relevant identifiers to that array.
- **`ItemPrefab.Name`** is used as the item's display name in the list; swap
  it for whatever field/method fits your localization setup if needed.
- **Security aggro** is implemented via
  `character.AIController.AddCombatObjective(AIObjectiveCombat.CombatMode.Offensive, thief, 0)`
  - a real `HumanAIController` method from the game's source, not a made-up
  "alarm" call. There is no single built-in "sound the alarm for the whole
  outpost" API, so the mod explicitly loops over every security NPC and
  assigns each one a combat objective.
- The mod is designed primarily for a **dedicated/hosted server with real
  clients** (per the original request, that's the scenario the
  synchronization needed to handle). In singleplayer, Barotrauma runs a
  local server internally in the same process, so the networking code should
  work there too, but it hasn't been separately tested.

Before relying on it in a real game, do a quick sanity check: approach any
vendor, press G, steal a few items in a row until you get caught, and
confirm security and reputation react as expected.

## License

MIT
