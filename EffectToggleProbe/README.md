# Effect Toggle Probe (OpenMW Lua)

A **throwaway diagnostic**, not the final mod. It exists to settle the open questions behind a future mod that lets you switch constant visual effects (chameleon, invisibility, light, the detects, night eye, water walking/breathing) on and off with a key, from gear, race and birthsign sources.

It does nothing until you press a key, and it never touches your spellbook. Everything it learns goes to `openmw.log`, on lines starting with `[EffectToggleProbe]`.

## Install
Copy the `EffectToggleProbe` folder as a mod (MO2 mod, or add its folder as a `data=` path) and add `content=EffectToggleProbe.omwscripts` to `openmw.cfg`. Targets OpenMW 0.52 master (Lua API revision 161). Not yet tested in-engine; logic was checked against stubbed API modules only. Every engine call is wrapped so a wrong guess shows up as an `ERR` line in the log rather than a crash.

## Use a throwaway save
Tests A and C remove things from your live magic state, and a save made while a test is active can keep the change. Use a save you do not mind losing, do not save during a test, and reload that save between tests.

Do not have a potion or temporary spell running while you test B and C: they act on the total magnitude of an effect, so they would cancel the potion's share too.

## Keys
Defaults below. If your keyboard lacks Home/End/PageUp/PageDown, rebind in-game under **Options > Scripts > Effect Toggle Probe** (or edit `CONFIG.keys` at the top of `player.lua`). Keys are ignored while any menu or the console is open.

| Key | Test |
|---|---|
| Insert | **Dump** what Lua sees: active spells, magnitudes, spellbook, birthsign and race |
| Home | **A** - remove the whole active spell that carries a target effect |
| End | **B** - cancel each target effect with a negative modifier |
| Page Up | **C** - remove each target effect from your active effects |
| Page Down | **Restore** the last of A, B or C |
| Delete | **Flourish**, attached to you: an "enable" visual and sound, then a "disable" one 2.5 s later |
| F6 | **Flourish**, spawned in the world at your position (uses the global script, scaled down) |
| F7 | **HUD icons**: the effect icons with a red cross and a pulse for a few seconds |

A small message confirms each key press registered.

## What to do
1. Load the throwaway save with a constant effect active. Do the whole routine once per source you have: **gear** (an item with chameleon, light, etc.), **birthsign** (your replacer's chameleon), and **race** if yours has one (Argonians have water breathing).
2. **Insert**, to see the baseline.
3. Press one of **Home / End / Page Up**. Look at the character (third person), the effects list in the Magic window, and the HUD icon. Wait about 30 seconds; the state is logged at 0, 1, 5, 15 and 30 seconds by itself.
4. Walk through a door into another cell, then **Insert** again. Then unequip and re-equip the item (gear), **Insert** again. This shows whether the engine puts the effect back.
5. **Page Down** to restore, then **Insert**. If anything is still wrong, reload the save.
6. Reload, then repeat from step 2 with the next of A, B and C.
7. Separately try **Delete**, **F6** and **F7** once or twice, in first and third person, and note what you saw and heard.
8. Quit the game and send me `openmw.log` **before relaunching** (OpenMW overwrites it each launch): `Documents\My Games\OpenMW\openmw.log` on Windows, `~/.config/openmw/openmw.log` on Linux. Add short notes: which tests you ran on which source, and what you saw on screen.

## What the log will tell me
- Whether each source appears as an active spell, and which flags it carries (gear vs ability, race vs birthsign).
- Whether a spell bundles chameleon with other effects, which would make test A too blunt.
- Which of A, B, C actually switches the effect off, in the effects list and on the character.
- Whether the engine restores the effect by itself (after a cell change, a re-equip, or just time).
- Whether the attached and world-spawned visuals and sounds play, and which one is better.
- Whether the settings page and rebindable keys work, and whether the HUD icon, cross and pulse can be drawn.
