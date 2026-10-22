--[[
	Egg Farm Simulator · Alt / Master trading
	Loaded by the main autofarm script from GitHub (kept separate so the main
	script stays small enough to paste into an executor). Not meant to be run on its own.

	Alts trade their items to the master account. Each account's role is saved per
	UserId in workspace/EggFarmSim/accounts.json, so several accounts on one PC each
	keep their own role, and an alt finds the master automatically once the master
	has picked its role on the same PC.
]]

return function(ctx)
	local tab = ctx.Tab
	local alive, track, log, notify = ctx.alive, ctx.track, ctx.log, ctx.notify
	local idFromLabel, heroOptions = ctx.idFromLabel, ctx.heroOptions

	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local HttpService = game:GetService("HttpService")
	local player = Players.LocalPlayer

	local Events = ReplicatedStorage:FindFirstChild("Events")
	local TradeEvent = Events and Events:WaitForChild("Trade", 5)
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

	-- Your live player data (same source the game's inventory and trade menus use).
	-- Only loaded the first time an alt builds a trade, so Off / Master never touch it.
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
		end
		if not dataJob.value then
			return nil, dataJob.done and ("Couldn't read your inventory: " .. tostring(dataJob.err)) or "Loading your inventory data..."
		end
		local ok, data = pcall(dataJob.value.Get, "data")
		if not ok or type(data) ~= "table" then
			return nil, "Couldn't read your inventory (DataHandler returned nothing)"
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
		task.wait(0.3) -- let the game finish showing its "Trade Requested" prompt
		if not alive() or isTradeOpen() then
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

		-- 1. request
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
			end
			return 5
		end

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
	-- Live card
	------------------------------------------------------------------
	task.spawn(function()
		while alive() do
			pcall(function()
				livePara:Set(tradeText())
			end)
			task.wait(1)
		end
	end)
end
