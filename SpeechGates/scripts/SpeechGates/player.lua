-- Speech Gates (player script)
--
-- Purely event-driven: nothing runs per frame. Work happens only when the
-- dialogue window opens and after each dialogue response.
--
-- While the dialogue window is open, shows a small panel listing the dialogue
-- responses that are relevant to your active quests and gated behind a skill,
-- attribute, level or disposition requirement, e.g. "Speechcraft 45 (you: 38)".
--
-- Limits (see README.md): the vanilla topic list is native UI and cannot be
-- edited from Lua, and gates implemented inside result scripts are invisible.

local core = require('openmw.core')
local self = require('openmw.self')
local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local CONFIG = {
    textSize = 16,
    showMetGates = true, -- also list requirements you already meet (in green)
    -- Topics you have not talked about yet (not in your journal topic list):
    --   'obscure' = show a grey "???" hint, 'hide' = omit, 'show' = show normally.
    unrevealedTopics = 'obscure',
    -- Panel placement as a fraction of the screen. The panel grows upward from
    -- this point (anchor bottom-centre), by default above the topic column.
    position = { x = 0.745, y = 0.52 },
    anchor = { x = 0.5, y = 1 },
}

local CT = core.dialogue.CONDITION_TYPE
local OP = core.dialogue.CONDITION_OPERATOR

---------------------------------------------------------------------------
-- Condition metadata
---------------------------------------------------------------------------

-- id -> label, condition type names are 'Pc' .. Name
local SKILLS = {
    block = 'Block', armorer = 'Armorer', mediumarmor = 'MediumArmor', heavyarmor = 'HeavyArmor',
    bluntweapon = 'BluntWeapon', longblade = 'LongBlade', axe = 'Axe', spear = 'Spear',
    athletics = 'Athletics', enchant = 'Enchant', destruction = 'Destruction',
    alteration = 'Alteration', illusion = 'Illusion', conjuration = 'Conjuration',
    mysticism = 'Mysticism', restoration = 'Restoration', alchemy = 'Alchemy',
    unarmored = 'Unarmored', security = 'Security', sneak = 'Sneak', acrobatics = 'Acrobatics',
    lightarmor = 'LightArmor', shortblade = 'ShortBlade', marksman = 'Marksman',
    mercantile = 'Mercantile', speechcraft = 'Speechcraft', handtohand = 'HandToHand',
}
local ATTRIBUTES = {
    strength = 'Strength', intelligence = 'Intelligence', willpower = 'Willpower',
    agility = 'Agility', speed = 'Speed', endurance = 'Endurance',
    personality = 'Personality', luck = 'Luck',
}

