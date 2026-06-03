-- deps
if not ISBaseTimedAction  then require "TimedActions/ISBaseTimedAction"  end
if not ISTimedActionQueue then require "TimedActions/ISTimedActionQueue" end
if not ISContextMenu     then require "ISUI/ISContextMenu"              end

WindowWasher = {}

WindowWasher.Add = function()
	addChallenge(WindowWasher);
end

-- ===== DEBUG HELPERS =========================================================
-- B42: PropertyContainer:Is(IsoFlagType) переименован в :has(IsoFlagType),
-- и часть констант IsoFlagType удалена/переименована (нет WallOverlayN/W,
-- WallTopN/W, DoorN/W, WallTransN/W, WallSW). Этот хелпер nil-безопасен:
-- неизвестное имя флага -> false, без "Object tried to call nil".
local function WW_propHas(props, name)
    if not props then return false end
    local ok, r = pcall(function()
        local fl = IsoFlagType[name]
        if fl == nil then return false end
        return props:has(fl) and true or false
    end)
    return ok and r or false
end

-- актуальные B42-имена структурных/настенных флагов (несуществующие просто игнорируются)
local WW_FLAG_NAMES = {
    "WallN","WallW","WallNW","WallSE",
    "HoppableN","HoppableW","TallHoppableN","TallHoppableW",
    "WindowN","WindowW","doorN","doorW","DoorWallN","DoorWallW",
    "WallNTrans","WallWTrans","transparentN","transparentW",
    "WallOverlay","FloorOverlay","solid","solidtrans",
}

local function WW_flagsToStr(props)
    if not props then return "(no-props)" end
    local t = {}
    for _,n in ipairs(WW_FLAG_NAMES) do
        if WW_propHas(props, n) then table.insert(t, n) end
    end
    return #t>0 and table.concat(t,",") or "(none)"
end

local function WW_dumpSquare(x,y,z, tag)
    local sq = getSquare(x,y,z)
    if not sq then
        print(("[WW/DBG] %s @(%d,%d,%d): sq=nil"):format(tag or "Square", x,y,z))
        return
    end
    print(("[WW/DBG] %s @(%d,%d,%d): objs=%d spc=%d wobj=%d")
        :format(tag or "Square", x,y,z,
                (sq:getObjects() and sq:getObjects():size() or 0),
                (sq:getSpecialObjects() and sq:getSpecialObjects():size() or 0),
                (sq:getWorldObjects() and sq:getWorldObjects():size() or 0)))
    local objs = sq:getObjects()
    if objs then
        for i=0,objs:size()-1 do
            local o = objs:get(i)
            local spr = o and o:getSprite()
            local nm = spr and spr:getName() or (o and o.getSpriteName and o:getSpriteName()) or "?"
            local fl = spr and WW_flagsToStr(spr:getProperties()) or "(no-sprite)"
            print(("[WW/DBG]   #%d %s  flags=[%s]  class=%s"):format(i, tostring(nm), fl, tostring(o)))
        end
    end
end

local function WW_checkSprite(name)
    local s = getSprite(name)
    if not s then
        print(("[WW/DBG] sprite '%s' = nil"):format(tostring(name)))
        return false
    end
    local isOverlay = WW_propHas(s:getProperties(), "WallOverlay")
    print(("[WW/DBG] sprite '%s' -> %s  WallOverlay=%s  flags=[%s]")
          :format(tostring(name), tostring(s),
                  tostring(isOverlay),
                  WW_flagsToStr(s:getProperties())))
    return isOverlay
end


-- ====== ТРОСЫ (только северные оверлеи) =====================================
-- B42 МИГРАЦИЯ: спрайты тросов ОТКЛЮЧЕНЫ. Старый .tiles (текстовый B41) и .pack
-- (магия PZPK) несовместимы с B42 (он ждёт бинарный tdef и свой формат пака) →
-- "tiledef not found". Тросы декоративны, поэтому отключены до отдельного этапа.
-- buildRopes() при enabled=false сразу выходит, ничего не строит и не спамит.
WindowWasher.ropes = {
    enabled = false,
    N_left  = "rope_N_left",
    N_right = "rope_N_right",
}

WindowWasher.ropeObjs = {}

-- B42: у Stats больше НЕТ getEndurance/setEndurance — выносливость стала
-- CharacterStat.ENDURANCE (0..1). Читается через get(). ВАЖНО: расход делать ТОЛЬКО
-- через remove() (как ванила — Farming/Camping: getStats():remove(CharacterStat.ENDURANCE,x)).
-- set(CharacterStat.ENDURANCE, v) НЕ «прилипает»: endurance recharge-управляемый, и система
-- восстановления перетирает заданное значение из lastEndurance → расход через set = no-op.
local function WW_getEndurance(s)
    if not s then return 0 end
    local ok, v = pcall(function() return s:get(CharacterStat.ENDURANCE) end)
    return (ok and v) or 0
end
local function WW_drainEndurance(s, amount)
    if not s or not amount or amount <= 0 then return end
    pcall(function()
        local probe = WindowWasher.debug and WindowWasher.debug.staminaProbe
        local before = probe and s:get(CharacterStat.ENDURANCE) or nil
        s:remove(CharacterStat.ENDURANCE, amount)
        if before ~= nil then
            print(string.format("[WW/STA] drain %.3f: endurance %.3f -> %.3f",
                amount, before, s:get(CharacterStat.ENDURANCE)))
        end
    end)
end

-- ====== Endurance drain for manual winch (per floor) ======
WindowWasher.stamina = WindowWasher.stamina or {}

-- Базовая цена за 1 этаж вручную (в долях шкалы 0..1).
-- 0.03 = 3% за этаж.
WindowWasher.stamina.manualPerFloor = 0.03

-- Базовая цена за 1 этаж вручную (ощутимая)
WindowWasher.stamina.manualPerFloor = 0.25
WindowWasher.stamina.manualUpMult   = 1.00
WindowWasher.stamina.manualDownMult = 0.50

-- Доп. «цена» за перегруз (на каждый кг сверх лимита) за 1 этаж.
WindowWasher.stamina.manualOverweightPerKg = 0.0035

-- При критически низкой выносливости — авто-отмена
WindowWasher.stamina.autoCancelThreshold = 0.12

-- ==== AUDIO (минимум) =======================================================
WindowWasher.audio = WindowWasher.audio or { emitter=nil, current=nil }

local function WW_audioCenter()
    local cx, cy, cz = WindowWasher.ps.cx or 0, WindowWasher.ps.cy or 0, WindowWasher.ps.cz or 0
    return cx + 0.5, cy + 0.5, cz
end

function WindowWasher.audio_start(loopName)
    -- Если уже играет другой луп — остановим его
    if WindowWasher.audio.emitter then
        WindowWasher.audio.emitter:stopAll()
        WindowWasher.audio.emitter = nil
        WindowWasher.audio.current = nil
    end
    local em = getWorld():getFreeEmitter()
    local x,y,z = WW_audioCenter()
    em:setPos(x, y, z)
    em:playSound(loopName)  -- имя из media/scripts/windowwasher_sounds.txt
    WindowWasher.audio.emitter = em
    WindowWasher.audio.current = loopName
end

function WindowWasher.audio_updatePos()
    local a = WindowWasher.audio
    if not a.emitter then return end
    local x,y,z = WW_audioCenter()
    a.emitter:setPos(x, y, z)
end

