--// Egg Farm Simulator Autofarm (Rayfield GUI)
--// Everything is controlled from the GUI. Settings are saved between runs.
--// Re-running the script closes the old GUI and stops the old loops.

------------------------------------------------------------------
-- Services
------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

------------------------------------------------------------------
-- Session guard (re-running replaces the old copy)
------------------------------------------------------------------
if _G.EggFarmRayfield then
	pcall(function() _G.EggFarmRayfield:Destroy() end)
end

local session = (_G.EggFarmSession or 0) + 1
_G.EggFarmSession = session
local function alive()
	return _G.EggFarmSession == session
end

------------------------------------------------------------------
-- State (driven by the GUI)
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

	-- trophy settings
	SavedTrophies = { ["2"] = true, ["26"] = true, ["40"] = true }, -- never reroll these
	RerollDelay = 0.25,    -- seconds between reroll calls

	-- boss settings
	DodgeMargin = 5,         -- extra studs around each attack's area
	BossHeight = 2,          -- studs above the top of the boss
	BossReturn = false,      -- teleport back to where you were after the fight
	BossJoinExisting = true, -- jump into a fight that's already going

	-- settings
	AdvanceCooldown = 3,   -- seconds to wait after advancing before trying again
	ReturnAfterDiamonds = true,
	DiamondTimeout = 1.5,
	MeatRange = 50,
	TouchInterval = 0.25,
	HeroTickInterval = 5,  -- seconds between hero ticks
	HeroBestCount = 3,     -- best N heroes upgraded every tick
	HeroBatchSize = 5,     -- heroes per rotating batch
	HeroBatchEvery = 3,    -- run the next batch every Nth tick
	HeroBuyEvery = 2,      -- try to buy the next hero every Nth tick
	SingleHero = false,    -- only upgrade one hero instead of best + batches
	SingleHeroId = 2,      -- which hero ID to upgrade in single mode
	UpgradeCount = 6,
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

-- True while the boss farm is controlling the character (pauses diamonds)
local bossActive = false

local DIAMOND_CHECK = 0.25
local REMOTE_DELAY = 0.1

local function log(...)
	if State.Debug then print("[EggFarm]", ...) end
end

------------------------------------------------------------------
-- General helpers
------------------------------------------------------------------
local function getRoot()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getPart(obj)
	if obj:IsA("BasePart") then return obj end
	if obj:IsA("Model") and obj.PrimaryPart then return obj.PrimaryPart end
	return obj:FindFirstChildWhichIsA("BasePart", true)
end

-- Finds the TouchTransmitter by class (not name, in case the game renames it)
-- and returns the part it belongs to
local function getTouchPart(obj)
	local tt = obj:FindFirstChildOfClass("TouchTransmitter")
		or obj:FindFirstChildWhichIsA("TouchTransmitter", true)
	if tt and tt.Parent and tt.Parent:IsA("BasePart") then
		return tt.Parent
	end
	return nil
end

local function fireTouch(root, part)
	if State.SwapArgs then
		firetouchinterest(part, root, 0)
		task.wait()
		firetouchinterest(part, root, 1)
	else
		firetouchinterest(root, part, 0)
		task.wait()
		firetouchinterest(root, part, 1)
	end
end

-- Only one feature moves the character at a time
local tpBusy = false
local function withTeleport(fn)
	while tpBusy do task.wait() end
	tpBusy = true
	local ok, err = pcall(fn)
	tpBusy = false
	if not ok then warn("[EggFarm]", err) end
end

------------------------------------------------------------------
-- Farm lookup
------------------------------------------------------------------
local cachedFarm

local function findFarm()
	local farms = workspace:FindFirstChild("Farms")
	if not farms then return nil end

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
	if cachedFarm then log("Found farm:", cachedFarm:GetFullName()) end
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
			if not skippedDiamonds[d] then n += 1 end
		end
	end
	return n
end

-- force = run one full pass even if the toggle is off (manual button)
local function collectDiamonds(folder, force)
	withTeleport(function()
		local root = getRoot()
		if not root then return end
		local original = root.CFrame

		while alive() and (force or State.Diamonds) and not bossActive and folder.Parent do
			local didAny = false

			for _, diamond in ipairs(folder:GetChildren()) do
				if not (alive() and (force or State.Diamonds)) or bossActive then break end
				if not skippedDiamonds[diamond] then
					local part = getPart(diamond)
					root = getRoot()
					if part and root then
						didAny = true
						root.CFrame = part.CFrame

						local touchPart = getTouchPart(diamond)
						if touchPart then fireTouch(root, touchPart) end

						local start = os.clock()
						repeat task.wait() until not diamond.Parent or os.clock() - start > State.DiamondTimeout

						if diamond.Parent then
							skippedDiamonds[diamond] = true
							log("Diamond wouldn't collect, skipping:", diamond:GetFullName())
						else
							Stats.Diamonds += 1
						end
					end
				end
			end

			if not didAny then break end
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
				collectDiamonds(folder, false)
			end
		end
		task.wait(DIAMOND_CHECK)
	end
end)

