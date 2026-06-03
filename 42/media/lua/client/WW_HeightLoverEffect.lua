-- 42/media/lua/client/WW_HeightLoverEffect.lua
-- HeightLover: boredom-only logic (Stats + BodyDamage sync, safe logging)

local HL = {
    -- B42: новый движковый трейт нельзя создать одним character_trait_definition
    -- (объект CharacterTrait должен быть в реестре). Поэтому эффект включается по
    -- ПРОФЕССИИ "Window Washer". Сопоставление по нормализованному имени профессии:
    -- getName() в B42 — ResourceLocation-производная (lowercase), может вернуть
    -- "ww:windowwasher" или "windowwasher"; нормализуем и ищем подстроку.
    ProfMatch       = "windowwasher",
    Tier2Z          = 7,
    TickEveryFrames = 180,        -- ~3 сек при 60 FPS

    -- Инерция синхронизации boredomLevel (ед/мин):
    LevelRisePerMin = 40.0,       -- насколько быстро подъём догоняет цель
    LevelFallPerMin = 20.0,       -- насколько быстро спад догоняет цель

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
local function clamp01(x) if x < 0 then return 0 elseif x > 100 then return 100 end return x end

-- B42: у Stats больше НЕТ boredom-методов (boredom переехал в BodyDamage с другим
-- rate-based API). Старые Stats:getBoredom/setBoredom и BodyDamage:get/setBoredomLevel
-- отсутствуют. Безопасные обёртки: вызываем метод только если он есть, иначе no-op/nil.
-- Это держит эффект «живым» (детект + логи) без краша. Полная миграция boredom-механики
-- на BodyDamage-API B42 — отдельная стадия.
local function sGetBoredom(s)   if s  and s.getBoredom       then return s:getBoredom()       end return nil end
local function sSetBoredom(s,v) if s  and s.setBoredom       then s:setBoredom(v)             end end
local function bdGetLevel(bd)   if bd and bd.getBoredomLevel then return bd:getBoredomLevel() end return nil end

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

-- Мгновенная очистка на высоте (обе шкалы)
local function onHeightPulse(p)
    local s = p and p:getStats()
    local bd = p and p:getBodyDamage()
    sSetBoredom(s, 0)
    if bd and bd.setBoredomLevel then bd:setBoredomLevel(0) end
    md(p).lastHeightH = worldHours()
    log("height z=%d: boredom -> 0, boredomLevel -> 0", p:getZ() or -1)
end

-- Притяжение boredomLevel к целевому Stats.boredom с инерцией.
-- dtMin — прошедшие минуты; up/down ограничивают скорость изменения level.
local function syncBoredomLevelToStats(p, target, dtMin)
    local bd = p and p:getBodyDamage()
    if not (bd and bd.getBoredomLevel and bd.setBoredomLevel) then return end
    local cur = bd:getBoredomLevel() or 0
    local delta = (target or 0) - cur
    if delta == 0 then return end

    local rate = (delta > 0) and (HL.LevelRisePerMin or 40.0) or (HL.LevelFallPerMin or 20.0)
    local step = rate * math.max(0, dtMin or 0)
    local new
    if delta > 0 then
        new = (math.abs(delta) <= step) and target or (cur + step)
    else
        new = (math.abs(delta) <= step) and target or (cur - step)
    end
    bd:setBoredomLevel(clamp01(new))
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
    local s  = p:getStats()

    -- На высоте — мгновенная очистка
    if isTier2(p) then
        onHeightPulse(p)
        if HL.Debug.enabled and (_dbgTickAcc % (HL.Debug.statusEvery or 10) == 0) then
            log("status: on height z=%d, boredom=%.1f, level=%.1f",
                p:getZ() or -1,
                sGetBoredom(s) or -1,
                bdGetLevel(p:getBodyDamage()) or -1)
        end
        return
    end

    -- Внизу — растим Stats.boredom и подтягиваем BodyDamage.boredomLevel
    local hoursAway  = math.max(0, nowH - (m.lastHeightH or nowH))
    local daysAway   = hoursAway / 24.0
    local ratePerMin = boredomPerMinute(daysAway)

    if s and ratePerMin > 0 then
        local add = ratePerMin * dtMin
        local cur = sGetBoredom(s) or 0
        local target = clamp01(cur + add)
        sSetBoredom(s, target)
        syncBoredomLevelToStats(p, target, dtMin)

        log("tick: z=%d days=%.2f rate=%.3f/min dt=%.2fmin  boredom %.1f->%.1f  level->%.1f",
            p:getZ() or -1, daysAway, ratePerMin, dtMin,
            cur, target,
            bdGetLevel(p:getBodyDamage()) or -1)
    elseif HL.Debug.enabled and (_dbgTickAcc % (HL.Debug.statusEvery or 10) == 0) then
        log("status: days=%.2f no-gain (z=%d, boredom=%.1f, level=%.1f)",
            daysAway, p:getZ() or -1,
            sGetBoredom(s) or -1,
            bdGetLevel(p:getBodyDamage()) or -1)
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