function WindowWasher.audio_stop()
    local a = WindowWasher.audio
    if a.emitter then
        a.emitter:stopAll()
    end
    a.emitter = nil
    a.current = nil
end
-- ============================================================================


WindowWasher.debug           = WindowWasher.debug or {}

-- ==== DEBUG: stamina console probe ==========================================
WindowWasher.debug.staminaProbe = false

-- ==== DEBUG: форс-отключение городской сети (тест генераторной фазы) =========
-- true  → при старте игры гасим городскую сеть (setHydroPowerOn(false)), и проверка
--         питания лебёдки ИГНОРИРУЕТ сеть: электролебёдка работает только от генератора
--         (haveElectricity на внутреннем тайле WindowWasher.genCheckX/Y/Z).
-- false → обычное поведение (сеть работает, пока город не обесточится по времени).
WindowWasher.debug.forceGridOff = false

do
    local _acc = 0
    local function WW_dbgStaminaTick()
        if not WindowWasher.debug.staminaProbe then return end
        _acc = _acc + 1
        if _acc >= 30 then -- 5 сек при 60 тиков/сек
            local p = getPlayer()
            if p then
                local e = WW_getEndurance(p:getStats())
                print(string.format("[WW/STA] Endurance: %.3f  (%.0f%%)", e, e*100))
            end
            _acc = 0
        end
    end
    Events.OnTick.Add(WW_dbgStaminaTick)
end


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

local function WW_overweightKg(ch)
    local inv = ch:getInventory()
    local cur = inv and inv:getCapacityWeight() or 0
    local max = inv and inv:getMaxWeight() or 0
    return math.max(0, cur - max)
end


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
    size = 3,                              -- odd: 3/5/7
    orient = "EW",                         -- "EW" or "NS"
    sprite = "constructedobjects_01_86",   -- metal floor sprite
    objs = {},                             -- created floor objects (to remove)
    railObjs = {},                         -- созданные объекты перил (стены)
    moving = false,
    moveDuration = 0.5                     -- seconds (UX)
}

-- ===== Sandbox config =====
-- Два режима испытания (см. регистрацию внизу файла):
--   Нормальный  — настройки мира как в Apocalypse (без респауна зомби);
--   Хардкор     — ванильный пресет «Вымирание» (Extinction), кроме даты старта.
-- Фреймворк (LastStandSetup.preLoadLastStandInit) сам вызывает OnInitWorld выбранного
-- режима, поэтому глобальный Events.OnInitWorld.Add больше НЕ нужен.

-- Общее для обоих режимов (не зависит от сложности).
WindowWasher.applyChallengeCommon = function()
    -- Мировая карта полностью открыта с самого старта.
    SandboxVars.Map = SandboxVars.Map or {}
    SandboxVars.Map.AllowWorldMap = true
    SandboxVars.Map.MapAllKnown   = true

    SandboxVars.MultiplierConfig = { XPMultiplierGlobal = 1, XPMultiplierGlobalToggle = true, }
    SandboxVars.StarterKit = false
    SandboxVars.LootItemRemovalList = ""

    -- Разрешаем выращивать с/х культуры на крышах (и выше уровня земли) в обоих режимах.
    -- ВАЖНО: PlaceDirtAboveground добавлен в extinctionSkipKeys, иначе пресет Extinction
    -- (PlaceDirtAboveground = false) перетёр бы это значение в хардкоре.
    SandboxVars.PlaceDirtAboveground = true
end

-- НОРМАЛЬНЫЙ: как Apocalypse. База новой игры уже ≈Apocalypse, поэтому переопределяем
-- только ключевое: нормальная популяция и ВЫКЛЮЧЕННЫЙ респаун (как в Apocalypse).
WindowWasher.applyNormalSandbox = function()
    WindowWasher.applyChallengeCommon()
    -- Старт на 6 дней позже стандарта: вирус доходит до Луисвилля через 6 дней после обычного начала.
    SandboxVars.StartMonth = 7; SandboxVars.StartDay = 15; SandboxVars.StartTime = 2
    SandboxVars.ZombieConfig.PopulationMultiplier  = 0.65   -- Apocalypse Normal
    SandboxVars.ZombieConfig.RespawnHours          = 0.0    -- респаун выкл
    SandboxVars.ZombieConfig.RespawnUnseenHours    = 0.0
    SandboxVars.ZombieConfig.RespawnMultiplier     = 0.0
    print("[WW] sandbox: NORMAL (Apocalypse-like, no respawn)")
end

