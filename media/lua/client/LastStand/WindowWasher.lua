
BoozyRampager = {}

WindowWasher.Add = function()
	addChallenge(WindowWasher);
end

local delayTicks = 0
local initialized = false

WindowWasher.OnInitWorld = function()

	SandboxVars.Zombies = 3;
	SandboxVars.Distribution = 1;
	SandboxVars.DayLength = 3;
	SandboxVars.StartMonth = 7;
	SandboxVars.StartDay = 9;
	SandboxVars.StartTime = 1;

	SandboxVars.WaterShut = 2;
	SandboxVars.WaterShutModifier = 14;

	SandboxVars.ElecShut = 2;
	SandboxVars.ElecShutModifier = 14;

 	SandboxVars.FoodLoot = 4;
 	SandboxVars.CannedFoodLoot = 4;

 	SandboxVars.RangedWeaponLoot = 3;
 	SandboxVars.AmmoLoot = 4;
 	SandboxVars.SurvivalGearsLoot = 3;
	SandboxVars.MechanicsLoot = 5;
 	SandboxVars.LiteratureLoot = 4;
 	SandboxVars.MedicalLoot = 4;
 	SandboxVars.WeaponLoot = 4;
 	SandboxVars.OtherLoot = 4;
    SandboxVars.LootItemRemovalList = "";
	SandboxVars.Temperature = 3;
	SandboxVars.Rain = 3;
	--    SandboxVars.erosion = 12
	SandboxVars.ErosionSpeed = 3
	SandboxVars.Farming = 3;
	SandboxVars.NatureAbundance = 3;
	SandboxVars.PlantResilience = 3;
	SandboxVars.PlantAbundance = 3;
	SandboxVars.Alarm = 3;
	SandboxVars.LockedHouses = 3;
	SandboxVars.FoodRotSpeed = 4;
	SandboxVars.FridgeFactor = 4;
	SandboxVars.LootRespawn = 1;
	SandboxVars.StatsDecrease = 3;
	SandboxVars.StarterKit = false;
	SandboxVars.TimeSinceApo = 1;
	SandboxVars.MultiHitZombies = false;

	SandboxVars.MultiplierConfig = {
		XPMultiplierGlobal = 1,
		XPMultiplierGlobalToggle = true,
	}
	

	SandboxVars.ZombieConfig.PopulationMultiplier = ZombiePopulationMultiplier.Insane

	print ("Set to :" .. BoozyRampage.x .. ", "..BoozyRampage.y..", ".. BoozyRampage.z)

	Events.OnGameStart.Add(BoozyRampage.OnGameStart);

end

WindowWasher.AddPlayer = function(playerNum, playerObj)

	if not playerObj or playerObj:getHoursSurvived() > 0 then return end

	-- Get descriptor and set name and profession
	local desc = playerObj:getDescriptor()

	print("setting up inventory and clothing for Boozy Rampage")
	-- Clear inventory and clothes
	playerObj:getInventory():clear()
	playerObj:clearWornItems()
	playerObj:setClothingItem_Feet(nil)
	playerObj:setClothingItem_Legs(nil)
	playerObj:setClothingItem_Torso(nil)

	-- Add black shoes
	local shoes = playerObj:getInventory():AddItem("Base.Shoes_TrainerTINT")
	playerObj:setClothingItem_Feet(shoes)

	-- Add prison jumpsuit
	local jumpsuit = playerObj:getInventory():AddItem("Base.Boilersuit_Prisoner")
	playerObj:setClothingItem_Torso(jumpsuit)
	playerObj:setClothingItem_Legs(jumpsuit)


	-- delay teleportation until game fully starts
	-- otherwise getChunkMap error
	-- we'll use a one-time OnTick event to do this safely
	local function delayedTeleport()
		playerObj:setX(12789)
		playerObj:setY(1616)
		playerObj:setZ(4)
		Events.OnTick.Remove(delayedTeleport)
	end
	Events.OnTick.Add(delayedTeleport)

end
	
WindowWasher.Render = function()
	--~ 	getTextManager():DrawStringRight(UIFont.Small, getCore():getOffscreenWidth() - 20, 20, "Zombies left : " .. (EightMonthsLater.zombiesSpawned - EightMonthsLater.deadZombie), 1, 1, 1, 0.8);
	--~ 	getTextManager():DrawStringRight(UIFont.Small, (getCore():getOffscreenWidth()*0.9), 40, "Next wave : " .. tonumber(((60*60) - EightMonthsLater.waveTime)), 1, 1, 1, 0.8);
end


WindowWasher.id = "WindowWasher";
WindowWasher.completionText = "The world ended while you were at work. You’re stuck on a scaffold, outside a skyscraper. Get in. Survive.";
WindowWasher.image = "media/ui/Challenge_WindowWasher.png";
WindowWasher.gameMode = "Window Washer";
WindowWasher.world = "Muldraugh, KY";

-- spawn 
WindowWasher.x = 12789;
WindowWasher.y = 1616;
WindowWasher.z = 4;

WindowWasher.hourOfDay = 7;

Events.OnInitWorld.Add(WindowWasher.OnInitWorld)
Events.OnChallengeQuery.Add(WindowWasher.Add)
