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
if profObj then
    local profDef = safe("addCharacterProfessionDefinition", function()
        return CharacterProfessionDefinition.addCharacterProfessionDefinition(
            profObj, "UI_prof_WindowWasher", 8, "UI_prof_WindowWasherDesc", "prof_windowwasher")
    end)
    if profDef and traitObj then
        safe("profDef:addGrantedTrait", function() return profDef:addGrantedTrait(traitObj) end)
    end
end

print("[WW/REG] chunk end")