-- ХАРДКОР: ванильный пресет «Вымирание» (Extinction).
-- WindowWasher.extinctionPreset ниже — ДОСЛОВНАЯ копия ванильного пресета
-- media/lua/shared/Sandbox/Extinction.lua (Build 42.15). При применении в SandboxVars:
--   • дату старта НЕ берём из пресета — ставим как в нормальном режиме (StartMonth=7/StartDay=15/StartTime=2);
--   • Map (раскрытие карты), MultiplierConfig (XP) и StarterKit задаёт applyChallengeCommon
--     — это решения мода, поэтому из пресета их НЕ копируем. Дополнительно: в рантайме
--     SandboxVars.MultiplierConfig использует имена XPMultiplierGlobal*, а не Global, как в
--     файле пресета, так что слепое копирование MultiplierConfig из пресета было бы неверным;
--   • Version — это маркер версии файла пресета, не SandboxVar, поэтому пропускаем.
WindowWasher.extinctionPreset = {
    Version = 6,
    Zombies = 3,
    Distribution = 1,
    ZombieVoronoiNoise = true,
    ZombieRespawn = 2,
    ZombieMigrate = true,
    DayLength = 4,
    StartYear = 1,
    StartMonth = 7,
    StartDay = 9,
    StartTime = 2,
    DayNightCycle = 1,
    ClimateCycle = 1,
    FogCycle = 1,
    WaterShut = 2,
    ElecShut = 2,
    AlarmDecay = 2,
    WaterShutModifier = 14,
    ElecShutModifier = 14,
    AlarmDecayModifier = 14,
    FoodLootNew = 0.4,
    LiteratureLootNew = 0.6,
    SkillBookLoot = 0.4,
    RecipeResourceLoot = 0.4,
    MedicalLootNew = 0.4,
    SurvivalGearsLootNew = 0.4,
    CannedFoodLootNew = 0.4,
    WeaponLootNew = 0.4,
    RangedWeaponLootNew = 0.6,
    AmmoLootNew = 0.2,
    MechanicsLootNew = 0.6,
    OtherLootNew = 0.4,
    ClothingLootNew = 0.6,
    ContainerLootNew = 0.4,
    KeyLootNew = 0.4,
    MediaLootNew = 0.4,
    MementoLootNew = 0.6,
    CookwareLootNew = 0.6,
    MaterialLootNew = 0.6,
    FarmingLootNew = 0.6,
    ToolLootNew = 0.4,
    RollsMultiplier = 1.0,
    RemoveStoryLoot = false,
    RemoveZombieLoot = false,
    ZombiePopLootEffect = 10,
    InsaneLootFactor = 0.05,
    ExtremeLootFactor = 0.2,
    RareLootFactor = 0.6,
    NormalLootFactor = 1.0,
    CommonLootFactor = 2.0,
    AbundantLootFactor = 3.0,
    Temperature = 3,
    Rain = 3,
    ErosionSpeed = 3,
    ErosionDays = 0,
    Farming = 3,
    CompostTime = 2,
    StatsDecrease = 3,
    NatureAbundance = 2,
    Alarm = 5,
    LockedHouses = 6,
    StarterKit = false,
    Nutrition = true,
    FoodRotSpeed = 3,
    FridgeFactor = 3,
    SeenHoursPreventLootRespawn = 0,
    HoursForLootRespawn = 0,
    MaxItemsForLootRespawn = 5,
    ConstructionPreventsLootRespawn = true,
    WorldItemRemovalList = "Base.Hat, Base.Glasses, Base.Maggots, Base.Slug, Base.Slug2, Base.Snail, Base.Worm, Base.Dung_Mouse, Base.Dung_Rat",
    HoursForWorldItemRemoval = 24.0,
    ItemRemovalListBlacklistToggle = false,
    TimeSinceApo = 1,
    PlantResilience = 4,
    PlantAbundance = 3,
    EndRegen = 3,
    Helicopter = 3,
    MetaEvent = 3,
    SleepingEvent = 1,
    GeneratorFuelConsumption = 0.1,
    GeneratorSpawning = 2,
    AnnotatedMapChance = 2,
    CharacterFreePoints = 0,
    ConstructionBonusPoints = 3,
    NightDarkness = 1,
    NightLength = 3,
    BoneFracture = true,
    InjurySeverity = 3,
    HoursForCorpseRemoval = 216.0,
    DecayingCorpseHealthImpact = 4,
    ZombieHealthImpact = true,
    BloodLevel = 3,
    ClothingDegradation = 4,
    FireSpread = true,
    DaysForRottenFoodRemoval = -1,
    AllowExteriorGenerator = true,
    MaxFogIntensity = 1,
    MaxRainFxIntensity = 1,
    EnableSnowOnGround = true,
    AttackBlockMovements = true,
    SurvivorHouseChance = 2,
    VehicleStoryChance = 3,
    ZoneStoryChance = 3,
    AllClothesUnlocked = false,
    EnableTaintedWaterText = false,
    EnableVehicles = true,
    CarSpawnRate = 3,
    ZombieAttractionMultiplier = 1.0,
    VehicleEasyUse = false,
    InitialGas = 2,
    FuelStationGasInfinite = false,
    FuelStationGasMin = 0.0,
    FuelStationGasMax = 0.7,
    FuelStationGasEmptyChance = 25,
    LockedCar = 6,
    CarGasConsumption = 1.0,
    CarGeneralCondition = 2,
    CarDamageOnImpact = 3,
    DamageToPlayerFromHitByACar = 1,
    TrafficJam = true,
    CarAlarm = 4,
    PlayerDamageFromCrash = true,
    SirenShutoffHours = 0.0,
    ChanceHasGas = 1,
    RecentlySurvivorVehicles = 2,
    MultiHitZombies = false,
    RearVulnerability = 3,
    SirenEffectsZombies = true,
    AnimalStatsModifier = 4,
    AnimalMetaStatsModifier = 4,
    AnimalPregnancyTime = 4,
    AnimalAgeModifier = 4,
    AnimalMilkIncModifier = 4,
    AnimalWoolIncModifier = 4,
    AnimalRanchChance = 4,
    AnimalGrassRegrowTime = 240,
    AnimalMetaPredator = true,
    AnimalMatingSeason = true,
    AnimalEggHatch = 4,
    AnimalSoundAttractZombies = true,
    AnimalTrackChance = 4,
    AnimalPathChance = 4,
    MaximumRatIndex = 25,
    DaysUntilMaximumRatIndex = 90,
    MetaKnowledge = 3,
    SeeNotLearntRecipe = true,
    MaximumLootedBuildingRooms = 50,
    EnablePoisoning = 1,
    MaggotSpawn = 1,
    LightBulbLifespan = 1.0,
    FishAbundance = 2,
    LevelForMediaXPCutoff = 3,
    LevelForDismantleXPCutoff = 0,
    BloodSplatLifespanDays = 0,
    LiteratureCooldown = 90,
    NegativeTraitsPenalty = 1,
    MinutesPerPage = 2.0,
    KillInsideCrops = true,
    PlantGrowingSeasons = true,
    PlaceDirtAboveground = false,
    FarmingSpeedNew = 1.0,
    FarmingAmountNew = 1.0,
    MaximumLooted = 50,
    DaysUntilMaximumLooted = 60,
    RuralLooted = 1.0,
    MaximumDiminishedLoot = 0,
    DaysUntilMaximumDiminishedLoot = 1825,
    MuscleStrainFactor = 1.0,
    DiscomfortFactor = 1.0,
    WoundInfectionFactor = 1.0,
    NoBlackClothes = true,
    EasyClimbing = false,
    MaximumFireFuelHours = 8,
    FirearmUseDamageChance = 2,
    FirearmNoiseMultiplier = 1.25,
    FirearmJamMultiplier = 1.25,
    FirearmMoodleMultiplier = 1.25,
    FirearmWeatherMultiplier = 1.25,
    FirearmHeadGearEffect = true,
    ClayLakeChance = 0.05,
    ClayRiverChance = 0.05,
    GeneratorTileRange = 20,
    GeneratorVerticalPowerRange = 3,
    Basement = {
        SpawnFrequency = 4,
    },
    Map = {
        AllowMiniMap = false,
        AllowWorldMap = true,
        MapAllKnown = false,
        MapNeedsLight = true,
    },
    ZombieLore = {
        Speed = 4,
        SprinterPercentage = 6,
        Strength = 1,
        Toughness = 1,
        Transmission = 1,
        Mortality = 5,
        Reanimate = 3,
        Cognition = 4,
        DoorOpeningPercentage = 10,
        CrawlUnderVehicle = 6,
        Memory = 1,
        Sight = 2,
        Hearing = 2,
        SpottedLogic = true,
        ThumpNoChasing = true,
        ThumpOnConstruction = true,
        ActiveOnly = 1,
        TriggerHouseAlarm = true,
        ZombiesDragDown = true,
        ZombiesCrawlersDragDown = true,
        ZombiesFenceLunge = true,
        ZombiesArmorFactor = 2.0,
        ZombiesMaxDefense = 90,
        ChanceOfAttachedWeapon = 6,
        ZombiesFallDamage = 1.0,
        DisableFakeDead = 2,
        PlayerSpawnZombieRemoval = 2,
        FenceThumpersRequired = 20,
        FenceDamageMultiplier = 1.5,
    },
    ZombieConfig = {
        PopulationMultiplier = 1.2,
        PopulationStartMultiplier = 1.5,
        PopulationPeakMultiplier = 2.0,
        PopulationPeakDay = 28,
        RespawnHours = 72.0,
        RespawnUnseenHours = 16.0,
        RespawnMultiplier = 0.1,
        RedistributeHours = 12.0,
        FollowSoundDistance = 200,
        RallyGroupSize = 10,
        RallyGroupSizeVariance = 50,
        RallyTravelDistance = 20,
        RallyGroupSeparation = 15,
        RallyGroupRadius = 3,
        ZombiesCountBeforeDelete = 300,
    },
}

-- Ключи пресета, которые НЕ применяем (см. комментарий выше):
-- дату старта храним отдельно; Map/MultiplierConfig/StarterKit — задаёт common;
-- PlaceDirtAboveground принудительно включаем в common (фарм на крышах), не из пресета.
WindowWasher.extinctionSkipKeys = {
    Version = true, StartYear = true, StartMonth = true, StartDay = true,
    StartTime = true, Map = true, MultiplierConfig = true, StarterKit = true,
    PlaceDirtAboveground = true,
}

