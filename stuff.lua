--[[
	Egg Farm Simulator · Autofarm
	UI: Ember (loaded from GitHub)

	• Everything is controlled from the menu. K hides / shows it.
	• Settings save automatically (workspace/EggFarmSim/Autofarm.json).
	• Running the script again closes the old menu and stops the old loops.
]]

local EMBER_URL = "https://raw.githubusercontent.com/sillysteals/main/refs/heads/main/ember.lua"
local Ember = loadstring(game:HttpGet(EMBER_URL))()

------------------------------------------------------------------
-- Services & remotes
------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local Events = ReplicatedStorage:WaitForChild("Events")
local HeroEvent = Events:WaitForChild("Heroes")
local ProgressEvent = Events:WaitForChild("Progress")
local WeaponEvent = Events:WaitForChild("Weapon")
local ItemsEvent = Events:WaitForChild("Items")

------------------------------------------------------------------
-- Hero data (read live from ReplicatedStorage.Settings.HeroesData)
-- Trophy IDs match the hero they belong to, so trophies use this too.
------------------------------------------------------------------
local Heroes = {} -- [id] = { name = "Tarzan", upgrades = 5 }
local heroDataError

do
	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Settings"):WaitForChild("HeroesData"))
	end)
	if ok and type(result) == "table" and type(result.Stats) == "table" then
		for id, info in pairs(result.Stats) do
			local n = tonumber(id)
			if n and type(info) == "table" then
				Heroes[n] = {
					name = type(info.Title) == "string" and info.Title or ("Hero " .. n),
					upgrades = type(info.Upgrades) == "table" and #info.Upgrades or nil,
				}
			end
		end
	else
		heroDataError = ok and "HeroesData had no Stats table" or tostring(result)
		warn("[EggFarm] Couldn't read HeroesData:", heroDataError)
	end
end

local DEFAULT_UPGRADES = 6 -- only used if a hero isn't in HeroesData

-- "[2] Tarzan"
local function heroLabel(id)
	id = tonumber(id)
	if not id then
		return "-"
	end
	return ("[%d] %s"):format(id, Heroes[id] and Heroes[id].name or "Unknown")
end

-- "[2] Tarzan" -> 2
local function idFromLabel(label)
	return tonumber(tostring(label):match("^%[(%d+)%]"))
end

-- Every hero as "[id] Name", sorted by ID
local function heroOptions()
	local ids = {}
	for id in pairs(Heroes) do
		table.insert(ids, id)
	end
	table.sort(ids)
	local options = {}
	for _, id in ipairs(ids) do
		table.insert(options, heroLabel(id))
	end
	return options
end

------------------------------------------------------------------
-- Session guard (re-running replaces the old copy)
------------------------------------------------------------------
if _G.EggFarm and _G.EggFarm.Stop then
	pcall(_G.EggFarm.Stop)
end
if _G.EggFarmRayfield then -- the old Rayfield version
	pcall(function()
		_G.EggFarmRayfield:Destroy()
	end)
	_G.EggFarmRayfield = nil
end

local session = (_G.EggFarmSession or 0) + 1
_G.EggFarmSession = session

local function alive()
	return _G.EggFarmSession == session
end

local connections = {}
local function track(conn)
	table.insert(connections, conn)
	return conn
end

------------------------------------------------------------------
-- State (driven by the menu) & stats
------------------------------------------------------------------
local State = {
	-- features
	Diamonds = false,
	Meat = false,
	Grapes = false,
	HeroFarm = false,
	AutoAdvance = false,
	BossFarm = false,
	AutoReroll = false,

	-- diamonds / meat / grapes
	ReturnAfterDiamonds = true,
	DiamondTimeout = 1.5,  -- skip a diamond that's still there after this long
	MeatRange = 50,
	TouchInterval = 0.25,  -- meat / grape rescan interval

	-- heroes
	SingleHero = false,
	SingleHeroId = 2,

	-- boss
	DodgeMargin = 10, -- extra studs kept around every attack's area
	BossHeight = 7,   -- studs above the top of the boss
	BossReturn = false,

	-- trophies
	SavedTrophies = { ["2"] = true, ["26"] = true, ["40"] = true },
	RerollDelay = 0.25,

	-- misc
	SwapArgs = false,
	Debug = false,
}

local Stats = {
	Diamonds = 0,
	Meat = 0,
	Grapes = 0,
	HeroBuyAttempts = 0,
	HeroTicks = 0,
	BatchPasses = 0,
	Advances = 0,
	BossFights = 0,
	Dodges = 0,
	BossAttacks = 0,
	Rerolls = 0,
}

local DIAMOND_CHECK = 0.25
local REMOTE_DELAY = 0.1

local hasTouch = typeof(firetouchinterest) == "function"
local bossActive = false -- boss farm owns the character (pauses diamonds)

local function log(...)
	if State.Debug then
		print("[EggFarm]", ...)
	end
end

------------------------------------------------------------------
-- Character & touch helpers
------------------------------------------------------------------
local function getRoot()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getPart(obj)
	if obj:IsA("BasePart") then
		return obj
	end
	if obj:IsA("Model") and obj.PrimaryPart then
		return obj.PrimaryPart
	end
	return obj:FindFirstChildWhichIsA("BasePart", true)
end

-- Finds the TouchTransmitter by class (in case the game renames it)
local function getTouchPart(obj)
	local tt = obj:FindFirstChildOfClass("TouchTransmitter") or obj:FindFirstChildWhichIsA("TouchTransmitter", true)
	if tt and tt.Parent and tt.Parent:IsA("BasePart") then
		return tt.Parent
	end
	return nil
end

-- state 0 = touch begin, 1 = touch end
local function touch(root, part, state)
	if not hasTouch then
		return
	end
	if State.SwapArgs then
		firetouchinterest(part, root, state)
	else
		firetouchinterest(root, part, state)
	end
end

local function tap(root, part)
	touch(root, part, 0)
	task.wait()
	touch(root, part, 1)
end

-- All touch-begins, one frame, all touch-ends (big batches go out instantly)
local function tapBatch(root, parts)
	for _, part in ipairs(parts) do
		pcall(touch, root, part, 0)
	end
	task.wait()
	for _, part in ipairs(parts) do
		if part.Parent then
			pcall(touch, root, part, 1)
		end
	end