-- condition type number -> { label, get = function() -> player's current value }
local gateTypes = {}
for id, name in pairs(SKILLS) do
    local t = CT['Pc' .. name]
    if t then
        gateTypes[t] = { label = name:gsub('(%l)(%u)', '%1 %2'), get = function()
            return types.NPC.stats.skills[id](self).modified
        end }
    end
end
for id, name in pairs(ATTRIBUTES) do
    local t = CT['Pc' .. name]
    if t then
        gateTypes[t] = { label = name, get = function()
            return types.Actor.stats.attributes[id](self).modified
        end }
    end
end
if CT.PcLevel then
    gateTypes[CT.PcLevel] = { label = 'Level', get = function()
        return types.Actor.stats.level(self).current
    end }
end

local function compare(op, a, b)
    if op == OP.Equal then return a == b
    elseif op == OP.NotEqual then return a ~= b
    elseif op == OP.Greater then return a > b
    elseif op == OP.GreaterEqual then return a >= b
    elseif op == OP.Less then return a < b
    elseif op == OP.LessEqual then return a <= b
    end
    return false
end

-- Only "at least X" style conditions are shown as requirements.
local function isMinimum(op)
    return op == OP.Greater or op == OP.GreaterEqual
end

local function minimumValue(cond)
    return cond.operator == OP.Greater and cond.value + 1 or cond.value
end

---------------------------------------------------------------------------
-- Index of gated, quest-related infos (built once, lazily)
---------------------------------------------------------------------------

local index = nil

local function buildIndex()
    index = {}
    for _, topic in ipairs(core.dialogue.topic.records) do
        for _, info in ipairs(topic.infos) do
            local conds = info.conditions
            if conds then
                local gates, journal = {}, {}
                for _, c in ipairs(conds) do
                    if c.type == CT.Journal then
                        journal[#journal + 1] = c
                    elseif gateTypes[c.type] and isMinimum(c.operator) then
                        gates[#gates + 1] = c
                    end
                end
                local disp = info.filterActorDisposition or 0
                if #journal > 0 and (#gates > 0 or disp > 0) then
                    index[#index + 1] = {
                        topic = topic.name, topicId = topic.id, info = info,
                        gates = gates, journal = journal, disposition = disp,
                    }
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Evaluation against the current actor / player state
---------------------------------------------------------------------------

local function lower(s) return s and tostring(s):lower() or nil end

local function actorMatches(actor, info)
    local rec = types.NPC.record(actor)
    if not rec then return false end
    local id = lower(info.filterActorId)
    if id and id ~= lower(actor.recordId) then return false end
    local race = lower(info.filterActorRace)
    if race and race ~= lower(rec.race) then return false end
    local class = lower(info.filterActorClass)
    if class and class ~= lower(rec.class) then return false end
    local gender = lower(info.filterActorGender)
    if gender and (gender == 'male') ~= (rec.isMale and true or false) then return false end
    local faction = lower(info.filterActorFaction)
    if faction then
        local ok, factions = pcall(types.NPC.getFactions, actor)
        local primary = ok and factions and lower(factions[1]) or ''
        if faction ~= primary then return false end
    end
    return true
end

-- All journal conditions currently hold and at least one of the quests is active.
local function questRelevant(entry, quests)
    local anyActive = false
    for _, c in ipairs(entry.journal) do
        local q = quests[c.recordId]
        local stage = q and q.stage or 0
        if not compare(c.operator, stage, c.value) then return false end
        if q and q.started and not q.finished then anyActive = true end
    end
    return anyActive
end

local function evaluate(actor)
    if not index then buildIndex() end
    local quests = types.Player.quests(self)
    local journalTopics = types.Player.journal(self).topics
    local disposition = types.NPC.getDisposition(actor, self)

    local byTopic, order, seen = {}, {}, {}
    for _, entry in ipairs(index) do
        local revealed = journalTopics[entry.topicId] ~= nil
        if (revealed or CONFIG.unrevealedTopics ~= 'hide')
            and actorMatches(actor, entry.info) and questRelevant(entry, quests) then
            local lines, locked = {}, false
            for _, c in ipairs(entry.gates) do
                local g = gateTypes[c.type]
                local need, have = minimumValue(c), g.get()
                local met = have >= need
                locked = locked or not met
                lines[#lines + 1] = { text = string.format('%s %d / %d', g.label, have, need), met = met }
            end
            if entry.disposition > 0 then
                local met = disposition >= entry.disposition
                locked = locked or not met
                lines[#lines + 1] = {
                    text = string.format('Disposition %d', entry.disposition), met = met }
            end
            if locked or CONFIG.showMetGates then
                local key = entry.topicId
                for _, l in ipairs(lines) do key = key .. '|' .. l.text end
                if not seen[key] then
                    seen[key] = true
                    local t = byTopic[entry.topic]
                    if not t then
                        t = { revealed = revealed }
                        byTopic[entry.topic] = t
                        order[#order + 1] = entry.topic
                    end
                    t[#t + 1] = lines
                end
            end
        end
    end
    table.sort(order)
    return order, byTopic, disposition
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

-- Use the game's own UI colours so the panel follows whatever UI mods set.
local function gmstColor(name, fallback)
    local ok, c = pcall(function() return util.color.commaString(core.getGMST(name)) end)
    return ok and c or fallback
end
local HEADER = gmstColor('FontColor_color_header', util.color.rgb(0.87, 0.79, 0.62))
local NORMAL = gmstColor('FontColor_color_normal', util.color.rgb(0.79, 0.65, 0.38))
local UNMET = util.color.rgb(0.92, 0.42, 0.34)
local MET = util.color.rgb(0.52, 0.82, 0.52)
local HINT = util.color.rgb(0.55, 0.52, 0.47)

local panel = nil
local currentActor = nil

local function text(str, color)
    return { type = ui.TYPE.Text, props = { text = str, textSize = CONFIG.textSize, textColor = color } }
end

local function destroyPanel()
    if panel then
        panel:destroy()
        panel = nil
    end
end

local function refresh()
    destroyPanel()
    if not currentActor or not currentActor:isValid() or currentActor.type ~= types.NPC then return end
    local order, byTopic, disposition = evaluate(currentActor)
    if #order == 0 then return end

    local rows = {
        text('Requirements', HEADER),
        text('Disposition: ' .. disposition, HEADER),
    }
    for _, topic in ipairs(order) do
        local t = byTopic[topic]
        if t.revealed or CONFIG.unrevealedTopics == 'show' then
            rows[#rows + 1] = text(topic, NORMAL)
            for _, lines in ipairs(t) do
                for _, l in ipairs(lines) do
                    rows[#rows + 1] = text('   ' .. l.text, l.met and MET or UNMET)
                end
            end
        else
            rows[#rows + 1] = text('???', HINT)
        end
    end

    panel = ui.create {
        layer = 'Windows',
        template = I.MWUI.templates.boxTransparentThick,
        props = {
            relativePosition = util.vector2(CONFIG.position.x, CONFIG.position.y),
            anchor = util.vector2(CONFIG.anchor.x, CONFIG.anchor.y),
        },
        content = ui.content {
            { type = ui.TYPE.Flex, props = { horizontal = false }, content = ui.content(rows) },
        },
    }
end

local function safeRefresh()
    local ok, err = pcall(refresh)
    if not ok then
        destroyPanel()
        print('[SpeechGates] ' .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------

local function onUiModeChanged(data)
    if data.newMode == I.UI.MODE.Dialogue then
        if data.arg then currentActor = data.arg end
        safeRefresh()
    else
        currentActor = nil
        destroyPanel()
    end
end

local function onDialogueResponse()
    if panel or currentActor then safeRefresh() end
end

return {
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        DialogueResponse = onDialogueResponse,
    },
}
