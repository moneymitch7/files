-- Effect Toggle Probe (global script)
--
-- Only used by the "world spawn" flourish test: the player script asks for a
-- visual effect to be spawned at a position, optionally scaled.

local world = require('openmw.world')

local TAG = '[EffectToggleProbe]'

local function onSpawn(e)
    local options = {}
    if e.scale then options.scale = e.scale end
    local ok, err = pcall(function()
        world.vfx.spawn(e.model, e.position, options)
    end)
    print(TAG .. ' global spawn ' .. tostring(e.model) .. ' scale=' .. tostring(e.scale) .. ' -> '
        .. (ok and 'ok' or ('ERR ' .. tostring(err))))
end

return {
    eventHandlers = { ETP_Spawn = onSpawn },
}
