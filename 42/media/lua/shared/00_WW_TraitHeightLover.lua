-- 00_WW_TraitHeightLover.lua
-- Регистрация трейта + привязка к профессии. Без событий, с защитой от дублей.

-- 1) Регистрируем трейт сразу при загрузке файла
if not TraitFactory.getTrait("WW_HeightLover") then
    local tr = TraitFactory.addTrait(
        "WW_HeightLover",
        getText("UI_trait_WWHeightLover"),
        0,
        getText("UI_trait_WWHeightLover_Desc"),
        true -- profession-only
    )
    if tr and tr.setIcon then tr:setIcon("Trait_WWHeightLover") end
end

-- 2) Привязываем к профессии, если уже существует
local function ensureTraitOnProfession()
    local prof = ProfessionFactory.getProfession("WindowWasher")
    if not prof then return end
    local list = prof:getFreeTraits()
    local has = false
    for i = 0, list:size()-1 do
        if list:get(i) == "WW_HeightLover" then has = true; break end
    end
    if not has then prof:addFreeTrait("WW_HeightLover") end
end

-- Пытаемся сразу:
pcall(ensureTraitOnProfession)
-- И дублируем проверку на старте (на случай другого порядка инициализации):
Events.OnGameBoot.Add(ensureTraitOnProfession)
