-- 42/media/lua/client/WW_HeightLoverEffect.lua
-- HeightLover: boredom-механика на B42-API (CharacterStat.BOREDOM via Stats:get/set).
-- На высоте (z>=Tier2Z) скука обнуляется; внизу растёт по дням без высоты.

local HL = {
    -- B42: новый движковый трейт нельзя создать одним character_trait_definition
    -- (объект CharacterTrait должен быть в реестре). Поэтому эффект включается по
    -- ПРОФЕССИИ "Window Washer". Сопоставление по нормализованному имени профессии:
    -- getName() в B42 — ResourceLocation-производная (lowercase), может вернуть
    -- "ww:windowwasher" или "windowwasher"; нормализуем и ищем подстроку.
    ProfMatch       = "windowwasher",
    Tier2Z          = 7,
    TickEveryFrames = 180,        -- ~3 сек при 60 FPS

    Debug = { enabled = true, tag = "[HL]", statusEvery = 10 },
}

-- --- logging ----------------------------------------------------------------
local _dbgTickAcc = 0
local function log(fmt, ...)
    local D = HL.Debug
    if not (D and D.enabled) then return end
    local ok, msg = pcall(string.format, (D.tag or "[HL]").." "..tostring(fmt), ...)
    print(ok and msg or ((D.tag or "[HL]").." (format-error) "..tostring(fmt)))
end
rawset(_G, "WW_HL_DebugToggle", function()
    HL.Debug.enabled = not HL.Debug.enabled
    print(string.format("%s debug = %s", HL.Debug.tag or "[HL]", tostring(HL.Debug.enabled)))
end)

-- --- utils ------------------------------------------------------------------
-- Имя профессии игрока (B42): p:getDescriptor():getCharacterProfession():getName().
-- Нормализуем (убираем не-буквенно-цифровые, в нижний регистр), чтобы матч был
-- устойчив к формату "ww:windowwasher" / "windowwasher" / возможной локализации.
-- Возвращает true/false если профессию удалось прочитать, иначе nil ("не знаю").
local function professionMatches(p, needle)
    if not p then return nil end
    local ok, name = pcall(function()
        local d = p:getDescriptor()
        local prof = d and d:getCharacterProfession()
        return prof and prof:getName() or nil
    end)
    if not (ok and name) then return nil end
    return (tostring(name):gsub("%W", ""):lower()):find(needle, 1, true) ~= nil
end

-- Кэшируем в ModData только ОПРЕДЕЛЁННЫЙ результат (профессия за игру не меняется);
-- временный nil (дескриптор ещё не готов) не кэшируем, чтобы не выключить эффект навсегда.
local function isWindowWasher(p)
    if not p then return false end
    local m = p:getModData(); m.WW = m.WW or {}
    if m.WW.isWW == nil then
        local r = professionMatches(p, HL.ProfMatch)
        if r == nil then return false end
        m.WW.isWW = r
    end
    return m.WW.isWW == true
end

local function worldHours() return getGameTime():getWorldAgeHours() end
local function isTier2(p) return p and (p:getZ() or 0) >= (HL.Tier2Z or 7) end

-- B42 boredom-API (сверено с jar rev 964): boredom — это CharacterStat.BOREDOM (0..100),
-- читается/пишется generic-методами Stats:get/set(CharacterStat, value) (как в ванильном
-- DebugUIs/.../ISStatsAndBody.lua). Старых Stats:get/setBoredom и BodyDamage:get/setBoredomLevel
-- из B41 НЕТ. Резолвим стат и его диапазон один раз, с защитой на случай раннего/иного загруза.
local BOREDOM, B_MIN, B_MAX
do
    local ok = pcall(function()
        if CharacterStat and CharacterStat.BOREDOM then
            BOREDOM = CharacterStat.BOREDOM
            B_MIN = BOREDOM:getMinimumValue()
            B_MAX = BOREDOM:getMaximumValue()
        end
    end)
    if not (ok and BOREDOM) then BOREDOM = nil end
    B_MIN = B_MIN or 0
    B_MAX = B_MAX or 100
end

local function clampB(x) if x < B_MIN then return B_MIN elseif x > B_MAX then return B_MAX end return x end

