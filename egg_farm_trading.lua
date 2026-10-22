--[[
	Egg Farm Simulator · Items tab (auto sell / auto open boxes), Abilities tab + Alt / Master trading
	Loaded by the main autofarm script from GitHub (kept separate so the main
	script stays small enough to paste into an executor). Not meant to be run on its own.

	Selling and box opening live here with trading so they can coordinate: a box
	reveal hides every menu (which cancels a trade), so boxes never open during a
	trade and trades wait for a box to finish.

	Alts trade their items to the master account. Each account's role is saved per
	UserId in workspace/EggFarmSim/accounts.json, so several accounts on one PC each
	keep their own role, and an alt finds the master automatically once the master
	has picked its role on the same PC.
]]

return function(ctx)
	local tab = ctx.Tab
	local alive, track, log, notify = ctx.alive, ctx.track, ctx.log, ctx.notify
	-- true while this account is fighting the boss: no trade starts during a fight
	local bossBusy = type(ctx.bossBusy) == "function" and ctx.bossBusy or function()
		return false
	end
	local idFromLabel, heroOptions = ctx.idFromLabel, ctx.heroOptions

	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local HttpService = game:GetService("HttpService")
	local player = Players.LocalPlayer

	local itemsTab = ctx.ItemsTab
	local Events = ReplicatedStorage:FindFirstChild("Events")
	local TradeEvent = Events and Events:WaitForChild("Trade", 5)
	local ItemsEvent = Events and Events:FindFirstChild("Items")
	if not TradeEvent then
		error("ReplicatedStorage.Events.Trade wasn't found", 0)
	end

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

	-- Opening a box plays a reveal that hides every menu, which cancels an open trade.
	-- The box opener sets this while a box is opening; trades wait for it, and the
	-- box opener waits for trades (see tradeActive below).
	local boxBusyUntil = 0
	local function boxBusy()
		return os.clock() < boxBusyUntil
	end
	local waitingToAccept = false -- master is holding a request until a box finishes

	-- Requires a game module, but gives up after `timeout` so it can never freeze loading
	local function requireWithin(folderName, moduleName, timeout)
		local job = { done = false }
		task.spawn(function()
			local ok, result = pcall(function()
				local folder = ReplicatedStorage:FindFirstChild(folderName)
				local module = folder and folder:FindFirstChild(moduleName)
				return module and require(module)
			end)
			job.value = ok and result or nil
			job.done = true
		end)
		local start = os.clock()
		while not job.done and os.clock() - start < timeout do
			task.wait()
		end
		return job.value
	end

	local ItemsFolder = ReplicatedStorage:FindFirstChild("Items")
	local BoxData = requireWithin("Settings", "BoxData", 3)
	if type(BoxData) ~= "table" then
		BoxData = nil
	end

	-- Your live inventory (the same data the game's inventory menu reads).
	-- Only loaded the first time something is sold, so it can't slow down startup.
	local dataJob
	local function getData()
		if not dataJob then
			dataJob = { done = false }
			task.spawn(function()
				local ok, result = pcall(function()
					local folder = ReplicatedStorage:WaitForChild("Modules", 10)
					local module = folder and folder:WaitForChild("DataHandler", 10)
					if not module then
						error("ReplicatedStorage.Modules.DataHandler wasn't found", 0)
					end
					return require(module)
				end)
				if ok and type(result) == "table" and type(result.Get) == "function" then
					dataJob.value = result
				else
					dataJob.err = ok and "DataHandler has no Get function" or tostring(result)
				end
				dataJob.done = true
			end)
			local start = os.clock()
			while not dataJob.done and os.clock() - start < 5 do
				task.wait()
			end
		end
		if not dataJob.value then
			return nil, dataJob.done and ("Couldn't read your inventory: " .. tostring(dataJob.err)) or "Still loading your inventory..."
		end
		local ok, data = pcall(dataJob.value.Get, "data")
		if not ok or type(data) ~= "table" or type(data.inventory) ~= "table" then
			return nil, "Couldn't read your inventory"
		end
		return data
	end

	---------------- accounts file ----------------
	local ACCOUNTS_FILE = "EggFarmSim/accounts.json"
	local ROLES = { Off = true, Alt = true, Master = true }
	local myKey = tostring(player.UserId)

	-- Always returns { accounts = { [userId] = { name, role, master?, updated } } },
	-- dropping anything malformed so the rest of the script can trust the shape.
	local function readAccounts()
		local data
		pcall(function()
			if isfile(ACCOUNTS_FILE) then
				data = HttpService:JSONDecode(readfile(ACCOUNTS_FILE))
			end
		end)
		if type(data) ~= "table" then
			data = {}
		end
		if type(data.accounts) ~= "table" then
			data.accounts = {}
		end
		for key, entry in pairs(data.accounts) do
			if type(entry) ~= "table" or type(entry.name) ~= "string" or not ROLES[entry.role] then
				data.accounts[key] = nil
			end
		end
		return data
	end

	local function writeAccounts(data)
		return (pcall(function()
			if not isfolder("EggFarmSim") then
				makefolder("EggFarmSim")
			end
			writefile(ACCOUNTS_FILE, HttpService:JSONEncode(data))
		end))
	end

	-- Re-reads before writing so another account's change in the meantime isn't lost
	local function updateMyAccount(changes)
		local data = readAccounts()
		local me = data.accounts[myKey] or { role = "Off" }
		for k, v in pairs(changes) do
			me[k] = v
		end
		me.name = player.Name
		me.updated = os.time()
		data.accounts[myKey] = me
		return writeAccounts(data)
	end

	local function myAccount()
		return readAccounts().accounts[myKey]
	end

	local currentRole = (myAccount() or {}).role or "Off"

	-- Master to send to: this account's own override, otherwise the account
	-- most recently set as Master on this PC
	local function getMasterName()
		local data = readAccounts()
		local me = data.accounts[myKey]
		if me and type(me.master) == "string" and me.master ~= "" then
			return me.master, "typed in"
		end
		local best
		for key, entry in pairs(data.accounts) do
			if key ~= myKey and entry.role == "Master" and (not best or (entry.updated or 0) > (best.updated or 0)) then
				best = entry
			end
		end
		if best then
			return best.name, "this PC"
		end
		return nil
	end

	local function knownAlts()
		local names = {}
		for key, entry in pairs(readAccounts().accounts) do
			if key ~= myKey and entry.role == "Alt" then
				table.insert(names, entry.name)
			end
		end
		table.sort(names)
		return names
	end

	local function findPlayer(name)
		local lower = string.lower(tostring(name))
		for _, p in ipairs(Players:GetPlayers()) do
			if string.lower(p.Name) == lower then
				return p
			end
		end
		return nil
	end

	---------------- settings (driven by the menu) ----------------
	local CATEGORIES = { "Boxes", "Weapons", "Wings", "Trails", "Trophies" }
	local MAX_SLOTS = 4 -- slots per trade

	local TradeSettings = {
		AutoSend = false,
		Types = { Boxes = true },
		Filter = {}, -- [category] = set of allowed keys; empty = everything
		Stacks = false,
		Diamonds = false,
		KeepDiamonds = 0,
		AutoAccept = false,
		AcceptAnyone = false,
		ExtraAlts = {}, -- lowercased names
	}

	---------------- building an offer ----------------
	-- Tier the game attaches to each slot (same rules as its trade menu)
	local function tierOf(cat, key, value)
		if cat == "Boxes" then
			return value
		elseif cat == "Trophies" then
			return 7
		end
		local folder = ItemsFolder and ItemsFolder:FindFirstChild(cat)
		local item = folder and folder:FindFirstChild(cat == "Weapons" and tostring(value[1]) or tostring(key))
		local tier = item and item:FindFirstChild("Tier")
		return tier and tier.Value or 1
	end

	-- What the per-category filters compare against
	local function filterKey(cat, key, value)
		if cat == "Boxes" then
			return tostring(value) -- box tier
		elseif cat == "Weapons" then
			return type(value) == "table" and tostring(value[1]) or nil -- weapon name
		end
		return tostring(key) -- wing / trail name, trophy hero ID
	end

	local function allowed(cat, key, value)
		local set = TradeSettings.Filter[cat]
		if not set or next(set) == nil then
			return true
		end
		local k = filterKey(cat, key, value)
		return k ~= nil and set[k] == true
	end

	local function sortedKeys(t)
		local keys = {}
		for key in pairs(t) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			if type(a) == "number" and type(b) == "number" then
				return a < b
			end
			return tostring(a) < tostring(b)
		end)
		return keys
	end

	-- Up to 4 slots in the game's trade format: { category, key, value, tier, count = n }
	-- Returns giving, diamonds, itemCount, errorMessage
	local function buildOffer()
		local data, dataErr = getData()
		if not data or type(data.inventory) ~= "table" then
			return nil, 0, 0, dataErr or "Couldn't read your inventory"
		end

		local giving, slots, items = {}, 0, 0
		local function add(cat, key, value, count)
			slots += 1
			giving[tostring(slots)] = { cat, key, value, tierOf(cat, key, value), count = count }
			items += count
		end

		for _, cat in ipairs(CATEGORIES) do
			if slots >= MAX_SLOTS then
				break
			end
			local inv = data.inventory[string.lower(cat)]
			local equipped = type(data.using) == "table" and data.using[string.lower(cat)] or nil
			if TradeSettings.Types[cat] and type(inv) == "table" then
				for _, key in ipairs(sortedKeys(inv)) do
					if slots >= MAX_SLOTS then
						break
					end
					local value = inv[key]
					local isEquipped = equipped ~= nil and tostring(key) == tostring(equipped)
					if not isEquipped and allowed(cat, key, value) then
						if cat == "Boxes" then
							add(cat, key, value, 1) -- every box is its own entry
						else
							local owned
							if cat == "Weapons" then
								owned = type(value) == "table" and (tonumber(value[3]) or 1) or 0
							else
								owned = tonumber(value) or 0
							end
							if owned > 0 then
								if TradeSettings.Stacks then
									add(cat, key, value, owned)
								else
									for _ = 1, math.min(owned, MAX_SLOTS - slots) do
										add(cat, key, value, 1)
									end
								end
							end
						end
					end
				end
			end
		end

		local diamonds = 0
		if TradeSettings.Diamonds then
			local have = tonumber(data.diamonds) or 0
			diamonds = math.min(math.floor(math.max(0, have - TradeSettings.KeepDiamonds)), 999999999999)
		end
		return giving, diamonds, items, nil
	end

	local function countSlots(slots)
		local n = 0
		for _, slot in pairs(slots or {}) do
			if type(slot) == "table" then
				n += tonumber(slot.count) or 1
			end
		end
		return n
	end

	---------------- trade window helpers ----------------
	local function getTradeFrame()
		local gui = player:FindFirstChild("PlayerGui")
		local menus = gui and gui:FindFirstChild("Menus")
		return menus and menus:FindFirstChild("Trade")
	end

	-- The game moves its Prompt between Menus.Trade and Menus, so look in both
	local promptRef
	local function getPrompt()
		if promptRef and promptRef.Parent then
			return promptRef
		end
		local trade = getTradeFrame()
		promptRef = trade and (trade:FindFirstChild("Prompt") or (trade.Parent and trade.Parent:FindFirstChild("Prompt")))
		return promptRef
	end

	local function isTradeOpen()
		local trade = getTradeFrame()
		return trade ~= nil and trade.Visible
	end

	-- The game's trade script declines an "Accept" unless this prompt is showing,
	-- so the alt shows it exactly like the game does when you send a request yourself
	local function showRequestPrompt()
		pcall(function()
			local trade, prompt = getTradeFrame(), getPrompt()
			prompt.Title.Text = "Trade Request Sent"
			prompt.Description.Text = "Waiting for other player"
			prompt.Confirm.Visible = false
			prompt.Parent = trade.Parent
			prompt.Visible = true
		end)
	end

	local function hidePrompt()
		pcall(function()
			local trade, prompt = getTradeFrame(), getPrompt()
			prompt.Visible = false
			prompt.Parent = trade
		end)
	end

	-- Hiding the window makes the game's trade script send Decline and reset itself
	local function closeTrade()
		local trade = getTradeFrame()
		if trade and trade.Visible then
			trade.Visible = false
		end
		hidePrompt()
	end

	---------------- trade events ----------------
	local TradeInfo = {
		phase = "Idle", -- Idle / Requesting / Offering / Confirming / Receiving
		partner = nil,
		startedAt = 0,
		message = "-",
		received = {},
		receivedDiamonds = 0,
		trades = 0,
		items = 0,
		diamonds = 0,
	}

	local FAIL_EVENTS = {
		Busy = "%s can't trade right now",
		Decline = "%s cancelled the trade",
		Throttle = "Trade cooldown (%ss)",
		Disable = "Trading is turned off",
		FriendsOnly = "Friends-only trading is on",
		Leave = "%s left the game",
	}

	local function failMessage(kind, arg)
		return (FAIL_EVENTS[kind] or kind):format(tostring(arg or "?"))
	end

	local function resetTradeInfo(message)
		TradeInfo.phase = "Idle"
		TradeInfo.partner = nil
		TradeInfo.received = {}
		TradeInfo.receivedDiamonds = 0
		if message then
			TradeInfo.message = message
		end
	end

	local pending = {} -- latest [eventName] = { arg1, arg2 } from the server

	-- Waits for `want` (or any failure). Returns the event name and its first argument, or nil on timeout.
	local function waitForEvent(want, timeout, partner)
		local start = os.clock()
		while alive() and os.clock() - start < timeout do
			if pending[want] then
				return want, pending[want][1]
			end
			for kind in pairs(FAIL_EVENTS) do
				local hit = pending[kind]
				if hit and (kind ~= "Leave" or hit[1] == partner) then
					return kind, hit[1]
				end
			end
			task.wait(0.1)
		end
		return nil
	end

	---------------- master side ----------------
	local function isAllowedAlt(name)
		if TradeSettings.AcceptAnyone then
			return true
		end
		local lower = string.lower(tostring(name))
		if TradeSettings.ExtraAlts[lower] then
			return true
		end
		for _, alt in ipairs(knownAlts()) do
			if string.lower(alt) == lower then
				return true
			end
		end
		return false
	end

	local function masterAccept(from)
		if currentRole ~= "Master" or not TradeSettings.AutoAccept or TradeInfo.partner then
			return
		end
		if not isAllowedAlt(from) then
			log("Ignoring trade request from", from)
			return
		end
		-- let a box that's opening finish first, or its reveal would close the trade
		waitingToAccept = true
		local start = os.clock()
		while alive() and boxBusy() and os.clock() - start < 15 do
			task.wait(0.1)
		end
		task.wait(0.3) -- let the game finish showing its "Trade Requested" prompt
		waitingToAccept = false
		if not alive() or isTradeOpen() then
			return
		end
		-- the boss fight comes first: turn the request down, the alt tries again later
		if bossBusy() then
			pcall(function()
				TradeEvent:FireServer("Decline", from)
			end)
			hidePrompt()
			TradeInfo.message = ("Declined %s's request: fighting the boss"):format(from)
			return
		end

		resetTradeInfo(("Trading with %s"):format(from))
		TradeInfo.partner, TradeInfo.phase, TradeInfo.startedAt = from, "Receiving", os.clock()

		-- same as pressing the game's Accept button
		pcall(function()
			TradeEvent:FireServer("Accept", from)
		end)
		hidePrompt()
		local trade = getTradeFrame()
		if trade then
			trade.Visible = true
		end
	end

	-- Confirms once the alt has confirmed. The master never offers anything back.
	local function masterConfirm()
		local partner = TradeInfo.partner
		if currentRole ~= "Master" or not partner or TradeInfo.phase ~= "Receiving" then
			return
		end
		TradeInfo.phase = "Confirming"
		task.wait(0.5)
		pcall(function()
			TradeEvent:FireServer("Confirm", partner, {
				Giving = {},
				Receiving = TradeInfo.received,
				GivingD = {},
				ReceivingD = TradeInfo.receivedDiamonds > 0 and { amount = TradeInfo.receivedDiamonds } or {},
			})
		end)
	end

	local function onTradeEvent(kind, a, b)
		pending[kind] = { a, b }

		if kind == "Request" then
			if currentRole == "Master" then
				task.spawn(masterAccept, a)
			end
		elseif kind == "Sync" then
			if a == TradeInfo.partner and type(b) == "table" then
				TradeInfo.received = b
			end
		elseif kind == "Diamonds" then
			if a == TradeInfo.partner then
				TradeInfo.receivedDiamonds = tonumber(b) or 0
			end
		elseif kind == "Confirm" then
			task.spawn(masterConfirm)
		elseif kind == "Success" then
			if currentRole == "Master" and TradeInfo.partner then
				local items, diamonds = countSlots(TradeInfo.received), TradeInfo.receivedDiamonds
				TradeInfo.trades += 1
				TradeInfo.items += items
				TradeInfo.diamonds += diamonds
				resetTradeInfo(("Received %d item(s)%s from %s"):format(
					items, diamonds > 0 and (" + " .. diamonds .. " diamonds") or "", TradeInfo.partner))
			end
		elseif FAIL_EVENTS[kind] then
			if currentRole == "Master" and TradeInfo.partner and (kind ~= "Leave" or a == TradeInfo.partner) then
				resetTradeInfo(failMessage(kind, a))
			end
		end
	end
	if TradeEvent then
		track(TradeEvent.OnClientEvent:Connect(onTradeEvent))
	end

	-- Master: give up on a trade that stalls
	task.spawn(function()
		while alive() do
			if currentRole == "Master" and TradeInfo.partner and os.clock() - TradeInfo.startedAt > 60 then
				local partner = TradeInfo.partner
				closeTrade()
				resetTradeInfo(("Trade with %s timed out"):format(partner))
			end
			task.wait(1)
		end
	end)

	---------------- alt side ----------------
	local REQUEST_TIMEOUT = 20 -- seconds for the master to accept
	local unanswered = 0 -- requests in a row the master didn't answer
	local CONFIRM_DELAY = 4.5  -- the game unlocks Accept 4s after the last change
	local SUCCESS_TIMEOUT = 30 -- seconds for the master to confirm

	-- One full trade to the master. Returns how long to wait before the next one.
	local function altTradeOnce()
		local name = getMasterName()
		if not name then
			TradeInfo.message = "No master set — pick Master on the main account, or type its name"
			return 5
		end
		local masterPlayer = findPlayer(name)
		if not masterPlayer then
			TradeInfo.message = name .. " isn't in this server"
			return 5
		end
		if masterPlayer == player then
			TradeInfo.message = "This account can't send to itself"
			return 10
		end
		local master = masterPlayer.Name -- exact spelling for the remote

		if isTradeOpen() then
			TradeInfo.message = "A trade window is already open"
			return 3
		end

		local giving, diamonds, items, err = buildOffer()
		if err then
			TradeInfo.message = err
			return 5
		end
		if items == 0 and diamonds <= 0 then
			TradeInfo.message = "Nothing to send"
			return 5
		end

		-- 1. request (nothing below yields before the request is out, so a box can't start in between)
		if bossBusy() then
			TradeInfo.message = "Waiting for the boss fight to end"
			return 3
		end
		if boxBusy() then
			TradeInfo.message = "Waiting for a box to finish opening"
			return 1
		end
		table.clear(pending)
		resetTradeInfo("Requesting a trade with " .. master)
		TradeInfo.partner, TradeInfo.phase, TradeInfo.startedAt = master, "Requesting", os.clock()
		showRequestPrompt()
		pcall(function()
			TradeEvent:FireServer("Request", master)
		end)

		local kind, arg = waitForEvent("Accept", REQUEST_TIMEOUT, master)
		if kind ~= "Accept" then
			hidePrompt()
			if kind == nil then
				pcall(function()
					TradeEvent:FireServer("Decline")
				end)
			end
			resetTradeInfo(kind and failMessage(kind, arg) or (master .. " didn't accept in time"))
			if kind == "Throttle" then
				return (tonumber(arg) or 5) + 1
			elseif kind == "Disable" or kind == "FriendsOnly" then
				return 30
			elseif kind == nil or kind == "Decline" or kind == "Busy" then
				-- the master isn't taking trades right now (auto accept off, fighting the boss...):
				-- wait longer each time so farming here isn't stuck paused on requests
				unanswered += 1
				local waitTime = math.min(15 * unanswered, 60)
				TradeInfo.message ..= (" — trying again in %ds"):format(waitTime)
				return waitTime
			end
			return 5
		end
		unanswered = 0

		-- 2. offer
		TradeInfo.phase = "Offering"
		TradeInfo.message = ("Offering %d item(s)%s"):format(items, diamonds > 0 and (" + " .. diamonds .. " diamonds") or "")
		task.wait(0.5)
		pcall(function()
			TradeEvent:FireServer("Sync", master, giving)
		end)
		if diamonds > 0 then
			pcall(function()
				TradeEvent:FireServer("Diamonds", master, diamonds)
			end)
		end

		local failed, failArg = waitForEvent("__none", CONFIRM_DELAY, master)
		if failed then
			resetTradeInfo(failMessage(failed, failArg))
			return 5
		end

		-- 3. confirm, then wait for the master
		TradeInfo.phase = "Confirming"
		pcall(function()
			TradeEvent:FireServer("Confirm", master, {
				Giving = giving,
				Receiving = {},
				GivingD = diamonds > 0 and { amount = diamonds } or {},
				ReceivingD = {},
			})
		end)

		local done, doneArg = waitForEvent("Success", SUCCESS_TIMEOUT, master)
		if done == "Success" then
			TradeInfo.trades += 1
			TradeInfo.items += items
			TradeInfo.diamonds += diamonds
			resetTradeInfo(("Sent %d item(s)%s to %s"):format(items, diamonds > 0 and (" + " .. diamonds .. " diamonds") or "", master))
			return 2 -- give the inventory a moment to update
		end
		if done == nil then
			closeTrade()
			resetTradeInfo(master .. " didn't confirm in time")
		else
			resetTradeInfo(failMessage(done, doneArg))
		end
		return 5
	end

	task.spawn(function()
		while alive() do
			local waitTime = 1
			if currentRole == "Alt" and TradeSettings.AutoSend then
				local ok, result = pcall(altTradeOnce)
				if ok then
					waitTime = result or 3
				else
					warn("[EggFarm] Trade error:", result)
					resetTradeInfo("Error: " .. tostring(result))
					waitTime = 5
				end
			end
			task.wait(waitTime)
		end
	end)

	---------------- menu option lists ----------------
	local function boxOptions()
		local list = {}
		if BoxData and type(BoxData.Name) == "table" then
			local tiers = {}
			for tier in pairs(BoxData.Name) do
				if tonumber(tier) then
					table.insert(tiers, tonumber(tier))
				end
			end
			table.sort(tiers)
			for _, tier in ipairs(tiers) do
				table.insert(list, ("[%d] %s Box"):format(tier, tostring(BoxData.Name[tier])))
			end
		end
		return list
	end

	local function itemOptions(cat)
		local list = {}
		local folder = ItemsFolder and ItemsFolder:FindFirstChild(cat)
		if folder then
			for _, item in ipairs(folder:GetChildren()) do
				table.insert(list, item.Name)
			end
		end
		table.sort(list)
		return list
	end

	-- Dropdown labels -> the keys filterKey() produces
	local function setFilter(cat, labels)
		local set = {}
		for _, label in ipairs(labels or {}) do
			if cat == "Boxes" or cat == "Trophies" then
				local id = idFromLabel(label)
				if id then
					set[tostring(id)] = true
				end
			else
				set[tostring(label)] = true
			end
		end
		TradeSettings.Filter[cat] = set
	end

	local function toSet(list)
		local set = {}
		for _, v in ipairs(list or {}) do
			set[v] = true
		end
		return set
	end

	local function parseNames(text)
		local set = {}
		for name in tostring(text or ""):gmatch("[^,%s]+") do
			set[string.lower(name)] = true
		end
		return set
	end

	-- True while a trade window, a trade request or one of our own trades is in progress
	local function tradeActive()
		if TradeInfo.partner ~= nil or waitingToAccept then
			return true
		end
		local trade = getTradeFrame()
		if trade and trade.Visible then
			return true
		end
		-- while it's showing, the game moves its trade prompt out of Menus.Trade into Menus
		local menus = trade and trade.Parent
		local prompt = menus and menus:FindFirstChild("Prompt")
		local title = prompt and prompt:FindFirstChild("Title")
		return prompt ~= nil and prompt.Visible and title ~= nil and tostring(title.Text):find("Trade") ~= nil
	end

	------------------------------------------------------------------
	-- Auto Sell (weapons, wings and trails; trophies and boxes are never touched)
	------------------------------------------------------------------
	local SELL_TYPES = { "Weapons", "Wings", "Trails" }

	local Sell = {
		Enabled = false,
		Types = { Weapons = true, Wings = true, Trails = true },
		KeepTiers = {}, -- [tier] = true
		Keep = { Weapons = {}, Wings = {}, Trails = {} }, -- [category][item name] = true
		Delay = 0.15,
		sold = 0,
		diamonds = 0,
		message = "-",
	}

	-- Rarity name for a tier ("Legendary"), from the game's BoxData
	local function rarityName(tier)
		return BoxData and type(BoxData.Rarity) == "table" and BoxData.Rarity[tier] or nil
	end

	-- Name and tier of an inventory entry. Weapons are keyed "Name#abilities".
	local function itemInfo(cat, key, value)
		local name = cat == "Weapons" and type(value) == "table" and tostring(value[1]) or tostring(key)
		local folder = ItemsFolder and ItemsFolder:FindFirstChild(cat)
		local item = folder and folder:FindFirstChild(name)
		local tier = item and item:FindFirstChild("Tier")
		return name, tier and tonumber(tier.Value) or nil
	end

	-- Everything that would be sold right now: { cat, key, name, tier, count }
	local function getSellList()
		local data, err = getData()
		if not data then
			return nil, err
		end
		local list = {}
		for _, cat in ipairs(SELL_TYPES) do
			local inv = data.inventory[string.lower(cat)]
			local equipped = type(data.using) == "table" and data.using[string.lower(cat)] or nil
			if Sell.Types[cat] and type(inv) == "table" then
				for key, value in pairs(inv) do
					local count
					if cat == "Weapons" then
						count = type(value) == "table" and (tonumber(value[3]) or 1) or 0
					else
						count = tonumber(value) or 0
					end
					local name, tier = itemInfo(cat, key, value)
					local keptTier = next(Sell.KeepTiers) ~= nil and (tier == nil or Sell.KeepTiers[tier])
					local isEquipped = equipped ~= nil and tostring(key) == tostring(equipped)
					if count > 0 and not isEquipped and not keptTier and not Sell.Keep[cat][name] then
						table.insert(list, { cat = cat, key = key, name = name, tier = tier, count = count })
					end
				end
			end
		end
		return list
	end

	-- Diamonds the game pays for one item (30% of its tier's box price, same as its sell menu)
	local function sellPrice(tier)
		local price = BoxData and type(BoxData.Price) == "table" and tier and tonumber(BoxData.Price[tier])
		return price and math.floor(price * 0.3) or 0
	end

	-- Sells everything on the list, one copy per call, re-reading the inventory
	-- between rounds until nothing sellable is left
	local selling = false
	local function sellAll(force)
		if selling then
			return 0
		end
		selling = true
		local total = 0
		local ok, err = pcall(function()
			local lastCount
			for _ = 1, 50 do -- safety cap on rounds
				local list, listErr = getSellList()
				if not list then
					Sell.message = listErr
					return
				end
				if #list == 0 then
					break
				end
				-- stop instead of spamming if the last round didn't remove anything
				local count = 0
				for _, entry in ipairs(list) do
					count += entry.count
				end
				if lastCount and count >= lastCount then
					Sell.message = "Your inventory didn't change after selling, so the game may be rejecting the sells"
					return
				end
				lastCount = count
				for _, entry in ipairs(list) do
					for _ = 1, entry.count do
						if tradeActive() then
							Sell.message = "Paused: a trade is active"
							return
						end
						if not (alive() and (force or Sell.Enabled)) then
							return
						end
						ItemsEvent:FireServer("Sell", entry.cat, entry.key)
						total += 1
						Sell.sold += 1
						Sell.diamonds += sellPrice(entry.tier)
						log("Sold", entry.cat, entry.key)
						task.wait(Sell.Delay)
					end
				end
				task.wait(0.5) -- let the inventory update before checking again
			end
			Sell.message = total > 0 and ("Sold %d item(s)"):format(total) or "Nothing to sell"
		end)
		if not ok then
			Sell.message = "Error: " .. tostring(err)
			warn("[EggFarm] Sell error:", err)
		end
		selling = false
		return total
	end

	task.spawn(function()
		while alive() do
			if Sell.Enabled and not tradeActive() then
				sellAll(false)
				task.wait(2)
			end
			task.wait(0.5)
		end
	end)

	------------------------------------------------------------------
	-- Auto Open Boxes
	-- Opening a box plays the game's reveal animation, which hides every other
	-- menu, including an open trade window (and hiding the trade window cancels
	-- the trade). So boxes are only opened while no trade is active or being set
	-- up, and the trading code waits for a box to finish before starting one.
	------------------------------------------------------------------
	local BoxesEvent = Events:FindFirstChild("Boxes")

	local Boxes = {
		Enabled = false,
		Only = {}, -- [tier] = true; empty = every box
		Delay = 0.5,
		opened = 0,
		message = "-",
	}

	local boxOpenedAt = 0
	if BoxesEvent then
		track(BoxesEvent.OnClientEvent:Connect(function(kind)
			if kind == "Open" then
				boxOpenedAt = os.clock()
			end
		end))
	end

	-- Inventory keys of every box we'd open, in order
	local function getBoxesToOpen()
		local data, err = getData()
		if not data then
			return nil, err
		end
		local inv = data.inventory.boxes
		local list = {}
		if type(inv) == "table" then
			for key, tier in pairs(inv) do
				if next(Boxes.Only) == nil or Boxes.Only[tonumber(tier)] then
					table.insert(list, key)
				end
			end
		end
		table.sort(list, function(a, b)
			return tostring(a) < tostring(b)
		end)
		return list
	end

	-- Opens one box and waits for the game to start its reveal. Returns false if the
	-- box wasn't opened because a trade started, nil if the game never answered.
	local function openOneBox(key)
		if tradeActive() then
			return false
		end
		-- no yield between the check above and this, so a trade can't sneak in between
		boxBusyUntil = os.clock() + 6
		local before = boxOpenedAt
		ItemsEvent:FireServer("Use", "Boxes", tostring(key))
		local start = os.clock()
		while alive() and boxOpenedAt == before and os.clock() - start < 5 do
			task.wait(0.05)
		end
		local opened = boxOpenedAt ~= before
		-- keep trades waiting until the reveal has had time to finish
		boxBusyUntil = os.clock() + Boxes.Delay + 1
		task.wait(Boxes.Delay)
		return opened or nil
	end

	local openingBoxes = false
	local function openAllBoxes(force)
		if openingBoxes then
			return 0
		end
		openingBoxes = true
		local total, misses = 0, 0
		local ok, err = pcall(function()
			while alive() and (force or Boxes.Enabled) do
				local list, listErr = getBoxesToOpen()
				if not list then
					Boxes.message = listErr
					return
				end
				if #list == 0 then
					break
				end
				local result = openOneBox(list[1]) -- keys shift after each open, so always re-read
				if result == false then
					Boxes.message = "Paused: a trade is active"
					return
				elseif result == nil then
					misses += 1
					if misses >= 3 then
						Boxes.message = "The game stopped answering box opens; trying again shortly"
						return
					end
				else
					misses = 0
					total += 1
					Boxes.opened += 1
					log("Opened box", list[1])
				end
			end
			Boxes.message = total > 0 and ("Opened %d box(es)"):format(total) or "No boxes to open"
		end)
		if not ok then
			Boxes.message = "Error: " .. tostring(err)
			warn("[EggFarm] Box error:", err)
		end
		openingBoxes = false
		return total
	end

	task.spawn(function()
		while alive() do
			if Boxes.Enabled and not tradeActive() then
				openAllBoxes(false)
				task.wait(2)
			end
			task.wait(0.5)
		end
	end)

	local function boxText()
		local lines = { bold("Auto open: ") .. (Boxes.Enabled and color("ON", GREEN) or color("OFF", GREY))
			.. (tradeActive() and "  " .. color("paused for trade", YELLOW) or "") }
		if dataJob then
			local list = getBoxesToOpen()
			if list then
				table.insert(lines, bold("Boxes to open: ") .. #list)
			end
		end
		table.insert(lines, bold("Opened: ") .. Boxes.opened)
		table.insert(lines, bold("Last: ") .. esc(Boxes.message))
		return table.concat(lines, "\n")
	end

	local function sellText()
		local lines = { bold("Auto sell: ") .. (Sell.Enabled and color("ON", GREEN) or color("OFF", GREY)) }
		if dataJob then
			local list = getSellList()
			if list then
				local items, worth = 0, 0
				for _, entry in ipairs(list) do
					items += entry.count
					worth += sellPrice(entry.tier) * entry.count
				end
				table.insert(lines, bold("Sellable now: ") .. items .. (worth > 0 and ("  (~%d 💎)"):format(worth) or ""))
			end
		else
			table.insert(lines, bold("Sellable now: ") .. color("press Sell Now or turn on Auto Sell", GREY))
		end
		table.insert(lines, bold("Sold: ") .. Sell.sold .. (Sell.diamonds > 0 and ("  (~%d 💎)"):format(Sell.diamonds) or ""))
		table.insert(lines, bold("Last: ") .. esc(Sell.message))
		return table.concat(lines, "\n")
	end

	---------------- live text ----------------
	local function tradeText()
		local lines = { bold("Role: ") .. currentRole }
		if currentRole == "Alt" then
			local master, source = getMasterName()
			if master then
				local here = findPlayer(master) and color("in server", GREEN) or color("not in server", RED)
				table.insert(lines, bold("Master: ") .. esc(master) .. " (" .. source .. ") · " .. here)
			else
				table.insert(lines, bold("Master: ") .. color("not set", RED))
			end
			table.insert(lines, bold("Auto send: ") .. (TradeSettings.AutoSend and color("ON", GREEN) or color("OFF", GREY)))
			table.insert(lines, ("Trades %d · Items sent %d · Diamonds sent %d"):format(TradeInfo.trades, TradeInfo.items, TradeInfo.diamonds))
		elseif currentRole == "Master" then
			local alts = knownAlts()
			table.insert(lines, bold("Auto accept: ") .. (TradeSettings.AutoAccept and color("ON", GREEN) or color("OFF", GREY)))
			table.insert(lines, bold("Alts on this PC: ") .. (#alts > 0 and esc(table.concat(alts, ", ")) or "none"))
			table.insert(lines, ("Trades %d · Items received %d · Diamonds received %d"):format(TradeInfo.trades, TradeInfo.items, TradeInfo.diamonds))
		else
			table.insert(lines, "Pick Alt or Master to start.")
			return table.concat(lines, "\n")
		end
		local phaseColor = TradeInfo.phase == "Idle" and GREY or YELLOW
		table.insert(lines, bold("Phase: ") .. color(TradeInfo.phase, phaseColor)
			.. (TradeInfo.partner and (" with " .. esc(TradeInfo.partner)) or ""))
		table.insert(lines, bold("Last: ") .. esc(TradeInfo.message))
		return table.concat(lines, "\n")
	end

	------------------------------------------------------------------
	-- Menu
	------------------------------------------------------------------
	---------------- Items tab ----------------
	-- "[5] Legendary" labels for every rarity the game has
	local rarityOptions = {}
	if BoxData and type(BoxData.Rarity) == "table" then
		local tiers = {}
		for tier in pairs(BoxData.Rarity) do
			if tonumber(tier) then
				table.insert(tiers, tonumber(tier))
			end
		end
		table.sort(tiers)
		for _, tier in ipairs(tiers) do
			table.insert(rarityOptions, ("[%d] %s"):format(tier, tostring(rarityName(tier))))
		end
	end

	local SellCard = itemsTab:Card({ Title = "Auto Sell", Side = "Left" })
	SellCard:Toggle({
		Name = "Auto Sell Items",
		Flag = "AutoSell",
		Keybind = true,
		Tooltip = "Keeps selling every weapon, wing and trail you get, except the ones kept on the right. "
			.. "Trophies, boxes and anything equipped are never sold. If this account is an alt sending items to "
			.. "the master, anything sold here can't be traded.",
		Callback = function(v)
			Sell.Enabled = v
		end,
	})
	SellCard:Dropdown({
		Name = "Item Types to Sell",
		Multi = true,
		Options = SELL_TYPES,
		Default = SELL_TYPES,
		Placeholder = "Nothing",
		Flag = "SellTypes",
		Callback = function(list)
			local set = {}
			for _, cat in ipairs(list or {}) do
				set[cat] = true
			end
			Sell.Types = set
		end,
	})
	SellCard:Slider({
		Name = "Delay Between Sells",
		Min = 0.05,
		Max = 1,
		Increment = 0.05,
		Default = 0.15,
		Suffix = "s",
		Flag = "SellDelay",
		Callback = function(v)
			Sell.Delay = v
		end,
	})
	SellCard:Button({
		Name = "Sell Now",
		Callback = function()
			task.spawn(function()
				notify("Sell", ("Sold %d item(s)."):format(sellAll(true)))
			end)
		end,
	})

	local BoxCard = itemsTab:Card({ Title = "Auto Open Boxes", Side = "Left" })
	BoxCard:Toggle({
		Name = "Auto Open Boxes",
		Flag = "AutoOpenBoxes",
		Keybind = true,
		Tooltip = "Opens your boxes one at a time. Pauses whenever a trade window or trade request is up, "
			.. "because the box animation would close the trade. If this account is an alt sending boxes "
			.. "to the master, opened boxes can't be traded.",
		Callback = function(v)
			Boxes.Enabled = v
		end,
	})
	BoxCard:Dropdown({
		Name = "Only Open These Boxes",
		Multi = true,
		Options = boxOptions(),
		Placeholder = "All",
		Flag = "OpenBoxTiers",
		Callback = function(labels)
			local set = {}
			for _, label in ipairs(labels or {}) do
				local tier = idFromLabel(label)
				if tier then
					set[tier] = true
				end
			end
			Boxes.Only = set
		end,
	})
	BoxCard:Slider({
		Name = "Delay Between Boxes",
		Min = 0,
		Max = 5,
		Increment = 0.25,
		Default = 0.5,
		Suffix = "s",
		Flag = "OpenBoxDelay",
		Tooltip = "Extra wait after each box so the reveal animation can finish.",
		Callback = function(v)
			Boxes.Delay = v
		end,
	})
	BoxCard:Button({
		Name = "Open All Now",
		Callback = function()
			task.spawn(function()
				if tradeActive() then
					notify("Boxes", "Finish or cancel the trade first.")
					return
				end
				notify("Boxes", ("Opened %d box(es)."):format(openAllBoxes(true)))
			end)
		end,
	})

	local KeepCard = itemsTab:Card({ Title = "Never Sell", Side = "Right" })
	KeepCard:Dropdown({
		Name = "Keep These Rarities",
		Multi = true,
		Options = rarityOptions,
		Placeholder = "None",
		Flag = "SellKeepTiers",
		Tooltip = "Items of these rarities are never sold.",
		Callback = function(labels)
			local set = {}
			for _, label in ipairs(labels or {}) do
				local tier = idFromLabel(label)
				if tier then
					set[tier] = true
				end
			end
			Sell.KeepTiers = set
		end,
	})
	for _, cat in ipairs(SELL_TYPES) do
		KeepCard:Dropdown({
			Name = "Keep These " .. cat,
			Multi = true,
			Search = true,
			Options = itemOptions(cat),
			Placeholder = "None",
			Flag = "SellKeep" .. cat,
			Callback = function(names)
				local set = {}
				for _, name in ipairs(names or {}) do
					set[name] = true
				end
				Sell.Keep[cat] = set
			end,
		})
	end

	local SellLive = itemsTab:Card({ Title = "Live", Side = "Right" })
	local sellPara = SellLive:Paragraph({ Content = "-" })
	local boxPara = SellLive:Paragraph({ Content = "-" })

	---------------- Alt / Master tab ----------------
	---------------- Alt / Master ----------------
	local AccountCard = tab:Card({ Title = "Account", Side = "Left" })
	local AltCard = tab:Card({ Title = "Send to Master", Side = "Left" })
	local MasterCard = tab:Card({ Title = "Receive From Alts", Side = "Left" })
	local TradeLive = tab:Card({ Title = "Live", Side = "Right" })
	local FilterCard = tab:Card({ Title = "What to Send", Side = "Right" })

	local function applyRoleVisibility()
		AltCard.Frame.Visible = currentRole == "Alt"
		FilterCard.Frame.Visible = currentRole == "Alt"
		MasterCard.Frame.Visible = currentRole == "Master"
	end

	AccountCard:Dropdown({
		Name = "This Account Is",
		Options = { "Off", "Alt", "Master" },
		Default = currentRole,
		Tooltip = "Saved for this account only (EggFarmSim/accounts.json), so alts and the master can run on the same PC.",
		Callback = function(role)
			if not ROLES[role] or role == currentRole then
				return
			end
			if TradeInfo.partner then
				closeTrade()
				resetTradeInfo("Role changed, trade cancelled")
			end
			currentRole = role
			applyRoleVisibility()
			if not updateMyAccount({ role = role }) then
				notify("Accounts", "Couldn't save the role — your executor has no file access.")
			end
		end,
	})
	AccountCard:Label("Account: " .. esc(player.Name))

	---- alt
	AltCard:Input({
		Name = "Master Username",
		Default = (myAccount() or {}).master or "",
		Placeholder = "Auto (Master on this PC)",
		Tooltip = "Leave empty to use whichever account is set as Master on this PC. Type a name if the master runs on another PC.",
		Callback = function(text)
			updateMyAccount({ master = (tostring(text or ""):gsub("%s", "")) })
		end,
	})
	AltCard:Toggle({
		Name = "Auto Send to Master",
		Flag = "TradeAutoSend",
		Keybind = true,
		Tooltip = "Keeps trading the items picked under What to Send to the master while it's in your server.",
		Callback = function(v)
			TradeSettings.AutoSend = v
		end,
	})
	AltCard:Toggle({
		Name = "Send Diamonds",
		Flag = "TradeSendDiamonds",
		Callback = function(v)
			TradeSettings.Diamonds = v
		end,
	})
	AltCard:Input({
		Name = "Keep Diamonds",
		Default = "0",
		Placeholder = "0",
		Numeric = true,
		Flag = "TradeKeepDiamonds",
		Tooltip = "How many diamonds stay on the alt when Send Diamonds is on.",
		Callback = function(n)
			TradeSettings.KeepDiamonds = math.max(0, math.floor(tonumber(n) or 0))
		end,
	})
	AltCard:Toggle({
		Name = "Send Whole Stacks",
		Flag = "TradeSendStacks",
		Tooltip = "Puts every copy of a weapon, wing, trail or trophy into one slot instead of one copy per slot. "
			.. "Much faster, but the game's own menu never does this — turn it off if trades fail.",
		Callback = function(v)
			TradeSettings.Stacks = v
		end,
	})

	FilterCard:Dropdown({
		Name = "Item Types",
		Multi = true,
		Options = CATEGORIES,
		Default = { "Boxes" },
		Placeholder = "Nothing",
		Flag = "TradeTypes",
		Callback = function(list)
			TradeSettings.Types = toSet(list)
		end,
	})
	FilterCard:Paragraph({ Content = "Narrow a type down below. Leave a list on <b>All</b> to send everything of that type." })
	for _, cat in ipairs(CATEGORIES) do
		local options
		if cat == "Boxes" then
			options = boxOptions()
		elseif cat == "Trophies" then
			options = heroOptions()
		else
			options = itemOptions(cat)
		end
		FilterCard:Dropdown({
			Name = "Only These " .. cat,
			Multi = true,
			Search = true,
			Options = options,
			Placeholder = "All",
			Flag = "TradeOnly" .. cat,
			Callback = function(labels)
				setFilter(cat, labels)
			end,
		})
	end

	---- master
	MasterCard:Toggle({
		Name = "Auto Accept Alt Trades",
		Flag = "TradeAutoAccept",
		Keybind = true,
		Tooltip = "Accepts and confirms trades from your alts. The master never puts anything in the trade.",
		Callback = function(v)
			TradeSettings.AutoAccept = v
		end,
	})
	MasterCard:Input({
		Name = "Other Alt Usernames",
		Placeholder = "alt1, alt2",
		Flag = "TradeExtraAlts",
		Tooltip = "Alts set up on this PC are trusted automatically. List alts that run on other PCs here.",
		Callback = function(text)
			TradeSettings.ExtraAlts = parseNames(text)
		end,
	})
	MasterCard:Toggle({
		Name = "Accept From Anyone",
		Flag = "TradeAcceptAnyone",
		Tooltip = "Accepts trade requests from any player, not just your alts. The master still never gives anything.",
		Callback = function(v)
			TradeSettings.AcceptAnyone = v
		end,
	})

	local livePara = TradeLive:Paragraph({ Content = "-" })
	applyRoleVisibility()

	------------------------------------------------------------------
	-- Auto Abilities
	-- Abilities are used with Events.Abilities:FireServer(id), the same call the
	-- game's own ability bar makes. data.cooldowns[id] is the server time each
	-- ability is ready again. Two modes, which can run together:
	--   • Groups: ordered lists of abilities. A group waits until every ability in
	--     it is ready, then uses them in order (e.g. Decoy -> Super Saiyan -> Hamburger).
	--     An ability can only be in one group.
	--   • When ready: every other ability is used the moment its cooldown ends.
	------------------------------------------------------------------
	local abilitiesTab = ctx.AbilitiesTab
	local AbilitiesEvent = Events and Events:FindFirstChild("Abilities")
	local attacking = type(ctx.attacking) == "function" and ctx.attacking or function()
		return true
	end

	local AbilitiesData = requireWithin("Settings", "AbilitiesData", 3)
	if type(AbilitiesData) ~= "table" then
		AbilitiesData = {}
	end

	local ABILITY_IDS = {}
	for id in pairs(AbilitiesData) do
		if tonumber(id) then
			table.insert(ABILITY_IDS, tostring(id))
		end
	end
	table.sort(ABILITY_IDS, function(a, b)
		return tonumber(a) < tonumber(b)
	end)

	local function abilityName(id)
		local info = AbilitiesData[tostring(id)]
		return type(info) == "table" and tostring(info.title) or ("Ability " .. tostring(id))
	end

	local function abilityLabel(id)
		return ("[%s] %s"):format(tostring(id), abilityName(id))
	end

	local GROUP_COUNT = 4
	local STEPS_PER_GROUP = 5

	local Abil = {
		Asap = false, -- use abilities the moment they're ready (anything not in an active group)
		GroupsOn = false,
		OnlyAttacking = false,
		Never = {}, -- [id] = true, skipped by "when ready"
		Gap = 0.5, -- seconds between abilities
	EarlyUse = true, -- use a group's quick abilities while it waits on a slow one
		used = 0,
		message = "-",
		pending = {}, -- [id] = os.clock() it was sent, until the server's cooldown shows up
	}

	local Groups = {}
	for g = 1, GROUP_COUNT do
		Groups[g] = { enabled = false, steps = {}, runs = 0, status = "-" }
	end

	local function serverNow()
		local ok, t = pcall(function()
			return workspace:GetServerTimeNow()
		end)
		return ok and t or os.time()
	end

	-- The game's ability bar slot for an id (its Lock shows whether you've unlocked it)
	local function getSlot(id)
		local gui = player:FindFirstChild("PlayerGui")
		local bar = gui and gui:FindFirstChild("Abilities")
		local slots = bar and bar:FindFirstChild("Slots")
		return slots and slots:FindFirstChild(tostring(id))
	end

	-- "ready", "locked", or "cooldown" plus seconds left
	local function abilityState(id, data)
		local slot = getSlot(id)
		local lock = slot and slot:FindFirstChild("Lock")
		if lock and lock.Visible then
			return "locked", 0
		end
		local cooldowns = data and type(data.cooldowns) == "table" and data.cooldowns or {}
		local readyAt = tonumber(cooldowns[id] or cooldowns[tonumber(id)])
		local left = readyAt and readyAt - serverNow() or 0
		local sent = Abil.pending[id]
		if sent then
			if left > 0 or os.clock() - sent > 15 then
				Abil.pending[id] = nil -- the server has taken it (or ignored it; try again)
			else
				return "cooldown", 1
			end
		end
		if left > 0 then
			return "cooldown", left
		end
		return "ready", 0
	end

	local function useAbility(id)
		if not AbilitiesEvent then
			error("ReplicatedStorage.Events.Abilities wasn't found", 0)
		end
		AbilitiesEvent:FireServer(tostring(id))
		Abil.pending[id] = os.clock()
		Abil.used += 1
		log("Used ability", id, abilityName(id))
	end

	-- Real cooldown of an ability: the base from AbilitiesData, cut by your equipped
	-- weapon if it boosts that ability (same maths as the game's ability bar)
	local WeaponCooldown = requireWithin("Settings", "WeaponCooldown", 3)
	local function effectiveCooldown(id, data)
		local info = AbilitiesData[id]
		local cooldown = type(info) == "table" and tonumber(info.cooldown) or nil
		if not cooldown then
			return nil
		end
		local key = type(data.using) == "table" and data.using.weapons or nil
		local weapons = type(data.inventory) == "table" and data.inventory.weapons or nil
		local weapon = key ~= nil and type(weapons) == "table" and weapons[key] or nil
		if type(weapon) == "table" and type(weapon[2]) == "table" and type(WeaponCooldown) == "table" then
			local folder = ItemsFolder and ItemsFolder:FindFirstChild("Weapons")
			local item = folder and folder:FindFirstChild(tostring(weapon[1]))
			local tier = item and item:FindFirstChild("Tier")
			local cut = tier and tonumber(WeaponCooldown[tier.Value])
			if cut then
				for _, ability in ipairs(weapon[2]) do
					if tostring(ability) == id then
						cooldown *= 1 - cut
						break
					end
				end
			end
		end
		return cooldown
	end

	-- Decoy and Hamburger change whatever ability comes next / came before, so using
	-- them early would spend them on the wrong ability. They only fire with their group.
	local NO_EARLY_USE = { ["8"] = true, ["9"] = true }
	local EARLY_USE_MARGIN = 3 -- seconds of slack so an early use is always back in time

	local function formatLeft(seconds)
		seconds = math.max(0, math.ceil(seconds))
		local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
		if h > 0 then
			return ("%dh %02dm"):format(h, m)
		end
		return ("%dm %02ds"):format(m, s)
	end

	-- Steps of a group in order, skipping empty ones
	local function groupSteps(g)
		local list = {}
		for k = 1, STEPS_PER_GROUP do
			local id = Groups[g].steps[k]
			if id then
				table.insert(list, id)
			end
		end
		return list
	end

	-- Abilities that belong to a group that's switched on (the "when ready" mode leaves these alone)
	local function groupedIds()
		local set = {}
		if Abil.GroupsOn then
			for g = 1, GROUP_COUNT do
				if Groups[g].enabled then
					for _, id in ipairs(groupSteps(g)) do
						set[id] = true
					end
				end
			end
		end
		return set
	end

	-- Why abilities can't be used right now, or nil
	local function abilityBlocker()
		if bossBusy() then
			return "boss fight"
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root.Position.Y > 5000 then
			return "can't use abilities on the moon"
		end
		if tradeActive() then
			return "trade"
		end
		if Abil.OnlyAttacking and not attacking() then
			return "waiting for Auto Attack"
		end
		return nil
	end

	task.spawn(function()
		while alive() do
			task.wait(0.5)
			if Abil.Asap or Abil.GroupsOn then
				local ok, err = pcall(function()
					local blocker = abilityBlocker()
					if blocker then
						Abil.message = "Paused: " .. blocker
						return
					end
					local data, dataErr = getData()
					if not data then
						Abil.message = dataErr
						return
					end

					-- groups first, in order
					if Abil.GroupsOn then
						for g = 1, GROUP_COUNT do
							local group = Groups[g]
							local steps = groupSteps(g)
							if group.enabled and #steps > 0 then
								local waitingOn, longest, locked = nil, 0, nil
								for _, id in ipairs(steps) do
									local state, left = abilityState(id, data)
									if state == "locked" then
										locked = id
									elseif state == "cooldown" and left > longest then
										waitingOn, longest = id, left
									end
								end
								if locked then
									group.status = "Locked: " .. abilityName(locked)
								elseif waitingOn then
									-- While waiting on the slowest ability, use any ready ability in this group
									-- whose cooldown ends before the slowest one does, so it's still ready when
									-- the whole group fires and its short cooldown isn't wasted.
									if Abil.EarlyUse then
										for _, id in ipairs(steps) do
											local cooldown = not NO_EARLY_USE[id] and effectiveCooldown(id, data)
											if cooldown and cooldown + EARLY_USE_MARGIN <= longest and abilityState(id, data) == "ready" then
												if abilityBlocker() then
													break
												end
												useAbility(id)
												group.early = (group.early or 0) + 1
												task.wait(Abil.Gap)
											end
										end
									end
									group.status = ("Waiting on %s (%s)"):format(abilityName(waitingOn), formatLeft(longest))
										.. ((group.early or 0) > 0 and (" · %d early use%s"):format(group.early, group.early == 1 and "" or "s") or "")
								else
									group.status = "Using..."
									for i, id in ipairs(steps) do
										if abilityBlocker() then
											break
										end
										if i > 1 then
											task.wait(Abil.Gap)
										end
										useAbility(id)
									end
									group.runs += 1
									group.early = 0
									group.status = ("Used (%d time%s)"):format(group.runs, group.runs == 1 and "" or "s")
									task.wait(Abil.Gap)
								end
							elseif group.enabled then
								group.status = "Empty"
							else
								group.status = "Off"
							end
						end
					end

					-- everything else, the moment it's ready
					if Abil.Asap then
						local grouped = groupedIds()
						for _, id in ipairs(ABILITY_IDS) do
							if not grouped[id] and not Abil.Never[id] and abilityState(id, data) == "ready" then
								if abilityBlocker() then
									break
								end
								useAbility(id)
								task.wait(Abil.Gap)
							end
						end
					end
					Abil.message = "Running"
				end)
				if not ok then
					Abil.message = "Error: " .. tostring(err)
					warn("[EggFarm] Ability error:", err)
				end
			else
				Abil.message = "Off"
			end
		end
	end)

	local function abilityText()
		local data = getData()
		local lines = { bold("Status: ") .. esc(Abil.message), bold("Abilities used: ") .. Abil.used }
		local grouped = groupedIds()
		for _, id in ipairs(ABILITY_IDS) do
			local state, left = abilityState(id, data)
			local text
			if state == "locked" then
				text = color("locked", GREY)
			elseif state == "cooldown" then
				text = color(formatLeft(left), YELLOW)
			else
				text = color("ready", GREEN)
			end
			local tag = grouped[id] and " (group)" or (Abil.Never[id] and " (never)" or "")
			table.insert(lines, esc(abilityName(id)) .. tag .. ": " .. text)
		end
		return table.concat(lines, "\n")
	end

	---------------- Abilities tab ----------------
	local abilityOptions = {}
	for _, id in ipairs(ABILITY_IDS) do
		table.insert(abilityOptions, abilityLabel(id))
	end

	local AbilCard = abilitiesTab:Card({ Title = "Auto Abilities", Side = "Left" })
	AbilCard:Toggle({
		Name = "Use Abilities When Ready",
		Flag = "AbilityAsap",
		Keybind = true,
		Tooltip = "Uses each unlocked ability the moment its cooldown ends. "
			.. "Abilities in a group that's switched on are left to that group.",
		Callback = function(v)
			Abil.Asap = v
		end,
	})
	AbilCard:Toggle({
		Name = "Use Ability Groups",
		Flag = "AbilityGroupsOn",
		Keybind = true,
		Tooltip = "Runs the groups below: each one waits until all of its abilities are ready, then uses them in order.",
		Callback = function(v)
			Abil.GroupsOn = v
		end,
	})
	AbilCard:Toggle({
		Name = "Reuse Quick Abilities While Waiting",
		Default = true,
		Flag = "AbilityEarlyUse",
		Tooltip = "While a group waits on its slowest ability, its faster ones are used in the meantime, "
			.. "but only when they'll be ready again before the group fires. Decoy and Hamburger are never used early.",
		Callback = function(v)
			Abil.EarlyUse = v
		end,
	})
	AbilCard:Toggle({
		Name = "Only While Auto Attack Is Attacking",
		Flag = "AbilityOnlyAttacking",
		Tooltip = "Holds abilities until Auto Attack is hitting your chicken, so boosts like Super Saiyan aren't wasted.",
		Callback = function(v)
			Abil.OnlyAttacking = v
		end,
	})
	AbilCard:Dropdown({
		Name = "Never Use When Ready",
		Multi = true,
		Options = abilityOptions,
		Placeholder = "None",
		Flag = "AbilityNever",
		Tooltip = "Skipped by Use Abilities When Ready (groups can still use them). "
			.. "Handy for Decoy and Hamburger, which work best right before / after a specific ability.",
		Callback = function(labels)
			local set = {}
			for _, label in ipairs(labels or {}) do
				local id = idFromLabel(label)
				if id then
					set[tostring(id)] = true
				end
			end
			Abil.Never = set
		end,
	})
	AbilCard:Slider({
		Name = "Delay Between Abilities",
		Min = 0.2,
		Max = 3,
		Increment = 0.1,
		Default = 0.5,
		Suffix = "s",
		Flag = "AbilityGap",
		Callback = function(v)
			Abil.Gap = v
		end,
	})

	-- Group settings live in a pop-up window (Ember's Dialog) so the tab stays tidy.
	-- An older ember.lua without Dialog gets the group cards on the tab instead.
	local window = abilitiesTab.Window
	local groupDialog
	if type(window) == "table" and type(window.Dialog) == "function" then
		groupDialog = window:Dialog({ Title = "Ability Groups", Width = 640, Height = 420 })
	end
	local groupHost = groupDialog or abilitiesTab
	local groupSummary
	if groupDialog then
		local GroupsCard = abilitiesTab:Card({ Title = "Groups", Side = "Left" })
		groupSummary = GroupsCard:Paragraph({ Content = "-" })
		GroupsCard:Button({
			Name = "Edit Groups",
			Callback = function()
				groupDialog:Open()
			end,
		})
	end

	local AbilLive = abilitiesTab:Card({ Title = "Live", Side = "Right" })
	local abilityPara = AbilLive:Paragraph({ Content = "-" })

	-- Group cards: one dropdown per step. Each ability can only be picked once across
	-- every group, so picking it anywhere removes it from all the other lists.
	local stepDropdowns = {} -- [g][k] = dropdown
	local groupParas = {}
	local refreshing = false

	local function refreshStepOptions()
		if refreshing then
			return
		end
		refreshing = true
		local used = {}
		for g = 1, GROUP_COUNT do
			for k = 1, STEPS_PER_GROUP do
				local id = Groups[g].steps[k]
				if id then
					used[id] = true
				end
			end
		end
		for g = 1, GROUP_COUNT do
			for k = 1, STEPS_PER_GROUP do
				local own = Groups[g].steps[k]
				local options = { "None" }
				for _, id in ipairs(ABILITY_IDS) do
					if not used[id] or id == own then
						table.insert(options, abilityLabel(id))
					end
				end
				local dropdown = stepDropdowns[g] and stepDropdowns[g][k]
				if dropdown then
					pcall(dropdown.Refresh, dropdown, options, true)
				end
			end
		end
		refreshing = false
	end

	local ORDINALS = { "1st", "2nd", "3rd", "4th", "5th" }
	for g = 1, GROUP_COUNT do
		local card = groupHost:Card({ Title = "Group " .. g, Side = g % 2 == 1 and "Left" or "Right" })
		card:Toggle({
			Name = "Use Group " .. g,
			Flag = "AbilityGroup" .. g,
			Callback = function(v)
				Groups[g].enabled = v
			end,
		})
		stepDropdowns[g] = {}
		for k = 1, STEPS_PER_GROUP do
			stepDropdowns[g][k] = card:Dropdown({
				Name = ORDINALS[k],
				Options = { "None", table.unpack(abilityOptions) },
				Default = "None",
				Flag = ("AbilityGroup%d_%d"):format(g, k),
				Callback = function(label)
					local id = idFromLabel(label)
					id = id and tostring(id) or nil
					-- an ability already used in another step can't be picked twice
					if id then
						for g2 = 1, GROUP_COUNT do
							for k2 = 1, STEPS_PER_GROUP do
								if (g2 ~= g or k2 ~= k) and Groups[g2].steps[k2] == id then
									id = nil
								end
							end
						end
					end
					Groups[g].steps[k] = id
					if not id and label ~= "None" and stepDropdowns[g] and stepDropdowns[g][k] then
						pcall(stepDropdowns[g][k].Set, stepDropdowns[g][k], "None", true)
					end
					refreshStepOptions()
				end,
			})
		end
		groupParas[g] = card:Paragraph({ Content = "-" })
	end
	refreshStepOptions()

	task.spawn(function()
		while alive() do
			pcall(function()
				abilityPara:Set(abilityText())
				local summary = {}
				for g = 1, GROUP_COUNT do
					local names = {}
					for _, id in ipairs(groupSteps(g)) do
						table.insert(names, esc(abilityName(id)))
					end
					local order = #names > 0 and table.concat(names, " → ") or "empty"
					groupParas[g]:Set(bold("Order: ") .. order .. "\n" .. bold("Status: ") .. esc(Groups[g].status))
					if #names > 0 then
						local on = Abil.GroupsOn and Groups[g].enabled
						table.insert(summary, bold("Group " .. g .. ": ") .. order .. "\n"
							.. (on and esc(Groups[g].status) or color("off", GREY)))
					end
				end
				if groupSummary then
					groupSummary:Set(#summary > 0 and table.concat(summary, "\n\n")
						or color("No groups set up yet.", GREY))
				end
			end)
			task.wait(1)
		end
	end)

	------------------------------------------------------------------
	-- Live card
	------------------------------------------------------------------
	task.spawn(function()
		while alive() do
			pcall(function()
				livePara:Set(tradeText())
			end)
			pcall(function()
				sellPara:Set(sellText())
				boxPara:Set(boxText())
			end)
			task.wait(1)
		end
	end)

	-- Lets the main script pause farming while a trade is going on
	return {
		busy = function()
			if waitingToAccept then
				return true, "master waiting to accept"
			end
			if TradeInfo.partner ~= nil then
				return true, ("%s with %s"):format(string.lower(TradeInfo.phase), tostring(TradeInfo.partner))
			end
			return false
		end,
	}
end
