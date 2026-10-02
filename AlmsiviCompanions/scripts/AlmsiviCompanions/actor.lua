-- Runs on every NPC/creature. On request from the player script, applies the shared spell
-- to itself, but only if it is currently following the player.
local self = require('openmw.self')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local function isFollowingPlayer(player)
    local pkg = I.AI.getActivePackage()
    return pkg ~= nil and (pkg.type == 'Follow' or pkg.type == 'Escort') and pkg.target == player
end

return {
    eventHandlers = {
        AlmsiviCompanions_Share = function(data)
            if types.Actor.isDead(self) or not isFollowingPlayer(data.caster) then return end
            types.Actor.activeSpells(self):add({
                id = data.spellId,
                effects = data.effects,
                caster = data.caster,
                stackable = false,
            })
        end,
    },
}