-- Глубокое слияние таблицы пресета в SandboxVars (вложенные таблицы — рекурсивно,
-- чтобы не затереть подключи, которые движок ожидает в ZombieLore/ZombieConfig).
local function WW_mergePresetTable(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            WW_mergePresetTable(dst[k], v)
        else
            dst[k] = v
        end
    end
end

WindowWasher.applyHardcoreSandbox = function()
    WindowWasher.applyChallengeCommon()

    -- Применяем весь пресет Extinction, кроме «защищённых» ключей.
    for k, v in pairs(WindowWasher.extinctionPreset) do
        if not WindowWasher.extinctionSkipKeys[k] then
            if type(v) == "table" then
                if type(SandboxVars[k]) ~= "table" then SandboxVars[k] = {} end
                WW_mergePresetTable(SandboxVars[k], v)
            else
                SandboxVars[k] = v
            end
        end
    end

    -- Дату старта берём как в нормальном режиме (+6 дней от стандарта: 15 июля) — НЕ из пресета.
    SandboxVars.StartMonth = 7
    SandboxVars.StartDay   = 15
    SandboxVars.StartTime  = 2

    print("[WW] sandbox: HARDCORE (Extinction preset, start date kept)")
end

function WindowWasher.OnGameStart()
    if not WindowWasher._deathHooked then
        Events.OnPlayerDeath.Add(function(player) WindowWasher._onDeath(player) end)
        WindowWasher._deathHooked = true
    end

    -- ТЕСТ: погасить городскую сеть с самого старта, чтобы проверять генераторную фазу.
    if WindowWasher.debug and WindowWasher.debug.forceGridOff then
        local ok = pcall(function()
            if getWorld().setHydroPowerOn then getWorld():setHydroPowerOn(false) end
        end)
        local cur = select(2, pcall(function() return getWorld():isHydroPowerOn() end))
        print(string.format("[WW/ELECTRIC] forceGridOff: setHydroPowerOn(false) ok=%s, isHydroPowerOn=%s",
            tostring(ok), tostring(cur)))
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

    -- B42: спрайты тросов отключены (см. WindowWasher.ropes.enabled=false) —
    -- диагностический дамп флагов rope-спрайтов закомментирован.
    -- local function logSpriteFlags(name)
    --     WW_checkSprite(name) -- печатает сразу всё нужное
    -- end
    --
    -- logSpriteFlags("rope_N_left")
    -- logSpriteFlags("rope_N_right")
end

-- вместо "half" будем везде считать left/right
local function WW_spanLR(sz)
    sz = math.max(1, tonumber(sz) or 5)
    local left  = math.floor((sz - 1) / 2)   -- сколько тайлов уйдёт в «минус»
    local right = sz - left - 1              -- сколько тайлов уйдёт в «плюс»
    return left, right, sz
end

-- === Control panel: two center tiles of the platform ===
local function WW_isPlayerOnControlSquares(player)
    if not player then return false end
    local cx, cy, cz = WindowWasher.ps.cx, WindowWasher.ps.cy, WindowWasher.ps.cz
    if not (cx and cy and cz) then return false end

    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = player:getZ()
    if pz ~= cz then return false end

    if WindowWasher.ps.orient == "EW" then
        -- центр = (cx,cy) и (cx+1,cy)
        return (py == cy) and (px == cx or px == cx + 1)
    else -- "NS"
        -- центр = (cx,cy) и (cx,cy+1)
        return (px == cx) and (py == cy or py == cy + 1)
    end
end


-- ===== Floor placement (single tile) =====
function WindowWasher.createSingleMetalFloor(x, y, z)
    local sq = getSquare(x, y, z)
    if not sq then return nil end

    -- Если на клетке УЖЕ есть родной пол (земля/пол здания на нижнем уровне) —
    -- НЕ кладём свой настил. addFloor занимает floor-слот клетки, поэтому наш
    -- металлический пол оказался бы завязан на тот же слот, что и родной; при
    -- уходе платформы вверх мы удаляли бы из ps.objs объект и сносили вместе с
    -- ним родной пол нижнего уровня (дыра в полу). На «воздушных» уровнях фасада
    -- пола нет (getFloor()==nil) — там настил кладём как обычно.
    -- Клетку, у которой пол уже есть, просто НЕ отслеживаем (возвращаем nil) —
    -- родной пол служит платформой на этом уровне и остаётся нетронутым.
    local hasNativeFloor = false
    pcall(function()
        local f = sq.getFloor and sq:getFloor() or nil
        if f and f:getSprite() then hasNativeFloor = true end
    end)
    if hasNativeFloor then
        return nil
    end

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
local function addRailSpriteAt(x, y, z, spriteName, label, isDecorative)
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
local function addFenceN(x, y, z, isDecorative)
    return addRailSpriteAt(x, y, z, WindowWasher.rails.N, "WW Rail N", isDecorative)
end

-- Перила по западной грани клетки (спрайт с флагами WallW)
local function addFenceW(x, y, z, isDecorative)
    return addRailSpriteAt(x, y, z, WindowWasher.rails.W, "WW Rail W", isDecorative)
end

-- Торцевые перила (заглушки) - для теста все декоративные
function WindowWasher.buildRailsCaps(cx, cy, cz)
    if not (WindowWasher.rails and WindowWasher.rails.enabled) then return end
    local left, right = WW_spanLR(WindowWasher.ps.size)

    if WindowWasher.ps.orient == "EW" then
        addFenceW(cx - left,     cy, cz, true)     -- западный торец (для теста декоративные)
        addFenceW(cx + right + 1, cy, cz, true)    -- восточный торец (для теста декоративные)
    else
        addFenceN(cx, cy - left,     cz, true)     -- северный торец (для теста декоративные)
        addFenceN(cx, cy + right + 1, cz, true)    -- южный торец (для теста декоративные)
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

-- Ставим перила вдоль длинных сторон платформы (обе стороны)
function WindowWasher.buildRailsAlongLine(cx, cy, cz)
	if not (WindowWasher.rails and WindowWasher.rails.enabled) then return end
	local left, right = WW_spanLR(WindowWasher.ps.size)

	if WindowWasher.ps.orient == "EW" then
		local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.EW) or "S"
		for x = cx - left, cx + right do
			-- Перила на внешней стороне (фасад) - декоративные
			if side == "N" then
				addFenceN(x, cy, cz, true)  -- декоративные
			else
				addFenceN(x, cy + 1, cz, true) -- S = север соседа снизу, декоративные
			end
			-- Перила на внутренней стороне (противоположной внешней) - пропускаем средний сегмент
			if x ~= cx then  -- пропускаем средний тайл (cx)
				if side == "N" then
					addFenceN(x, cy + 1, cz, true) -- внутренняя сторона (юг) - декоративные
				else
					addFenceN(x, cy, cz, true) -- внутренняя сторона (север) - декоративные
				end
			end
		end
	else
		local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.NS) or "E"
		for y = cy - left, cy + right do
			-- Перила на внешней стороне (фасад) - декоративные
			if side == "W" then
				addFenceW(cx, y, cz, true)  -- декоративные
			else
				addFenceW(cx + 1, y, cz, true) -- E = запад соседа справа, декоративные
			end
			-- Перила на внутренней стороне (противоположной внешней) - пропускаем средний сегмент
			if y ~= cy then  -- пропускаем средний тайл (cy)
				if side == "W" then
					addFenceW(cx + 1, y, cz, true) -- внутренняя сторона (восток) - декоративные
				else
					addFenceW(cx, y, cz, true) -- внутренняя сторона (запад) - декоративные
				end
			end
		end
	end
