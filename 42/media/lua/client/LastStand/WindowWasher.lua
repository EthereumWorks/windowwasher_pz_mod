-- deps
if not ISBaseTimedAction  then require "TimedActions/ISBaseTimedAction"  end
if not ISTimedActionQueue then require "TimedActions/ISTimedActionQueue" end
if not ISContextMenu     then require "ISUI/ISContextMenu"              end

WindowWasher = {}

WindowWasher.Add = function()
    addChallenge(WindowWasher);
end

WindowWasher.debug           = WindowWasher.debug or {}

-- ==== DEBUG: blood splats logging ===============
WindowWasher.debug.blood = true
local function WW_logBlood(fmt, ...)
    if WindowWasher.debug and WindowWasher.debug.blood then
        local ok, msg = pcall(string.format, "[WW/BLOOD] " .. tostring(fmt), ...)
        print(ok and msg or ("[WW/BLOOD] (format-error) "..tostring(fmt)))
    end
end

-- ==== DEBUG: dead bodies logging =================================================
WindowWasher.debug.dead      = true   -- включить/выключить подробные логи по трупам
local function WW_logDead(fmt, ...)
    if WindowWasher.debug and WindowWasher.debug.dead then
        -- Важное отличие: передаём varargs прямо в pcall на string.format,
        -- без вложенной анонимной функции -> нет захвата `...`
        local ok, msg = pcall(string.format, "[WW/DEAD] " .. tostring(fmt), ...)
        if ok and msg then
            print(msg)
        else
            -- если формат / аргументы не совпали — не падаем, а пишем безопасно
            print("[WW/DEAD] (format-error) " .. tostring(fmt))
        end
    end
end


local function sqStr(sq)
    if not sq then return "(nil)" end
    local okx, x = pcall(function() return sq:getX() end)
    local oky, y = pcall(function() return sq:getY() end)
    local okz, z = pcall(function() return sq:getZ() end)
    return string.format("(%s,%s,%s)", tostring(okx and x or "?"), tostring(oky and y or "?"), tostring(okz and z or "?"))
end

local function bodyStr(body)
    if not body then return "nil" end
    local tag = tostring(body) -- например "IsoDeadBody(....)"
    -- попробуем вытащить что-то уникальное, если доступно
    local oid = nil
    pcall(function() oid = body.getOnlineID and body:getOnlineID() end)
    if oid and oid ~= -1 then tag = tag .. "#oid=" .. tostring(oid) end
    return tag
end
-- ================================================================================


-- ====== ПЕРИЛА (НАСТРОЙКА СПРАЙТОВ) ==========================================


-- ЗАМЕНИ эти два значения на нужные тайлы из TileZed (низкий забор/перила):
WindowWasher.rails = {
    enabled = true,                   -- можно выключить перила, не меняя код
    N = "construction_01_32",         -- спрайт для стены по стороне North
    W = "construction_01_38",         -- спрайт для стены по стороне West
}

-- Какая сторона считается «наружной»:
-- для платформы вдоль X (EW): "N" (север/к стене сверху) или "S" (юг/вниз, обычно внешняя)
-- для платформы вдоль Y (NS): "W" (запад/влево) или "E" (восток/вправо, часто внешняя)
WindowWasher.railsOuterSide = {
    EW = "S",   -- обычно у тебя стена сверху, а внешняя кромка снизу → "S"
    NS = "E",   -- если нужно с другой стороны, поставь "W"
}

-- единая логика на смерть
function WindowWasher._onDeath(player)
    WindowWasher.ps.moving = false
    print(string.format("WindowWasher: player died at %s,%s,%s",
    tostring(WindowWasher.ps.cx), tostring(WindowWasher.ps.cy), tostring(WindowWasher.ps.cz)))
end

-- адаптер: сработает и при вызове WindowWasher.onPlayerDeath(player),
-- и при вызове WindowWasher:onPlayerDeath(player) (через двоеточие)
function WindowWasher.onPlayerDeath(a, b)
    local player = b or a
    WindowWasher._onDeath(player)
end

-- ===== Basic variables =====
local delayTicks = 0
local initialized = false

-- ===== Platform state & params =====
WindowWasher.ps = {
    cx = nil, cy = nil, cz = nil,          -- current center
    size = 6,                              -- odd: 3/5/7
    orient = "EW",                         -- "EW" or "NS"
    sprite = "constructedobjects_01_86",   -- metal floor sprite
    objs = {},                             -- created floor objects (to remove)
    railObjs = {},                         -- созданные объекты перил (стены)
    moving = false,
    moveDuration = 0.5                     -- seconds (UX)
}

-- ===== Sandbox config =====
WindowWasher.OnInitWorld = function()

    SandboxVars.Zombies = 3;
    SandboxVars.Distribution = 1;
    SandboxVars.DayLength = 3;
    SandboxVars.StartMonth = 7;
    SandboxVars.StartDay = 9;
    SandboxVars.StartTime = 1;

    SandboxVars.WaterShut = 2; SandboxVars.WaterShutModifier = 14;
    SandboxVars.ElecShut  = 2; SandboxVars.ElecShutModifier  = 14;

    SandboxVars.FoodLoot = 4; SandboxVars.CannedFoodLoot = 4;
    SandboxVars.RangedWeaponLoot = 3; SandboxVars.AmmoLoot = 4;
    SandboxVars.SurvivalGearsLoot = 3; SandboxVars.MechanicsLoot = 5;
    SandboxVars.LiteratureLoot = 4; SandboxVars.MedicalLoot = 4;
    SandboxVars.WeaponLoot = 4; SandboxVars.OtherLoot = 4;
    SandboxVars.LootItemRemovalList = "";
    SandboxVars.Temperature = 3; SandboxVars.Rain = 3;
    SandboxVars.ErosionSpeed = 3
    SandboxVars.Farming = 3; SandboxVars.NatureAbundance = 3;
    SandboxVars.PlantResilience = 3; SandboxVars.PlantAbundance = 3;
    SandboxVars.Alarm = 3; SandboxVars.LockedHouses = 3;
    SandboxVars.FoodRotSpeed = 4; SandboxVars.FridgeFactor = 4;
    SandboxVars.LootRespawn = 1; SandboxVars.StatsDecrease = 3;
    SandboxVars.StarterKit = false; SandboxVars.TimeSinceApo = 1;
    SandboxVars.MultiHitZombies = false;

    SandboxVars.MultiplierConfig = { XPMultiplierGlobal = 1, XPMultiplierGlobalToggle = true, }
    SandboxVars.ZombieConfig.PopulationMultiplier = ZombiePopulationMultiplier.Insane

    print ("Set to :" .. WindowWasher.x .. ", "..WindowWasher.y..", ".. WindowWasher.z)

    Events.OnGameStart.Add(WindowWasher.OnGameStart);
end

function WindowWasher.OnGameStart()
    if not WindowWasher._deathHooked then
        Events.OnPlayerDeath.Add(function(player) WindowWasher._onDeath(player) end)
        WindowWasher._deathHooked = true
    end

    local ls = _G.LastStandData
    if ls then
        local gm = getCore():getGameMode()
        local obj = ls[gm]
        if obj and type(obj.onPlayerDeath) ~= "function" then
            obj.onPlayerDeath = function(self, player)
                WindowWasher._onDeath(player)
            end
            print("WindowWasher: patched LastStandData.onPlayerDeath")
        end
    end
end

-- вместо "half" будем везде считать left/right
local function WW_spanLR(sz)
    sz = math.max(1, tonumber(sz) or 5)
    local left  = math.floor((sz - 1) / 2)   -- сколько тайлов уйдёт в «минус»
    local right = sz - left - 1              -- сколько тайлов уйдёт в «плюс»
    return left, right, sz