------------------------------------------------------------------
-- Meat / Grapes
------------------------------------------------------------------
local touchTargets = {
	{
		label = "Meat",
		key = "Meat",
		getContainer = function() return workspace end,
		nameFilter = "Meat",
		useRange = true,
		teleport = false,
	},
	-- Grapes have their own dedicated loop below
}

local function touchItem(part, teleport)
	if teleport then
		withTeleport(function()
			local root = getRoot()
			if not root then return end
			local original = root.CFrame
			root.CFrame = part.CFrame
			task.wait()
			fireTouch(root, part)
			root.CFrame = original
		end)
	else
		local root = getRoot()
		if root then fireTouch(root, part) end
	end
end

local function fireState(root, part, state)
	if State.SwapArgs then
		firetouchinterest(part, root, state)
	else
		firetouchinterest(root, part, state)
	end
end

-- Every touchable part for a target right now (fresh scan each call)
local function getTargetParts(t, root)
	local container = t.getContainer()
	if not container then return {}, "container not found" end

	local parts, seen = {}, {}
	local function add(part)
		if part and not seen[part] then
			if not t.useRange or (part.Position - root.Position).Magnitude <= State.MeatRange then
				seen[part] = true
				table.insert(parts, part)
			end
		end
	end

	if t.deep then
		for _, d in ipairs(container:GetDescendants()) do
			if d:IsA("TouchTransmitter") and d.Parent and d.Parent:IsA("BasePart") then
				add(d.Parent)
			end
		end
	else
		for _, obj in ipairs(container:GetChildren()) do
			if not t.nameFilter or obj.Name == t.nameFilter then
				add(getTouchPart(obj))
			end
		end
	end
	return parts
end

-- Fires every part at once (all touch-begins, one frame, all touch-ends)
-- instead of one frame per item, so big batches go out instantly
local function fireBatch(root, parts)
	for _, part in ipairs(parts) do
		pcall(fireState, root, part, 0)
	end
	task.wait()
	for _, part in ipairs(parts) do
		if part.Parent then
			pcall(fireState, root, part, 1)
		end
	end
end

