-- Watches the player's active spells. When the shrine spell appears, hand the nearby actors to
-- global.lua, which attaches actor.lua to them just long enough to apply the spell to followers.
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

local radiusSq = CONFIG.radius * CONFIG.radius
local patterns = {}
for i, pat in ipairs(CONFIG.namePatterns) do patterns[i] = pat:lower() end

-- Spell ids to share, resolved once instead of string-matching names on every poll.
local wantedIds = {}
local function buildWantedIds()
    wantedIds = {}
    for _, id in ipairs(CONFIG.spellIds) do wantedIds[id:lower()] = true end
    for _, rec in ipairs(core.magic.spells.records) do
        local name = rec.name and rec.name:lower()
        if name then
            for _, pat in ipairs(patterns) do
                if name:find(pat, 1, true) then
                    wantedIds[rec.id:lower()] = true
                    break
                end
            end
        end
    end
end

local seen = {}   -- activeSpellId -> scan generation it was last present in, so each cast is shared once
local generation = 0
local timer = 0

local function share(spellId)
    local rec = core.magic.spells.records[spellId]
    local effects = {}
    if rec then for i = 1, #rec.effects do effects[i] = i - 1 end end   -- 0-based effect indexes
    local pos = self.position
    local px, py, pz = pos.x, pos.y, pos.z
    local actors = {}
    for _, actor in ipairs(nearby.actors) do
        if actor ~= self.object then
            local p = actor.position
            local dx, dy, dz = p.x - px, p.y - py, p.z - pz
            if dx * dx + dy * dy + dz * dz <= radiusSq then actors[#actors + 1] = actor end
        end
    end
    if #actors > 0 then
        core.sendGlobalEvent('AlmsiviCompanions_Share',
            { spellId = spellId, effects = effects, caster = self.object, actors = actors })
    end
end

local function scan()
    generation = generation + 1
    for _, spell in pairs(types.Actor.activeSpells(self)) do
        local key = spell.activeSpellId
        if seen[key] == nil then
            if CONFIG.debug then print('[AlmsiviCompanions] new active spell: ' .. tostring(spell.id)) end
            local id = spell.id:lower()
            if wantedIds[id] then share(id) end
        end
        seen[key] = generation
    end
    for key, gen in pairs(seen) do   -- forget expired spells so a later cast counts as new
        if gen ~= generation then seen[key] = nil end
    end
end

return {
    engineHandlers = {
        onInit = buildWantedIds,
        onLoad = buildWantedIds,
        onUpdate = function(dt)
            timer = timer + dt
            if timer < CONFIG.interval then return end
            timer = 0
            scan()
        end,
    },
}
