print("WindowWasher.lua started")  -- Проверка: выполняется ли вообще скрипт

local BoozyRampage = {}

function BoozyRampage.ChallengeName()
    return "Window Washer Challenge"
end

function BoozyRampage.OnStart()
    print("Challenge started!")
end

print("Type of AddChallenge: ", type(AddChallenge))  -- Проверка: определена ли функция
