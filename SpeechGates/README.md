# Speech Gates (OpenMW Lua)

While the dialogue window is open, a small panel lists responses that are tied to your **active quests** and gated by a skill, attribute, level or disposition requirement:

```
Requirements
Rumors
   Speechcraft 38 / 45        <- red: not met
   Disposition 60               <- green: met
```

Event-driven only: nothing runs per frame. Work happens when the dialogue window opens and after each dialogue response. The requirement index is built once, on your first dialogue after launch.

## Install
Copy the `SpeechGates` folder as a mod (MO2 mod, or add its folder as a `data=` path) and add `content=SpeechGates.omwscripts` to `openmw.cfg`. Targets OpenMW 0.52 master (Lua API revision 161).

## Settings
Edit the `CONFIG` table at the top of `scripts/SpeechGates/player.lua`:
- `showMetGates` - also list requirements you already meet.
- `unrevealedTopics` - topics not yet in your journal topic list: `'obscure'` (default; smudge bars, or grey `???` with `blurStyle = 'text'`), `'hide'`, or `'show'`.
- `blurStyle` / `smudgeFixedWidth` - look of obscured topics.
- `position` / `anchor` - screen placement (fractions of the screen).

## Limits
- The vanilla topic list is native UI; the panel sits beside it rather than labelling topics inline.
- Only filter conditions are seen. Gates inside result scripts (`if player->GetSpeechcraft > 50`) are invisible.
- A response shows only when every Journal condition on it currently holds and one of those quests is active.
- Only "at least X" conditions are shown. Reputation gates and Admire/Intimidate/Bribe chances are not shown.
- Not yet tested in-engine; logic was checked against stubbed API modules only.