end

local function placeAt(root, pos)
	root.CFrame = CFrame.new(pos)
	root.AssemblyLinearVelocity = Vector3.zero
end

-- Only one feature moves the character at a time
local tpBusy = false
local function lockTeleport()
	while tpBusy do
		task.wait()
	end
	tpBusy = true
end
local function unlockTeleport()
	tpBusy = false
end
local function withTeleport(fn)
	lockTeleport()
	local ok, err = pcall(fn)
	unlockTeleport()
	if not ok then
		warn("[EggFarm]", err)
	end
end

------------------------------------------------------------------
-- Farm lookup
------------------------------------------------------------------
local cachedFarm

local function findFarm()
	local farms = workspace:FindFirstChild("Farms")
	if not farms then
		return nil
	end
	for _, d in ipairs(farms:GetDescendants()) do
		if d:IsA("ObjectValue") and d.Value then
			if d.Value == player or d.Value.Name == player.Name then
				return d.Parent
			end
		elseif d:IsA("StringValue") and d.Value == player.Name then
			return d.Parent
		end
	end
	return nil
end

local function getFarm(forceRefresh)
	if not forceRefresh and cachedFarm and cachedFarm.Parent then
		return cachedFarm
	end
	cachedFarm = findFarm()
	if cachedFarm then
		log("Found farm:", cachedFarm:GetFullName())
	end
	return cachedFarm
end

------------------------------------------------------------------
-- Diamonds
------------------------------------------------------------------
local skippedDiamonds = setmetatable({}, { __mode = "k" })

local function getDiamondFolder()
	local farm = getFarm()
	return farm and farm:FindFirstChild("Diamonds")
end

local function countDiamonds(folder)
	local n = 0
	if folder then
		for _, d in ipairs(folder:GetChildren()) do
			if not skippedDiamonds[d] then
				n += 1
			end
		end
	end
	return n
end

local function countSkipped()
	local n = 0
	for d in pairs(skippedDiamonds) do
		if d.Parent then
			n += 1
		end
	end
	return n
end

local function collectDiamonds(folder)
	withTeleport(function()
		local root = getRoot()
		if not root then
			return
		end
		local original = root.CFrame

		local function running()
			return alive() and State.Diamonds and not bossActive
		end

		while running() and folder.Parent do
			local didAny = false
			for _, diamond in ipairs(folder:GetChildren()) do
				if not running() then
					break
				end
				if not skippedDiamonds[diamond] then
					local part = getPart(diamond)
					root = getRoot()
					if part and root then
						didAny = true
						root.CFrame = part.CFrame

						local touchPart = getTouchPart(diamond)
						if touchPart then
							pcall(tap, root, touchPart)
						end

						local start = os.clock()
						repeat
							task.wait()
						until not diamond.Parent or os.clock() - start > State.DiamondTimeout

						if diamond.Parent then
							skippedDiamonds[diamond] = true
							log("Diamond wouldn't collect, skipping:", diamond:GetFullName())
						else
							Stats.Diamonds += 1
						end
					end
				end
			end
			if not didAny then
				break
			end
		end

		root = getRoot()
		if State.ReturnAfterDiamonds and root then
			root.CFrame = original
		end
	end)
end

task.spawn(function()
	while alive() do
		if State.Diamonds and not bossActive then
			local folder = getDiamondFolder()
			if countDiamonds(folder) > 0 then
				collectDiamonds(folder)
			end
		end
		task.wait(DIAMOND_CHECK)
	end
end)

------------------------------------------------------------------
-- Meat (anything named "Meat" in workspace, within range)
------------------------------------------------------------------
local function inRange(root, part)
	return (part.Position - root.Position).Magnitude <= State.MeatRange
end

local function getMeatParts(root)
	local parts = {}
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj.Name == "Meat" then
			local part = getTouchPart(obj)
			if part and inRange(root, part) then
				table.insert(parts, part)
			end
		end
	end
	return parts
end

