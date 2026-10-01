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
local vfs = require('openmw.vfs')

local CONFIG = {
    textSize = 16,
    showMetGates = true, -- also list requirements you already meet (in green)
    -- Topics you have not discovered yet (see README, "Known topics"):
    --   'obscure' = show a blurred hint, 'hide' = omit, 'show' = show normally.
    unrevealedTopics = 'obscure',
    -- How 'obscure' looks: 'smear' = soft blurred scrambled text (default),
    -- 'bars' = translucent bars, 'text' = a grey "???".
    blurStyle = 'smear',
    -- Panel box: 'auto' uses the Interface Reimagined fade box when its textures
    -- are installed, 'ir' forces it, 'vanilla' uses the stock OpenMW box.
    boxStyle = 'auto',
    -- Placement as fractions of the screen. Default sits directly above the
    -- topic column of the dialogue window, left edges aligned.
    position = { x = 0.6846, y = 0.545 },
    anchor = { x = 0, y = 1 },
    -- Minimum panel width as a fraction of the screen (matches the topic column).
    minWidth = 0.118,
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
-- Known topics (best effort)
--
-- OpenMW does not expose which topics the player knows. A topic is treated as
-- discovered when it is in the journal topic list, or when its name appeared in
-- text the player has seen: journal entries, reached quest stages, and NPC
-- responses heard while this mod is active (remembered in the save file).
---------------------------------------------------------------------------

local learned = {} -- topic id -> true
local seeded = false

local function containsWord(text, word)
    local init = 1
    while true do
        local a, b = text:find(word, init, true)
        if not a then return false end
        local before = a > 1 and text:sub(a - 1, a - 1) or ' '
        local after = b < #text and text:sub(b + 1, b + 1) or ' '
        if not before:match('[%w]') and not after:match('[%w]') then return true end
        init = a + 1
    end
end

local function scanText(text)
    if not text or not index then return end
    text = text:lower()
    for _, entry in ipairs(index) do
        if not learned[entry.topicId] and containsWord(text, entry.topicId) then
            learned[entry.topicId] = true
        end
    end
end

local function seedLearned()
    seeded = true
    if not index then buildIndex() end
    local ok, err = pcall(function()
        for _, topic in pairs(types.Player.journal(self).topics) do
            learned[topic.id] = true
            for _, e in ipairs(topic.entries) do scanText(e.text) end
        end
        for questId, q in pairs(types.Player.quests(self)) do
            local rec = core.dialogue.journal.records[questId]
            if rec and q.stage then
                for _, info in ipairs(rec.infos) do
                    if info.questStage and info.questStage <= q.stage then scanText(info.text) end
                end
            end
        end
    end)
    if not ok then print('[SpeechGates] seeding known topics failed: ' .. tostring(err)) end
end

local function isRevealed(topicId)
    return learned[topicId] or types.Player.journal(self).topics[topicId] ~= nil
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
    if not seeded then seedLearned() end
    local disposition = types.NPC.getDisposition(actor, self)

    local byTopic, order, seen = {}, {}, {}
    for _, entry in ipairs(index) do
        local revealed = isRevealed(entry.topicId)
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
local v2 = util.vector2

local function text(str, color)
    return { type = ui.TYPE.Text, props = { text = str, textSize = CONFIG.textSize, textColor = color } }
end

-- Deterministic letter substitution so hidden entries are unreadable but stable
-- between refreshes. Spaces and punctuation are kept so the length still hints.
local function scramble(str)
    local out = {}
    for i = 1, #str do
        local c = str:sub(i, i)
        local b = c:byte()
        local h = (b * 7 + i * 13 + #str * 5) % 26
        if c:match('%l') then
            out[i] = string.char(97 + h)
        elseif c:match('%u') then
            out[i] = string.char(65 + h)
        elseif c:match('%d') then
            out[i] = tostring(h % 10)
        else
            out[i] = c
        end
    end
    return table.concat(out)
end

-- Fake blur: the scrambled text drawn several times with 1-2px offsets at low
-- opacity. (OpenMW cannot apply a shader to a UI widget.)
local SMEAR_OFFSETS = {}
for dx = -2, 2, 2 do
    for dy = -1, 1 do
        SMEAR_OFFSETS[#SMEAR_OFFSETS + 1] = v2(dx, dy)
    end
end

local function smear(str, color, indent)
    local copies = {}
    for _, o in ipairs(SMEAR_OFFSETS) do
        copies[#copies + 1] = {
            type = ui.TYPE.Text,
            props = {
                text = scramble(str), textSize = CONFIG.textSize, textColor = color,
                alpha = 0.16, position = o + v2(indent, 0),
            },
        }
    end
    return {
        props = { size = v2(#str * CONFIG.textSize * 0.55 + indent + 4, CONFIG.textSize + 4) },
        content = ui.content(copies),
    }
end

local barTexture = ui.texture { path = 'white' }

-- A soft translucent bar standing in for blurred text of roughly `chars` letters.
local function smudge(chars, indent)
    local height = CONFIG.textSize + 2
    local width = (CONFIG.smudgeFixedWidth and 14 or math.max(4, math.min(chars, 28))) * CONFIG.textSize * 0.5
    return {
        props = { size = v2(width + indent, height) },
        content = ui.content {
            {
                type = ui.TYPE.Image,
                props = {
                    resource = barTexture, color = HINT, alpha = 0.3,
                    position = v2(indent, 0), size = v2(width, height * 0.6),
                    relativePosition = v2(0, 0.2),
                },
            },
        },
    }
end

---------------------------------------------------------------------------
-- Box: a Lua rebuild of Interface Reimagined's "MW_Box_Fade" skin (the box used
-- by the dialogue window): translucent background, a thin solid left edge and
-- faded top / bottom / right edges. Uses the same texture files, so it follows
-- whatever texture replacers are installed.
---------------------------------------------------------------------------

local FADE_TEXTURES = {
    'textures/menu_semitransparent_bg.dds',
    'textures/menu_semitransparent_fade_bg.dds',
    'textures/menu_semitransparent_fade_top_bg.dds',
    'textures/menu_semitransparent_fade_bottom_bg.dds',
    'textures/menu_semitransparent_fade_top_right_bg.dds',
    'textures/menu_semitransparent_fade_bottom_right_bg.dds',
    'textures/menu_thin_border_left.dds',
}

local function haveFadeTextures()
    for _, path in ipairs(FADE_TEXTURES) do
        local ok, exists = pcall(vfs.fileExists, path)
        if not (ok and exists) then return false end
    end
    return true
end

local fadeBoxTemplate = nil

local function getFadeBox()
    if fadeBoxTemplate then return fadeBoxTemplate end
    local PAD, FADE, EDGE = 10, 20, 2
    local function img(path, props, tileH, tileV)
        props.resource = ui.texture { path = path }
        props.tileH = tileH or false
        props.tileV = tileV or false
        return { template = { type = ui.TYPE.Image, props = {} }, props = props }
    end
    local inner = PAD * 2 - FADE * 2
    fadeBoxTemplate = {
        type = ui.TYPE.Container,
        content = ui.content {
            -- background (between the fades)
            img('textures/menu_semitransparent_bg.dds',
                { position = v2(EDGE, FADE), size = v2(PAD * 2 - EDGE - FADE, inner), relativeSize = v2(1, 1) },
                true, true),
            -- solid thin left edge
            img('textures/menu_thin_border_left.dds',
                { size = v2(EDGE, PAD * 2), relativeSize = v2(0, 1) }, false, true),
            -- fades
            img('textures/menu_semitransparent_fade_top_bg.dds',
                { position = v2(EDGE, 0), size = v2(PAD * 2 - EDGE - FADE, FADE), relativeSize = v2(1, 0) }, true, false),
            img('textures/menu_semitransparent_fade_bottom_bg.dds',
                { relativePosition = v2(0, 1), position = v2(EDGE, PAD * 2 - FADE),
                  size = v2(PAD * 2 - EDGE - FADE, FADE), relativeSize = v2(1, 0) }, true, false),
            img('textures/menu_semitransparent_fade_bg.dds',
                { relativePosition = v2(1, 0), position = v2(PAD * 2 - FADE, FADE),
                  size = v2(FADE, inner), relativeSize = v2(0, 1) }, false, true),
            img('textures/menu_semitransparent_fade_top_right_bg.dds',
                { relativePosition = v2(1, 0), position = v2(PAD * 2 - FADE, 0), size = v2(FADE, FADE) }),
            img('textures/menu_semitransparent_fade_bottom_right_bg.dds',
                { relativePosition = v2(1, 1), position = v2(PAD * 2 - FADE, PAD * 2 - FADE), size = v2(FADE, FADE) }),
            { external = { slot = true }, props = { position = v2(PAD, PAD), relativeSize = v2(1, 1) } },
        },
    }
    return fadeBoxTemplate
end

local function boxTemplate()
    local style = CONFIG.boxStyle
    if style == 'ir' or (style == 'auto' and haveFadeTextures()) then
        return getFadeBox()
    end
    return I.MWUI.templates.boxTransparentThick
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

    local minWidth = math.floor(ui.screenSize().x * CONFIG.minWidth)
    local rows = {
        { props = { size = v2(minWidth, 0) } }, -- keeps the panel as wide as the topic column
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
        elseif CONFIG.blurStyle == 'smear' then
            rows[#rows + 1] = smear(topic, NORMAL, 0)
            for _, l in ipairs(t[1]) do
                rows[#rows + 1] = smear('   ' .. l.text, NORMAL, 0)
            end
        elseif CONFIG.blurStyle == 'bars' then
            rows[#rows + 1] = smudge(#topic, 0)
            for _ in ipairs(t[1]) do
                rows[#rows + 1] = smudge(14, CONFIG.textSize)
            end
        else
            rows[#rows + 1] = text('???', HINT)
        end
    end

    panel = ui.create {
        layer = 'Windows',
        template = boxTemplate(),
        props = {
            relativePosition = v2(CONFIG.position.x, CONFIG.position.y),
            anchor = v2(CONFIG.anchor.x, CONFIG.anchor.y),
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

-- Remember topics whose names appear in NPC speech, then redraw.
local function onDialogueResponse(e)
    if index and e and e.recordId and core.dialogue[e.type] then
        pcall(function()
            local rec = core.dialogue[e.type].records[e.recordId]
            if rec then
                for _, info in ipairs(rec.infos) do
                    if info.id == e.infoId then
                        scanText(info.text)
                        break
                    end
                end
            end
        end)
    end
    if panel or currentActor then safeRefresh() end
end

local function onSave()
    return { learned = learned }
end

local function onLoad(data)
    learned = data and data.learned or {}
    seeded = false
end

return {
    engineHandlers = { onSave = onSave, onLoad = onLoad },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        DialogueResponse = onDialogueResponse,
    },
}
