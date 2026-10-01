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
    -- Only list responses that actually do something: their result script
    -- advances a journal quest, adds a topic, or gives/takes items. Plain
    -- flavour lines that merely differ by disposition are skipped.
    requireEffect = true,
    -- Print each listed response (id, result script) to openmw.log.
    debug = false,
    maxTopics = 8, -- most topics listed at once
    showMetGates = true, -- also list requirements you already meet (in green)
    -- Topics you have not discovered yet (see README, "Known topics"):
    --   'obscure' = show a blurred hint, 'hide' = omit, 'show' = show normally.
    unrevealedTopics = 'obscure',
    -- How 'obscure' looks: 'smear' = soft blurred scrambled text (default),
    -- 'bars' = translucent bars, 'text' = a grey "???".
    blurStyle = 'smear',
    -- Placement, as fractions of the screen. The defaults put the panel in the
    -- empty part of the dialogue window's topic column, under "Goodbye", aligned
    -- to the column. Tune these if your dialogue window sits elsewhere.
    columnX = 0.6846,       -- left edge of the topic column
    columnWidth = 0.1184,   -- width of the topic column
    panelTop = 0.893,       -- where the panel starts (just under the Goodbye button)
    columnBottom = 0.9766,  -- where the column's own background ends; the panel
                            -- draws its own background only below this line
    -- Your [GUI] "scaling factor" from settings.cfg. ui.screenSize() reports real
    -- pixels, but UI positions are in units of pixels / scaling factor.
    guiScale = 1.25,
    -- Look (UI units).
    edgeWidth = 3,          -- thickness of the left line
    textInset = 19,         -- gap between the left line and the text
    padY = 6,               -- space above and below the text
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

local EFFECT_COMMANDS = { 'journal', 'addtopic', 'additem', 'removeitem', 'startscript', 'modpcfacrep', 'payfine' }

-- Looks at an info's result script. Returns nil when it has no lasting effect,
-- otherwise a table with `quest` (quest id advanced by a Journal command, if any).
local function parseEffect(script)
    if not script or script == '' then return nil end
    local low = script:lower()
    for _, cmd in ipairs(EFFECT_COMMANDS) do
        if low:find(cmd, 1, true) then
            local quest = low:match('journal[%s,]+"?([%w_%-%.]+)')
            return { quest = quest, command = cmd }
        end
    end
    return nil
end

local function questName(questId)
    if not questId then return nil end
    local ok, rec = pcall(function() return core.dialogue.journal.records[questId] end)
    return ok and rec and rec.questName or nil
end

local topicSet, maxWords = {}, 1