end

-- ===== Floor placement (single tile) =====
function WindowWasher.createSingleMetalFloor(x, y, z)
    local sq = getSquare(x, y, z)
    if not sq then return nil end
    local obj = sq:addFloor(WindowWasher.ps.sprite)  -- place REAL floor
    if obj then
        obj:setName("WindowWasher Platform")
        sq:RecalcAllWithNeighbours(true)
        return obj
    end
    return nil
end

-- ====== ПЕРИЛА: утилиты (БЕЗ addWallN/W) ====================================

-- Общий конструктор тайл-объекта по имени спрайта
local function addRailSpriteAt(x, y, z, spriteName, label)
    if not spriteName or spriteName == "" then return nil end
    local sq = getSquare(x, y, z); if not sq then return nil end
    local cell = getWorld():getCell()

    -- ВАЖНО: именно (cell, sq, "tileset_index")
    local obj = IsoObject.new(cell, sq, tostring(spriteName))
    if not obj then return nil end

    if label then obj:setName(label) end
    sq:AddTileObject(obj)                     -- ставим объект на клетку
    sq:RecalcAllWithNeighbours(true)
    table.insert(WindowWasher.ps.railObjs, obj)
    return obj
end

-- Перила по северной грани клетки (используем спрайт с флагами WallN)
local function addFenceN(x, y, z)
    return addRailSpriteAt(x, y, z, WindowWasher.rails.N, "WW Rail N")
end

-- Перила по западной грани клетки (спрайт с флагами WallW)
local function addFenceW(x, y, z)
    return addRailSpriteAt(x, y, z, WindowWasher.rails.W, "WW Rail W")
end

-- Торцевые перила (заглушки)
function WindowWasher.buildRailsCaps(cx, cy, cz)
    if not (WindowWasher.rails and WindowWasher.rails.enabled) then return end
    local left, right = WW_spanLR(WindowWasher.ps.size)

    if WindowWasher.ps.orient == "EW" then
        addFenceW(cx - left,     cy, cz)     -- западный торец
        addFenceW(cx + right + 1, cy, cz)    -- восточный торец как «W» у соседа справа
    else
        addFenceN(cx, cy - left,     cz)     -- северный торец
        addFenceN(cx, cy + right + 1, cz)    -- южный торец как «N» у соседа снизу
    end
end

function WindowWasher.destroyRails()
    for _, obj in ipairs(WindowWasher.ps.railObjs) do
        if obj then
            local sq = obj:getSquare()
            if sq then
                -- RemoveTileObject корректно удаляет то, что добавили через AddTileObject
                sq:RemoveTileObject(obj)
                sq:RecalcAllWithNeighbours(true)
            end
        end
    end
    WindowWasher.ps.railObjs = {}
end

-- Ставим перила вдоль длинных сторон платформы
function WindowWasher.buildRailsAlongLine(cx, cy, cz)
    if not (WindowWasher.rails and WindowWasher.rails.enabled) then return end
    local left, right = WW_spanLR(WindowWasher.ps.size)

    if WindowWasher.ps.orient == "EW" then
        local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.EW) or "S"
        for x = cx - left, cx + right do
            if side == "N" then
                addFenceN(x, cy, cz)
            else
                addFenceN(x, cy + 1, cz) -- S = север соседа снизу
            end
        end
    else
        local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.NS) or "E"
        for y = cy - left, cy + right do
            if side == "W" then
                addFenceW(cx, y, cz)
            else
                addFenceW(cx + 1, y, cz) -- E = запад соседа справа
            end
        end
    end
end


-- ===== Platform build / remove =====
function WindowWasher.destroyPlatform()
    -- пол
    for _, obj in ipairs(WindowWasher.ps.objs) do
        local sq = obj and obj:getSquare()
        if sq and obj then
            sq:DeleteTileObject(obj)
            sq:RecalcAllWithNeighbours(true)
        end
    end
    WindowWasher.ps.objs = {}
    -- перила
    WindowWasher.destroyRails()
end

function WindowWasher.buildPlatformAt(cx, cy, cz)
    WindowWasher.ps.cx, WindowWasher.ps.cy, WindowWasher.ps.cz = cx, cy, cz
    WindowWasher.ps.objs = {}
    local left, right = WW_spanLR(WindowWasher.ps.size)

    if WindowWasher.ps.orient == "NS" then
        for i = -left, right do
            local obj = WindowWasher.createSingleMetalFloor(cx, cy + i, cz)
            if obj then table.insert(WindowWasher.ps.objs, obj) end
        end
    else
        for i = -left, right do
            local obj = WindowWasher.createSingleMetalFloor(cx + i, cy, cz)
            if obj then table.insert(WindowWasher.ps.objs, obj) end
        end
    end

    WindowWasher.buildRailsAlongLine(cx, cy, cz)
    WindowWasher.buildRailsCaps(cx, cy, cz)
end

-- совместимость с прежним API
function WindowWasher.createPlatform(cx, cy, cz, size, orient)
    WindowWasher.ps.size   = size   or WindowWasher.ps.size
    WindowWasher.ps.orient = orient or WindowWasher.ps.orient
    WindowWasher.buildPlatformAt(cx, cy, cz)
end

-- Проверка: все целевые квадраты загружены (учитываем и клетки для перил)
local function squaresExistFor(cx, cy, cz, size, orient)
    local left, right = WW_spanLR(size)
    if orient == "NS" then
        local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.NS) or "E"
        for y = cy - left, cy + right do
            if not getSquare(cx, y, cz) then return false end              -- пол
            if side == "W" then
                if not getSquare(cx, y, cz) then return false end          -- перила на самой клетке
            else
                if not getSquare(cx + 1, y, cz) then return false end      -- перила на соседе справа
            end
        end
        if not getSquare(cx, cy - left,     cz) then return false end      -- северный торец
        if not getSquare(cx, cy + right + 1, cz) then return false end     -- южный торец (сосед снизу)
    else
        local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.EW) or "S"
        for x = cx - left, cx + right do
            if not getSquare(x, cy, cz) then return false end              -- пол
            if side == "N" then
                if not getSquare(x, cy, cz) then return false end          -- перила на самой клетке
            else
                if not getSquare(x, cy + 1, cz) then return false end      -- перила на соседе снизу
            end
        end
        if not getSquare(cx - left,     cy, cz) then return false end      -- западный торец
        if not getSquare(cx + right + 1, cy, cz) then return false end     -- восточный торец (сосед справа)
    end
    return true
end

-- Клетки, на которых лежит настил платформы (без перил)
local function getPlatformSquares(cx, cy, cz, size, orient)
    local list = {}
    local left, right = WW_spanLR(size)
    if orient == "EW" then
        for x = cx - left, cx + right do
            local sq = getSquare(x, cy, cz)
            if sq then table.insert(list, sq) end
        end
    else
        for y = cy - left, cy + right do
            local sq = getSquare(cx, y, cz)
            if sq then table.insert(list, sq) end
        end
    end
    return list
end