end

local function addRopeSpriteAt(x, y, z, spriteName, label)
    print(("[WW/ROPES] try add '%s' at (%d,%d,%d)"):format(tostring(spriteName),x,y,z))
    if not spriteName or spriteName == "" then print("[WW/ROPES]   abort: empty spriteName"); return nil end

    local haveOverlay = WW_checkSprite(spriteName)

    local sq = getSquare(x, y, z); if not sq then print("[WW/ROPES]   abort: no square"); return nil end
    local cell = getWorld():getCell()
    local obj = IsoObject.new(cell, sq, tostring(spriteName))
    if not obj then print("[WW/ROPES]   abort: IsoObject.new == nil"); return nil end

    if label then obj:setName(label) end
    sq:AddTileObject(obj)
    sq:RecalcAllWithNeighbours(true)

    print(("[WW/ROPES]   ADDED ok (overlay=%s). After add:"):format(tostring(haveOverlay)))
    WW_dumpSquare(x,y,z,"RopeSquare")

    table.insert(WindowWasher.ropeObjs, obj)
    return obj
end


local function addRopeN(x, y, z, spriteName)
    -- спрайт должен иметь флаг WallOverlayN
    return addRopeSpriteAt(x, y, z, spriteName, "WW Rope N")
end

function WindowWasher.destroyRopes()
    for _, obj in ipairs(WindowWasher.ropeObjs) do
        local sq = obj and obj:getSquare()
        if sq and obj then
            sq:RemoveTileObject(obj)
            sq:RecalcAllWithNeighbours(true)
        end
    end
    WindowWasher.ropeObjs = {}
end

function WindowWasher.buildRopes(cx, cy, cz)
    if not (WindowWasher.ropes and WindowWasher.ropes.enabled) then
        print("[WW/ROPES] disabled"); return
    end
    local left, right = (function(sz)
        sz = math.max(1, tonumber(sz) or 3)
        local l = math.floor((sz - 1) / 2)
        local r = sz - l - 1
        return l, r
    end)(WindowWasher.ps.size)

    print(("[WW/ROPES] buildRopes: center=(%d,%d,%d) size=%d orient=%s")
        :format(cx,cy,cz, WindowWasher.ps.size, WindowWasher.ps.orient))

    if WindowWasher.ps.orient == "EW" then
        local side = (WindowWasher.railsOuterSide and WindowWasher.railsOuterSide.EW) or "S"
        local xL = cx - left
        local xR = cx + right
        print(("[WW/ROPES]   EW side=%s xL=%d xR=%d"):format(side, xL, xR))

        if side == "N" then
            print("[WW/ROPES]   place at y=cy (north edge of same squares)")
            addRopeN(xL, cy, cz, WindowWasher.ropes.N_left)
            addRopeN(xR, cy, cz, WindowWasher.ropes.N_right)
        else
            print("[WW/ROPES]   place at y=cy+1 (north edge of squares below)")
            addRopeN(xL, cy + 1, cz, WindowWasher.ropes.N_left)
            addRopeN(xR, cy + 1, cz, WindowWasher.ropes.N_right)
        end

        -- Контрольный дамп обеих клеток
        WW_dumpSquare(xL, (side=="N") and cy or (cy+1), cz, "AfterRope-LEFT")
        WW_dumpSquare(xR, (side=="N") and cy or (cy+1), cz, "AfterRope-RIGHT")

    else
        print("[WW/ROPES]   NS orientation — пропуск (нужны WallOverlayW)")
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
    WindowWasher.destroyRopes()

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
    WindowWasher.buildRopes(cx, cy, cz)

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

-- === CONTROL AREA (две центральные клетки платформы) =========================
function WindowWasher.getControlSquares()
    local cx, cy, cz = WindowWasher.ps.cx, WindowWasher.ps.cy, WindowWasher.ps.cz
    local orient, size = WindowWasher.ps.orient, WindowWasher.ps.size
    if not (cx and cy and cz and orient and size) then return {}, cz end

    -- Для чётного размера (6) считаем центральной парой:
    -- EW: (cx,cy) и (cx+1,cy)
    -- NS: (cx,cy) и (cx,cy+1)
    local s1, s2
    if orient == "EW" then
        s1 = getSquare(cx,     cy, cz)
        s2 = getSquare(cx + 1, cy, cz)
    else -- "NS"
        s1 = getSquare(cx, cy,     cz)
        s2 = getSquare(cx, cy + 1, cz)
    end

    local out = {}
    if s1 then table.insert(out, s1) end
    if s2 then table.insert(out, s2) end
    return out, cz
end

