-- Effect Toggle Probe (player script)
--
-- A throwaway diagnostic for a future "toggle constant effects" mod. It changes
-- nothing by itself: every test runs only when you press its key, and every
-- result goes to openmw.log on lines starting with [EffectToggleProbe].
--
-- It answers four questions about your game:
--   1. What do your constant effects look like to Lua (gear, race, birthsign)?
--   2. Which way of switching one off works, and does the engine put it back?
--   3. Can a visual and a sound be played on the player (the "flourish")?
--   4. Does the in-game settings page (rebindable keys) work?
--
-- Every engine call is wrapped in pcall, so a wrong guess about the API shows up
-- as an "ERR ..." line in the log instead of breaking the script.

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local async = require('openmw.async')
local input = require('openmw.input')
local I = require('openmw.interfaces')

local function tryRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    print('[EffectToggleProbe] module ' .. name .. ' not available: ' .. tostring(mod))
    return nil
end
local ambient = tryRequire('openmw.ambient')
local anim = tryRequire('openmw.animation')

local TAG = '[EffectToggleProbe]'

local CONFIG = {
    -- Default keys (names from openmw.input KEY). Rebind them in-game under
    -- Options > Scripts > Effect Toggle Probe, or change them here.
    keys = {
        dump = 'Insert',
        methodA = 'Home',
        methodB = 'End',
        methodC = 'PageUp',
        restore = 'PageDown',
        flourishLocal = 'Delete',
        flourishWorld = 'F6',
        icons = 'F7',
    },
    volume = 0.6,           -- flourish sound volume
    worldScale = 0.5,       -- scale used by the world-spawn flourish
    followUps = { 0, 1, 5, 15, 30 }, -- seconds after a test at which the state is logged
    iconSeconds = 4,        -- how long the icon test stays on screen
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function s(v)
    if v == nil then return 'nil' end
    local ok, r = pcall(tostring, v)
    return ok and r or '<unprintable>'
end

local function log(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = s((select(i, ...))) end
    print(TAG .. ' ' .. table.concat(parts, ' '))
end

local function toast(msg)
    pcall(ui.showMessage, msg)
end

-- obj[name] without ever throwing.
local function get(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

-- pcall wrapper that logs failures and returns the first result only.
local function try(fn, ...)
    if fn == nil then
        log('ERR function is missing in this build')
        return nil
    end
    local ok, r = pcall(fn, ...)
    if ok then return r end
    log('ERR', r)
    return nil
end

local function each(t, fn)
    if t == nil then return end
    local ok, err = pcall(function()
        for k, v in pairs(t) do fn(v, k) end
    end)
    if not ok then log('ERR iterating:', err) end
end

local function concat(t)
    if #t == 0 then return '-' end
    return table.concat(t, ',')
end

local actor = self.object or self

-- Run fn(delay) now (delay 0) and after each delay in `delays` (seconds of game time).
local function after(delays, fn)
    for _, d in ipairs(delays) do
        if d == 0 then
            local ok, err = pcall(fn, d)
            if not ok then log('ERR follow-up', err) end
        else
            local ok, err = pcall(function()
                async:newUnsavableSimulationTimer(d, async:callback(function()
                    local ok2, err2 = pcall(fn, d)
                    if not ok2 then log('ERR follow-up', err2) end
                end))
            end)
            if not ok then log('ERR timer unavailable:', err) end
        end
    end
end

---------------------------------------------------------------------------
-- Target effects
---------------------------------------------------------------------------

local ET = get(core.magic, 'EFFECT_TYPE') or {}
local TARGET_NAMES = { 'Chameleon', 'Invisibility', 'Light', 'DetectAnimal', 'DetectEnchantment',
    'DetectKey', 'NightEye', 'WaterWalking', 'WaterBreathing' }
local TARGET_IDS = {}
local isTarget = {}
for _, name in ipairs(TARGET_NAMES) do
    local id = ET[name] or name:lower()
    TARGET_IDS[#TARGET_IDS + 1] = id
    isTarget[id] = true
end
local DISPEL = ET.Dispel or 'dispel'

local function effectRecord(id)
    local records = get(get(core.magic, 'effects'), 'records')
    local rec = get(records, id)
    if rec then return rec end
    each(records, function(r) if get(r, 'id') == id then rec = r end end)
    return rec
end

---------------------------------------------------------------------------
-- Reading the player's magic state
---------------------------------------------------------------------------

local origin = {} -- spell id (lowercase) -> 'race:x' / 'birthsign:y'

local function buildOrigins()
    origin = {}
    local function addAll(label, rec)
        each(get(rec, 'spells'), function(v)
            local id = type(v) == 'string' and v or get(v, 'id')
            if id then origin[s(id):lower()] = label end
        end)
    end
    local signId = try(types.Player and types.Player.birthSign, actor)
    if signId ~= nil then
        local signs = get(types.Player, 'birthSigns')
        local rec = get(get(signs, 'records'), signId)
        if not rec and signs and signs.record then rec = try(signs.record, signId) end
        addAll('birthsign:' .. s(signId), rec)
    end
    local npcRec = try(types.NPC and types.NPC.record, actor)
    local raceId = get(npcRec, 'race')
    if raceId ~= nil then
        local races = get(types.NPC, 'races')
        local rec = get(get(races, 'records'), raceId)
        if not rec and races and races.record then rec = try(races.record, raceId) end
        addAll('race:' .. s(raceId), rec)
    end
    local n = 0
    for _ in pairs(origin) do n = n + 1 end
    log('origins birthsign=', signId, 'race=', raceId, 'known ability ids=', n)
end

local function classify(src)
    if src.temporary then return 'temporary' end
    if src.fromEquipment then return 'gear' end
    return origin[s(src.id):lower()] or 'ability(other)'
end

-- One entry per active spell that carries at least one target effect.
local function collectSources()
    local out = {}
    local spells = try(types.Actor.activeSpells, actor)
    each(spells, function(sp)
        local src = {
            id = get(sp, 'id'), name = get(sp, 'name'), item = get(sp, 'item'), caster = get(sp, 'caster'),
            fromEquipment = get(sp, 'fromEquipment') and true or false,
            temporary = get(sp, 'temporary') and true or false,
            targets = {}, others = {}, indices = {},
        }
        each(get(sp, 'effects'), function(e)
            local id = get(e, 'id')
            local idx = get(e, 'index')
            if idx ~= nil then src.indices[#src.indices + 1] = idx end
            if isTarget[id] then
                src.targets[#src.targets + 1] = s(id) .. '=' .. s(get(e, 'magnitudeThisFrame'))
            else
                src.others[#src.others + 1] = s(id)
            end
        end)
        if #src.targets > 0 then
            src.kind = classify(src)
            out[#out + 1] = src
        end
    end)
    return out
end

local function activeEffects()
    return try(types.Actor.activeEffects, actor)
end

local function magnitude(ae, id)
    local e = try(ae and ae.getEffect, ae, id)
    return get(e, 'magnitude') or 0
end

-- Logs, for every target effect, its active magnitude and how many active spells carry it.
local function status(label)
    local counts = {}
    each(try(types.Actor.activeSpells, actor), function(sp)
        each(get(sp, 'effects'), function(e)
            local id = get(e, 'id')
            if isTarget[id] then counts[id] = (counts[id] or 0) + 1 end
        end)
    end)
    local ae = activeEffects()
    local shown = false
    for _, id in ipairs(TARGET_IDS) do
        local m = magnitude(ae, id)
        if m ~= 0 or counts[id] then
            shown = true
            log(label, id, 'magnitude', m, 'active spells carrying it', counts[id] or 0)
        end
    end
    if not shown then log(label, 'no target effects active') end
end

local function envLine()
    local cell = get(actor, 'cell')
    log('env cell', get(cell, 'name') or get(cell, 'id'), 'waterLevel', get(cell, 'waterLevel'),
        'z', get(get(actor, 'position'), 'z'),
        'swimming', try(types.Actor.isSwimming, actor),
        'onGround', try(types.Actor.isOnGround, actor),
        'stance', try(types.Actor.getStance, actor),
        'sneakControl', get(self.controls, 'sneak'))
end

---------------------------------------------------------------------------
-- Test 1: dump
---------------------------------------------------------------------------

local function dump()
    log('=== DUMP ===', 'API revision', core.API_REVISION)
    buildOrigins()
    envLine()
    status('effect')
    for _, src in ipairs(collectSources()) do
        log('source', src.kind, 'spell', src.id, 'name', src.name, 'item', get(src.item, 'recordId') or src.item,
            'targets', concat(src.targets), 'other effects in same spell', concat(src.others),
            'fromEquipment', src.fromEquipment, 'temporary', src.temporary)
    end
    local spellbook = try(types.Actor.spells, actor)
    each(spellbook, function(sp)
        local hits = {}
        each(get(sp, 'effects'), function(e)
            local id = get(e, 'id')
            if isTarget[id] then hits[#hits + 1] = s(id) end
        end)
        if #hits > 0 then
            log('spellbook', get(sp, 'id'), 'name', get(sp, 'name'), 'type', get(sp, 'type'), 'targets', concat(hits))
        end
    end)
    log('=== END DUMP ===')
end

---------------------------------------------------------------------------
-- Tests 2-4: ways of switching an effect off
---------------------------------------------------------------------------

local last = nil -- what the last test did, for restore

local function followUps(label)
    after(CONFIG.followUps, function(d) status(label .. ' +' .. d .. 's') end)
end

-- A: remove the whole active spell that carries a target effect.
local function methodA()
    log('=== TEST A: activeSpells:remove ===')
    local spells = try(types.Actor.activeSpells, actor)
    local removed = {}
    for _, src in ipairs(collectSources()) do
        if src.temporary then
            log('A skip (temporary)', src.id)
        else
            local ok, err = pcall(function() spells:remove(src.id) end)
            log('A remove', src.kind, src.id, ok and 'ok' or ('ERR ' .. s(err)),
                'collateral (other effects lost with it)', concat(src.others))
            if ok then removed[#removed + 1] = src end
        end
    end
    last = { kind = 'A', removed = removed }
    followUps('A')
end

-- B: cancel each target effect with a negative modifier.
local function methodB()
    log('=== TEST B: activeEffects:modify ===')
    local ae = activeEffects()
    local applied = {}
    for _, id in ipairs(TARGET_IDS) do
        local m = magnitude(ae, id)
        if m ~= 0 then
            local ok, err = pcall(function() ae:modify(-m, id) end)
            log('B modify', id, -m, ok and 'ok' or ('ERR ' .. s(err)), 'magnitude now', magnitude(ae, id))
            if ok then applied[id] = m end
        end
    end
    last = { kind = 'B', applied = applied }
    followUps('B')
end

-- C: remove each target effect from the active effects.
local function methodC()
    log('=== TEST C: activeEffects:remove ===')
    local ae = activeEffects()
    local original = {}
    for _, id in ipairs(TARGET_IDS) do
        local m = magnitude(ae, id)
        if m ~= 0 then
            local ok, err = pcall(function() ae:remove(id) end)
            log('C remove', id, ok and 'ok' or ('ERR ' .. s(err)), 'magnitude now', magnitude(ae, id))
            if ok then original[id] = m end
        end
    end
    last = { kind = 'C', original = original }
    followUps('C')
end

local function restore()
    if not last then
        log('RESTORE nothing to restore')
        return
    end
    log('=== RESTORE test', last.kind, '===')
    if last.kind == 'A' then
        local spells = try(types.Actor.activeSpells, actor)
        local present = {}
        each(spells, function(sp) present[s(get(sp, 'id'))] = true end)
        for _, src in ipairs(last.removed) do
            if present[s(src.id)] then
                log('RESTORE A', src.id, 'already present: the engine re-applied it by itself')
            else
                local ok, err = pcall(function()
                    spells:add {
                        id = src.id, name = src.name, effects = src.indices, item = src.item,
                        caster = src.caster or actor, fromEquipment = src.fromEquipment, temporary = false,
                    }
                end)
                log('RESTORE A add', src.id, ok and 'ok' or ('ERR ' .. s(err)))
            end
        end
    elseif last.kind == 'B' then
        local ae = activeEffects()
        for id, m in pairs(last.applied) do
            local ok, err = pcall(function() ae:modify(m, id) end)
            log('RESTORE B', id, m, ok and 'ok' or ('ERR ' .. s(err)))
        end
    elseif last.kind == 'C' then
        local ae = activeEffects()
        for id, m in pairs(last.original) do
            local ok, err = pcall(function() ae:set(m, id) end)
            log('RESTORE C set', id, m, ok and 'ok' or ('ERR ' .. s(err)), 'magnitude now', magnitude(ae, id))
        end
    end
    last = nil
    after({ 0, 1, 5 }, function(d) status('restored +' .. d .. 's') end)
    log('If anything still looks wrong, reload your save.')
end

---------------------------------------------------------------------------
-- Tests 6-7: the flourish (visual + sound)
---------------------------------------------------------------------------

local function modelOf(ref)
    if ref == nil or ref == '' then return nil end
    if type(ref) == 'string' then
        local rec = try(types.Static and types.Static.record, ref)
        if not rec then rec = get(get(types.Static, 'records'), ref) end
        return get(rec, 'model')
    end
    return get(ref, 'model')
end

local function nonEmpty(v)
    if v == nil or v == '' then return nil end
    return v
end

local function soundExists(id)
    if not id then return false end
    local records = get(get(core, 'sound'), 'records')
    if records == nil then return 'unknown' end
    return get(records, id) ~= nil
end

local function flourish(effectId, mode, variant)
    local srcId = (mode == 'disable') and DISPEL or effectId
    local rec = effectRecord(srcId)
    if not rec then
        log('FLOURISH no effect record for', srcId)
        return
    end
    local staticRef = nonEmpty(get(rec, 'hitStatic')) or nonEmpty(get(rec, 'castStatic'))
    local model = modelOf(staticRef)
    local soundId = nonEmpty(get(rec, 'hitSound')) or nonEmpty(get(rec, 'castSound'))
    if not soundId and get(rec, 'school') then soundId = s(get(rec, 'school')):lower() .. ' hit' end
    log('FLOURISH', mode, 'using effect', srcId, 'static', staticRef, 'model', model,
        'sound', soundId, 'sound exists', soundExists(soundId), 'variant', variant)

    if variant == 'local' then
        if model and anim then
            local ok, err = pcall(anim.addVfx, actor, model, { loop = false, vfxId = 'ETP_' .. mode })
            log('addVfx', ok and 'ok' or ('ERR ' .. s(err)))
        end
        if soundId then
            local ok, err = pcall(core.sound.playSound3d, soundId, actor, { volume = CONFIG.volume })
            log('playSound3d', ok and 'ok' or ('ERR ' .. s(err)))
        end
    else
        if model then
            local ok, err = pcall(core.sendGlobalEvent, 'ETP_Spawn',
                { model = model, position = actor.position, scale = CONFIG.worldScale })
            log('sendGlobalEvent ETP_Spawn', ok and 'ok (see global spawn line)' or ('ERR ' .. s(err)))
        end
        if soundId and ambient then
            local ok, err = pcall(ambient.playSound, soundId, { volume = CONFIG.volume })
            log('ambient.playSound', ok and 'ok' or ('ERR ' .. s(err)))
        end
    end
end

-- Plays "effect switched on", then 2.5 s later "effect switched off" (Dispel's look).
local function flourishDemo(variant)
    log('=== TEST FLOURISH', variant, '===')
    local ae = activeEffects()
    local id = ET.Chameleon or 'chameleon'
    for _, tid in ipairs(TARGET_IDS) do
        if magnitude(ae, tid) ~= 0 then id = tid break end
    end
    log('flourish demo uses effect', id)
    flourish(id, 'enable', variant)
    after({ 2.5 }, function() flourish(id, 'disable', variant) end)
end

---------------------------------------------------------------------------
-- Test 8: HUD icons with a cross and a pulse
---------------------------------------------------------------------------

local iconElement = nil

local function destroyIcons()
    if iconElement then
        pcall(function() iconElement:destroy() end)
        iconElement = nil
    end
end

local function iconTest()
    log('=== TEST ICONS ===')
    destroyIcons()
    local v2 = util.vector2
    local content = ui.content {}
    local x = 0
    for _, id in ipairs(TARGET_IDS) do
        local icon = get(effectRecord(id), 'icon')
        if type(icon) == 'string' and icon ~= '' then
            content:add {
                type = ui.TYPE.Widget,
                props = { position = v2(x, 0), size = v2(32, 32) },
                content = ui.content {
                    { type = ui.TYPE.Image, props = { resource = ui.texture { path = icon }, size = v2(32, 32) } },
                    { type = ui.TYPE.Text, props = {
                        text = 'X', textSize = 32, textColor = util.color.rgb(0.85, 0.1, 0.1),
                        size = v2(32, 32), textAlignH = ui.ALIGNMENT.Center, textAlignV = ui.ALIGNMENT.Center } },
                },
            }
            x = x + 36
        else
            log('icons: no icon path for', id)
        end
    end
    local ok, err = pcall(function()
        iconElement = ui.create {
            layer = 'HUD',
            props = { position = v2(24, 24), size = v2(math.max(x, 1), 32), alpha = 1 },
            content = content,
        }
    end)
    log('ui.create', ok and 'ok' or ('ERR ' .. s(err)), 'width', x)
    if not ok then return end
    -- Pulse by rewriting alpha a few times a second; proves live updates work.
    local steps = CONFIG.iconSeconds * 5
    for i = 1, steps do
        after({ i * 0.2 }, function()
            if not iconElement then return end
            iconElement.layout.props.alpha = 0.55 + 0.45 * math.cos(i * 0.9)
            iconElement:update()
        end)
    end
    after({ CONFIG.iconSeconds }, destroyIcons)
end

---------------------------------------------------------------------------
-- Actions, keys and the settings page
---------------------------------------------------------------------------

local ACTIONS = {
    { id = 'dump', fn = dump },
    { id = 'methodA', fn = methodA },
    { id = 'methodB', fn = methodB },
    { id = 'methodC', fn = methodC },
    { id = 'restore', fn = restore },
    { id = 'flourishLocal', fn = function() flourishDemo('local') end },
    { id = 'flourishWorld', fn = function() flourishDemo('world') end },
    { id = 'icons', fn = iconTest },
}

local lastFired = {}

local function fire(action)
    -- Ignore presses while any menu is open (typing in the console, inventory, ...).
    local mode = I.UI and try(I.UI.getMode)
    if mode then return end
    -- A key bound both here and in the settings page would fire twice.
    local now = core.getRealTime and core.getRealTime() or 0
    if lastFired[action.id] and now - lastFired[action.id] < 0.25 then return end
    lastFired[action.id] = now
    toast('Effect Toggle Probe: ' .. action.id)
    local ok, err = pcall(action.fn)
    if not ok then log('ERR in', action.id, err) end
end

for _, action in ipairs(ACTIONS) do
    local name = CONFIG.keys[action.id]
    action.code = name and input.KEY and input.KEY[name] or nil
    if not action.code then log('key', name, 'for', action.id, 'is not a known key name') end
end

local function onKeyPress(key)
    for _, action in ipairs(ACTIONS) do
        if action.code and key.code == action.code then
            fire(action)
            return
        end
    end
end

-- In-game page: Options > Scripts > Effect Toggle Probe, one rebindable key per action.
local function registerSettings()
    local Settings = I.Settings
    if not Settings then
        log('settings page: interface not available')
        return
    end
    Settings.registerPage {
        key = 'EffectToggleProbe', l10n = 'EffectToggleProbe',
        name = 'PageName', description = 'PageDescription',
    }
    local items = {}
    for _, action in ipairs(ACTIONS) do
        local trigger = 'ETP_' .. action.id
        input.registerTrigger {
            key = trigger, l10n = 'EffectToggleProbe',
            name = action.id .. 'Name', description = action.id .. 'Description',
        }
        input.registerTriggerHandler(trigger, async:callback(function() fire(action) end))
        items[#items + 1] = {
            key = action.id .. 'Binding', renderer = 'inputBinding',
            name = action.id .. 'Name', description = action.id .. 'Description',
            default = '',
            argument = { type = 'trigger', key = trigger },
        }
    end
    Settings.registerGroup {
        key = 'SettingsPlayerEffectToggleProbe', page = 'EffectToggleProbe', l10n = 'EffectToggleProbe',
        name = 'GroupName', permanentStorage = true, settings = items,
    }
end

local okSettings, errSettings = pcall(registerSettings)
log('settings page', okSettings and 'registered' or ('FAILED: ' .. s(errSettings)))

local function banner()
    log('loaded. API revision', core.API_REVISION, '- default keys:')
    for _, action in ipairs(ACTIONS) do log('  ', action.id, '=', CONFIG.keys[action.id]) end
end

return {
    engineHandlers = {
        onInit = banner,
        onLoad = banner,
        onKeyPress = onKeyPress,
    },
}