-- Перенос мировых предметов (IsoWorldInventoryObject) из sqFrom -> sqTo
-- ВАЖНО: не вызывать item:setWorldItem(nil) !
local function moveWorldItems(sqFrom, sqTo)
    if not (sqFrom and sqTo) then return end
    local wos = sqFrom:getWorldObjects()
    if not wos then return end

    for i = wos:size()-1, 0, -1 do
        local wio = wos:get(i)
        if wio and wio.getItem then
            local item = wio:getItem()
            if item then
                -- cохраняем оффсеты, падать не даём
                local okX, ox = pcall(function() return wio:getOffsetX() end); ox = (okX and ox) or 0.5
                local okY, oy = pcall(function() return wio:getOffsetY() end); oy = (okY and oy) or 0.5
                -- z у AddWorldInventoryItem – это "визуальная" высота, ставим 0 точно числом
                local oz = 0

                -- аккуратно убираем старый world-object (НЕ трогаем item:setWorldItem)
                if wio.removeFromSquare then pcall(function() wio:removeFromSquare() end) end
                if sqFrom.RemoveWorldObject then pcall(function() sqFrom:RemoveWorldObject(wio) end) end
                if wio.removeFromWorld then pcall(function() wio:removeFromWorld() end) end

                -- кладём тот же InventoryItem в новую клетку
                sqTo:AddWorldInventoryItem(item, ox, oy, oz)
            end
        end
    end
end


-- Осторожный перенос трупов (IsoDeadBody) для B42: явный setSquare + явное добавление в списки
local function moveDeadBodies(sqFrom, sqTo, targetZ)
    if not (sqFrom and sqTo) then
        WW_logDead("ABORT: moveDeadBodies bad squares from=%s to=%s", sqStr(sqFrom), sqStr(sqTo))
        return
    end

    WW_logDead("BEGIN moveDeadBodies from %s -> %s targetZ=%s", sqStr(sqFrom), sqStr(sqTo), tostring(targetZ))

    local collected, seen = {}, {}
    local listA = sqFrom.getDeadBodys and sqFrom:getDeadBodys() or nil
    local listB = sqFrom.getStaticMovingObjects and sqFrom:getStaticMovingObjects() or nil
    WW_logDead("Scan from-square: deadBodys=%s, staticMoving=%s",
        tostring(listA and listA:size() or 0), tostring(listB and listB:size() or 0))

    if listA then
        for i=listA:size()-1,0,-1 do
            local b = listA:get(i)
            if b and instanceof(b,"IsoDeadBody") and not seen[b] then seen[b]=true; table.insert(collected,b) end
        end
    end
    if listB then
        for i=listB:size()-1,0,-1 do
            local mo = listB:get(i)
            if mo and instanceof(mo,"IsoDeadBody") and not seen[mo] then seen[mo]=true; table.insert(collected,mo) end
        end
    end

    WW_logDead("Collected unique bodies to move: %d", #collected)

    local function ensureListContains(list, obj, listName)
        if not list then return false end
        local okHas, has = pcall(function() return list:contains(obj) end)
        if okHas and not has then
            local okAdd = pcall(function() list:add(obj) end)
            WW_logDead("  ensure in %s: %s", listName, okAdd and "ADDED" or "ADD-ERR")
            return okAdd
        end
        WW_logDead("  ensure in %s: already", listName)
        return okHas and has
    end

    for _, body in ipairs(collected) do
        local tag = bodyStr(body)

        -- Если уже перенесён кем-то другим — пропустим
        local curSq = nil; pcall(function() curSq = body:getSquare() end)
        if curSq ~= sqFrom then
            WW_logDead("SKIP %s: current square is %s, expected %s", tag, sqStr(curSq), sqStr(sqFrom))
        else
            local bx, by, bz = nil, nil, nil
            pcall(function() bx,by,bz = body:getX(), body:getY(), body:getZ() end)
            local onFloor = nil; pcall(function() onFloor = body.isOnFloor and body:isOnFloor() end)
            WW_logDead("Move %s | before pos=(%s,%s,%s) onFloor=%s", tag,tostring(bx),tostring(by),tostring(bz),tostring(onFloor))

            -- 1) вытащить из старой клетки (НЕ removeFromWorld)
            local ok_rm = pcall(function() if body.removeFromSquare then body:removeFromSquare() end end)
            WW_logDead("  removeFromSquare: %s", ok_rm and "OK" or "ERR")

            -- 2) позиция под целевую клетку
            local nx, ny, nz = (sqTo:getX()+0.5), (sqTo:getY()+0.5), targetZ
            local ok_pos = pcall(function()
                if body.setX then body:setX(nx) end
                if body.setY then body:setY(ny) end
                if body.setZ then body:setZ(nz) end
            end)
            WW_logDead("  set pos -> (%s,%s,%s): %s", tostring(nx), tostring(ny), tostring(nz), ok_pos and "OK" or "ERR")

            -- 3) КРИТИЧНО: для IsoDeadBody делаем ЯВНО setSquare
            local ok_setSq = pcall(function() if body.setSquare then body:setSquare(sqTo) end end)
            WW_logDead("  setSquare(sqTo): %s", ok_setSq and "OK" or "ERR")

            -- 4) Гарантируем принадлежность спискам клетки
            local dlTo = sqTo.getDeadBodys and sqTo:getDeadBodys() or nil
            local slTo = sqTo.getStaticMovingObjects and sqTo:getStaticMovingObjects() or nil
            ensureListContains(dlTo, body, "sqTo:getDeadBodys()")
            ensureListContains(slTo, body, "sqTo:getStaticMovingObjects()")

            -- 5) Вернуть в мир при необходимости
            if body.isAddedToWorld and not body:isAddedToWorld() then
                local ok_world = pcall(function() if body.addToWorld then body:addToWorld() end end)
                WW_logDead("  addToWorld (needed): %s", ok_world and "OK" or "ERR")
            else
                WW_logDead("  addToWorld not needed")
            end

            -- 6) Стабилизация
            local ok_stab = pcall(function()
                if body.setLx then body:setLx(nx) end
                if body.setLy then body:setLy(ny) end
                if body.setLz then body:setLz(nz) end
                if body.setOnFloor then body:setOnFloor(true) end
            end)
            WW_logDead("  stabilize last coords + setOnFloor(true): %s", ok_stab and "OK" or "ERR")

            if sqTo.RecalcAllWithNeighbours then sqTo:RecalcAllWithNeighbours(true) end

            -- 7) Проверка результата
            local nowSq = nil; pcall(function() nowSq = body:getSquare() end)
            local inDead = dlTo and dlTo:contains(body) or false
            local inStat = slTo and slTo:contains(body) or false
            local fx, fy, fz = nil, nil, nil
            pcall(function() fx,fy,fz = body:getX(), body:getY(), body:getZ() end)

            WW_logDead("  verify -> square=%s | inDead=%s (sz=%s), inStatic=%s (sz=%s)",
                sqStr(nowSq), tostring(inDead), tostring(dlTo and dlTo:size() or "nil"),
                tostring(inStat), tostring(slTo and slTo:size() or "nil"))

            -- 8) ЖЁСТКИЙ фолбек, если всё ещё не прикрепился
            if (nowSq ~= sqTo) or ((not inDead) and (not inStat)) then
                WW_logDead("  FALLBACK: force rebind")
                pcall(function() if body.removeFromWorld then body:removeFromWorld() end end)
                pcall(function() if body.removeFromSquare then body:removeFromSquare() end end)
                pcall(function()
                    if body.setX then body:setX(nx) end
                    if body.setY then body:setY(ny) end
                    if body.setZ then body:setZ(nz) end
                    if body.setSquare then body:setSquare(sqTo) end
                end)
                -- повторно гарантируем списки
                dlTo = sqTo.getDeadBodys and sqTo:getDeadBodys() or dlTo
                slTo = sqTo.getStaticMovingObjects and sqTo:getStaticMovingObjects() or slTo
                ensureListContains(dlTo, body, "sqTo:getDeadBodys()")
                ensureListContains(slTo, body, "sqTo:getStaticMovingObjects()")
                pcall(function() if body.addToWorld then body:addToWorld() end end)
                if sqTo.RecalcAllWithNeighbours then sqTo:RecalcAllWithNeighbours(true) end
            end

            -- финальный снимок
            pcall(function() nowSq = body:getSquare() end)
            pcall(function() fx,fy,fz = body:getX(), body:getY(), body:getZ() end)
            inDead = dlTo and dlTo:contains(body) or false
            inStat = slTo and slTo:contains(body) or false
            WW_logDead("DONE %s | after pos=(%s,%s,%s) square=%s | deadList=%s, staticList=%s",
                tag, tostring(fx), tostring(fy), tostring(fz), sqStr(nowSq), tostring(inDead), tostring(inStat))
        end
    end

    local dl = sqTo.getDeadBodys and sqTo:getDeadBodys() or nil
    local sl = sqTo.getStaticMovingObjects and sqTo:getStaticMovingObjects() or nil
    WW_logDead("END moveDeadBodies -> to %s: deadBodys=%s, staticMoving=%s",
        sqStr(sqTo), tostring(dl and dl:size() or "nil"), tostring(sl and sl:size() or "nil"))