local function buildIndex()
    index = {}
    topicSet, maxWords = {}, 1
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
                    if not topicSet[topic.id] then
                        topicSet[topic.id] = true
                        local _, spaces = topic.id:gsub(' ', '')
                        maxWords = math.max(maxWords, math.min(spaces + 1, 6))
                    end
                    index[#index + 1] = {
                        topic = topic.name, topicId = topic.id, info = info,
                        gates = gates, journal = journal, disposition = disp,
                        effect = parseEffect(info.resultScript),
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

-- Cost control: the index holds thousands of entries and a journal can hold
-- thousands of texts, so a text is NOT compared against every topic. Instead its
-- words are looked up as 1..maxWords-word phrases in a set of topic names, and
-- the total work per call is capped (OpenMW aborts a script call that runs more
-- than the "[Lua] instruction limit per call" setting).
local WORD_BUDGET = 400000
local wordsLeft = WORD_BUDGET

local function scanText(text)
    if not text or wordsLeft <= 0 then return end
    local words, n = {}, 0
    for w in text:lower():gmatch("[%w'%-]+") do
        n = n + 1
        words[n] = w
    end
    wordsLeft = wordsLeft - n
    for i = 1, n do
        local phrase = words[i]
        if topicSet[phrase] then learned[phrase] = true end
        for j = i + 1, math.min(i + maxWords - 1, n) do
            phrase = phrase .. ' ' .. words[j]
            if topicSet[phrase] then learned[phrase] = true end
        end
    end
end

local function seedLearned()
    seeded = true
    if not index then buildIndex() end
    wordsLeft = WORD_BUDGET
    local ok, err = pcall(function()
        -- quest stages reached (few texts) first, then the topic entries
        for questId, q in pairs(types.Player.quests(self)) do
            local rec = core.dialogue.journal.records[questId]
            if rec and q.stage then
                for _, info in ipairs(rec.infos) do
                    if info.questStage and info.questStage <= q.stage then scanText(info.text) end
                end
            end
        end
        for _, topic in pairs(types.Player.journal(self).topics) do
            learned[topic.id] = true
            for _, e in ipairs(topic.entries) do scanText(e.text) end
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

local function actorMatches(actor, rec, info)
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
    local actorRecord = types.NPC.record(actor)
    if not actorRecord then return {}, {}, disposition end

    local byTopic, order, seen = {}, {}, {}
    for _, entry in ipairs(index) do
        local revealed = isRevealed(entry.topicId)
        if (revealed or CONFIG.unrevealedTopics ~= 'hide')
            and (entry.effect or not CONFIG.requireEffect)
            and questRelevant(entry, quests) and actorMatches(actor, actorRecord, entry.info) then
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
            if CONFIG.debug then
                print(string.format('[SpeechGates] %s / info %s | effect=%s | script=%s', entry.topicId,
                    tostring(entry.info.id), entry.effect and entry.effect.command or 'none',
                    tostring(entry.info.resultScript):gsub('%s+', ' '):sub(1, 160)))
            end
            local qn = entry.effect and questName(entry.effect.quest)
            if qn then lines[#lines + 1] = { text = 'Advances: ' .. qn, met = true, note = true } end
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
    local extra = #order - CONFIG.maxTopics
    if extra > 0 then
        for i = #order, CONFIG.maxTopics + 1, -1 do order[i] = nil end
    end
    return order, byTopic, disposition, math.max(extra, 0)
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

local function smear(str, color)
    local copies = {}
    for _, o in ipairs(SMEAR_OFFSETS) do
        copies[#copies + 1] = {
            type = ui.TYPE.Text,
            props = {
                text = scramble(str), textSize = CONFIG.textSize, textColor = color,
                alpha = 0.16, position = o,
            },
        }
    end
    return {
        props = { size = v2(#str * CONFIG.textSize * 0.55 + 4, CONFIG.textSize) },
        content = ui.content(copies),
    }
end

local barTexture = ui.texture { path = 'white' }

-- A soft translucent bar standing in for blurred text of roughly `chars` letters.
local function smudge(chars, indent)
    local height = CONFIG.textSize
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
-- Panel background: Interface Reimagined's "MW_Box_Fade" look, built from the
-- same texture files. The panel sits inside the dialogue window's topic column,
-- which already has this background, so a background is only drawn for the part
-- of the panel that hangs below the column's end - blending into it.
---------------------------------------------------------------------------

local FADE = 20 -- thickness of the faded edges

local TEX = {
    bg = 'textures/menu_semitransparent_bg.dds',
    right = 'textures/menu_semitransparent_fade_bg.dds',
    bottom = 'textures/menu_semitransparent_fade_bottom_bg.dds',
    corner = 'textures/menu_semitransparent_fade_bottom_right_bg.dds',
    left = 'textures/menu_thin_border_left.dds',
}

local warnedTextures = false
local function haveTextures()
    local missing = {}
    for _, path in pairs(TEX) do
        local ok, exists = pcall(vfs.fileExists, path)
        if not (ok and exists) then missing[#missing + 1] = path end
    end
    if #missing > 0 and not warnedTextures then
        warnedTextures = true
        print('[SpeechGates] fade textures not found, using plain background: ' .. table.concat(missing, ', '))
    end
    return #missing == 0
end

local function image(path, props, tileH, tileV)
    props.resource = ui.texture { path = path }
    props.tileH = tileH or false
    props.tileV = tileV or false
    return { type = ui.TYPE.Image, props = props }
end

-- Background pieces for a panel of size (W, H) whose first `shared` pixels
-- (from the top) lie over the column's own background.
local function backgroundPieces(W, H, shared)
    local pieces = {}
    local edge = CONFIG.edgeWidth
    local hang = H - shared -- height hanging below the column
    if haveTextures() then
        if hang > 0 then
            local bgH = math.max(0, hang - FADE)
            if bgH > 0 then
                pieces[#pieces + 1] = image(TEX.bg,
                    { position = v2(edge, shared), size = v2(W - edge - FADE, bgH) }, true, true)
                pieces[#pieces + 1] = image(TEX.right,
                    { position = v2(W - FADE, shared), size = v2(FADE, bgH) }, false, true)
            end
            pieces[#pieces + 1] = image(TEX.bottom,
                { position = v2(edge, H - FADE), size = v2(W - edge - FADE, FADE) }, true, false)
            pieces[#pieces + 1] = image(TEX.corner,
                { position = v2(W - FADE, H - FADE), size = v2(FADE, FADE) })
        end
        pieces[#pieces + 1] = image(TEX.left, { size = v2(edge, H) }, false, true)
    elseif hang > 0 then
        pieces[#pieces + 1] = {
            type = ui.TYPE.Image,
            props = {
                resource = barTexture, color = util.color.rgb(0, 0, 0), alpha = 0.67,
                position = v2(0, shared), size = v2(W, hang),
            },
        }
    end
    return pieces
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
    local order, byTopic, disposition, extra = evaluate(currentActor)
    if #order == 0 then return end

    -- Rows, top to bottom. Each is a layout that gets an absolute position.
    local rows = { text('Requirements', HEADER), text('Disposition: ' .. disposition, HEADER) }
    for _, topic in ipairs(order) do
        local t = byTopic[topic]
        if t.revealed or CONFIG.unrevealedTopics == 'show' then
            rows[#rows + 1] = text(topic, NORMAL)
            for _, lines in ipairs(t) do
                for _, l in ipairs(lines) do
                    rows[#rows + 1] = text('   ' .. l.text, l.note and HINT or (l.met and MET or UNMET))
                end
            end
        elseif CONFIG.blurStyle == 'smear' then
            rows[#rows + 1] = smear(topic, NORMAL)
            for _, l in ipairs(t[1]) do
                rows[#rows + 1] = smear('   ' .. l.text, NORMAL)
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
    if extra > 0 then rows[#rows + 1] = text(string.format('+ %d more', extra), HINT) end

    local real = ui.screenSize()
    local screen = v2(real.x / CONFIG.guiScale, real.y / CONFIG.guiScale)
    local W = math.floor(screen.x * CONFIG.columnWidth)
    local rowH = CONFIG.textSize
    local H = CONFIG.padY * 2 + #rows * rowH
    local top = math.floor(screen.y * CONFIG.panelTop)
    top = math.max(0, math.min(top, screen.y - H)) -- keep it on screen
    local shared = math.max(0, math.min(H, math.floor(screen.y * CONFIG.columnBottom) - top))

    local content = ui.content(backgroundPieces(W, H, shared))
    for i, row in ipairs(rows) do
        row.props = row.props or {}
        row.props.position = v2(CONFIG.textInset, CONFIG.padY + (i - 1) * rowH)
        content:add(row)
    end

    panel = ui.create {
        layer = 'Windows',
        props = {
            position = v2(math.floor(screen.x * CONFIG.columnX), top),
            size = v2(W, H),
        },
        content = content,
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
                        wordsLeft = 20000
                        scanText(info.text)
                        break
                    end
                end
            end
        end)
    end
    if panel or currentActor then safeRefresh() end
end

-- Build the index in its own engine call (load / new game) instead of during the
-- first dialogue, so no single call has to do all the work.
local function prebuild()
    if index then return end
    local ok, err = pcall(buildIndex)
    if not ok then
        index = nil
        print('[SpeechGates] index build failed: ' .. tostring(err))
    end
end

local function onInit()
    prebuild()
end

local function onSave()
    return { learned = learned }
end

local function onLoad(data)
    learned = data and data.learned or {}
    seeded = false
    prebuild()
end

return {
    engineHandlers = { onInit = onInit, onSave = onSave, onLoad = onLoad },
    eventHandlers = {
        UiModeChanged = onUiModeChanged,
        DialogueResponse = onDialogueResponse,
    },
}
