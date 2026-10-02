-- Attaches actor.lua to the actors the player script names, and detaches it once it has run.
local world = require('openmw.world')

local SCRIPT = 'scripts/AlmsiviCompanions/actor.lua'
local TIMEOUT = 5   -- seconds before a script that never reported back is detached anyway

local pending = {}  -- actor -> seconds since it was given the script

local function detach(actor)
    pending[actor] = nil
    if actor:isValid() and actor:hasScript(SCRIPT) then actor:removeScript(SCRIPT) end
end

return {
    engineHandlers = {
        onUpdate = function(dt)
            for actor, age in pairs(pending) do
                age = age + dt
                if age >= TIMEOUT or not actor:isValid() then detach(actor) else pending[actor] = age end
            end
        end,
        onSave = function()
            local list = {}
            for actor in pairs(pending) do list[#list + 1] = actor end
            return { pending = list }
        end,
        onLoad = function(data)
            pending = {}
            for _, actor in ipairs(data and data.pending or {}) do pending[actor] = 0 end
        end,
    },
    eventHandlers = {
        AlmsiviCompanions_Share = function(data)
            for _, actor in ipairs(data.actors) do
                if actor:isValid() and not actor:hasScript(SCRIPT) then
                    actor:addScript(SCRIPT, { spellId = data.spellId, effects = data.effects, caster = data.caster })
                    pending[actor] = 0
                end
            end
        end,
        AlmsiviCompanions_Done = detach,
    },
}