end


-- Перенос живых существ (зомби/NPC и т.п.), игрока здесь можно пропустить
local function moveLivePawns(sqFrom, sqTo, targetZ, playerToSkip)
    if not (sqFrom and sqTo) then return end
    local mos = sqFrom:getMovingObjects()
    if not mos then return end

    for i = mos:size()-1, 0, -1 do
        local mo = mos:get(i)
        if mo and mo ~= playerToSkip then
            -- Переносим всех "живых" не-игроков: зомби и NPC/выживших
            if instanceof(mo, "IsoZombie")
               or (instanceof(mo, "IsoGameCharacter") and not instanceof(mo, "IsoPlayer"))
            then
                pcall(function()
                    local nx = sqTo:getX() + 0.5
                    local ny = sqTo:getY() + 0.5
                    local nz = targetZ

                    if mo.removeFromSquare then mo:removeFromSquare() end
                    if mo.setX then mo:setX(nx) end
                    if mo.setY then mo:setY(ny) end
                    if mo.setZ then mo:setZ(nz) end
                    if mo.setSquare then mo:setSquare(sqTo) end
                    if mo.addToWorld then mo:addToWorld() end

                    -- стабилизация физики/путефайдинга после телепорта
                    if mo.setLx and mo.setLy and mo.setLz then
                        mo:setLx(nx); mo:setLy(ny); mo:setLz(nz)
                    end
                    if mo.setMoving then mo:setMoving(false) end
                    if mo.clearVariable then mo:clearVariable("ClimbFenceOutcome") end
                end)
            end
        end
    end

    if sqFrom.RecalcAllWithNeighbours then sqFrom:RecalcAllWithNeighbours(true) end
    if sqTo.RecalcAllWithNeighbours   then sqTo:RecalcAllWithNeighbours(true)   end
end

