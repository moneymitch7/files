-- Attached on demand by global.lua. On its first update it applies the shared spell to itself,
-- but only if it is currently following the player, then asks to be removed.
local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local job

local function isFollowingPlayer(player)
    local pkg = I.AI.getActivePackage()
    return pkg ~= nil and (pkg.type == 'Follow' or pkg.type == 'Escort') and pkg.target == player
end

local function run()
    local data = job
    job = nil
    if not types.Actor.isDead(self) and isFollowingPlayer(data.caster) then
        types.Actor.activeSpells(self):add({
            id = data.spellId,
            effects = data.effects,
            caster = data.caster,
            stackable = false,
        })
    end
    core.sendGlobalEvent('AlmsiviCompanions_Done', self.object)
end

return {
    engineHandlers = {
        onInit = function(data) job = data end,
        onUpdate = function() if job then run() end end,
        onSave = function() return job end,
        onLoad = function(data) job = data end,
    },
}