-- Sweep
task.spawn(function()
	while alive() do
		local root = getRoot()
		if State.Meat and root then
			local parts = getMeatParts(root)
			if #parts > 0 then
				log(("Meat: touching %d"):format(#parts))
				tapBatch(root, parts)
				Stats.Meat += #parts
			end
		end
		task.wait(State.TouchInterval)
	end
end)

-- Instant: grab new meat the moment it spawns
track(workspace.ChildAdded:Connect(function(obj)
	if obj.Name ~= "Meat" or not (alive() and State.Meat) then
		return
	end
	task.spawn(function()
		-- the TouchTransmitter can replicate a moment after the item itself
		local part
		local start = os.clock()
		repeat
			part = getTouchPart(obj)
			if part then
				break
			end
			task.wait(0.1)
		until not obj.Parent or os.clock() - start > 3

		local root = getRoot()
		if not (alive() and State.Meat and part and part.Parent and root and inRange(root, part)) then
			return
		end
		log("Meat: new item, touching", part:GetFullName())
		pcall(tap, root, part)
		Stats.Meat += 1
	end)
end))

------------------------------------------------------------------
-- Grapes (every TouchTransmitter under Alien.Moon.Grapes)
------------------------------------------------------------------
local grapeTransmitters = 0

local function getGrapesFolder()
	local alien = workspace:FindFirstChild("Alien")
	local moon = alien and alien:FindFirstChild("Moon")
	return moon and moon:FindFirstChild("Grapes")
end

-- One grape, in its own thread so every grape fires in parallel
local function fireGrape(tt)
	local part = tt.Parent
	local root = getRoot()
	if not (root and part and part:IsA("BasePart")) then
		return
	end
	local ok, err = pcall(tap, root, part)
	if ok then
		Stats.Grapes += 1
	else
		warn("[EggFarm] Grape fire failed:", err)
	end
end

-- Sweep
task.spawn(function()
	while alive() do
		local folder = getGrapesFolder()
		local count = 0
		if folder then
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("TouchTransmitter") then
					count += 1
					if State.Grapes then
						task.spawn(fireGrape, d)
					end
				end
			end
		end
		grapeTransmitters = count
		if State.Grapes then
			log(("Grapes: fired %d"):format(count))
		end
		task.wait(State.TouchInterval)
	end
end)

-- Instant: fire new transmitters as they appear (re-hooks if the folder is replaced)
task.spawn(function()
	local hooked, conn
	while alive() do
		local folder = getGrapesFolder()
		if folder ~= hooked then
			if conn then
				conn:Disconnect()
			end
			conn, hooked = nil, folder
			if folder then
				conn = folder.DescendantAdded:Connect(function(d)
					if alive() and State.Grapes and d:IsA("TouchTransmitter") then
						task.defer(fireGrape, d)
					end
				end)
				log("Grapes: watching", folder:GetFullName())
			end
		end
		task.wait(1)
	end
	if conn then
		conn:Disconnect()
	end
end)

------------------------------------------------------------------
-- Heroes
------------------------------------------------------------------
local function getHeroFolder()
	local farm = getFarm()
	return farm and (farm:FindFirstChild("Heroes") or farm:FindFirstChild("Heros"))
end

local function getOwnedHeroIds()
	local ids = {}
	local folder = getHeroFolder()
	if folder then
		for _, hero in ipairs(folder:GetChildren()) do
			local id = tonumber(hero.Name)
			if id then
				table.insert(ids, id)
			end
		end
	end
	table.sort(ids)
	return ids
end

-- Buying a hero is done by training it
local function buyNextHero()
	if not getFarm() then
		return
	end
	local owned = getOwnedHeroIds()
	local nextId = (owned[#owned] or 0) + 1
	log("Trying to buy hero", nextId)
	pcall(function()
		HeroEvent:FireServer("Train", tostring(nextId), nil, "MAX")
	end)
	Stats.HeroBuyAttempts += 1
end

-- Train MAX + every upgrade this hero actually has
local function maxUpgradeHero(id)
	local idStr = tostring(id)
	pcall(function()
		HeroEvent:FireServer("Train", idStr, nil, "MAX")
	end)
	task.wait(REMOTE_DELAY)
	local hero = Heroes[tonumber(id)]
	for upgrade = 1, (hero and hero.upgrades) or DEFAULT_UPGRADES do
		pcall(function()
			HeroEvent:FireServer("Upgrade", idStr, upgrade)
		end)
		task.wait(REMOTE_DELAY)
	end
end

local function upgradeList(ids, force)
	for _, id in ipairs(ids) do
		if not (alive() and (force or State.HeroFarm)) then
			return
		end
		maxUpgradeHero(id)
	end
end

-- Best N heroes, best -> worst
local function getBestHeroes(owned, n)
	local list = {}
	for i = #owned, math.max(1, #owned - n + 1), -1 do
		table.insert(list, owned[i])
	end
	return list
end

-- Rotating batches from the worst hero up, wrapping around. Each batch runs best -> worst.
local HERO_TICK_INTERVAL = 5 -- seconds between ticks
local HERO_BEST_COUNT = 3    -- best N heroes upgraded every tick
local HERO_BATCH_SIZE = 5    -- heroes per rotating batch
local HERO_BATCH_EVERY = 3   -- run the next batch every Nth tick
local HERO_BUY_EVERY = 2     -- try to buy the next hero every Nth tick

local batchIndex = 0

local function getBatchRange(owned)
	local size = HERO_BATCH_SIZE
	if batchIndex * size >= #owned then
		batchIndex = 0
	end
	local first = batchIndex * size + 1
	return first, math.min(first + size - 1, #owned)
end

local function getNextBatch(owned)
	local first, last = getBatchRange(owned)
	local list = {}
	for i = last, first, -1 do
		table.insert(list, owned[i])
	end
	return list
end

local heroTick = 0
local heroNextTick = 0 -- reset to 0 when the toggle turns on so it starts right away

local function heroFarmTick(force)
	if not getFarm() then
		return
	end
	heroTick += 1
	Stats.HeroTicks += 1

	-- buy first so the new hero is included below
	if heroTick % HERO_BUY_EVERY == 0 then
		buyNextHero()
		task.wait(REMOTE_DELAY)
	end

	if State.SingleHero then
		upgradeList({ State.SingleHeroId }, force)
		return
	end

	local owned = getOwnedHeroIds()
	upgradeList(getBestHeroes(owned, HERO_BEST_COUNT), force)

	if heroTick % HERO_BATCH_EVERY == 0 and #owned > 0 then
		local batch = getNextBatch(owned)
		log("Batch", batchIndex + 1, "->", table.concat(batch, ", "))
		upgradeList(batch, force)
		batchIndex += 1
		Stats.BatchPasses += 1
	end
end

task.spawn(function()
	while alive() do
		if State.HeroFarm and os.clock() >= heroNextTick then
			heroNextTick = os.clock() + HERO_TICK_INTERVAL
			heroFarmTick(false)
		end
		task.wait(0.25)
	end
end)

------------------------------------------------------------------
-- Auto Advance
------------------------------------------------------------------
-- Key the game sends with the "Next Level" call (captured with Cobalt)
local ADVANCE_KEY = "\xE5\x9B\x9E\xE5\xB0\x8F\xE4\xBD\x8F\xE4\xBD\x8D\xE5\xA6\xBB\xE5\x9B\x9E\xE5\xB9\xB3\xE5\xA6\xBB\xE8\xA6\x81\xE6\x8A\x84\xE3\x81\x8B\xE4\xBD\x8F\xE3\x83\x8B\xE3\x81\x8C\xE5\xB9\xB3\xE3\x82\x82\xE5\xB0\x8F\xE3\x83\x8D\xE3\x83\x8D\xE5\x9B\x9E\xE3\x83\x8D\xE6\x8A\x84\xE6\xBF\x80\xE3\x81\xA6\xE3\x82\x82"

local function getProgressLabel()
	local gui = player:FindFirstChild("PlayerGui")
	local screen = gui and gui:FindFirstChild("Progress")
	return screen and screen:FindFirstChild("Progress")
end

-- current, needed from text like "6 / 10" (commas allowed)
local function getProgress()
	local label = getProgressLabel()
	if not label then
		return nil
	end
	local text = label.Text:gsub(",", "")
	local current, needed = text:match("(%d+)%s*/%s*(%d+)")
	return tonumber(current), tonumber(needed)
end

local function advance()
	local ok, err = pcall(function()
		ProgressEvent:FireServer(ADVANCE_KEY, "Next Level")
	end)
	if ok then
		Stats.Advances += 1
		log("Advanced to next level")
	else
		warn("[EggFarm] Advance failed:", err)
	end
end

local function readyToAdvance()
	local current, needed = getProgress()
	return current ~= nil and needed ~= nil and needed > 0 and current >= needed
end

-- Advances the moment the bar is full, then waits for the label to change
-- (or 2s) so the same level is never sent twice.
local advancing = false
local function tryAdvance()
	if advancing or not (alive() and State.AutoAdvance) or not readyToAdvance() then
		return
	end
	advancing = true
	local label = getProgressLabel()
	local before = label and label.Text
	advance()
	local start = os.clock()
	while alive() and label and label.Parent and label.Text == before and os.clock() - start < 2 do
		task.wait()
	end
	advancing = false
end

-- Reacts instantly to the progress label changing, with a fast poll as a fallback
task.spawn(function()
	local hooked, conn
	while alive() do
		local label = getProgressLabel()
		if label ~= hooked then
			if conn then
				conn:Disconnect()
			end
			conn, hooked = nil, label
			if label then
				conn = label:GetPropertyChangedSignal("Text"):Connect(function()
					task.spawn(tryAdvance)
				end)
			end
		end
		tryAdvance()
		task.wait(0.25)
	end
	if conn then
		conn:Disconnect()
	end
end)

------------------------------------------------------------------
-- Boss Farm
------------------------------------------------------------------
local HAZARD_NAMES = { CandyCorn = true, Target = true }
local BOSS_TICK = 0.05           -- fight loop / attack rate
local DODGE_SEARCH_RADIUS = 80   -- how far to look for a safe spot
local WAIT_FOR_BOSS_TIMEOUT = 60 -- give up waiting at the rocket after this

local Boss = {
	phase = "Idle", -- Idle / Waiting / Fighting
	countdown = nil,
	dodging = false,
	hazardCount = 0,
}

local function getAlien()
	return workspace:FindFirstChild("Alien")
end

local function getRocketCircle()
	local alien = getAlien()
	local rocket = alien and alien:FindFirstChild("Rocket")
	return rocket and rocket:FindFirstChild("Circle")
end

local function getCountdownLabel()
	local circle = getRocketCircle()
	local info = circle and circle:FindFirstChild("InfoGui")
	local wrapper = info and info:FindFirstChild("Wrapper")
	return wrapper and wrapper:FindFirstChild("Title")
end

local function getBossChicken()
	local alien = getAlien()
	return alien and alien:FindFirstChild("Chicken")
end

-- Handles "15", "Launching in 15s", "0:15", "1,000"
local function getCountdown()
	local label = getCountdownLabel()
	if not label then
		return nil
	end
	local text = label.Text:gsub(",", "")
	local m, s = text:match("(%d+):(%d+)")
	if m then
		return tonumber(m) * 60 + tonumber(s)
	end
	return tonumber(text:match("%d+%.?%d*"))
end

---------------- hazards (every CandyCorn / Target under Terrain) ----------------
local hazards = {}

local function trackHazard(obj)
	if HAZARD_NAMES[obj.Name] then
		hazards[obj] = true
	end
end

for _, child in ipairs(workspace.Terrain:GetChildren()) do
	trackHazard(child)
end
track(workspace.Terrain.ChildAdded:Connect(trackHazard))
track(workspace.Terrain.ChildRemoved:Connect(function(obj)
	hazards[obj] = nil
end))

-- Expands an XZ box to cover a (possibly rotated) part
local function addPartBounds(part, b)
	local cf, size = part.CFrame, part.Size
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local ex = math.abs(r.X) * hx + math.abs(u.X) * hy + math.abs(l.X) * hz
	local ez = math.abs(r.Z) * hx + math.abs(u.Z) * hy + math.abs(l.Z) * hz
	local p = cf.Position
	b.minX = math.min(b.minX, p.X - ex)
	b.maxX = math.max(b.maxX, p.X + ex)
	b.minZ = math.min(b.minZ, p.Z - ez)
	b.maxZ = math.max(b.maxZ, p.Z + ez)
end

-- XZ area an attack covers (Y ignored). Works for a Part, Model or Folder.
local function getXZBounds(obj)
	local b = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
	if obj:IsA("BasePart") then
		addPartBounds(obj, b)
	end
	for _, d in ipairs(obj:GetDescendants()) do
		if d:IsA("BasePart") then
			addPartBounds(d, b)
		end
	end
	if b.minX == math.huge then
		return nil
	end
	return b
end

-- Current areas of every live attack (moving / growing attacks are re-measured each tick)
local function snapshotHazards()
	for _, child in ipairs(workspace.Terrain:GetChildren()) do
		trackHazard(child) -- anything renamed after spawning
	end
	local list = {}
	for obj in pairs(hazards) do
		if not obj.Parent then
			hazards[obj] = nil
		else
			local b = getXZBounds(obj)
			if b then
				table.insert(list, b)
			end
		end
	end
	return list
end

local function inDanger(pos, list, margin)
	for _, b in ipairs(list) do
		if pos.X >= b.minX - margin and pos.X <= b.maxX + margin and pos.Z >= b.minZ - margin and pos.Z <= b.maxZ + margin then
			return true
		end
	end
	return false
end

-- Nearest safe spot around `center`; keeps the current one while it's still safe
local function findSafeSpot(center, list, margin, current, playerPos)
	if current and not inDanger(current, list, margin) then
		return current
	end
	local searchMargin = margin + 2 -- don't sit right on the edge
	for radius = 6, DODGE_SEARCH_RADIUS, 4 do
		local steps = math.max(12, math.floor(radius))
		local best, bestDist
		for i = 0, steps - 1 do
			local a = (i / steps) * math.pi * 2
			local p = center + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
			if not inDanger(p, list, searchMargin) then
				local d = (p - playerPos).Magnitude
				if not bestDist or d < bestDist then
					best, bestDist = p, d
				end
			end
		end
		if best then
			return best
		end
	end
	return nil
end

-- BossHeight studs above the top of the boss
local function getBossAttackPos(boss)
	local cf, size
	if boss:IsA("BasePart") then
		cf, size = boss.CFrame, boss.Size
	elseif boss:IsA("Model") then
		cf, size = boss:GetBoundingBox()
	else
		local p = boss:FindFirstChildWhichIsA("BasePart", true)
		if not p then
			return nil
		end
		cf, size = p.CFrame, p.Size
	end
	return cf.Position + Vector3.new(0, size.Y / 2 + State.BossHeight, 0)
end

---------------- fight ----------------
local function fightBoss()
	Boss.phase = "Fighting"
	Stats.BossFights += 1
	log("Boss fight started")

	local safeSpot
	while alive() and State.BossFarm do
		local boss = getBossChicken()
		if not boss then
			break
		end

		local root = getRoot()
		local attackPos = getBossAttackPos(boss)
		if root and attackPos then
			local list = snapshotHazards()
			Boss.hazardCount = #list

			if inDanger(attackPos, list, State.DodgeMargin) then
				-- dodge always wins: hold a safe spot until the attack spot clears
				if not Boss.dodging then
					Boss.dodging = true
					Stats.Dodges += 1
					log("Dodging")
				end
				safeSpot = findSafeSpot(attackPos, list, State.DodgeMargin, safeSpot, root.Position)
				if safeSpot then
					placeAt(root, safeSpot)
				end
			else
				if Boss.dodging then
					Boss.dodging = false
					safeSpot = nil
					log("Clear, back to attacking")
				end
				placeAt(root, attackPos)
				pcall(function()
					WeaponEvent:FireServer("alien", "")
				end)
				Stats.BossAttacks += 1
			end
		end
		task.wait(BOSS_TICK)
	end

	Boss.dodging = false
	Boss.hazardCount = 0
	log("Boss fight over")
end

---------------- full cycle: rocket -> wait -> fight ----------------
local function teleportToRocket()
	local circle = getRocketCircle()
	local part = circle and getPart(circle)
	local root = getRoot()
	if not (part and root) then
		return nil
	end
	local target = part.Position + Vector3.new(0, 3, 0)
	placeAt(root, target)
	return target
end

local function runBossCycle()
	bossActive = true
	lockTeleport() -- waits for anything mid-teleport (e.g. diamonds) to finish

	local root = getRoot()
	local startCFrame = root and root.CFrame

	local ok, err = pcall(function()
		if not getBossChicken() then
			Boss.phase = "Waiting"
			local target = teleportToRocket()
			if target then
				log("Teleported to rocket")
				local start = os.clock()
				while alive() and State.BossFarm and not getBossChicken() and os.clock() - start < WAIT_FOR_BOSS_TIMEOUT do
					-- stay on the pad during the final countdown
					local v = getCountdown()
					root = getRoot()
					if root and v and v > 1 and v <= 10 and (root.Position - target).Magnitude > 8 then
						placeAt(root, target)
					end
					task.wait(0.25)
				end
			end
		end

		if alive() and State.BossFarm and getBossChicken() then
			fightBoss()
		end
	end)
	if not ok then
		warn("[EggFarm] Boss error:", err)
	end

	root = getRoot()
	if State.BossReturn and root and startCFrame then
		root.CFrame = startCFrame
	end

	Boss.phase = "Idle"
	unlockTeleport()
	bossActive = false
end

---------------- countdown watcher ----------------
task.spawn(function()
	local lastValue, armed = nil, false
	while alive() do
		local value = getCountdown()
		Boss.countdown = value

		-- arm only while it's really counting down between 10 and 120
		if value and value ~= lastValue then
			if lastValue and value < lastValue and value > 10 and value < 120 then
				armed = true
			elseif lastValue and value > lastValue then
				armed = false -- reset / cooldown started
			end
			lastValue = value
		end

		if State.BossFarm and armed and value ~= nil and value <= 10 then
			armed = false
			runBossCycle()
			lastValue = nil
		end

		task.wait(BOSS_TICK)
	end
end)

------------------------------------------------------------------
-- Trophy Auto Reroll
------------------------------------------------------------------
local function getTrophyList()
	local gui = player:FindFirstChild("PlayerGui")
	local menus = gui and gui:FindFirstChild("Menus")
	local inv = menus and menus:FindFirstChild("Inventory")
	return inv and inv:FindFirstChild("List")
end

-- "02" / " 2 " / 2 -> "2"
local function normId(v)
	local n = tonumber(tostring(v):match("%d+"))
	return n and tostring(n) or nil
end

-- {"[2] Tarzan", "[26] Aang"} -> { ["2"] = true, ["26"] = true }
local function savedFromLabels(labels)
	local saved = {}
	for _, label in ipairs(labels or {}) do
		local id = idFromLabel(label)
		if id then
			saved[tostring(id)] = true
		end
	end
	return saved
end

-- Every trophy we own (one per TextButton, duplicates included)
local function getOwnedTrophies()
	local ids = {}
	local list = getTrophyList()
	if list then
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then
				local id = normId(child.Name)
				if id then
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

local function isSaved(id)
	return State.SavedTrophies[id] == true
end

-- One pass: reroll every trophy that isn't saved
local function rerollPass(force)
	local count = 0
	for _, id in ipairs(getOwnedTrophies()) do
		if not (alive() and (force or State.AutoReroll)) then
			break
		end
		if not isSaved(id) then
			pcall(function()
				ItemsEvent:FireServer("Reforge1", id)
			end)
			Stats.Rerolls += 1
			count += 1
			log("Rerolled trophy", id)
			task.wait(State.RerollDelay)
		end
	end
	return count
end

task.spawn(function()
	while alive() do
		if State.AutoReroll then
			-- rescans each pass, so trophies that rolled into a saved ID are left alone
			if rerollPass(false) == 0 then
				task.wait(1)
			end
		end
		task.wait(0.1)
	end
end)

------------------------------------------------------------------
-- Status text (shared by the Status tab and the per-feature cards)
------------------------------------------------------------------
local GREEN, YELLOW, RED, GREY = "#2ECC71", "#F1C40F", "#E74C3C", "#8A8D96"

local function esc(s)
	return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local function color(text, hex)
	return ('<font color="%s">%s</font>'):format(hex, text)
end
local function bold(text)
	return "<b>" .. text .. "</b>"
end

local function farmText()
	local farm = getFarm()
	local lines = {}
	if farm then
		table.insert(lines, bold("Farm: ") .. color("Found", GREEN) .. " (" .. esc(farm.Name) .. ")")
		table.insert(lines, bold("Diamonds waiting: ") .. countDiamonds(farm:FindFirstChild("Diamonds")))
	else
		table.insert(lines, bold("Farm: ") .. color("Not found", RED) .. " — use Re-find My Farm")
	end
	table.insert(lines, bold("Grape transmitters: ") .. grapeTransmitters)
	if not hasTouch then
		table.insert(lines, color("firetouchinterest isn't supported by this executor", RED))
	end
	return table.concat(lines, "\n")
end

local function progressText()
	local current, needed = getProgress()
	local chickens
	if current and needed then
		chickens = ("%d / %d"):format(current, needed) .. (current >= needed and "  " .. color("ready!", GREEN) or "")
	else
		chickens = color("label not found", GREY)
	end
	return bold("Chickens: ") .. chickens .. "\n" .. bold("Levels advanced: ") .. Stats.Advances
end

local function bossText()
	local phaseColor = Boss.phase == "Fighting" and RED or Boss.phase == "Waiting" and YELLOW or GREY
	return table.concat({
		bold("Phase: ") .. color(Boss.phase, phaseColor) .. (Boss.dodging and "  " .. color("DODGING", YELLOW) or ""),
		bold("Countdown: ") .. (Boss.countdown and tostring(Boss.countdown) or "-"),
		bold("Active attacks: ") .. Boss.hazardCount,
		("Fights %d · Dodges %d · Hits %d"):format(Stats.BossFights, Stats.Dodges, Stats.BossAttacks),
	}, "\n")
end

local function heroText()
	local owned = getOwnedHeroIds()
	local highest = owned[#owned]
	local nextId = (highest or 0) + 1

	local mode
	if State.SingleHero then
		mode = "Only " .. esc(heroLabel(State.SingleHeroId))
	else
		mode = ("Best %d + batches"):format(HERO_BEST_COUNT)
	end

	local lines = {
		bold("Owned: ") .. #owned .. "   " .. bold("Tick: ") .. heroTick,
		bold("Best: ") .. (highest and esc(heroLabel(highest)) or "none"),
		bold("Next to buy: ") .. (Heroes[nextId] and esc(heroLabel(nextId)) or color("all bought", GREEN)),
		bold("Mode: ") .. mode,
	}
	if not State.SingleHero and #owned > 0 then
		local first, last = getBatchRange(owned)
		table.insert(lines, bold("Next batch: ") .. esc(heroLabel(owned[first])) .. " to " .. esc(heroLabel(owned[last])))
	end
	return table.concat(lines, "\n")
end

local function trophyText()
	local trophies = getOwnedTrophies()
	local savedCount, unsaved, seen, savedIds = 0, 0, {}, {}
	for _, id in ipairs(trophies) do
		if isSaved(id) then
			savedCount += 1
			if not seen[id] then
				seen[id] = true
				table.insert(savedIds, tonumber(id))
			end
		else
			unsaved += 1
		end
	end
	table.sort(savedIds)
	local names = {}
	for _, id in ipairs(savedIds) do
		table.insert(names, esc(heroLabel(id)))
	end
	return table.concat({
		bold("Owned: ") .. #trophies .. "   " .. bold("To reroll: ") .. unsaved,
		bold("Saved owned: ") .. savedCount .. (#names > 0 and "\n" .. table.concat(names, ", ") or ""),
		bold("Rerolls sent: ") .. Stats.Rerolls,
	}, "\n")
end

local function sessionText()
	return table.concat({
		bold("Diamonds: ") .. Stats.Diamonds .. "   " .. bold("Skipped: ") .. countSkipped(),
		bold("Meat touches: ") .. Stats.Meat,
		bold("Grape touches: ") .. Stats.Grapes,
		bold("Hero ticks: ") .. Stats.HeroTicks .. "   " .. bold("Batches: ") .. Stats.BatchPasses,
		bold("Hero buy attempts: ") .. Stats.HeroBuyAttempts,
	}, "\n")
end

------------------------------------------------------------------
-- Menu
------------------------------------------------------------------
local Window

local stopped = false
local function stop()
	if stopped then
		return
	end
	stopped = true
	if _G.EggFarmSession == session then
		_G.EggFarmSession = session + 1 -- stops every loop
	end
	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(connections)
	if Window then
		Window:Destroy()
	end
end
_G.EggFarm = { Stop = stop }

local function notify(title, content)
	Ember:Notify({ Title = title, Content = content, Duration = 4 })
end

Window = Ember:CreateWindow({
	Title = "Egg Farm",
	Subtitle = "Autofarm",
	ConfigFolder = "EggFarmSim",
	ToggleKey = Enum.KeyCode.K,
	OnClose = stop,
})

Window:Section("Farming")
local CollectTab = Window:Tab({ Name = "Collect" })
local HeroTab = Window:Tab({ Name = "Heroes" })
local ProgressTab = Window:Tab({ Name = "Progress", Columns = 1 })
local BossTab = Window:Tab({ Name = "Boss" })
local TrophyTab = Window:Tab({ Name = "Trophies" })
Window:Section("Info")
local StatusTab = Window:Tab({ Name = "Status" })
Window:Section("Settings")
local SettingsTab = Window:Tab({ Name = "Settings" })

-- Live paragraphs, refreshed once a second at the bottom of the file
local live = {}

---------------- Collect ----------------
local Diamonds = CollectTab:Card({ Title = "Diamonds", Side = "Left" })
Diamonds:Toggle({
	Name = "Auto Collect Diamonds",
	Flag = "AutoDiamonds",
	Keybind = true,
	Callback = function(v)
		State.Diamonds = v
	end,
})
Diamonds:Toggle({
	Name = "Return to Spot After",
	Default = true,
	Flag = "ReturnAfterDiamonds",
	Tooltip = "Teleports you back to where you were once every diamond is collected.",
	Callback = function(v)
		State.ReturnAfterDiamonds = v
	end,
})
Diamonds:Slider({
	Name = "Skip Stuck Diamond After",
	Min = 0.5,
	Max = 5,
	Increment = 0.5,
	Default = 1.5,
	Suffix = "s",
	Flag = "DiamondTimeout",
	Tooltip = "A diamond that's still there after this long is skipped until you reset the skipped list.",
	Callback = function(v)
		State.DiamondTimeout = v
	end,
})
live.diamonds = Diamonds:Paragraph({ Content = "-" })
Diamonds:Button({
	Name = "Reset Skipped Diamonds",
	Style = "Secondary",
	Callback = function()
		table.clear(skippedDiamonds)
		notify("Diamonds", "Skipped list cleared.")
	end,
})

local Pickups = CollectTab:Card({ Title = "Meat & Grapes", Side = "Right" })
Pickups:Toggle({
	Name = "Auto Collect Meat",
	Flag = "AutoMeat",
	Keybind = true,
	Callback = function(v)
		State.Meat = v
	end,
})
Pickups:Slider({
	Name = "Meat Range",
	Min = 10,
	Max = 200,
	Increment = 5,
	Default = 50,
	Suffix = " studs",
	Flag = "MeatRange",
	Callback = function(v)
		State.MeatRange = v
	end,
})
Pickups:Toggle({
	Name = "Auto Collect Grapes",
	Flag = "AutoGrapes",
	Keybind = true,
	Callback = function(v)
		State.Grapes = v
	end,
})
Pickups:Slider({
	Name = "Sweep Interval",
	Min = 0.1,
	Max = 2,
	Increment = 0.05,
	Default = 0.25,
	Suffix = "s",
	Flag = "TouchInterval",
	Tooltip = "How often meat and grapes are rescanned. New ones are also grabbed the instant they spawn.",
	Callback = function(v)
		State.TouchInterval = v
	end,
})
live.pickups = Pickups:Paragraph({ Content = "-" })

---------------- Heroes ----------------
local HeroFarm = HeroTab:Card({ Title = "Hero Autofarm", Side = "Left" })
HeroFarm:Toggle({
	Name = "Hero Autofarm",
	Flag = "HeroAutofarm",
	Keybind = true,
	Callback = function(v)
		State.HeroFarm = v
		if v then
			heroNextTick = 0
		end
	end,
})
HeroFarm:Paragraph({
	Content = "Every 5s max-upgrades your 3 best heroes (every upgrade each hero has). Every 3rd tick it also upgrades "
		.. "the next batch of 5, starting from your worst heroes and wrapping around. Every 2nd tick it tries to buy the next hero.",
})
local HeroLive = HeroTab:Card({ Title = "Live", Side = "Right" })
live.heroes = HeroLive:Paragraph({ Content = "-" })

local Single = HeroTab:Card({ Title = "Single Hero Mode", Side = "Left" })
Single:Toggle({
	Name = "Only Upgrade One Hero",
	Flag = "SingleHero",
	Tooltip = "Skips the best-heroes and batch upgrades and only upgrades the hero picked below.",
	Callback = function(v)
		State.SingleHero = v
	end,
})
Single:Dropdown({
	Name = "Hero",
	Options = heroOptions(),
	Default = heroLabel(State.SingleHeroId),
	Search = true,
	Flag = "SingleHeroPick",
	Callback = function(label)
		local id = idFromLabel(label)
		if id then
			State.SingleHeroId = id
		end
	end,
})

local HeroManual = HeroTab:Card({ Title = "Manual", Side = "Right" })
HeroManual:Button({
	Name = "Run One Tick Now",
	Callback = function()
		task.spawn(heroFarmTick, true)
	end,
})
HeroManual:Button({
	Name = "Buy Next Hero Now",
	Style = "Secondary",
	Callback = function()
		task.spawn(buyNextHero)
	end,
})
HeroManual:Button({
	Name = "Restart Batches From Worst",
	Style = "Secondary",
	Callback = function()
		batchIndex = 0
		notify("Heroes", "Next batch will start from your worst heroes.")
	end,
})

---------------- Progress ----------------
local Advance = ProgressTab:Card({ Title = "Auto Advance" })
Advance:Toggle({
	Name = "Auto Advance When Ready",
	Flag = "AutoAdvance",
	Keybind = true,
	Tooltip = "Advances the moment the chicken bar is full.",
	Callback = function(v)
		State.AutoAdvance = v
		if v then
			task.spawn(tryAdvance)
		end
	end,
})
live.chickens = Advance:Progress({ Name = "Chickens" })
live.progress = Advance:Paragraph({ Content = "-" })
Advance:Button({
	Name = "Advance Now",
	Callback = function()
		local current, needed = getProgress()
		if current and needed and current < needed then
			return notify("Progress", ("Not ready yet (%d / %d)."):format(current, needed))
		end
		task.spawn(advance)
	end,
})

---------------- Boss ----------------
local BossFarm = BossTab:Card({ Title = "Boss Farm", Side = "Left" })
BossFarm:Toggle({
	Name = "Boss Farm",
	Flag = "BossFarm",
	Keybind = true,
	Callback = function(v)
		State.BossFarm = v
	end,
})
BossFarm:Paragraph({
	Content = "When the rocket countdown hits 10 you're sent to the rocket to wait for the boss, then you attack "
		.. "from above it while dodging CandyCorn and Target attacks. Diamonds pause until the fight ends.",
})
BossFarm:Toggle({
	Name = "Return to Start Spot After",
	Flag = "BossReturn",
	Callback = function(v)
		State.BossReturn = v
	end,
})

local BossLive = BossTab:Card({ Title = "Live", Side = "Right" })
live.boss = BossLive:Paragraph({ Content = "-" })
BossLive:Button({
	Name = "Teleport to Rocket Now",
	Style = "Secondary",
	Callback = function()
		if not teleportToRocket() then
			notify("Boss", "Couldn't find the rocket.")
		end
	end,
})

---------------- Trophies ----------------
local Reroll = TrophyTab:Card({ Title = "Auto Reroll", Side = "Left" })
Reroll:Toggle({
	Name = "Auto Reroll Trophies",
	Flag = "AutoReroll",
	Keybind = true,
	Callback = function(v)
		State.AutoReroll = v
	end,
})
Reroll:Dropdown({
	Name = "Saved Trophies",
	Multi = true,
	Search = true,
	Options = heroOptions(),
	Default = { heroLabel(2), heroLabel(26), heroLabel(40) },
	Placeholder = "None (rerolls everything)",
	Flag = "SavedTrophyList",
	Tooltip = "Trophies picked here are never rerolled. Each trophy shares its ID with a hero.",
	Callback = function(labels)
		State.SavedTrophies = savedFromLabels(labels)
	end,
})
Reroll:Slider({
	Name = "Delay Between Rerolls",
	Min = 0.05,
	Max = 2,
	Increment = 0.05,
	Default = 0.25,
	Suffix = "s",
	Flag = "RerollDelay",
	Callback = function(v)
		State.RerollDelay = v
	end,
})
Reroll:Button({
	Name = "Reroll Unsaved Once",
	Callback = function()
		task.spawn(function()
			notify("Trophies", ("Rerolled %d trophies."):format(rerollPass(true)))
		end)
	end,
})

local TrophyLive = TrophyTab:Card({ Title = "Live", Side = "Right" })
live.trophies = TrophyLive:Paragraph({ Content = "-" })

---------------- Status ----------------
local FarmCard = StatusTab:Card({ Title = "Farm", Side = "Left" })
local statusFarm = FarmCard:Paragraph({ Content = "Searching..." })
FarmCard:Button({
	Name = "Re-find My Farm",
	Style = "Secondary",
	Callback = function()
		local farm = getFarm(true)
		notify("Farm", farm and ("Found: " .. farm.Name) or "Couldn't find your farm.")
	end,
})
local statusProgress = StatusTab:Card({ Title = "Progress", Side = "Left" }):Paragraph({ Content = "-" })
local statusBoss = StatusTab:Card({ Title = "Boss", Side = "Left" }):Paragraph({ Content = "-" })
local statusHeroes = StatusTab:Card({ Title = "Heroes", Side = "Right" }):Paragraph({ Content = "-" })
local statusTrophies = StatusTab:Card({ Title = "Trophies", Side = "Right" }):Paragraph({ Content = "-" })
local statusSession = StatusTab:Card({ Title = "Session", Side = "Right" }):Paragraph({ Content = "-" })

---------------- Settings ----------------
Ember:BuildSettings(SettingsTab)

local Script = SettingsTab:Card({ Title = "Script", Side = "Right" })
Script:Toggle({
	Name = "Swap Touch Arguments",
	Flag = "SwapArgs",
	Tooltip = "Flips the part order passed to firetouchinterest. Try this if diamonds, meat or grapes stop collecting.",
	Callback = function(v)
		State.SwapArgs = v
	end,
})
Script:Toggle({
	Name = "Debug Prints (F9)",
	Flag = "DebugPrints",
	Callback = function(v)
		State.Debug = v
	end,
})
Script:Label("Settings save automatically.")
Script:Button({
	Name = "Stop Everything & Close",
	Callback = stop,
})

------------------------------------------------------------------
-- Live updates
------------------------------------------------------------------
task.spawn(function()
	while alive() do
		pcall(function()
			local farm, progress, boss = farmText(), progressText(), bossText()
			local heroes, trophies, sessionStats = heroText(), trophyText(), sessionText()

			statusFarm:Set(farm)
			statusProgress:Set(progress)
			statusBoss:Set(boss)
			statusHeroes:Set(heroes)
			statusTrophies:Set(trophies)
			statusSession:Set(sessionStats)

			live.diamonds:Set(table.concat({
				bold("Waiting: ") .. countDiamonds(getDiamondFolder()),
				bold("Collected: ") .. Stats.Diamonds,
				bold("Skipped: ") .. countSkipped(),
			}, "   "))
			live.pickups:Set(table.concat({
				bold("Meat touches: ") .. Stats.Meat,
				bold("Grape touches: ") .. Stats.Grapes .. "   " .. bold("Loaded: ") .. grapeTransmitters,
			}, "\n"))
			live.heroes:Set(heroes)
			live.boss:Set(boss)
			live.trophies:Set(trophies)

			local current, needed = getProgress()
			if current and needed and needed > 0 then
				live.chickens:Set(current / needed, ("%d / %d"):format(current, needed))
			else
				live.chickens:Set(0, "-")
			end
			live.progress:Set(bold("Levels advanced: ") .. Stats.Advances)
		end)
		task.wait(1)
	end
end)

------------------------------------------------------------------
-- Saved settings (load now, auto-save on change)
------------------------------------------------------------------
local CONFIG = "Autofarm"
local restored = Ember:LoadConfig(CONFIG)

-- One-time move from the old RightShift default to K (a key you pick later sticks)
pcall(function()
	local marker = "EggFarmSim/.menukey-k"
	if not isfile(marker) then
		if Ember.Flags.Ember_MenuKey == "RightShift" and Ember.Options.Ember_MenuKey then
			Ember.Options.Ember_MenuKey:Set("K")
		end
		writefile(marker, "1")
	end
end)

task.spawn(function()
	local function snapshot()
		local ok, json = pcall(HttpService.JSONEncode, HttpService, Ember.Flags)
		return ok and json or nil
	end
	local last = snapshot()
	while alive() do
		task.wait(2)
		local now = snapshot()
		if alive() and now and now ~= last then
			last = now
			Ember:SaveConfig(CONFIG)
		end
	end
end)

------------------------------------------------------------------
-- Startup notice
------------------------------------------------------------------
local farm = getFarm()
local lines = { farm and ("Farm found: " .. farm.Name) or "Your farm wasn't found yet." }
if restored then
	table.insert(lines, "Saved settings restored.")
end
if not hasTouch then
	table.insert(lines, "Your executor doesn't support firetouchinterest, so meat and grapes won't collect.")
end
if heroDataError then
	table.insert(lines, "Couldn't read HeroesData, so hero names and upgrade counts are missing.")
end
table.insert(lines, "Press " .. tostring(Ember.Flags.Ember_MenuKey or "K") .. " to hide or show the menu.")
Ember:Notify({ Title = "Egg Farm loaded", Content = table.concat(lines, "\n"), Duration = 6 })