-- Перенос «простых» тайл-объектов (например, разбитое стекло и пр. декор)
-- Создаём такой же спрайт на новой клетке и удаляем старый.
-- НЕ трогаем наш настил, перила и любые структурные тайлы (стены/пе
-- + чёрный список appliances_com_01_* (спутниковые тарелки и пр.)
local function moveSimpleTileObjects(sqFrom, sqTo, platformSprite, railN, railW)
    local objs = sqFrom and sqFrom:getObjects()
    if not (objs and sqTo) then return end
    local cell = getWorld():getCell()

    local function hasPrefix(s, p)
        return s and p and string.sub(s, 1, #p) == p
    end

    for i = objs:size()-1, 0, -1 do
        local obj = objs:get(i)
        if obj and obj.getSprite then
            local spr   = obj:getSprite()
            local sname = (spr and spr:getName()) or (obj.getSpriteName and obj:getSpriteName()) or ""

            local skip = false

            -- наш пол / наши перила
            if sname == platformSprite or sname == railN or sname == railW then
                skip = true
            end

            -- чёрный список: все appliances_com_01_*
            if (not skip) and hasPrefix(sname, "appliances_com_01_") then
                skip = true
            end

            -- динамика/интерактив
            if (not skip) and (
                instanceof(obj, "IsoMovingObject")
                or instanceof(obj, "IsoWindow")
                or instanceof(obj, "IsoDoor")
                or instanceof(obj, "IsoThumpable")
                or instanceof(obj, "IsoCurtain")
                or instanceof(obj, "IsoLightSwitch")
            ) then
                skip = true
            end

            -- «структурные» тайлы и настенные оверлеи
            if not skip then
                local props = spr and spr:getProperties()
                local F = _G.IsoFlagType
                local isStructure = props and (
                    props:Is(F.WallN) or props:Is(F.WallW) or
                    props:Is(F.WallSE) or props:Is(F.WallSW) or
                    props:Is(F.HoppableN) or props:Is(F.HoppableW) or
                    props:Is(F.WindowN)   or props:Is(F.WindowW)   or
                    props:Is(F.DoorN)     or props:Is(F.DoorW)     or
                    props:Is(F.WallOverlayN) or props:Is(F.WallOverlayW) or
                    props:Is(F.WallTopN)  or props:Is(F.WallTopW)  or
                    props:Is(F.WallTransN) or props:Is(F.WallTransW)
                )
                if isStructure then skip = true end
            end

            -- кровь переносим отдельной функцией, тут пропускаем
            if WindowWasher.isBloodDecalSpriteName(sname) then
                skip = true
            end
            

            if (not skip) and sname and sname ~= "" then
                local newObj = IsoObject.new(cell, sqTo, sname)
                if newObj then
                    sqTo:AddTileObject(newObj)
                    sqFrom:RemoveTileObject(obj)
                end
            end
        end
    end

    if sqFrom.RecalcAllWithNeighbours then sqFrom:RecalcAllWithNeighbours(true) end
    if sqTo.RecalcAllWithNeighbours   then sqTo:RecalcAllWithNeighbours(true)   end
end

-- ==== BLOOD DECAL FALLBACK (для билдов без addBloodSplat) ====
WindowWasher.bloodDecal = {
    enabled = true,
    maxPerSquare = (math and math.huge) or 1e9,   -- чтобы не заспамить клетку
    sprites = nil       -- заполним автоматически из overlay_blood_floor_01_*
}

-- Кластерная заливка крови по соседним клеткам платформы:
WindowWasher.bloodDecal.clusterSpan = 1   -- 1 = центр + соседи на 1 клетку вдоль платформы (EW: x±1; NS: y±1)
WindowWasher.bloodDecal.maxPerSquare = 8  -- больше «мяса», чтобы точно перекрывать движковые сплэты


-- Сколько кровавых ОВЕРЛЕЕВ уже лежит на клетке
function WindowWasher.countBloodOverlays(sq)
    local objs = sq and sq.getObjects and sq:getObjects() or nil
    if not objs then return 0 end
    local n = 0
    for i = 0, objs:size()-1 do
        local o   = objs:get(i)
        local spr = o and o.getSprite and o:getSprite()
        local nm  = spr and spr.getName and spr:getName() or ""
        if WindowWasher.isBloodDecalSpriteName and WindowWasher.isBloodDecalSpriteName(nm) then
            n = n + 1
        end
    end
    return n
end

-- Пытаемся понять, есть ли «боевая» кровь (splat’ы), которую игра рисует не тайлами
function WindowWasher.countEngineBlood(sq)
    if not sq then return 0 end
    local n = 0

    -- Вариант 1: новые билды — отдельный список сплатов
    if sq.getBloodSplats then
        local bs = sq:getBloodSplats()
        if bs and bs.size then
            local ok, sz = pcall(function() return bs:size() end)
            if ok and sz and sz > 0 then n = math.max(n, sz) end
        end
    end

    -- Вариант 2: на всякий — вдруг кровь видна как спец-объекты
    local objs = sq.getSpecialObjects and sq:getSpecialObjects() or nil
    if objs and objs.size then
        for i = 0, objs:size()-1 do
            local o  = objs:get(i)
            local on = o and o.getObjectName and o:getObjectName() or ""
            if on == "BloodSplat" or on == "Blood" then n = n + 1 end
        end
    end

    -- Вариант 3: совсем грубый фолбек — по флагам/имени объектов (встречается редко)
    if n == 0 then
        local all = sq.getObjects and sq:getObjects() or nil
        if all and all.size then
            for i = 0, all:size()-1 do
                local o  = all:get(i)
                local on = o and o.getObjectName and o:getObjectName() or ""
                if on == "BloodSplat" or on == "Blood" then n = n + 1 end
            end
        end
    end

    return n
end

-- === deterministic PRNG без битовых операций (совместим с Kahlua/Lua 5.1)
local WW_MOD = 2147483647 -- 2^31-1

local function WW_seedFromXYZ(x, y, z)
    x = tonumber(x) or 0; y = tonumber(y) or 0; z = tonumber(z) or 0
    local s = (x*73856093 + y*19349663 + z*83492791) % WW_MOD
    if s < 0 then s = s + WW_MOD end
    return s
end

local function WW_nextSeed(s)
    s = (s * 1103515245 + 12345) % WW_MOD
    if s < 0 then s = s + WW_MOD end
    return s
end

-- клетка входит в текущую полосу настила?
local function WW_isPlatformSquare(sq)
    if not sq then return false end
    local x,y,z = sq:getX(), sq:getY(), sq:getZ()
    if z ~= WindowWasher.ps.cz then return false end
    local left, right = WW_spanLR(WindowWasher.ps.size)
    if WindowWasher.ps.orient == "EW" then
        return (y == WindowWasher.ps.cy) and (x >= WindowWasher.ps.cx - left) and (x <= WindowWasher.ps.cx + right)
    else
        return (x == WindowWasher.ps.cx) and (y >= WindowWasher.ps.cy - left) and (y <= WindowWasher.ps.cy + right)
    end
end

-- положить 1–2 оверлея крови (overlay_blood_floor_01_*) на клетку, без спама
local function WW_ensureBloodOverlayOnSquare(sq)
    if not (sq and WindowWasher.bloodDecal and WindowWasher.bloodDecal.enabled) then return end

    local have = WindowWasher.countBloodOverlays(sq)
    local maxPer = WindowWasher.bloodDecal.maxPerSquare or 3
    if have >= maxPer then return end

    local sprites = WindowWasher.getBloodDecalSprites()
    if #sprites == 0 then return end

    local cell = getWorld():getCell()
    local toAdd = math.min(2, maxPer - have)
    local seed  = (sq:getX()*73856093 + sq:getY()*19349663 + sq:getZ()*83492791) % 2147483647

    for i=1,toAdd do
        seed  = (seed * 1103515245 + 12345) % 2147483647
        local idx = (seed % #sprites) + 1
        local sname = sprites[idx]
        local ok, obj = pcall(function() return IsoObject.new(cell, sq, sname) end)
        if ok and obj then
            obj:setName("WW Blood Decal")
            sq:AddTileObject(obj)
        end
    end

    if sq.RecalcAllWithNeighbours then pcall(function() sq:RecalcAllWithNeighbours(true) end) end
    WW_logBlood("mirror: added %d overlays at %s", toAdd, (sq:getX()..","..sq:getY()..","..sq:getZ()))
end

-- Пробежка по соседним клеткам ВДОЛЬ платформы и постановка декалей
local function WW_ensureBloodOverlayClusterOnPlatform(sq, span)
    if not (sq and WindowWasher.bloodDecal and WindowWasher.bloodDecal.enabled) then return end

    -- используем уже имеющуюся проверку: клетка входит в текущую полосу платформы?
    if not WW_isPlatformSquare(sq) then return end

    span = math.max(0, math.min(2, tonumber(WindowWasher.bloodDecal.clusterSpan or span or 1)))

    local x0, y0, z = sq:getX(), sq:getY(), sq:getZ()
    local function ensureAt(x, y)
        local s = getSquare(x, y, z)
        if s and WW_isPlatformSquare(s) then
            WW_ensureBloodOverlayOnSquare(s)
        end
    end

    -- центр
    ensureAt(x0, y0)

    -- соседи вдоль оси платформы (чтобы кластер «ехал» вместе с настилом)
    local orient = WindowWasher.ps and WindowWasher.ps.orient or "EW"
    if orient == "EW" then
        for dx = 1, span do
            ensureAt(x0 - dx, y0)
            ensureAt(x0 + dx, y0)
        end
    else
        for dy = 1, span do
            ensureAt(x0, y0 - dy)
            ensureAt(x0, y0 + dy)
        end
    end
end

-- любой признак движковой крови на клетке
-- любой признак движковой крови на клетке
local function WW_hasEngineBlood(sq)
    if not sq then return false end
    local ok, v

    ok, v = pcall(function() return sq.HasBlood and sq:HasBlood() end)
    if ok and v then return true end

    ok, v = pcall(function() return sq.hasBlood and sq:hasBlood() end)
    if ok and v then return true end

    ok, v = pcall(function()
        local b = sq.getBlood and sq:getBlood()
        return (b or 0) > 0
    end)
    if ok and v then return true end

    ok, v = pcall(function()
        local bs = sq.getBloodSplats and sq:getBloodSplats()
        return bs and bs.size and bs:size() > 0
    end)
    if ok and v then return true end

    -- важно для некоторых билдов: кровь как спец-объекты
    ok, v = pcall(function()
        local so = sq.getSpecialObjects and sq:getSpecialObjects()
        if not (so and so.size) then return false end
        for i = 0, so:size()-1 do
            local o  = so:get(i)
            local on = o and o.getObjectName and o:getObjectName() or ""
            if on == "BloodSplat" or on == "Blood" then return true end
        end
        return false
    end)
    if ok and v then return true end

    return false
end


-- Клонируем «боевую» кровь в ДЕКАЛИ на целевой клетке (только если на исходной нет уже оверлеев)
function WindowWasher.snapshotBloodToDecals(sqFrom, sqTo)
    if not (sqFrom and sqTo) then return 0 end

    -- все вычисления через pcall, чтобы не упасть на редких сборках
    local overlaysFrom = 0
    pcall(function() overlaysFrom = WindowWasher.countBloodOverlays(sqFrom) end)
    local overlaysTo   = 0
    pcall(function() overlaysTo   = WindowWasher.countBloodOverlays(sqTo)   end)

    local hasEngine = false
    do local ok, v = pcall(WW_hasEngineBlood, sqFrom); hasEngine = ok and v or false end

    -- снимок нужен только для движковой крови и только если на from нет уже оверлеев
    if overlaysFrom > 0 or not hasEngine then
        WW_logBlood("snapshot skip: overlayFrom=%d engine=%s", overlaysFrom, tostring(hasEngine))
        return 0
    end

    local sprites = {}
    do
        local ok, list = pcall(function() return WindowWasher.getBloodDecalSprites() end)
        if ok and type(list)=="table" then sprites = list end
    end
    if #sprites == 0 then
        WW_logBlood("no blood decal sprites available")
        return 0
    end

    local maxPer = (WindowWasher.bloodDecal and WindowWasher.bloodDecal.maxPerSquare) or 3
    local capacity = math.max(0, maxPer - overlaysTo)
    if capacity <= 0 then
        WW_logBlood("snapshot no capacity: overlaysTo=%d maxPer=%d", overlaysTo, maxPer)
        return 0
    end

    local cell = nil
    do
        local ok, c = pcall(function() return getWorld():getCell() end)
        if ok then cell = c end
    end
    if not cell then return 0 end

    local x, y, z = 0, 0, 0
    pcall(function() x = sqFrom:getX(); y = sqFrom:getY(); z = sqFrom:getZ() end)

    local seed  = WW_seedFromXYZ(x, y, z)
    local toAdd = math.min(3, capacity)
    local added = 0

    for i = 1, toAdd do
        seed = WW_nextSeed(seed + i * 1013904223)
        local idx   = (seed % #sprites) + 1
        local sname = tostring(sprites[idx])

        local obj = nil
        pcall(function() obj = IsoObject.new(cell, sqTo, sname) end)
        if obj then
            pcall(function() obj:setName("WW Blood Decal") end)
            pcall(function() sqTo:AddTileObject(obj) end)
            added = added + 1
        end
    end

    pcall(function() if added > 0 and sqTo.RecalcAllWithNeighbours then sqTo:RecalcAllWithNeighbours(true) end end)

    -- важно подчистить исходную «движковую» кровь
    pcall(WindowWasher.clearEngineBlood, sqFrom)

    WW_logBlood("snapshot -> added %d decals (engine=%s, to had %d)", added, tostring(hasEngine), overlaysTo)
    return added
end


-- Чуть болтливее: логируем и нулевые переносы
function WindowWasher.moveBloodDecalsVerbose(sqFrom, sqTo)
    local before = WindowWasher.countBloodOverlays(sqFrom)
    local moved = WindowWasher.moveBloodDecals and WindowWasher.moveBloodDecals(sqFrom, sqTo) or 0
    WW_logBlood("moveBloodDecals: from had=%d, moved=%d", before, moved)

    WW_logBlood("moved %d blood decals from %s to %s",
    moved,
    tostring(sqFrom and (sqFrom:getX()..","..sqFrom:getY()..","..sqFrom:getZ()) or "(nil)"),
    tostring(sqTo   and (sqTo:getX()..","..sqTo:getY()..","..sqTo:getZ())   or "(nil)"))

    return moved
end

-- === IsoFloorBloodSplat helpers (chunk-level) ================================

local function WW_getChunkAndListForSquare(sq)
    if not (sq and sq.getChunk) then return nil, nil end
    local ch = sq:getChunk(); if not ch then return nil, nil end
    local list = nil
    if ch.getFloorBloodSplats then
        local ok, v = pcall(function() return ch:getFloorBloodSplats() end)
        if ok then list = v end
    end
    if (not list) and ch.getBloodSplats then
        local ok, v = pcall(function() return ch:getBloodSplats() end)
        if ok then list = v end
    end
    return ch, list
end

local function WW_splatBelongsToSquare(s, X, Y, Z)
    if not s then return false end
    local sx = math.floor(tonumber(s.x) or -1)
    local sy = math.floor(tonumber(s.y) or -1)
    local sz = math.floor(tonumber(s.z) or -1)
    return (sx == X) and (sy == Y) and (sz == Z)
end


-- попытаться убрать движковую кровь со старой клетки (перебором известных API)
function WindowWasher.clearEngineBlood(sq)
    if not sq then return end
    local X,Y,Z = sq:getX(), sq:getY(), sq:getZ()

    -- A) Пытаемся удалить реальные IsoFloorBloodSplat из списка чанка
    local _, list = WW_getChunkAndListForSquare(sq)
    if list and list.size then
        local okN, n = pcall(function() return list:size() end); n = (okN and n) or 0
        if n > 0 then
            local removed = 0
            for i = n-1, 0, -1 do
                local s = list:get(i)
                if WW_splatBelongsToSquare(s, X, Y, Z) then
                    pcall(function() list:remove(i) end)
                    removed = removed + 1
                end
            end
            if removed > 0 then
                WW_logBlood("clearEngineBlood: removed %d splats @ (%d,%d,%d)", removed, X,Y,Z)
            end
        end
    else
        WW_logBlood("clearEngineBlood: chunk list not available @ (%d,%d,%d)", X,Y,Z)
    end

    -- B) Сбрасываем возможные счётчики/флаги у клетки
    pcall(function() if sq.setBlood   then sq:setBlood(0)   end end)
    pcall(function() if sq.setHasBlood then sq:setHasBlood(false) end end)

    -- C) На всякий: убрать Blood/BloodSplat как спец-объекты
    pcall(function()
        local so = sq.getSpecialObjects and sq:getSpecialObjects()
        if so and so.size then
            for i = so:size()-1, 0, -1 do
                local o  = so:get(i)
                local on = o and o.getObjectName and o:getObjectName() or ""
                if on == "BloodSplat" or on == "Blood" then
                    if o.removeFromSquare then o:removeFromSquare() end
                    if sq.RemoveSpecialObject then sq:RemoveSpecialObject(o) end
                    if o.removeFromWorld  then o:removeFromWorld()  end
                end
            end
        end
    end)

    -- D) Пересчёт визуала
    pcall(function() if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end end)