task.spawn(function()
	while alive() do
		local root = getRoot()
		if root then
			for _, t in ipairs(touchTargets) do
				if State[t.key] then
					local parts, err = getTargetParts(t, root)
					if err then
						log(t.label .. ": " .. err)
					elseif #parts > 0 then
						log(("%s: touching %d"):format(t.label, #parts))
						fireBatch(root, parts)
						Stats[t.key] += #parts
					end
				end
			end
		end
		task.wait(State.TouchInterval)
	end
end)

-- Instant pickup: listen for new Meat/Grapes the moment they spawn,
-- on top of the sweep above (which also rescans every interval).
local function onNewItem(t, obj)
	if not (alive() and State[t.key]) then return end
	if t.nameFilter and obj.Name ~= t.nameFilter then return end

	-- The TouchTransmitter can replicate a moment after the item itself
	local part
	local start = os.clock()
	repeat
		part = getTouchPart(obj)
		if part then break end
		task.wait(0.1)
	until not obj.Parent or os.clock() - start > 3
	if not part or not part.Parent then return end

	local root = getRoot()
	if not root then return end
	if t.useRange and (part.Position - root.Position).Magnitude > State.MeatRange then return end

	log(t.label .. ": new item, touching", part:GetFullName())
	touchItem(part, t.teleport)
	Stats[t.key] += 1
end

-- For deep targets (Grapes): fires the moment any new TouchTransmitter shows up
-- under the folder, whether it's a brand new grape or one that respawned in place
local function onNewTransmitter(t, tt)
	if not (alive() and State[t.key]) then return end
	task.wait() -- let it finish parenting

	local part = tt.Parent
	if not (part and part:IsA("BasePart")) then return end

	local root = getRoot()
	if not root then return end
	if t.useRange and (part.Position - root.Position).Magnitude > State.MeatRange then return end

	log(t.label .. ": new item, touching", part:GetFullName())
	touchItem(part, t.teleport)
	Stats[t.key] += 1
end

-- Keeps a spawn hook on each container, re-hooking if it gets replaced
task.spawn(function()
	local hooks = {}

	while alive() do
		for _, t in ipairs(touchTargets) do
			local container = t.getContainer()
			local hook = hooks[t.key]

			if not hook or hook.container ~= container then
				if hook then hook.conn:Disconnect() end
				hooks[t.key] = nil

				if container then
					hooks[t.key] = {
						container = container,
						conn = t.deep
							and container.DescendantAdded:Connect(function(d)
								if d:IsA("TouchTransmitter") then
									task.spawn(onNewTransmitter, t, d)
								end
							end)
							or container.ChildAdded:Connect(function(obj)
								task.spawn(onNewItem, t, obj)
							end),
					}
					log(t.label .. ": watching", container:GetFullName())
				end
			end
		end
		task.wait(1)
	end

	for _, hook in pairs(hooks) do
		hook.conn:Disconnect()
	end
end)

------------------------------------------------------------------
-- Grapes (dedicated): every TouchTransmitter under Alien.Moon.Grapes
------------------------------------------------------------------
local grapeTransmitters = 0 -- shown on the Status tab

local function getGrapesFolder()
	local alien = workspace:FindFirstChild("Alien")
	local moon = alien and alien:FindFirstChild("Moon")
	return moon and moon:FindFirstChild("Grapes")
end

-- Fires one TouchTransmitter's part: touch begin, next frame touch end.
-- Runs in its own thread so every grape fires in parallel.
local function fireGrape(tt)
	local part = tt.Parent
	local root = getRoot()
	if not (root and part and part:IsA("BasePart")) then return end

	local ok, err = pcall(function()
		fireState(root, part, 0)
		task.wait()
		fireState(root, part, 1)
	end)
	if ok then
		Stats.Grapes += 1
	else
		warn("[EggFarm] Grape fire failed:", err)
	end
end

-- Sweep: search all descendants and fire every TouchTransmitter found
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

-- Instant: fire any new TouchTransmitter the moment it appears under the folder
task.spawn(function()
	local hookedFolder, conn

	while alive() do
		local folder = getGrapesFolder()
		if folder ~= hookedFolder then
			if conn then conn:Disconnect() end
			conn = nil
			hookedFolder = folder
			if folder then
				conn = folder.DescendantAdded:Connect(function(d)
					if State.Grapes and d:IsA("TouchTransmitter") then
						task.defer(fireGrape, d)
					end
				end)
				log("Grapes: watching", folder:GetFullName())
			end
		end
		task.wait(1)
	end

	if conn then conn:Disconnect() end
end)

------------------------------------------------------------------
-- Heroes
------------------------------------------------------------------
local HeroEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Heroes")

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
			if id then table.insert(ids, id) end
		end
	end
	table.sort(ids)
	return ids
end

-- Buying a hero is done by training it
local function buyHero(id)
	HeroEvent:FireServer("Train", tostring(id), nil, "MAX")
end

local function buyNextHero()
	if not getFarm() then return end
	local owned = getOwnedHeroIds()
	local nextId = (owned[#owned] or 0) + 1
	log("Trying to buy hero", nextId)
	pcall(buyHero, nextId)
	Stats.HeroBuyAttempts += 1
end

-- Train MAX + every upgrade on one hero
local function maxUpgradeHero(id)
	local idStr = tostring(id)

	pcall(function()
		HeroEvent:FireServer("Train", idStr, nil, "MAX")
	end)
	task.wait(REMOTE_DELAY)

	for upgrade = 1, State.UpgradeCount do
		pcall(function()
			HeroEvent:FireServer("Upgrade", idStr, upgrade)
		end)
		task.wait(REMOTE_DELAY)
	end
end

local function upgradeList(ids, force)
	for _, id in ipairs(ids) do
		if not (alive() and (force or State.HeroFarm)) then return end
		maxUpgradeHero(id)
	end
end

-- Best N heroes, ordered best -> worst
local function getBestHeroes(owned, n)
	local list = {}
	for i = #owned, math.max(1, #owned - n + 1), -1 do
		table.insert(list, owned[i])
	end
	return list
end

-- Rotating batches counted from the worst hero up.
-- Batch 0 = 5 worst, batch 1 = next 5, ... then wraps. Each batch runs best -> worst.
local batchIndex = 0

local function getBatchRange(owned)
	local size = State.HeroBatchSize
	if batchIndex * size >= #owned then batchIndex = 0 end
	local first = batchIndex * size + 1
	local last = math.min(first + size - 1, #owned)
	return first, last
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
	if not getFarm() then return end
	heroTick += 1
	Stats.HeroTicks += 1

	-- Every Nth tick: try to buy the next hero first, so it's included below
	if heroTick % State.HeroBuyEvery == 0 then
		buyNextHero()
		task.wait(REMOTE_DELAY)
	end

	-- Single hero mode: only upgrade that one hero, skip best + batches
	if State.SingleHero then
		upgradeList({ State.SingleHeroId }, force)
		return
	end

	local owned = getOwnedHeroIds()

	-- Every tick: best N heroes, best -> worst
	upgradeList(getBestHeroes(owned, State.HeroBestCount), force)

	-- Every Nth tick: the next rotating batch
	if heroTick % State.HeroBatchEvery == 0 and #owned > 0 then
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
			heroNextTick = os.clock() + State.HeroTickInterval
			heroFarmTick(false)
		end
		task.wait(0.25)
	end
end)

------------------------------------------------------------------
-- Auto Advance
------------------------------------------------------------------
local ProgressEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Progress")

-- Key the game sends with the "Next Level" call (captured with Cobalt)
local ADVANCE_KEY = "\xE5\x9B\x9E\xE5\xB0\x8F\xE4\xBD\x8F\xE4\xBD\x8D\xE5\xA6\xBB\xE5\x9B\x9E\xE5\xB9\xB3\xE5\xA6\xBB\xE8\xA6\x81\xE6\x8A\x84\xE3\x81\x8B\xE4\xBD\x8F\xE3\x83\x8B\xE3\x81\x8C\xE5\xB9\xB3\xE3\x82\x82\xE5\xB0\x8F\xE3\x83\x8D\xE3\x83\x8D\xE5\x9B\x9E\xE3\x83\x8D\xE6\x8A\x84\xE6\xBF\x80\xE3\x81\xA6\xE3\x82\x82"

local function getProgressLabel()
	local gui = player:FindFirstChild("PlayerGui")
	local screen = gui and gui:FindFirstChild("Progress")
	return screen and screen:FindFirstChild("Progress")
end

-- Returns current, needed from text like "6 / 10" (commas allowed)
local function getProgress()
	local label = getProgressLabel()
	if not label then return nil end
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

task.spawn(function()
	while alive() do
		if State.AutoAdvance then
			local current, needed = getProgress()
			if current and needed and needed > 0 and current >= needed then
				advance()
				task.wait(State.AdvanceCooldown)
			end
		end
		task.wait(1)
	end
end)

------------------------------------------------------------------
-- Boss Farm
------------------------------------------------------------------
local WeaponEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Weapon")

local HAZARD_NAMES = { CandyCorn = true, Target = true }
local BOSS_TICK = 0.05               -- fight loop / attack rate
local DODGE_SEARCH_RADIUS = 80       -- how far to look for a safe spot
local WAIT_FOR_BOSS_TIMEOUT = 60     -- give up waiting at the rocket after this

local Boss = {
	phase = "Idle",   -- Idle / Waiting / Fighting
	countdown = nil,
	dodging = false,
	hazardCount = 0,
}

---------------- paths ----------------
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

---------------- countdown ----------------
-- Handles "15", "Launching in 15s", "0:15", "1,000" etc.
local function getCountdown()
	local label = getCountdownLabel()
	if not label then return nil end
	local text = label.Text:gsub(",", "")
	local m, s = text:match("(%d+):(%d+)")
	if m then
		return tonumber(m) * 60 + tonumber(s)
	end
	return tonumber(text:match("%d+%.?%d*"))
end

---------------- hazard tracking ----------------
-- Every CandyCorn / Target under Terrain, old and new
local hazards = {}

local function trackHazard(obj)
	if HAZARD_NAMES[obj.Name] then
		hazards[obj] = true
	end
end

for _, child in ipairs(workspace.Terrain:GetChildren()) do
	trackHazard(child)
end
local hazardAddedConn = workspace.Terrain.ChildAdded:Connect(trackHazard)
local hazardRemovedConn = workspace.Terrain.ChildRemoved:Connect(function(obj)
	hazards[obj] = nil
end)

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
	if b.minX == math.huge then return nil end
	return b
end

-- Current areas of every live attack (refreshed every tick, so moving/growing attacks are handled)
local function snapshotHazards()
	-- catch anything the ChildAdded hook missed (e.g. renamed after spawning)
	for _, child in ipairs(workspace.Terrain:GetChildren()) do
		trackHazard(child)
	end

	local list = {}
	for obj in pairs(hazards) do
		if not obj.Parent then
			hazards[obj] = nil
		else
			local b = getXZBounds(obj)
			if b then table.insert(list, b) end
		end
	end
	return list
end

local function inDanger(pos, list, margin)
	for _, b in ipairs(list) do
		if pos.X >= b.minX - margin and pos.X <= b.maxX + margin
			and pos.Z >= b.minZ - margin and pos.Z <= b.maxZ + margin then
			return true
		end
	end
	return false
end

-- Nearest safe spot around `center`. Keeps the current safe spot if it's still safe.
-- Searches with a little extra margin so we don't sit right on the edge.
local function findSafeSpot(center, list, margin, current, playerPos)
	if current and not inDanger(current, list, margin) then
		return current
	end

	local searchMargin = margin + 2
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
		if best then return best end
	end
	return nil
end

---------------- movement / targeting ----------------
local function placeAt(root, pos)
	root.CFrame = CFrame.new(pos)
	root.AssemblyLinearVelocity = Vector3.zero
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
		if not p then return nil end
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
		if not boss then break end

		local root = getRoot()
		local attackPos = getBossAttackPos(boss)

		if root and attackPos then
			local list = snapshotHazards()
			Boss.hazardCount = #list

			if inDanger(attackPos, list, State.DodgeMargin) then
				-- DODGE (highest priority): hold a safe spot until the attack spot is clear
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
				-- ATTACK
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
local function runBossCycle(fromCountdown)
	bossActive = true

	-- take over movement once anything mid-teleport (e.g. diamonds) finishes
	while tpBusy do task.wait() end
	tpBusy = true

	local root = getRoot()
	local startCFrame = root and root.CFrame

	local ok, err = pcall(function()
		if fromCountdown and not getBossChicken() then
			Boss.phase = "Waiting"
			local circle = getRocketCircle()
			local circlePart = circle and getPart(circle)

			if circlePart then
				local target = circlePart.Position + Vector3.new(0, 3, 0)
				root = getRoot()
				if root then placeAt(root, target) end
				log("Teleported to rocket")

				local start = os.clock()
				while alive() and State.BossFarm and not getBossChicken()
					and os.clock() - start < WAIT_FOR_BOSS_TIMEOUT do
					-- stay on the pad only during the final countdown
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
	if not ok then warn("[EggFarm] Boss error:", err) end

	root = getRoot()
	if State.BossReturn and root and startCFrame then
		root.CFrame = startCFrame
	end

	Boss.phase = "Idle"
	tpBusy = false
	bossActive = false
end

---------------- countdown watcher ----------------
task.spawn(function()
	local lastValue, armed = nil, false

	while alive() do
		local value = getCountdown()
		Boss.countdown = value

		-- Arm only when it's actually counting down between 10 and 120
		if value and value ~= lastValue then
			if lastValue and value < lastValue and value > 10 and value < 120 then
				armed = true
			elseif lastValue and value > lastValue then
				armed = false -- reset / cooldown started
			end
			lastValue = value
		end

		if State.BossFarm then
			local countdownHit = armed and value ~= nil and value <= 10
			local bossAlready = State.BossJoinExisting and getBossChicken() ~= nil

			if countdownHit or bossAlready then
				armed = false
				runBossCycle(countdownHit)
				lastValue = nil
			end
		end

		task.wait(BOSS_TICK)
	end

	hazardAddedConn:Disconnect()
	hazardRemovedConn:Disconnect()
end)

------------------------------------------------------------------
-- Trophy Auto Reroll
------------------------------------------------------------------
local ItemsEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Items")

local function getTrophyList()
	local gui = player:FindFirstChild("PlayerGui")
	local menus = gui and gui:FindFirstChild("Menus")
	local inv = menus and menus:FindFirstChild("Inventory")
	return inv and inv:FindFirstChild("List")
end

-- Normalizes "02" / " 2 " / 2 -> "2"
local function normId(v)
	local n = tonumber(tostring(v):match("%d+"))
	return n and tostring(n) or nil
end

-- All trophies we own (one entry per TextButton, duplicates included)
local function getOwnedTrophies()
	local ids = {}
	local list = getTrophyList()
	if list then
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then
				local id = normId(child.Name)
				if id then table.insert(ids, id) end
			end
		end
	end
	return ids
end

local function isSaved(id)
	return State.SavedTrophies[id] == true
end

-- One pass: reroll every trophy that isn't on the saved list
local function rerollPass(force)
	local count = 0
	for _, id in ipairs(getOwnedTrophies()) do
		if not (alive() and (force or State.AutoReroll)) then break end
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
			-- rescans each pass, so rerolled trophies that became saved are left alone
			local count = rerollPass(false)
			if count == 0 then
				task.wait(1) -- nothing to reroll right now
			end
		end
		task.wait(0.1)
	end
end)

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
_G.EggFarmRayfield = Rayfield

local Window = Rayfield:CreateWindow({
	Name = "Egg Farm Simulator",
	Icon = 0,
	LoadingTitle = "Egg Farm Simulator",
	LoadingSubtitle = "Autofarm",
	Theme = "Default",
	DisableRayfieldPrompts = false,
	DisableBuildWarnings = false,
	ConfigurationSaving = {
		Enabled = true,
		FolderName = "EggFarmSim",
		FileName = "Autofarm",
	},
	KeySystem = false,
})

local function notify(title, content)
	Rayfield:Notify({ Title = title, Content = content, Duration = 4, Image = "info" })
end

---------------- Farming tab ----------------
local FarmTab = Window:CreateTab("Farming", "gem")

FarmTab:CreateSection("Diamonds")

FarmTab:CreateToggle({
	Name = "Auto Collect Diamonds",
	CurrentValue = false,
	Flag = "AutoDiamonds",
	Callback = function(v) State.Diamonds = v end,
})

FarmTab:CreateToggle({
	Name = "Return to Spot After Collecting",
	CurrentValue = true,
	Flag = "ReturnAfterDiamonds",
	Callback = function(v) State.ReturnAfterDiamonds = v end,
})

FarmTab:CreateSlider({
	Name = "Skip Stuck Diamond After",
	Range = { 0.5, 5 },
	Increment = 0.5,
	Suffix = "s",
	CurrentValue = 1.5,
	Flag = "DiamondTimeout",
	Callback = function(v) State.DiamondTimeout = v end,
})

FarmTab:CreateButton({
	Name = "Collect Diamonds Once",
	Callback = function()
		if bossActive then
			notify("Diamonds", "Paused during the boss fight.")
			return
		end
		local folder = getDiamondFolder()
		if not folder then
			notify("Diamonds", "Couldn't find your farm's Diamonds folder.")
			return
		end
		task.spawn(collectDiamonds, folder, true)
	end,
})

FarmTab:CreateButton({
	Name = "Reset Skipped Diamonds",
	Callback = function()
		table.clear(skippedDiamonds)
		notify("Diamonds", "Skipped list cleared.")
	end,
})

FarmTab:CreateSection("Meat & Grapes")

FarmTab:CreateToggle({
	Name = "Auto Collect Meat",
	CurrentValue = false,
	Flag = "AutoMeat",
	Callback = function(v) State.Meat = v end,
})

FarmTab:CreateSlider({
	Name = "Meat Range",
	Range = { 10, 200 },
	Increment = 5,
	Suffix = " studs",
	CurrentValue = 50,
	Flag = "MeatRange",
	Callback = function(v) State.MeatRange = v end,
})

FarmTab:CreateToggle({
	Name = "Auto Collect Grapes",
	CurrentValue = false,
	Flag = "AutoGrapes",
	Callback = function(v) State.Grapes = v end,
})

FarmTab:CreateSlider({
	Name = "Sweep Interval",
	Range = { 0.1, 2 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = 0.25,
	Flag = "TouchInterval",
	Callback = function(v) State.TouchInterval = v end,
})

---------------- Heroes tab ----------------
local HeroTab = Window:CreateTab("Heroes", "swords")

HeroTab:CreateSection("Hero Autofarm")

HeroTab:CreateToggle({
	Name = "Hero Autofarm",
	CurrentValue = false,
	Flag = "HeroAutofarm",
	Callback = function(v)
		State.HeroFarm = v
		if v then heroNextTick = 0 end
	end,
})

HeroTab:CreateParagraph({
	Title = "How it works",
	Content = "Every tick: max upgrade your best heroes (best -> worst).\n"
		.. "Every Nth tick: also run the next batch, starting from your worst heroes and moving up, then wrapping around.\n"
		.. "Every Nth tick: try to buy the next hero.",
})

HeroTab:CreateSlider({
	Name = "Tick Interval",
	Range = { 1, 30 },
	Increment = 1,
	Suffix = "s",
	CurrentValue = 5,
	Flag = "HeroTickInterval",
	Callback = function(v) State.HeroTickInterval = v end,
})

HeroTab:CreateSlider({
	Name = "Best Heroes Each Tick",
	Range = { 1, 10 },
	Increment = 1,
	Suffix = "",
	CurrentValue = 3,
	Flag = "HeroBestCount",
	Callback = function(v) State.HeroBestCount = v end,
})

HeroTab:CreateSlider({
	Name = "Batch Size",
	Range = { 1, 20 },
	Increment = 1,
	Suffix = "",
	CurrentValue = 5,
	Flag = "HeroBatchSize",
	Callback = function(v) State.HeroBatchSize = v end,
})

HeroTab:CreateSlider({
	Name = "Run Batch Every N Ticks",
	Range = { 1, 10 },
	Increment = 1,
	Suffix = "",
	CurrentValue = 3,
	Flag = "HeroBatchEvery",
	Callback = function(v) State.HeroBatchEvery = v end,
})

HeroTab:CreateSlider({
	Name = "Buy Hero Every N Ticks",
	Range = { 1, 10 },
	Increment = 1,
	Suffix = "",
	CurrentValue = 2,
	Flag = "HeroBuyEvery",
	Callback = function(v) State.HeroBuyEvery = v end,
})

HeroTab:CreateSlider({
	Name = "Upgrades Per Hero",
	Range = { 1, 6 },
	Increment = 1,
	Suffix = "",
	CurrentValue = 6,
	Flag = "UpgradeCount",
	Callback = function(v) State.UpgradeCount = v end,
})

HeroTab:CreateSection("Single Hero Mode")

HeroTab:CreateToggle({
	Name = "Only Upgrade One Hero",
	CurrentValue = false,
	Flag = "SingleHero",
	Callback = function(v) State.SingleHero = v end,
})

HeroTab:CreateInput({
	Name = "Hero ID",
	CurrentValue = "2",
	PlaceholderText = "2",
	RemoveTextAfterFocusLost = false,
	Flag = "SingleHeroId",
	Callback = function(text)
		local id = tonumber(text)
		if id and id >= 1 then
			State.SingleHeroId = math.floor(id)
		end
	end,
})

HeroTab:CreateSection("Manual")

HeroTab:CreateButton({
	Name = "Run One Tick Now",
	Callback = function() task.spawn(heroFarmTick, true) end,
})

HeroTab:CreateButton({
	Name = "Buy Next Hero Now",
	Callback = function() task.spawn(buyNextHero) end,
})

HeroTab:CreateButton({
	Name = "Restart Batches From Worst",
	Callback = function()
		batchIndex = 0
		notify("Heroes", "Next batch will start from your worst heroes.")
	end,
})

---------------- Progress tab ----------------
local ProgressTab = Window:CreateTab("Progress", "trending-up")

ProgressTab:CreateSection("Auto Advance")

ProgressTab:CreateToggle({
	Name = "Auto Advance When Ready",
	CurrentValue = false,
	Flag = "AutoAdvance",
	Callback = function(v) State.AutoAdvance = v end,
})

ProgressTab:CreateSlider({
	Name = "Cooldown After Advancing",
	Range = { 1, 15 },
	Increment = 1,
	Suffix = "s",
	CurrentValue = 3,
	Flag = "AdvanceCooldown",
	Callback = function(v) State.AdvanceCooldown = v end,
})

ProgressTab:CreateButton({
	Name = "Advance Now",
	Callback = function()
		local current, needed = getProgress()
		if current and needed and current < needed then
			notify("Progress", ("Not ready yet (%d / %d)."):format(current, needed))
			return
		end
		task.spawn(advance)
	end,
})

---------------- Boss tab ----------------
local BossTab = Window:CreateTab("Boss", "skull")

BossTab:CreateSection("Boss Farm")

BossTab:CreateToggle({
	Name = "Boss Farm",
	CurrentValue = false,
	Flag = "BossFarm",
	Callback = function(v) State.BossFarm = v end,
})

BossTab:CreateParagraph({
	Title = "How it works",
	Content = "When the rocket countdown hits 10, teleports you to the rocket and waits for the boss.\n"
		.. "Then attacks from above the boss, dodging CandyCorn / Target attacks (dodging always wins).\n"
		.. "Diamond collecting is paused until the boss is gone.",
})

BossTab:CreateToggle({
	Name = "Join Fight If Boss Already Exists",
	CurrentValue = true,
	Flag = "BossJoinExisting",
	Callback = function(v) State.BossJoinExisting = v end,
})

BossTab:CreateToggle({
	Name = "Return to Start Spot After Fight",
	CurrentValue = false,
	Flag = "BossReturn",
	Callback = function(v) State.BossReturn = v end,
})

BossTab:CreateSection("Tuning")

BossTab:CreateSlider({
	Name = "Dodge Margin",
	Range = { 0, 15 },
	Increment = 1,
	Suffix = " studs",
	CurrentValue = 5,
	Flag = "DodgeMargin",
	Callback = function(v) State.DodgeMargin = v end,
})

BossTab:CreateSlider({
	Name = "Height Above Boss",
	Range = { 0, 15 },
	Increment = 1,
	Suffix = " studs",
	CurrentValue = 2,
	Flag = "BossHeight",
	Callback = function(v) State.BossHeight = v end,
})

BossTab:CreateSection("Manual")

BossTab:CreateButton({
	Name = "Teleport to Rocket Now",
	Callback = function()
		local circle = getRocketCircle()
		local part = circle and getPart(circle)
		local root = getRoot()
		if part and root then
			placeAt(root, part.Position + Vector3.new(0, 3, 0))
		else
			notify("Boss", "Couldn't find the rocket.")
		end
	end,
})

---------------- Trophies tab ----------------
local TrophyTab = Window:CreateTab("Trophies", "trophy")

TrophyTab:CreateSection("Auto Reroll")

TrophyTab:CreateToggle({
	Name = "Auto Reroll Trophies",
	CurrentValue = false,
	Flag = "AutoReroll",
	Callback = function(v) State.AutoReroll = v end,
})

TrophyTab:CreateInput({
	Name = "Saved Trophy IDs (never rerolled)",
	CurrentValue = "2, 26, 40",
	PlaceholderText = "2, 26, 40",
	RemoveTextAfterFocusLost = false,
	Flag = "SavedTrophies",
	Callback = function(text)
		local saved = {}
		for part in tostring(text):gmatch("[^,%s]+") do
			local id = normId(part)
			if id then saved[id] = true end
		end
		State.SavedTrophies = saved
	end,
})

TrophyTab:CreateSlider({
	Name = "Delay Between Rerolls",
	Range = { 0.05, 2 },
	Increment = 0.05,
	Suffix = "s",
	CurrentValue = 0.25,
	Flag = "RerollDelay",
	Callback = function(v) State.RerollDelay = v end,
})

TrophyTab:CreateSection("Manual")

TrophyTab:CreateButton({
	Name = "Reroll Unsaved Once",
	Callback = function()
		task.spawn(function()
			local n = rerollPass(true)
			notify("Trophies", ("Rerolled %d trophies."):format(n))
		end)
	end,
})

---------------- Status tab ----------------
local StatusTab = Window:CreateTab("Status", "activity")

StatusTab:CreateSection("Live Info")

local FarmInfo = StatusTab:CreateParagraph({ Title = "Farm", Content = "Searching..." })
local ProgressInfo = StatusTab:CreateParagraph({ Title = "Progress", Content = "-" })
local BossInfo = StatusTab:CreateParagraph({ Title = "Boss", Content = "-" })
local TrophyInfo = StatusTab:CreateParagraph({ Title = "Trophies", Content = "-" })
local HeroInfo = StatusTab:CreateParagraph({ Title = "Heroes", Content = "-" })
local StatsInfo = StatusTab:CreateParagraph({ Title = "Session Stats", Content = "-" })

StatusTab:CreateButton({
	Name = "Re-find My Farm",
	Callback = function()
		local farm = getFarm(true)
		notify("Farm", farm and ("Found: " .. farm.Name) or "Couldn't find your farm.")
	end,
})

---------------- Settings tab ----------------
local SettingsTab = Window:CreateTab("Settings", "settings")

SettingsTab:CreateSection("Touch")

SettingsTab:CreateToggle({
	Name = "Swap firetouchinterest Args",
	CurrentValue = false,
	Flag = "SwapArgs",
	Callback = function(v) State.SwapArgs = v end,
})

SettingsTab:CreateSection("Misc")

SettingsTab:CreateToggle({
	Name = "Debug Prints (F9 console)",
	CurrentValue = false,
	Flag = "DebugPrints",
	Callback = function(v) State.Debug = v end,
})

SettingsTab:CreateButton({
	Name = "Stop Everything & Close GUI",
	Callback = function()
		_G.EggFarmSession = session + 1 -- stops all loops
		_G.EggFarmRayfield = nil
		Rayfield:Destroy()
	end,
})

------------------------------------------------------------------
-- Status updater
------------------------------------------------------------------
task.spawn(function()
	while alive() do
		pcall(function()
			local farm = getFarm()
			local folder = farm and farm:FindFirstChild("Diamonds")

			FarmInfo:Set({
				Title = "Farm",
				Content = (farm
					and ("Found: " .. farm.Name .. "\nDiamonds waiting: " .. countDiamonds(folder))
					or "Not found yet (use Re-find My Farm)")
					.. "\nGrape TouchTransmitters loaded: " .. grapeTransmitters,
			})

			local current, needed = getProgress()
			ProgressInfo:Set({
				Title = "Progress",
				Content = current and needed
					and ("Chickens: %d / %d%s\nLevels advanced: %d"):format(
						current, needed,
						current >= needed and "  (ready!)" or "",
						Stats.Advances
					)
					or ("Progress label not found\nLevels advanced: %d"):format(Stats.Advances),
			})

			local trophies = getOwnedTrophies()
			local savedOwned, unsaved = {}, 0
			for _, id in ipairs(trophies) do
				if isSaved(id) then
					table.insert(savedOwned, id)
				else
					unsaved += 1
				end
			end
			table.sort(savedOwned, function(a, b) return tonumber(a) < tonumber(b) end)

			TrophyInfo:Set({
				Title = "Trophies",
				Content = ("Owned: %d\nSaved: %d (%s)\nTo reroll: %d\nRerolls sent: %d"):format(
					#trophies,
					#savedOwned,
					#savedOwned > 0 and table.concat(savedOwned, ", ") or "none",
					unsaved,
					Stats.Rerolls
				),
			})

			BossInfo:Set({
				Title = "Boss",
				Content = ("Phase: %s%s\nCountdown: %s\nActive attacks: %d\nFights: %d | Dodges: %d | Hits sent: %d"):format(
					Boss.phase,
					Boss.dodging and " (DODGING)" or "",
					Boss.countdown and tostring(Boss.countdown) or "-",
					Boss.hazardCount,
					Stats.BossFights, Stats.Dodges, Stats.BossAttacks
				),
			})

			local owned = getOwnedHeroIds()
			local batchText = "none"
			if #owned > 0 then
				local first, last = getBatchRange(owned)
				batchText = ("IDs %d - %d"):format(owned[first], owned[last])
			end

			HeroInfo:Set({
				Title = "Heroes",
				Content = ("Owned: %d\nHighest ID: %s\nNext to buy: %d\nTick: %d\nMode: %s"):format(
					#owned,
					owned[#owned] and tostring(owned[#owned]) or "none",
					(owned[#owned] or 0) + 1,
					heroTick,
					State.SingleHero
						and ("single hero (ID " .. State.SingleHeroId .. ")")
						or ("best " .. State.HeroBestCount .. " + batches, next batch " .. batchText)
				),
			})

			StatsInfo:Set({
				Title = "Session Stats",
				Content = ("Diamonds collected: %d\nMeat touches: %d\nGrape touches: %d\nHero ticks: %d\nBatches run: %d\nHero buy attempts: %d"):format(
					Stats.Diamonds, Stats.Meat, Stats.Grapes,
					Stats.HeroTicks, Stats.BatchPasses, Stats.HeroBuyAttempts
				),
			})
		end)
		task.wait(1)
	end
end)

------------------------------------------------------------------
-- Load saved settings + startup notice
------------------------------------------------------------------
Rayfield:LoadConfiguration()

if getFarm() then
	notify("Egg Farm", "Loaded. Farm found: " .. cachedFarm.Name)
else
	notify("Egg Farm", "Loaded, but your farm wasn't found yet.")
end
