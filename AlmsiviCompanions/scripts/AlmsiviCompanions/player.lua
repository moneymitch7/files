-- Watches the player's active spells. When the shrine spell appears, tell nearby actors;
-- the ones that are following the player apply the same spell to themselves (actor.lua).
local self = require('openmw.self')
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local types = require('openmw.types')

local CONFIG = {
    -- Exact spell record ids (lowercase) to share. Add the shrine spell's id here if the name match misses it.
    spellIds = {},
    -- Case-insensitive substrings of the spell *name* to share.
    namePatterns = { 'almsivi restoration' },
    -- Only share with followers within this many units of the player.
    radius = 3000,
    -- Seconds between checks.
    interval = 0.5,
    -- Log every new active spell on the player to openmw.log (use it to find the shrine spell's id).
    debug = false,
}

local wantedIds = {}
for _, id in ipairs(CONFIG.spellIds) do wantedIds[id:lower()] = true end

local seen = {}   -- activeSpellId -> true, so each cast is shared once
local timer = 0

local function matches(spellId)
    spellId = spellId:lower()
    if wantedIds[spellId] then return true end
    local rec = core.magic.spells.records[spellId]
    local name = rec and rec.name and rec.name:lower()
    if not name then return false end
    for _, pat in ipairs(CONFIG.namePatterns) do
        if name:find(pat:lower(), 1, true) then return true end
    end
    return false
end

local function share(spellId)
    local rec = core.magic.spells.records[spellId]
    local effects = {}
    if rec then for i = 1, #rec.effects do effects[i] = i - 1 end end   -- 0-based effect indexes
    local pos = self.position
    for _, actor in ipairs(nearby.actors) do
        if actor ~= self.object and (actor.position - pos):length() <= CONFIG.radius then
            actor:sendEvent('AlmsiviCompanions_Share', { spellId = spellId, effects = effects, caster = self.object })
        end
    end
end

local function scan()
    local current = {}
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        current[spell.activeSpellId] = true
        if not seen[spell.activeSpellId] then
            seen[spell.activeSpellId] = true
            if CONFIG.debug then print('[AlmsiviCompanions] new active spell: ' .. tostring(spell.id)) end
            if matches(spell.id) then share(spell.id) end
        end
    end
    seen = current   -- forget expired spells so a later cast counts as new
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            timer = timer + dt
            if timer < CONFIG.interval then return end
            timer = 0
            scan()
        end,
    },
}