end

-- === Deferred blood cleanup ===================================================
WindowWasher._bloodClearQueue = WindowWasher._bloodClearQueue or {}

local function WW_enqueueBloodClear(sq, ticks)
    if not sq then return end
    local key = string.format("%d:%d:%d", sq:getX(),sq:getY(),sq:getZ())
    WindowWasher._bloodClearQueue[key] = { sq = sq, t = math.max(1, tonumber(ticks) or 2) }
end

local function WW_onTickBloodClear()
    local any = false
    for k, rec in pairs(WindowWasher._bloodClearQueue) do
        if rec and rec.sq then
            rec.t = rec.t - 1
            if rec.t <= 0 then
                WindowWasher.clearEngineBlood(rec.sq)
                WindowWasher._bloodClearQueue[k] = nil
            else
                any = true
            end
        else
            WindowWasher._bloodClearQueue[k] = nil
        end
    end
    -- если очередь пуста — можно оставить обработчик висеть, он лёгкий
end
Events.OnTick.Add(WW_onTickBloodClear)

function WindowWasher._mirrorBlood_OnWeaponHitCharacter(weapon, attacker, target, dmg)
    if not (target and instanceof(target, "IsoZombie")) then return end
    local sq = target.getSquare and target:getSquare() or nil
    if sq and WW_isPlatformSquare(sq) then
        WW_ensureBloodOverlayOnSquare(sq)
        -- движок может дорисовать сплаты после события -> чистим с задержкой
        WW_enqueueBloodClear(sq, 3)
    end
end

function WindowWasher._mirrorBlood_OnZombieDead(zombie)
    if not zombie then return end
    local sq = zombie.getSquare and zombie:getSquare() or nil
    if sq and WW_isPlatformSquare(sq) then
        WW_ensureBloodOverlayOnSquare(sq)
        WW_enqueueBloodClear(sq, 5)  -- смерть часто спавнит кровь кадром позже
    end
end

-- Метка: это кровь-наложение (overlay_blood_floor_01_*)
function WindowWasher.isBloodDecalSpriteName(name)
    return type(name) == "string"
       and name ~= ""
       and name:find("overlay_blood", 1, true) ~= nil
end