function WindowWasher.isPlayerOnControlSquares(player)
    if not player then return false end
    local ctrls, cz = WindowWasher.getControlSquares()
    if not cz or #ctrls == 0 then return false end

    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = player:getZ()
    if pz ~= cz then return false end

    for _, sq in ipairs(ctrls) do
        if sq and sq:getX() == px and sq:getY() == py then
            return true
        end
    end
    return false
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

            -- 1) вытащить из старой клетки И из мира.
            --    removeFromWorld нужен ОБЯЗАТЕЛЬНО: только после него последующий addToWorld
            --    заново зарегистрирует труп в мире/чанке, на что опирается система вони/гниения.
            local ok_rmw = pcall(function() if body.removeFromWorld then body:removeFromWorld() end end)
            local ok_rm  = pcall(function() if body.removeFromSquare then body:removeFromSquare() end end)
            WW_logDead("  removeFromWorld: %s, removeFromSquare: %s", ok_rmw and "OK" or "ERR", ok_rm and "OK" or "ERR")

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

            -- 5) Вернуть в мир БЕЗУСЛОВНО.
            --    Раньше addToWorld вызывался только если isAddedToWorld()==false, но removeFromSquare
            --    не сбрасывает этот флаг -> регистрация трупа в мире оставалась "несвежей" и мудл вони
            --    не следовал за платформой. Теперь после removeFromWorld всегда регистрируем заново.
            local ok_world = pcall(function() if body.addToWorld then body:addToWorld() end end)
            WW_logDead("  addToWorld (unconditional): %s", ok_world and "OK" or "ERR")

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
            -- B42: :Is -> :has (см. WW_propHas), и актуальные имена флагов
            if not skip then
                local props = spr and spr:getProperties()
                local isStructure = props and (
                    WW_propHas(props, "WallN")     or WW_propHas(props, "WallW")     or
                    WW_propHas(props, "WallNW")    or WW_propHas(props, "WallSE")    or
                    WW_propHas(props, "HoppableN") or WW_propHas(props, "HoppableW") or
                    WW_propHas(props, "TallHoppableN") or WW_propHas(props, "TallHoppableW") or
                    WW_propHas(props, "WindowN")   or WW_propHas(props, "WindowW")   or
                    WW_propHas(props, "doorN")     or WW_propHas(props, "doorW")     or
                    WW_propHas(props, "DoorWallN") or WW_propHas(props, "DoorWallW") or
                    WW_propHas(props, "WallOverlay") or
                    WW_propHas(props, "WallNTrans") or WW_propHas(props, "WallWTrans")
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

-- Координаты точки электролебедки (где подвешена люлька тросами)
WindowWasher.winchElectricX = 12785
WindowWasher.winchElectricY = 1538
WindowWasher.winchElectricZ = 26

-- Точка проверки ГЕНЕРАТОРНОГО питания — ВНУТРЕННИЙ запитанный тайл здания.
-- Внешний тайл лебёдки в электросеть не включён, поэтому haveElectricity()/isNoPower()
-- на нём всегда возвращают «нет питания» даже при работающем генераторе или живой сети
-- (см. memory electric-winch-power-check). Поэтому генератор сэмплим на интерьерном тайле.
-- Ближайший ВНУТРЕННИЙ (запитанный) тайл к электролебёдке — для детекта генератора.
WindowWasher.genCheckX = 12780
WindowWasher.genCheckY = 1536
WindowWasher.genCheckZ = 26

-- Проверка наличия электричества для электролебёдки.
-- Питание есть, если: (A) включена городская сеть (getWorld():isHydroPowerOn()),
-- ИЛИ (B) внутренний тайл genCheck запитан (haveElectricity() — генератор/сеть).
-- Тестовый тумблер WindowWasher.debug.forceGridOff пропускает ветку (A) — остаётся только генератор.
function WindowWasher.hasElectricityAtWinch()
	local dbg = WindowWasher.debug or {}

	-- (A) Городская сеть
	if dbg.forceGridOff then
		print("[WW/ELECTRIC] forceGridOff: городская сеть игнорируется (тест генератора)")
	else
		local ok, grid = pcall(function() return getWorld():isHydroPowerOn() end)
		print(string.format("[WW/ELECTRIC] grid: isHydroPowerOn=%s", tostring(ok and grid)))
		if ok and grid then return true end
	end

	-- (B1) Генератор: haveElectricity() на внутреннем запитанном тайле (надёжный способ)
	local gx, gy, gz = WindowWasher.genCheckX, WindowWasher.genCheckY, WindowWasher.genCheckZ
	if gx and gy and gz then
		local sq = getSquare(gx, gy, gz)
		if sq then
			local ok, e = pcall(function() return sq:haveElectricity() end)
			print(string.format("[WW/ELECTRIC] gen interior (%d,%d,%d): haveElectricity=%s",
				gx, gy, gz, tostring(ok and e)))
			if ok and e then return true end
		else
			print(string.format("[WW/ELECTRIC] gen interior (%d,%d,%d): square NOT loaded", gx, gy, gz))
		end
	else
		print("[WW/ELECTRIC] genCheckX/Y/Z не заданы — генераторная фаза не проверяется")
	end

	-- (примечание) Прямую проверку генератора на ВНЕШНЕМ тайле лебёдки
	-- (isGeneratorPoweringSquare) убрали: в B42 она кидает RuntimeException, а внешний
	-- тайл всё равно не запитан. Генератор сэмплим на внутреннем тайле genCheck (ветка B1).

	return false
end

-- Длительности
WindowWasher.ps.moveDurationElectric = 0.5   -- секунды на этаж
WindowWasher.ps.moveDurationManual   = 1.5   -- дольше, игрок крутит руками
-- ===== Timed Action for movement (vertical) =====
ISMovePlatformAction = ISBaseTimedAction:derive("ISMovePlatformAction")

-- ===== Stamina & duration helpers (manual winch) ============================
local function WW_statMults(character)
    local s = math.max(1, math.min(10, character:getPerkLevel(Perks.Strength) or 5))
    local f = math.max(1, math.min(10, character:getPerkLevel(Perks.Fitness)  or 5))

    -- Endurance cost multipliers
    local ms = 1 - 0.1 * (s - 5); ms = math.max(0.50, math.min(1.50, ms))
    local mf = 1 - 0.08 * (f - 5); mf = math.max(0.60, math.min(1.4, mf))

    -- Duration multiplier (faster with strength/fitness)
    local md = 1 - 0.02 * (s - 5) - 0.01 * (f - 5)
    md = math.max(0.80, math.min(1.20, md))

    return ms, mf, md
end

local function WW_manualCostAndDuration(character, isDown)
    local baseCost = WindowWasher.stamina.manualPerFloor or 0.09
    local dirMult  = isDown and (WindowWasher.stamina.manualDownMult or 0.70)
                             or (WindowWasher.stamina.manualUpMult   or 1.00)

    local baseDur  = WindowWasher.ps.moveDurationManual or 1.5
    local dirDur   = isDown and 0.85 or 1.00  -- вниз чуть быстрее

    local ms, mf, md = WW_statMults(character)

    -- === НОВОЕ: перегрузка
    local owkg = WW_overweightKg(character) or 0
    local owCost = owkg * (WindowWasher.stamina.manualOverweightPerKg or 0)

    local staminaCost = baseCost * dirMult * ms * mf + owCost
    local duration    = baseDur * dirDur * md * (1 + math.min(0.50, owkg * 0.01)) -- +1% длительности на 1 кг, макс +50%

    -- штрафы на низкой выносливости (оставляем твою логику)
    local e = WW_getEndurance(character:getStats())
    if e < 0.15 then
        staminaCost = staminaCost * 2.0
        duration    = duration    * 1.50
    elseif e < 0.30 then
        staminaCost = staminaCost * 1.50
        duration    = duration    * 1.25
    end

    return staminaCost, duration
end

function ISMovePlatformAction:new(character, dx, dy, dz, winchType)
    local o = ISBaseTimedAction.new(self, character)
    o.dx, o.dy, o.dz   = dx, dy, dz
    o.winchType        = winchType or "electric"

    if o.winchType == "manual" then
        local isDown = (dz or 0) < 0
        local perFloorCost, durSec = WW_manualCostAndDuration(character, isDown)
        o._totalDrain     = math.max(0, perFloorCost)
        o._drainPerSecond = (durSec > 0) and (o._totalDrain / durSec) or 0
        o.maxTime = (durSec > 0 and durSec or 1.5) * 60

        print(string.format("[WW] Manual calc: cost=%.3f, dur=%.2fs, ow=%.1fkg, S=%d F=%d",
            perFloorCost, durSec, WW_overweightKg(character) or 0,
            character:getPerkLevel(Perks.Strength) or 0,
            character:getPerkLevel(Perks.Fitness)  or 0))
    else
        o.maxTime         = WindowWasher.ps.moveDurationElectric * 60
        o._drainPerSecond = 0
    end
    o.stopOnWalk, o.stopOnRun, o.stopOnAim = true, true, true
    return o
end


function ISMovePlatformAction:isValid()
	if not WW_isPlayerOnControlSquares(self.character) then return false end
	if self.winchType == "manual" then
		local thr = WindowWasher.stamina.autoCancelThreshold or 0.12
		if WW_getEndurance(self.character:getStats()) <= thr then
			return false
		end
	elseif self.winchType == "electric" then
		-- Проверка электричества для электролебедки
		if WindowWasher.hasElectricityAtWinch and type(WindowWasher.hasElectricityAtWinch) == "function" then
			if not WindowWasher.hasElectricityAtWinch() then
				return false
			end
		else
			print("[WW/ELECTRIC] ERROR: hasElectricityAtWinch function not found!")
			return false
		end
	end
	return true
end

function ISMovePlatformAction:start()
    WindowWasher.ps.moving = true
    if self.winchType == "manual" then
        WindowWasher.audio_start("WW_Winch_Manual_Loop")
        self._lastJobDelta = 0
        self._drained = 0
        -- по желанию: WW_beginManualMetabolic(self)
    else
        WindowWasher.audio_start("WW_Winch_Electric_Loop")
    end
    WindowWasher.audio_updatePos()
end

function ISMovePlatformAction:update()
    ISBaseTimedAction.update(self)
    WindowWasher.audio_updatePos()

    if self.winchType == "manual" then
        local d = self.getJobDelta and (self:getJobDelta() or 0) or 0
        local inc = math.max(0, d - (self._lastJobDelta or 0))
        self._lastJobDelta = d

        local de = (self._totalDrain or 0) * inc
        if de > 0 then
            local s = self.character:getStats()
            WW_drainEndurance(s, de)
            self._drained = (self._drained or 0) + de
        end

        local thr = WindowWasher.stamina.autoCancelThreshold or 0.12
        if WW_getEndurance(self.character:getStats()) <= thr then
            self._exhaustedCancel = true
            -- Критично: именно forceStop(), иначе perform() всё равно вызовут
            self:forceStop()
            return
        end
    end
end

function ISMovePlatformAction:stop()
    WindowWasher.audio_stop()
    WindowWasher.ps.moving = false
    -- по желанию: WW_endManualMetabolic(self)
    ISBaseTimedAction.stop(self)
end

function ISMovePlatformAction:perform()

    -- safety-гейт: если автокэнсел уже случился — не двигаем ничего
    if self._exhaustedCancel then
        WindowWasher.audio_stop()
        WindowWasher.ps.moving = false
        -- завершаем действие как отменённое без сайд-эффектов
        return
    end

    if not WW_isPlayerOnControlSquares(self.character) then
        print("WW TA perform ABORT: player left control panel")
        WindowWasher.ps.moving = false
        return
    end

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

    -- Меняем только высоту персонажа, X/Y сохраняем полностью
        local px = self.character:getX()
        local py = self.character:getY()

        self.character:setZ(tz)
        if self.character.setLz then self.character:setLz(tz) end  -- стабилизация физики по Z

        -- X/Y НЕ меняем (оставляем как были)
        self.character:setX(px)
        self.character:setY(py)

    if self.winchType == "manual" then
        -- по желанию: WW_endManualMetabolic(self)
        -- добор крошечного остатка (на случай редких апдейтов)
        local drained   = self._drained or 0
        local remainder = math.max(0, (self._totalDrain or 0) - drained)
        if remainder > 0 then
            local s = self.character:getStats()
            WW_drainEndurance(s, remainder)
        end
    end
    WindowWasher.audio_stop()
    WindowWasher.ps.moving = false
    ISBaseTimedAction.perform(self)
end


-- Public API for moves (only vertical for now)
function WindowWasher.move(dx, dy, dz, playerObj, winchType)
    if WindowWasher.ps.moving then print("WW: already moving"); return end
    local p = playerObj or getPlayer()
    if not WW_isPlayerOnControlSquares(p) then
        print("WW: move denied (player not on control panel)")
        return
    end

	-- ⬇️ мгновенный отказ, если сил не хватает для ручной лебёдки
	if winchType == "manual" then
		local thr = WindowWasher.stamina.autoCancelThreshold or 0.12
		if WW_getEndurance(p:getStats()) <= thr then
			-- тут без UI, просто тихо откажем
			print(string.format("WW: manual move denied (endurance<=%.2f)", thr))
			return
		end
	elseif winchType == "electric" then
		-- Проверка электричества для электролебедки
		if WindowWasher.hasElectricityAtWinch and type(WindowWasher.hasElectricityAtWinch) == "function" then
			if not WindowWasher.hasElectricityAtWinch() then
				print("WW: electric move denied (no electricity at winch point)")
				return
			end
		else
			print("[WW/ELECTRIC] ERROR: hasElectricityAtWinch function not found!")
			return
		end
	end

    ISTimedActionQueue.add(ISMovePlatformAction:new(p, dx, dy, dz, winchType))
end


function WindowWasher.moveInstant(dx, dy, dz, playerObj)
    local p = playerObj or getPlayer()
    if not WW_isPlayerOnControlSquares(p) then
        print("WW: instant move denied (player not on control panel)")
        return
    end

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

    local px, py = playerObj:getX(), playerObj:getY()
    playerObj:setZ(tz)
    if playerObj.setLz then playerObj:setLz(tz) end
    playerObj:setX(px)
    playerObj:setY(py)
end

-- wrappers for context menu (чтобы учесть target первым аргументом)
function WindowWasher.moveMenu(_, dx, dy, dz, playerObj, winchType)
    WindowWasher.move(dx, dy, dz, playerObj, winchType)
end
function WindowWasher.moveInstantMenu(_, dx, dy, dz, playerObj)
    WindowWasher.moveInstant(dx, dy, dz, playerObj)
end



-- ===== Context menu (vertical only) =====
function WindowWasher.onFillWorldContextMenu(player, context, worldobjects, test)
    if test then return end
    local p = getSpecificPlayer(player); if not p then return end
    if not WindowWasher.isPlayerOnControlSquares(p) then return end

	local root = context:addOption("Move Scaffold")
	local sub  = ISContextMenu:getNew(context); context:addSubMenu(root, sub)

	-- Электро (только если есть электричество)
	if WindowWasher.hasElectricityAtWinch and type(WindowWasher.hasElectricityAtWinch) == "function" then
		if WindowWasher.hasElectricityAtWinch() then
			sub:addOption("Up (Electric)",   WindowWasher, WindowWasher.moveMenu, 0, 0,  1, p, "electric")
			sub:addOption("Down (Electric)", WindowWasher, WindowWasher.moveMenu, 0, 0, -1, p, "electric")
		end
	else
		print("[WW/ELECTRIC] ERROR: hasElectricityAtWinch function not found in context menu!")
	end

	-- Ручная (всегда доступна)
	sub:addOption("Up (Manual)",   WindowWasher, WindowWasher.moveMenu, 0, 0,  1, p, "manual")
	sub:addOption("Down (Manual)", WindowWasher, WindowWasher.moveMenu, 0, 0, -1, p, "manual")
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

-- ===== Window Washer: стартовый аутфит и лут =================================

-- Удобный хелпер: безопасно надеть предмет (подберёт правильный BodyLocation)
-- СИЛОВОЕ надевание вещи в нужный BodyLocation
local function WW_wear(playerObj, item)
    if not (playerObj and item) then return end
    local loc = item.getBodyLocation and item:getBodyLocation() or nil
    if not loc or loc == "" then
        -- на всякий: попытка авто-надевания (некоторые сумки/пояса)
        pcall(function() if playerObj.wearItem then playerObj:wearItem(item) end end)
        return
    end
    -- основной способ: прямо в нужный слот
    pcall(function() playerObj:setWornItem(loc, item) end)
    -- подстраховка: если не встал — попробовать авто-надевание
    if not pcall(function() return playerObj:getWornItem(loc) == item end) then
        pcall(function() if playerObj.wearItem then playerObj:wearItem(item) end end)
        pcall(function() playerObj:setWornItem(loc, item) end)
    end
end

-- Подготовка еды/напитков (свежесть/заполненность)
local function WW_freshFood(item)
    if item and item:IsFood() then pcall(function() item:setAge(0) end) end
end
local function WW_fillDrainable(item)
    if item and item.setUsedDelta then pcall(function() item:setUsedDelta(1.0) end) end
end

-- Главная процедура наполнения инвентаря и одежды
function WindowWasher.setupWindowWasherLoadout(playerObj)
    if not playerObj then return end
    print("[WW] setting up inventory and clothing for Window Washer")

    local inv = playerObj:getInventory()

    -- Полная очистка инвентаря и одежды
    pcall(function() inv:clear() end)
    pcall(function() playerObj:clearWornItems() end)
    pcall(function() playerObj:setClothingItem_Feet(nil) end)
    pcall(function() playerObj:setClothingItem_Legs(nil) end)
    pcall(function() playerObj:setClothingItem_Torso(nil) end)

    local glasses   = inv:AddItem("Base.Glasses_Sun")
    local socks     = inv:AddItem("Base.Socks_Ankle")
    local boots     = inv:AddItem("Base.Shoes_WorkBoots")
    local jeans     = inv:AddItem("Base.Trousers_Denim")
    local tshirt    = inv:AddItem("Base.Tshirt_DefaultDECAL")
    local shirt     = inv:AddItem("Base.Shirt_Lumberjack")
    local gloves    = inv:AddItem("Base.Gloves_LeatherGloves")
    local helmet    = inv:AddItem("Base.Hat_HardHat")
    local fanny     = inv:AddItem("Base.Bag_FannyPackFront")
    local belt      = inv:AddItem("Base.Belt2")   -- B42: "Base.Belt" переименован в "Base.Belt2"

    -- Порядок слоёв важен:
    WW_wear(playerObj, socks)
    WW_wear(playerObj, boots)
    WW_wear(playerObj, jeans)
    WW_wear(playerObj, tshirt)   -- сначала футболка (нижний слой)
    WW_wear(playerObj, shirt)    -- сверху рубашка
    WW_wear(playerObj, gloves)   -- перчатки
    WW_wear(playerObj, glasses)
    WW_wear(playerObj, helmet)
    WW_wear(playerObj, belt)
    WW_wear(playerObj, fanny)

    -- ⌚ Часы на левую руку
    local watch = inv:AddItem("Base.WristWatch_Left_DigitalBlack")
    if watch then
        WW_wear(playerObj, watch) -- поставит по BodyLocation (ожидаемо "LeftWrist")
    end

    -- Явные гарантийные проверки на проблемные слоты.
    -- B42: getWornItem/setWornItem принимают ItemBodyLocation, а НЕ строку
    -- (строка → «expected argument of type ItemBodyLocation, got String»).
    -- Берём слот у самого предмета через :getBodyLocation().
    local function WW_ensureWorn(item)
        if not item then return end
        pcall(function()
            local loc = item.getBodyLocation and item:getBodyLocation() or nil
            if loc and playerObj:getWornItem(loc) ~= item then
                playerObj:setWornItem(loc, item)
            end
        end)
    end
    WW_ensureWorn(socks)
    WW_ensureWorn(gloves)
    WW_ensureWorn(tshirt)

    -- ==== ДОП. СТАРТОВЫЙ ИНВЕНТАРЬ ===========================================
    local function WW_safeAdd(inv, fullType)
        if not inv or not fullType then return nil end
        local ok, item = pcall(function() return inv:AddItem(tostring(fullType)) end)
        return (ok and item) or nil
    end

    -- Ланчбокс с едой (без воды)
    local lunch = WW_safeAdd(inv, "Base.Lunchbox")
    if lunch and lunch.IsInventoryContainer and lunch:IsInventoryContainer() then
        local boxInv = lunch:getInventory()
        local it1 = WW_safeAdd(boxInv, "Base.Sandwich");  WW_freshFood(it1)
        local it2 = WW_safeAdd(boxInv, "Base.Apple");           WW_freshFood(it2)
        local it3 = WW_safeAdd(boxInv, "Base.Pop2");            WW_fillDrainable(it3)
    else
        local it1 = WW_safeAdd(inv, "Base.Sandwich");  WW_freshFood(it1)
        local it2 = WW_safeAdd(inv, "Base.Apple");           WW_freshFood(it2)
        local it3 = WW_safeAdd(inv, "Base.Pop2");            WW_fillDrainable(it3)
    end

    -- Вода в инвентарь (не в ланчбокс)
    local water = WW_safeAdd(inv, "Base.WaterBottle")
    WW_fillDrainable(water)

    -- Две верёвки
    for i = 1, 2 do
        WW_safeAdd(inv, "Base.Rope")
    end
end


-- ===== Player spawn =====
WindowWasher.AddPlayer = function(playerNum, playerObj)
    if not playerObj or playerObj:getHoursSurvived() > 0 then return end
	local function delayedTeleport()
        local cx, cy, cz = WindowWasher.x, WindowWasher.y, WindowWasher.z

        WindowWasher.ps.size   = 3
        WindowWasher.ps.orient = "EW"
        WindowWasher.ps.sprite = "constructedobjects_01_86"

        WindowWasher.buildPlatformAt(cx, cy, cz)
        playerObj:setX(cx + 0.5); playerObj:setY(cy + 0.5); playerObj:setZ(cz)

        WindowWasher.setupWindowWasherLoadout(playerObj)

        print(("WindowWasher: platform ready at %d,%d,%d"):format(cx,cy,cz))
		Events.OnTick.Remove(delayedTeleport)
	end

    Events.OnTick.Add(delayedTeleport)
end
	


WindowWasher.Render = function() end
-- фреймворк вызывает globalChallenge.RemovePlayer на смерть — без no-op будет nil-краш
WindowWasher.RemovePlayer = function(_) end

-- ===== Challenge metadata (общие для обоих режимов) =====
WindowWasher.completionText = "The world ended while you were at work. You’re stuck on a scaffold, outside a skyscraper. Get in. Survive.";
WindowWasher.image = "media/ui/Challenge_WindowWasher.png";
WindowWasher.world = "Muldraugh, KY";

-- spawn coordinates in Louisville
WindowWasher.x = 12785;
WindowWasher.y = 1539;
WindowWasher.z = 24;
WindowWasher.hourOfDay = 7;

-- ===== Два режима испытания =====
-- Каждый режим — отдельная запись с уникальным id/gameMode и своим OnInitWorld,
-- но с общей логикой платформы/спавна/эффекта (наследуется от WindowWasher).
-- Имя/описание в меню берётся по ключам Challenge_<id>_name / _desc (Challenge.json).
local function makeMode(id, gameMode, applySandbox)
    local C = {}
    for k, v in pairs(WindowWasher) do C[k] = v end   -- общие поля и функции
    C.id       = id
    C.gameMode = gameMode
    C.OnInitWorld = function()
        applySandbox()
        print(("[WW] OnInitWorld mode=%s gameMode=%s"):format(id, gameMode))
        Events.OnGameStart.Add(WindowWasher.OnGameStart)
    end
    return C
end

local NORMAL   = makeMode("WindowWasher",   "Window Washer",          WindowWasher.applyNormalSandbox)
local HARDCORE = makeMode("WindowWasherHC", "Window Washer Hardcore", WindowWasher.applyHardcoreSandbox)

-- ===== Register events =====
-- НЕ регистрируем OnInitWorld глобально — фреймворк сам вызывает OnInitWorld выбранного
-- режима (иначе настройки протекали бы во все миры).
Events.OnChallengeQuery.Add(function()
    addChallenge(NORMAL)
    addChallenge(HARDCORE)
end)