-- Чтение/запись boredom через Stats (в MP — досылаем стат на сервер, как ванильный код).
local function getBoredom(p)
    if not (p and BOREDOM) then return nil end
    local ok, v = pcall(function() return p:getStats():get(BOREDOM) end)
    return ok and v or nil
end
local function setBoredom(p, v)
    if not (p and BOREDOM) then return end
    pcall(function()
        p:getStats():set(BOREDOM, clampB(v))
        if isClient and isClient() then sendPlayerStat(p, BOREDOM) end
    end)
end

-- Нелинейное накопление скуки (ед/мин) по дням без высоты
local function boredomPerMinute(daysWithout)
    local d = math.max(0, math.floor(daysWithout or 0))
    -- (подгони числа под баланс; сейчас агрессивнее для тестов)
    if d <= 1 then return 0.05 end
    if d == 2 then return 0.10 end
    if d == 3 then return 0.20 end
    if d == 4 then return 0.30 end
    local base, peak = 0.50, 3.00
    local t = math.min(1.0, (d - 5) / 9)
    return base + (peak - base) * t
end

-- ModData
local function md(p) local m=p:getModData(); m.WW=m.WW or {}; m.WW.HL=m.WW.HL or {}; return m.WW.HL end
local function initIfNeeded(p)
    local m = md(p); if m._init then return end
    local now = worldHours()
    m.lastHeightH, m.lastUpdateH, m._init = now, now, true
    log("init: lastHeightH=%.2fh z=%d", now, p and p:getZ() or -1)
end

-- Мгновенная очистка скуки на высоте (мойщик окон обожает высоту).
local function onHeightPulse(p)
    setBoredom(p, B_MIN)
    md(p).lastHeightH = worldHours()
    log("height z=%d: boredom -> %.1f", p:getZ() or -1, B_MIN)
end

-- --- tick -------------------------------------------------------------------
local frameAcc = 0
local function HL_OnTick()
    local p = getPlayer(); if not p or not isWindowWasher(p) then return end
    frameAcc = frameAcc + 1; if frameAcc < (HL.TickEveryFrames or 180) then return end
    frameAcc, _dbgTickAcc = 0, _dbgTickAcc + 1

    initIfNeeded(p)

    local m    = md(p)
    local nowH = worldHours()
    local dtH  = math.max(0, nowH - (m.lastUpdateH or nowH))
    m.lastUpdateH = nowH
    if dtH <= 0 then return end

    local dtMin = dtH * 60.0

    -- На высоте — мгновенная очистка
    if isTier2(p) then
        onHeightPulse(p)
        if HL.Debug.enabled and (_dbgTickAcc % (HL.Debug.statusEvery or 10) == 0) then
            log("status: on height z=%d, boredom=%.1f",
                p:getZ() or -1, getBoredom(p) or -1)
        end
        return
    end

    -- Внизу — растим boredom (CharacterStat.BOREDOM) по дням без высоты
    local hoursAway  = math.max(0, nowH - (m.lastHeightH or nowH))
    local daysAway   = hoursAway / 24.0
    local ratePerMin = boredomPerMinute(daysAway)

    if BOREDOM and ratePerMin > 0 then
        local add    = ratePerMin * dtMin
        local cur    = getBoredom(p) or 0
        local target = clampB(cur + add)
        setBoredom(p, target)

        log("tick: z=%d days=%.2f rate=%.3f/min dt=%.2fmin  boredom %.1f->%.1f",
            p:getZ() or -1, daysAway, ratePerMin, dtMin, cur, target)
    elseif HL.Debug.enabled and (_dbgTickAcc % (HL.Debug.statusEvery or 10) == 0) then
        log("status: days=%.2f no-gain (z=%d, boredom=%.1f)",
            daysAway, p:getZ() or -1, getBoredom(p) or -1)
    end
end

local function HL_OnCreatePlayer(_, p)
    if not p then return end
    local isWW = isWindowWasher(p)
    log("OnCreatePlayer: isWindowWasher=%s", tostring(isWW))
    if isWW then initIfNeeded(p) end
end
Events.OnTick.Add(HL_OnTick)
Events.OnCreatePlayer.Add(HL_OnCreatePlayer)