-- Переносим кровавые наложения с клетки-источника на целевую
function WindowWasher.moveBloodDecals(sqFrom, sqTo)
    if not (sqFrom and sqTo) then return 0 end
    local objs = sqFrom.getObjects and sqFrom:getObjects() or nil
    if not objs or objs:size() == 0 then return 0 end

    local cell  = getWorld():getCell()
    local moved = 0

    -- считаем, сколько крови уже на целевой клетке (для лимита)
    local exist = 0
    local toObjs = sqTo.getObjects and sqTo:getObjects() or nil
    if toObjs then
        for j = 0, toObjs:size()-1 do
            local o   = toObjs:get(j)
            local spr = o and o.getSprite and o:getSprite()
            local nm  = spr and spr.getName and spr:getName() or ""
            if WindowWasher.isBloodDecalSpriteName(nm) then
                exist = exist + 1
            end
        end
    end
    local maxPer = (WindowWasher.bloodDecal and WindowWasher.bloodDecal.maxPerSquare) or math.huge

    -- переносим все overlay_blood_floor_01_* как простые тайл-объекты
    for i = objs:size()-1, 0, -1 do
        local obj   = objs:get(i)
        local spr   = obj and obj.getSprite and obj:getSprite()
        local sname = spr and spr.getName and spr:getName() or ""
        if WindowWasher.isBloodDecalSpriteName(sname) then
            if exist < maxPer then
                local ok, newObj = pcall(function() return IsoObject.new(cell, sqTo, sname) end)
                if ok and newObj then
                    newObj:setName(obj.getName and obj:getName() or "WW Blood Decal")
                    sqTo:AddTileObject(newObj)
                    sqFrom:RemoveTileObject(obj)
                    moved = moved + 1
                    exist = exist + 1
                end
            else
                -- лимит достигнут — ничего не добавляем (чтобы не спамить клетку)
            end
        end
    end

    if moved > 0 then
        if sqFrom.RecalcAllWithNeighbours then sqFrom:RecalcAllWithNeighbours(true) end
        if sqTo.RecalcAllWithNeighbours   then sqTo:RecalcAllWithNeighbours(true)   end
        WW_logBlood("moved %d blood decals from %s to %s", moved,
            tostring(sqFrom and (sqFrom:getX()..","..sqFrom:getY()..","..sqFrom:getZ()) or "(nil)"),
            tostring(sqTo   and (sqTo:getX()..","..sqTo:getY()..","..sqTo:getZ())   or "(nil)"))
    end
    return moved
end


-- Автозагрузка доступных кадров overlay_blood_floor_01_0..63
function WindowWasher.getBloodDecalSprites()
    if WindowWasher.bloodDecal.sprites and #WindowWasher.bloodDecal.sprites > 0 then
        return WindowWasher.bloodDecal.sprites
    end
    local list = {}
    for i = 0, 63 do
        local name = ("overlay_blood_floor_01_%d"):format(i)
        local ok, spr = pcall(function() return getSprite(name) end)
        if ok and spr then table.insert(list, name) end
    end
    -- на всякий случай, если getSprite недоступен — положимся на IsoObject.new
    if #list == 0 then
        for i = 0, 15 do
            table.insert(list, ("overlay_blood_floor_01_%d"):format(i))
        end
    end
    WindowWasher.bloodDecal.sprites = list
    return list
end

-- зеркалим кровь при каждом ударе по зомби на нашей платформе
function WindowWasher._mirrorBlood_OnWeaponHitCharacter(weapon, attacker, target, dmg)
    if not (target and instanceof(target, "IsoZombie")) then return end
    local sq = target.getSquare and target:getSquare() or nil
    if sq and WW_isPlatformSquare(sq) then
        WW_ensureBloodOverlayClusterOnPlatform(sq, 1)  -- было: WW_ensureBloodOverlayOnSquare(sq)
        -- движок всё равно может дорисовать сплэты кадром позже — можно оставить твой отложенный клинер,
        -- но он и не нужен, если нас устраивает чисто визуальное перекрытие.
        -- WW_enqueueBloodClear(sq, 3)
    end
end

function WindowWasher._mirrorBlood_OnZombieDead(zombie)
    if not zombie then return end
    local sq = zombie.getSquare and zombie:getSquare() or nil
    if sq and WW_isPlatformSquare(sq) then
        WW_ensureBloodOverlayClusterOnPlatform(sq, 1)  -- было: WW_ensureBloodOverlayOnSquare(sq)
        -- WW_enqueueBloodClear(sq, 5)
    end
end


-- регистрируем хуки один раз
if not WindowWasher._bloodMirrorHooked then
    Events.OnWeaponHitCharacter.Add(WindowWasher._mirrorBlood_OnWeaponHitCharacter)
    Events.OnZombieDead.Add(WindowWasher._mirrorBlood_OnZombieDead)
    WindowWasher._bloodMirrorHooked = true
end

-- Перенос по заранее собранным спискам клеток (до/после)
function movePlatformContentsLists(fromList, toList, newZ, playerObj, bloodSnap)
    local count = math.min(#fromList, #toList)
    for i = 1, count do
        local sqFrom, sqTo = fromList[i], toList[i]
        if sqFrom and sqTo then

        -- сначала «сфоткаем» боевую кровь в декали на целевой клетке
        WindowWasher.snapshotBloodToDecals(sqFrom, sqTo)
        -- затем перевезём уже существующие оверлеи (если таковые были)
        WindowWasher.moveBloodDecalsVerbose(sqFrom, sqTo)         
        -- на всякий: снесём движковую кровь на старой клетке
        WindowWasher.clearEngineBlood(sqFrom)   
            
            moveWorldItems(sqFrom, sqTo)
            moveDeadBodies(sqFrom, sqTo, newZ)
            moveLivePawns(sqFrom, sqTo, newZ, playerObj)
            moveSimpleTileObjects(sqFrom, sqTo, WindowWasher.ps.sprite, WindowWasher.rails.N, WindowWasher.rails.W)
        end
    end
end

-- Перенести всё содержимое «ручья» платформы
local function movePlatformContents(oldCx, oldCy, oldCz, newCx, newCy, newCz, size, orient, playerObj)
    local fromList = getPlatformSquares(oldCx, oldCy, oldCz, size, orient)
   
    local bloodSnap = {}

    local toList   = getPlatformSquares(newCx,  newCy,  newCz,  size, orient)
    local count = math.min(#fromList, #toList)
    for idx = 1, count do
        local sqFrom = fromList[idx]
        local sqTo   = toList[idx]
        if sqFrom and sqTo then
            moveWorldItems(sqFrom, sqTo)              -- брошенные/выпавшие предметы
            moveDeadBodies(sqFrom, sqTo, newCz)       -- трупы
            moveLivePawns(sqFrom, sqTo, newCz, playerObj) -- живые зомби/NPC (кроме игрока)
        end
    end
end


-- ===== Timed Action for movement (vertical) =====
ISMovePlatformAction = ISBaseTimedAction:derive("ISMovePlatformAction")

function ISMovePlatformAction:new(character, dx, dy, dz)
    local o = ISBaseTimedAction.new(self, character)
    o.dx, o.dy, o.dz = dx, dy, dz
    o.maxTime = WindowWasher.ps.moveDuration * 60  -- seconds -> ticks
    o.stopOnWalk = true
    o.stopOnRun  = true
    o.stopOnAim  = true
    return o
end

function ISMovePlatformAction:isValid()
    return true
end

function ISMovePlatformAction:start()
    print("WW TA start")
    WindowWasher.ps.moving = true
end

function ISMovePlatformAction:perform()
    local tx = WindowWasher.ps.cx + self.dx
    local ty = WindowWasher.ps.cy + self.dy
    local tz = WindowWasher.ps.cz + self.dz

    if not squaresExistFor(tx, ty, tz, WindowWasher.ps.size, WindowWasher.ps.orient) then
        print(("WW TA perform ABORT: target squares not loaded %d,%d,%d"):format(tx,ty,tz))
        WindowWasher.ps.moving = false
        return
    end

    -- Сохраняем старые клетки ручья и старые объекты платформы ДО перестройки
    local ox, oy, oz = WindowWasher.ps.cx, WindowWasher.ps.cy, WindowWasher.ps.cz
    local fromList = getPlatformSquares(ox, oy, oz, WindowWasher.ps.size, WindowWasher.ps.orient)

    local function copyList(t) local r = {}; for i=1,#t do r[i]=t[i] end; return r end
    local oldFloors = copyList(WindowWasher.ps.objs)
    local oldRails  = copyList(WindowWasher.ps.railObjs)

    print(("WW TA perform -> %d,%d,%d"):format(tx,ty,tz))

    -- 1) СНАЧАЛА строим новую платформу
    WindowWasher.buildPlatformAt(tx, ty, tz)

    -- 2) Переносим содержимое на новые клетки
    local toList = getPlatformSquares(tx, ty, tz, WindowWasher.ps.size, WindowWasher.ps.orient)
    movePlatformContentsLists(fromList, toList, tz, self.character, bloodSnap)

    -- 2b) ДОЧИСТКА движковой крови с задержкой на обоих наборах клеток
    for _, sq in ipairs(fromList) do WW_enqueueBloodClear(sq, 3) end
    for _, sq in ipairs(toList)   do WW_enqueueBloodClear(sq, 3) end

    -- 3) Теперь можно снести СТАРЫЕ перила/полы (по сохранённым спискам)
    local function destroyTileObjectList(list)
        for _, obj in ipairs(list) do
            local sq = obj and obj:getSquare()
            if sq and obj then
                pcall(function() sq:RemoveTileObject(obj) end)
                pcall(function() sq:DeleteTileObject(obj) end)
                if sq.RecalcAllWithNeighbours then sq:RecalcAllWithNeighbours(true) end
            end
        end
    end
    destroyTileObjectList(oldRails)
    destroyTileObjectList(oldFloors)

    -- Телепорт игрока как раньше
    self.character:setX(tx + 0.5); self.character:setY(ty + 0.5); self.character:setZ(tz)

    WindowWasher.ps.moving = false
    ISBaseTimedAction.perform(self)
