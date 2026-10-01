# Speech Gates (OpenMW Lua)

While the dialogue window is open, a small panel lists responses that are tied to your **active quests** and gated by a skill, attribute, level or disposition requirement:

```
Requirements
Rumors
   Speechcraft 38 / 45        <- red: not met
   Disposition 60               <- red: not met
   Personality 55 / 62          <- Personality that would close the gap
```

Event-driven only: nothing runs per frame. Work happens when the dialogue window opens and after each dialogue response. The requirement index is built once, on your first dialogue after launch.

## Install
Copy the `SpeechGates` folder as a mod (MO2 mod, or add its folder as a `data=` path) and add `content=SpeechGates.omwscripts` to `openmw.cfg`. Targets OpenMW 0.52 master (Lua API revision 161).

## Settings
Edit the `CONFIG` table at the top of `scripts/SpeechGates/player.lua`:
- `requireEffect` (default on) - only list responses whose result script advances a quest, adds a topic or moves items; plain flavour lines that merely differ by disposition are skipped. Matching quests show an `Advances: <quest name>` line.
- `maxTopics` - most topics listed at once (the rest show as `+ N more`).
- `debug` - print each listed response and its result script to `openmw.log`.
- `showMetGates` - also list requirements you already meet.
- `unrevealedTopics` - undiscovered topics: `'obscure'` (default), `'hide'`, or `'show'`.
- `blurStyle` - how obscured topics look: `'smear'` (soft blurred scrambled text, default), `'bars'`, or `'text'` (`???`).
- Placement: `columnX`, `columnWidth`, `panelTop`, `columnBottom` (fractions of the screen) and `guiScale` (your `[GUI] scaling factor` from `settings.cfg`). Defaults put the panel in the empty part of the dialogue window's topic column, under "Goodbye", lined up with the column. Its own background (Interface Reimagined's fade box textures) covers the whole panel with a soft top edge that blends into the column above (`fullBackground = false` draws it only below `columnBottom`).
- Look: `edgeWidth` (left line thickness), `textInset`, `padY`.

## Known topics
OpenMW does not tell Lua which topics you know. A topic counts as discovered if it is in your journal topic list, or its name appeared in text you have seen: journal entries, reached quest stages, and NPC speech heard while the mod is active (remembered in your save). A topic you learned some other way can still be shown blurred; set `unrevealedTopics = 'show'` if that bothers you.

## Limits
- The vanilla topic list is native UI; the panel sits beside it rather than labelling topics inline.
- Only filter conditions are seen. Gates inside result scripts (`if player->GetSpeechcraft > 50`) are invisible.
- A response shows only when every Journal condition on it currently holds and one of those quests is active.
- Only "at least X" conditions are shown. Reputation gates and Admire/Intimidate/Bribe chances are not shown.
- Blur is faked with overlapping low-opacity scrambled text; OpenMW cannot shader a UI widget.
- Not yet tested in-engine; logic was checked against stubbed API modules only.
