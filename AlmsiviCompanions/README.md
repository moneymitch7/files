# Almsivi Companions (OpenMW Lua)

When you receive the shrine's **Almsivi Restoration** blessing, your followers (NPCs or creatures with a Follow/Escort package targeting you) get the same spell applied.

## Install
Add this folder as a `data=` path and `content=AlmsiviCompanions.omwscripts` to `openmw.cfg`. Needs OpenMW 0.49+ (active spell `add` from Lua).

## How it works
`player.lua` checks your active spells every 0.5s. When a new one matches (by spell id or name), it sends an event to nearby actors; `actor.lua` on each follower applies the spell to itself.

## Settings
`CONFIG` at the top of `scripts/AlmsiviCompanions/player.lua`: `spellIds`, `namePatterns`, `radius`, `interval`, `debug`.

## Not tested in-engine
- If the restoration is instant (restore health/fatigue/magicka with no duration), it may never show up as an active spell and would not be detected. Turn on `debug`, visit a shrine, and check `openmw.log`; if nothing is listed, the detection needs to hook the shrine activation instead.
- If the blessing is not named "Almsivi Restoration", put its record id in `spellIds`.