end

-- Public API for moves (only vertical for now)
function WindowWasher.move(dx, dy, dz, playerObj)
    if WindowWasher.ps.moving then print("WW: already moving"); return end
        print(string.format("WW: enqueue TA dx=%s dy=%s dz=%s from %s,%s,%s",
        tostring(dx), tostring(dy), tostring(dz),
        tostring(WindowWasher.ps.cx), tostring(WindowWasher.ps.cy), tostring(WindowWasher.ps.cz)))
    ISTimedActionQueue.add(ISMovePlatformAction:new(playerObj, dx, dy, dz))
end

-- instant (debug)
function WindowWasher.moveInstant(dx, dy, dz, playerObj)
    dx = tonumber(dx) or 0; dy = tonumber(dy) or 0; dz = tonumber(dz) or 0
    local tx = WindowWasher.ps.cx + dx
    local ty = WindowWasher.ps.cy + dy
    local tz = WindowWasher.ps.cz + dz
    print(("WW moveInstant to %d,%d,%d"):format(tx,ty,tz))
    if not squaresExistFor(tx, ty, tz, WindowWasher.ps.size, WindowWasher.ps.orient) then
        print("WW moveInstant ABORT: target not loaded")
        return
    end
    WindowWasher.destroyPlatform()
    WindowWasher.buildPlatformAt(tx, ty, tz)
    playerObj:setX(tx + 0.5); playerObj:setY(ty + 0.5); playerObj:setZ(tz)
end

-- wrappers for context menu (чтобы учесть target первым аргументом)
function WindowWasher.moveMenu(_, dx, dy, dz, playerObj)
    WindowWasher.move(dx, dy, dz, playerObj)
end
function WindowWasher.moveInstantMenu(_, dx, dy, dz, playerObj)
    WindowWasher.moveInstant(dx, dy, dz, playerObj)
end

-- ===== Context menu (vertical only) =====
function WindowWasher.onFillWorldContextMenu(player, context, worldobjects, test)
    if test then return end
    local p = getSpecificPlayer(player); if not p then return end

    local root = context:addOption("Move Scaffold")
    local sub  = ISContextMenu:getNew(context); context:addSubMenu(root, sub)

    sub:addOption("Up (+1 floor)",   WindowWasher, WindowWasher.moveMenu,        0, 0,  1, p)
    sub:addOption("Down (-1 floor)", WindowWasher, WindowWasher.moveMenu,        0, 0, -1, p)

    -- DEBUG:
    sub:addOption("[DEBUG] Up instant",   WindowWasher, WindowWasher.moveInstantMenu, 0, 0,  1, p)
    sub:addOption("[DEBUG] Down instant", WindowWasher, WindowWasher.moveInstantMenu, 0, 0, -1, p)
end
Events.OnFillWorldObjectContextMenu.Add(WindowWasher.onFillWorldContextMenu)

-- ===== Hotkeys (PgUp/PgDn) =====
WindowWasher.keys = { up=Keyboard.KEY_PRIOR, down=Keyboard.KEY_NEXT }
function WindowWasher.OnKeyPressed(key)
    local p = getPlayer(); if not p then return end
    if key == WindowWasher.keys.up   then print("WW key: Up");   WindowWasher.move(0,0, 1,p)
    elseif key == WindowWasher.keys.down then print("WW key: Down"); WindowWasher.move(0,0,-1,p)
    end
end
Events.OnKeyPressed.Add(WindowWasher.OnKeyPressed)

-- ===== Player spawn =====
WindowWasher.AddPlayer = function(playerNum, playerObj)
    if not playerObj or playerObj:getHoursSurvived() > 0 then return end
    local function delayedTeleport()
        local cx, cy, cz = WindowWasher.x, WindowWasher.y, WindowWasher.z

        WindowWasher.ps.size   = 6
        WindowWasher.ps.orient = "EW"
        WindowWasher.ps.sprite = "constructedobjects_01_86"

        WindowWasher.buildPlatformAt(cx, cy, cz)
        playerObj:setX(cx + 0.5); playerObj:setY(cy + 0.5); playerObj:setZ(cz)

        print(("WindowWasher: platform ready at %d,%d,%d"):format(cx,cy,cz))
        Events.OnTick.Remove(delayedTeleport)
    end
    Events.OnTick.Add(delayedTeleport)
end



WindowWasher.Render = function() end

-- ===== Challenge metadata =====
WindowWasher.id = "WindowWasher";
WindowWasher.completionText = "The world ended while you were at work. You’re stuck on a scaffold, outside a skyscraper. Get in. Survive.";
WindowWasher.image = "media/ui/Challenge_WindowWasher.png";
WindowWasher.gameMode = "Window Washer";
WindowWasher.world = "Muldraugh, KY";

-- spawn coordinates in Louisville
WindowWasher.x = 12782;
WindowWasher.y = 1539;
WindowWasher.z = 24;
WindowWasher.hourOfDay = 7;

-- ===== Register events =====
Events.OnInitWorld.Add(WindowWasher.OnInitWorld)
Events.OnChallengeQuery.Add(WindowWasher.Add)
