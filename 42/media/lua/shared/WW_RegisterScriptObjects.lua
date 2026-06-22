-- 42/media/lua/shared/WW_RegisterScriptObjects.lua
-- B42 (rev 964): кастомные профессия/трейт создаются ПОЛНОСТЬЮ из Lua.
-- Почему не скриптом: скрипты character_*_definition парсятся РАНЬШЕ mod-Lua
-- (подтверждено логами), а *_definition кэширует объект CharacterProfession/
-- CharacterTrait в конструкторе -> зарегистрировать объект до парсинга из Lua
-- нельзя (трейт -> NPE при загрузке, профессия -> краш при выборе).
-- Решение: регистрируем объект + добавляем definition здесь, из Lua. Экран создания
-- персонажа читает реестр/список definition'ов «вживую», поэтому порядок не важен.
-- Подтверждено тестом: register(id), addCharacterTraitDefinition,
-- addCharacterProfessionDefinition и profDef:addGrantedTrait вызываются из Lua.

print("[WW/REG] chunk start")

local PROF_ID  = "ww:windowwasher"
local TRAIT_ID = "ww:heightlover"

local function safe(label, fn)
    local ok, res = pcall(fn)
    print(("[WW/REG] %s -> ok=%s res=%s"):format(label, tostring(ok), tostring(res)))
    if ok then return res end
    return nil
end

-- Объекты (рабочая форма — register(id), 1 аргумент).
local profObj  = safe("CharacterProfession.register", function() return CharacterProfession.register(PROF_ID) end)
local traitObj = safe("CharacterTrait.register",      function() return CharacterTrait.register(TRAIT_ID) end)

-- Definition трейта: addCharacterTraitDefinition(CharacterTrait, uiName, cost, uiDesc, isProfessionTrait, disabledMP)
if traitObj then
    safe("addCharacterTraitDefinition", function()
        return CharacterTraitDefinition.addCharacterTraitDefinition(
            traitObj, "UI_trait_WWHeightLover", 0, "UI_trait_WWHeightLover_Desc", true, false)
    end)
end

-- Definition профессии: addCharacterProfessionDefinition(CharacterProfession, uiName, cost, uiDesc, iconPath)
-- cost = очки, выдаваемые профессией. Раньше было 8; теперь профессия даёт перки
-- (granted-трейты + Fitness), поэтому бонусных очков не даём — cost = 0.
if profObj then
    local profDef = safe("addCharacterProfessionDefinition", function()
        return CharacterProfessionDefinition.addCharacterProfessionDefinition(
            profObj, "UI_prof_WindowWasher", 0, "UI_prof_WindowWasherDesc", "prof_windowwasher")
    end)
    if profDef then
        -- Кастомный трейт Height Lover — выдаётся профессией бесплатно.
        if traitObj then
            safe("profDef:addGrantedTrait(heightlover)", function() return profDef:addGrantedTrait(traitObj) end)
        end

        -- Стартовый фитнес 5 -> 6. XPBoost не влияет на стоимость профессии
        -- (vanilla-профессии задают Fitness=1 так же).
        safe("profDef:addXPBoost(Fitness,1)", function()
            return profDef:addXPBoost(PerkFactory.getPerk(Perks.Fitness), 1)
        end)

        -- Профильные vanilla-трейты, выдаются профессией бесплатно (granted):
        -- Brave, Gymnast (Lightfoot+1/Nimble+1), Outdoorsman. Объекты vanilla-
        -- трейтов уже существуют на этом этапе (скрипты парсятся раньше mod-Lua).
        -- Стоимость профессии при этом не меняется.
        local granted = {
            { name = "BRAVE",       id = "Base.Brave" },
            { name = "GYMNAST",     id = "Base.Gymnast" },
            { name = "OUTDOORSMAN", id = "Base.Outdoorsman" },
        }
        for _, g in ipairs(granted) do
            local tr = CharacterTrait[g.name]
            if tr == nil then
                tr = safe("CharacterTrait.get(" .. g.id .. ")", function() return CharacterTrait.get(g.id) end)
            end
            if tr then
                safe("profDef:addGrantedTrait(" .. g.name .. ")", function() return profDef:addGrantedTrait(tr) end)
            else
                print("[WW/REG] WARN vanilla trait not found: " .. g.name)
            end
        end
    end
end

print("[WW/REG] chunk end")
