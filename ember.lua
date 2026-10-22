--[[
	Ember UI  ·  v1.0.0
	A dark, card-based Roblox GUI library.

	Loading
		Executor : local Ember = loadstring(game:HttpGet("<raw url to ember.lua>"))()
		Studio   : put this file in a ModuleScript, then  local Ember = require(path.to.Ember)
		           (client-side only — it needs Players.LocalPlayer)

	Quick start
		local Window = Ember:CreateWindow({ Title = "Ember", Subtitle = "Demo" })
		Window:Section("Main")
		local Tab  = Window:Tab({ Name = "Farming" })
		local Card = Tab:Card({ Title = "Auto Farm", Side = "Left" })
		Card:Toggle({ Name = "Enabled", Flag = "AutoFarm", Callback = function(on) print(on) end })

	Full API reference is at the bottom of this file.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- State & theme
--------------------------------------------------------------------------------

local Library = {
	Version = "1.0.0",
	Flags = {},       -- Flag -> current value
	Options = {},     -- Flag -> element object (has :Set)
	Windows = {},
	ConfigFolder = "EmberUI",
	_painted = {},    -- accent-coloured instances, recoloured by SetAccent
	_repaint = {},    -- stateful elements that redraw on accent change
	_capturing = false,
}

local Theme = {
	Accent     = Color3.fromRGB(220, 60, 60),
	Background = Color3.fromRGB(22, 24, 29),
	Panel      = Color3.fromRGB(30, 31, 36),
	Field      = Color3.fromRGB(33, 35, 39),
	Stroke     = Color3.fromRGB(55, 56, 63),
	Divider    = Color3.fromRGB(65, 65, 65),
	Text       = Color3.fromRGB(255, 255, 255),
	SubText    = Color3.fromRGB(160, 162, 170),
	Font       = Enum.Font.Gotham,
	FontMedium = Enum.Font.GothamMedium,
	FontBold   = Enum.Font.GothamBold,
}
Library.Theme = Theme

Library.AccentPresets = {
	Crimson = Color3.fromRGB(220, 60, 60),
	Ocean   = Color3.fromRGB(60, 130, 230),
	Violet  = Color3.fromRGB(150, 90, 230),
	Emerald = Color3.fromRGB(50, 190, 120),
	Amber   = Color3.fromRGB(235, 160, 40),
	Rose    = Color3.fromRGB(230, 80, 150),
}
Library.AccentOrder = { "Crimson", "Ocean", "Violet", "Emerald", "Amber", "Rose" }

local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)

local function deriveAccent()
	local a = Theme.Accent
	Theme.AccentLight = a:Lerp(WHITE, 0.2)
	Theme.AccentMid = a:Lerp(BLACK, 0.25)
	Theme.AccentDark = a:Lerp(BLACK, 0.5)
	Theme.AccentDeep = a:Lerp(BLACK, 0.65)
end
deriveAccent()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function create(className, props)
	local obj = Instance.new(className)
	if obj:IsA("GuiObject") then
		obj.BorderSizePixel = 0
	end
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			obj[k] = v
		end
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end

-- t == nil/0 applies instantly
local function tween(obj, props, t, style, dir)
	if not t or t <= 0 then
		for k, v in pairs(props) do
			obj[k] = v
		end
		return nil
	end
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function round(parent, px)
	return create("UICorner", { CornerRadius = px and UDim.new(0, px) or UDim.new(1, 0), Parent = parent })
end

local function outline(parent, color, thickness, transparency)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function seq(points)
	local kp = {}
	for _, p in ipairs(points) do
		table.insert(kp, NumberSequenceKeypoint.new(p[1], p[2]))
	end
	return NumberSequence.new(kp)
end

local function fade(parent, points, rotation)
	return create("UIGradient", { Transparency = seq(points), Rotation = rotation or 90, Parent = parent })
end

local function pad(parent, l, r, t, b)
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0),
		PaddingRight = UDim.new(0, r or 0),
		PaddingTop = UDim.new(0, t or 0),
		PaddingBottom = UDim.new(0, b or 0),
		Parent = parent,
	})
end

local function list(parent, padding, horizontal, hAlign, vAlign)
	return create("UIListLayout", {
		Padding = UDim.new(0, padding or 0),
		FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
end

local function text(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Theme.Font
	props.TextColor3 = props.TextColor3 or Theme.Text
	props.TextSize = props.TextSize or 13
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props)
end

local function hitbox(parent, z)
	return create("TextButton", {
		Name = "Hitbox",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = z or 2,
		Parent = parent,
	})
end

-- Colour an instance from the theme and remember it for live accent changes.
local function paint(obj, prop, key)
	obj[prop] = Theme[key]
	table.insert(Library._painted, { obj, prop, key })
	return obj
end

local function asset(id)
	if id == nil then
		return nil
	end
	if type(id) == "number" or tonumber(id) then
		return "rbxassetid://" .. tostring(id)
	end
	return id
end

local function isClick(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function keyName(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode ~= Enum.KeyCode.Unknown then
			return input.KeyCode.Name
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		return "MouseRight"
	elseif input.UserInputType == Enum.UserInputType.MouseButton3 then
		return "MouseMiddle"
	end
	return nil
end

local function normalizeKey(k)
	if typeof(k) == "EnumItem" then
		return k.Name
	end
	if type(k) == "string" and k ~= "" then
		return k
	end
	return "None"
end

local function fire(callback, ...)
	if callback then
		task.spawn(callback, ...)
	end
end

local function register(el, flag)
	if flag then
		el.Flag = flag
		Library.Options[flag] = el
		Library.Flags[flag] = el.Value
	end
end

local function setFlag(el)
	if el.Flag then
		Library.Flags[el.Flag] = el.Value
	end
end

local function guiParent()
	local ok, hui = pcall(function()
		return gethui()
	end)
	if ok and typeof(hui) == "Instance" then
		return hui
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

-- Two rounded panels (sidebar + content) share this look.
local function panel(parent, name, size, position)
	local p = create("Frame", {
		Name = name,
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = 0.06,
		Size = size,
		Position = position or UDim2.new(),
		Parent = parent,
	})
	round(p, 8)
	paint(outline(p, Theme.AccentDeep, 1, 0.35), "Color", "AccentDeep")

	local tint = create("Frame", { Name = "Tint", BackgroundTransparency = 0.89, Size = UDim2.fromScale(1, 1), Parent = p })
	paint(tint, "BackgroundColor3", "Accent")
	round(tint, 8)
	fade(tint, { { 0, 0.06 }, { 0.32, 0.2 }, { 0.68, 0.51 }, { 1, 0.77 } })

	local inner = create("Frame", {
		Name = "InnerBorder",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		Parent = p,
	})
	round(inner, 6)
	paint(outline(inner, Theme.AccentDark, 1.5, 0.72), "Color", "AccentDark")
	return p
end

-- Small "i" button that shows a tooltip on hover (or tap on mobile).
local function infoIcon(window, parent, tip)
	local b = create("TextButton", {
		Name = "Info",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(15, 15),
		Font = Theme.FontBold,
		TextSize = 10,
		TextColor3 = Theme.Text,
		TextTransparency = 0.35,
		Text = "i",
		LayoutOrder = -10,
		ZIndex = 4,
		Parent = parent,
	})
	round(b)
	outline(b, Theme.Stroke, 1, 0.2)

	local frame
	local function hide()
		if frame then
			frame:Destroy()
			frame = nil
		end
	end
	local function show()
		hide()
		local overlay = window._overlay
		frame = create("Frame", {
			Name = "Tooltip",
			BackgroundColor3 = Theme.Background,
			Size = UDim2.fromOffset(210, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			ZIndex = 5,
			Parent = overlay,
		})
		round(frame, 5)
		outline(frame, Theme.AccentDark, 1.2, 0.35)
		pad(frame, 8, 8, 6, 6)
		text({
			Text = tip,
			TextSize = 12,
			TextTransparency = 0.15,
			TextWrapped = true,
			RichText = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = frame,
		})
		local rel = b.AbsolutePosition - overlay.AbsolutePosition
		local x = rel.X + b.AbsoluteSize.X + 8
		if x + 214 > overlay.AbsoluteSize.X then
			x = rel.X - 218
		end
		frame.Position = UDim2.fromOffset(x, rel.Y - 4)
	end
	b.MouseEnter:Connect(show)
	b.MouseLeave:Connect(hide)
	b.MouseButton1Click:Connect(function()
		if frame then
			hide()
		else
			show()
		end
	end)
	b.AncestryChanged:Connect(function()
		if not b.Parent then
			hide()
		end
	end)
	return b
end

-- Small key box: click it, press a key (Esc/Backspace = None, click = cancel).
local function keybox(parent, default, order)
	local kb = { Key = normalizeKey(default) }
	local box = create("TextButton", {
		Name = "Keybind",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.FontMedium,
		TextSize = 11,
		TextColor3 = Theme.Text,
		TextTransparency = 0.25,
		Text = kb.Key,
		LayoutOrder = order or 5,
		ZIndex = 4,
		Parent = parent,
	})
	round(box, 4)
	local st = outline(box, Theme.Stroke, 1, 0.1)
	pad(box, 7, 7, 0, 0)

	function kb:Set(k)
		kb.Key = normalizeKey(k)
		box.Text = kb.Key
		if kb.OnChanged then
			kb.OnChanged(kb.Key)
		end
	end

	box.MouseButton1Click:Connect(function()
		if Library._capturing then
			return
		end
		Library._capturing = true
		box.Text = "..."
		tween(st, { Color = Theme.Accent }, 0.15)
		local conn
		conn = UserInputService.InputBegan:Connect(function(input)
			local result
			if isClick(input) then
				result = kb.Key -- cancel, keep old key
			elseif input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Backspace then
				result = "None"
			else
				result = keyName(input)
			end
			if not result then
				return
			end
			conn:Disconnect()
			kb:Set(result)
			tween(st, { Color = Theme.Stroke }, 0.15)
			task.defer(function()
				Library._capturing = false
			end)
		end)
	end)
	return kb
end

local TabMeta = {}
TabMeta.__index = TabMeta
local CardMeta = {}
CardMeta.__index = CardMeta

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

function Library:CreateWindow(opts)
	opts = opts or {}
	if opts.Accent then
		Theme.Accent = opts.Accent
		deriveAccent()
	end

	local title = opts.Title or "Ember"
	local subtitle = opts.Subtitle or ""
	local sidebarW = opts.SidebarWidth or 170
	local contentW = opts.Width or 520
	local height = opts.Height or 460
	local gap = 6

	local folder = opts.ConfigFolder or (title:gsub("[^%w%-_ ]", ""))
	Library.ConfigFolder = folder ~= "" and folder or "EmberUI"

	local Window = {
		Tabs = {},
		Visible = false,
		ToggleKey = opts.ToggleKey or Enum.KeyCode.RightShift,
		Flags = Library.Flags,
		_keyHandlers = {},
		_conns = {},
	}
	local function bind(signal, fn)
		local c = signal:Connect(fn)
		table.insert(Window._conns, c)
		return c
	end
	Window._bind = bind

	local gui = create("ScreenGui", {
		Name = "Ember_" .. HttpService:GenerateGUID(false):sub(1, 8),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = opts.DisplayOrder or 100,
	})
	Window.Gui = gui

	local root = create("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(sidebarW + gap + contentW, height),
		Visible = false,
		Parent = gui,
	})
	local scale = create("UIScale", { Parent = root })
	Window.Root = root
	Window._scale = scale

	create("ImageLabel", {
		Name = "Shadow",
		BackgroundTransparency = 1,
		Image = "rbxassetid://6014261993",
		ImageColor3 = BLACK,
		ImageTransparency = 0.45,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(49, 49, 450, 450),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 50, 1, 50),
		ZIndex = 0,
		Parent = root,
	})

	---------------------------------------------------------------- sidebar
	local sidebar = panel(root, "Sidebar", UDim2.fromOffset(sidebarW, height))

	local header = create("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), Parent = sidebar })
	if opts.Logo then
		local img = create("ImageLabel", {
			Name = "Logo",
			BackgroundTransparency = 1,
			Image = asset(opts.Logo),
			Position = UDim2.fromOffset(12, 12),
			Size = UDim2.fromOffset(36, 36),
			Parent = header,
		})
		round(img, 8)
	else
		local badge = create("Frame", { Name = "Logo", Position = UDim2.fromOffset(12, 12), Size = UDim2.fromOffset(36, 36), Parent = header })
		paint(badge, "BackgroundColor3", "Accent")
		round(badge, 8)
		paint(outline(badge, Theme.AccentDark, 1.5, 0.2), "Color", "AccentDark")
		local sheen = create("Frame", { BackgroundColor3 = WHITE, Size = UDim2.fromScale(1, 1), Parent = badge })
		round(sheen, 8)
		fade(sheen, { { 0, 0.72 }, { 0.45, 0.98 }, { 1, 1 } })
		local initial = text({
			Text = string.upper(title:sub(1, 1)),
			Font = Theme.FontBold,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = badge,
		})
		paint(create("UIStroke", { Thickness = 1.5, Transparency = 0.3, Parent = initial }), "Color", "AccentDeep")
	end
	text({
		Name = "Title",
		Text = title,
		Font = Theme.FontBold,
		TextSize = 15,
		Position = UDim2.fromOffset(56, 13),
		Size = UDim2.new(1, -64, 0, 17),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})
	text({
		Name = "Subtitle",
		Text = subtitle,
		TextSize = 12,
		TextTransparency = 0.5,
		Position = UDim2.fromOffset(56, 31),
		Size = UDim2.new(1, -64, 0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})

	local tabList = create("ScrollingFrame", {
		Name = "TabList",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -124),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 2,
		ScrollBarImageTransparency = 0.7,
		Parent = sidebar,
	})
	paint(tabList, "ScrollBarImageColor3", "Accent")
	list(tabList, 3)
	pad(tabList, 8, 8, 0, 8)

	local profile = create("Frame", {
		Name = "Profile",
		BackgroundColor3 = Theme.Field,
		BackgroundTransparency = 0.55,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -16, 0, 48),
		Parent = sidebar,
	})
	round(profile, 6)
	outline(profile, Theme.Stroke, 1.2, 0.7)
	local avatar = create("ImageLabel", {
		Name = "Avatar",
		BackgroundColor3 = Theme.Panel,
		Position = UDim2.fromOffset(7, 7),
		Size = UDim2.fromOffset(34, 34),
		Parent = profile,
	})
	round(avatar, 6)
	task.spawn(function()
		local ok, img = pcall(function()
			return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		if ok and img then
			avatar.Image = img
		end
	end)
	text({
		Name = "DisplayName",
		Text = LocalPlayer.DisplayName,
		Font = Theme.FontBold,
		TextSize = 13,
		Position = UDim2.fromOffset(49, 9),
		Size = UDim2.new(1, -55, 0, 15),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = profile,
	})
	local rank = text({
		Name = "Rank",
		Text = opts.ProfileText or ("@" .. LocalPlayer.Name),
		TextSize = 11,
		TextTransparency = 0.45,
		RichText = true,
		Position = UDim2.fromOffset(49, 25),
		Size = UDim2.new(1, -55, 0, 14),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = profile,
	})
	if opts.ProfileColor then
		rank.Font = Theme.FontBold
		rank.TextColor3 = opts.ProfileColor
		rank.TextTransparency = 0
	end

	---------------------------------------------------------------- content
	local content = panel(root, "Content", UDim2.fromOffset(contentW, height), UDim2.fromOffset(sidebarW + gap, 0))

	local topbar = create("Frame", { Name = "Topbar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 42), Parent = content })
	local pageTitle = text({
		Name = "PageTitle",
		Text = "",
		Font = Theme.FontBold,
		TextSize = 15,
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -100, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = topbar,
	})
	local controls = create("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = topbar,
	})
	list(controls, 6, true, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)

	local function controlButton(glyph, order, danger, parent)
		local b = create("TextButton", {
			AutoButtonColor = false,
			BackgroundColor3 = Theme.Panel,
			BackgroundTransparency = 0.15,
			Size = UDim2.fromOffset(22, 22),
			Font = Theme.FontBold,
			TextSize = 15,
			TextColor3 = Theme.Text,
			TextTransparency = 0.4,
			Text = glyph,
			LayoutOrder = order,
			Parent = parent or controls,
		})
		round(b, 5)
		local st = outline(b, Theme.Stroke, 1.25, 0.5)
		b.MouseEnter:Connect(function()
			tween(b, { TextTransparency = 0, BackgroundColor3 = danger and Theme.Accent or Theme.Field }, 0.15)
			tween(st, { Color = danger and Theme.AccentDark or Theme.Stroke, Transparency = 0.2 }, 0.15)
		end)
		b.MouseLeave:Connect(function()
			tween(b, { TextTransparency = 0.4, BackgroundColor3 = Theme.Panel }, 0.15)
			tween(st, { Color = Theme.Stroke, Transparency = 0.5 }, 0.15)
		end)
		return b
	end
	local minimizeBtn = controlButton("–", 1)
	local closeBtn = controlButton("×", 2, true)

	local topLine = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 42),
		Size = UDim2.new(1, -24, 0, 1),
		BackgroundColor3 = Theme.Divider,
		BackgroundTransparency = 0.4,
		Parent = content,
	})
	fade(topLine, { { 0, 1 }, { 0.1, 0.3 }, { 0.5, 0 }, { 0.9, 0.3 }, { 1, 1 } }, 0)

	local pages = create("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 43),
		Size = UDim2.new(1, 0, 1, -46),
		ClipsDescendants = true,
		Parent = content,
	})

	---------------------------------------------------------------- overlay layers
	local overlay = create("Frame", { Name = "Overlay", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = gui })
	Window._overlay = overlay

	local notifs = create("Frame", {
		Name = "Notifications",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.new(0, 290, 1, -32),
		ZIndex = 60,
		Parent = gui,
	})
	list(notifs, 8, false, nil, Enum.VerticalAlignment.Bottom)
	Library._notifHolder = notifs

	local openBtn = create("TextButton", {
		Name = "OpenButton",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.FontBold,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = "Open " .. title,
		Visible = false,
		ZIndex = 40,
		Parent = gui,
	})
	paint(openBtn, "BackgroundColor3", "Accent")
	round(openBtn)
	pad(openBtn, 16, 16, 0, 0)
	paint(outline(openBtn, Theme.AccentDark, 1.5, 0.2), "Color", "AccentDark")

	---------------------------------------------------------------- popups (dropdown lists)
	local popup
	function Window:_closePopup()
		if not popup then
			return
		end
		local p = popup
		popup = nil
		p.backdrop:Destroy()
		p.frame:Destroy()
		if p.onClose then
			p.onClose()
		end
	end
	function Window:_openPopup(frame, onClose)
		self:_closePopup()
		local backdrop = create("TextButton", {
			Name = "Backdrop",
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = overlay,
		})
		frame.ZIndex = 2
		frame.Parent = overlay
		popup = { frame = frame, backdrop = backdrop, onClose = onClose }
		backdrop.InputBegan:Connect(function(input)
			if isClick(input) or input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:_closePopup()
			end
		end)
	end

	---------------------------------------------------------------- dragging
	local dragging, dragStart, startPos = false, nil, nil
	local function beginDrag(input)
		if not isClick(input) then
			return
		end
		dragging = true
		dragStart = input.Position
		startPos = root.Position
		Window:_closePopup()
		local c
		c = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				c:Disconnect()
			end
		end)
	end
	header.InputBegan:Connect(beginDrag)
	topbar.InputBegan:Connect(beginDrag)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)

	---------------------------------------------------------------- scaling & visibility
	local baseScale = 1
	local function fit()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		baseScale = math.clamp(math.min((vp.X - 24) / root.Size.X.Offset, (vp.Y - 24) / root.Size.Y.Offset), 0.4, 1)
		if Window.Visible then
			scale.Scale = baseScale
		end
	end
	fit()
	if workspace.CurrentCamera then
		bind(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), fit)
	end

	function Window:SetVisible(v)
		self.Visible = v
		self:_closePopup()
		if v then
			root.Visible = true
			openBtn.Visible = false
			scale.Scale = baseScale * 0.94
			tween(scale, { Scale = baseScale }, 0.25, Enum.EasingStyle.Back)
		else
			local tw = tween(scale, { Scale = baseScale * 0.94 }, 0.12, Enum.EasingStyle.Quad)
			tw.Completed:Connect(function()
				if not self.Visible then
					root.Visible = false
				end
			end)
			if opts.ShowOpenButton ~= nil then
				openBtn.Visible = opts.ShowOpenButton
			else
				openBtn.Visible = UserInputService.TouchEnabled
			end
		end
	end

	function Window:Toggle()
		self:SetVisible(not self.Visible)
	end

	local hinted = false
	minimizeBtn.MouseButton1Click:Connect(function()
		Window:SetVisible(false)
		if not hinted and not UserInputService.TouchEnabled then
			hinted = true
			Library:Notify({ Title = title, Content = "Hidden. Press " .. normalizeKey(Window.ToggleKey) .. " to reopen.", Duration = 4 })
		end
	end)
	closeBtn.MouseButton1Click:Connect(function()
		Window:Destroy()
	end)
	openBtn.MouseButton1Click:Connect(function()
		Window:SetVisible(true)
	end)

	bind(UserInputService.InputBegan, function(input)
		if Library._capturing or UserInputService:GetFocusedTextBox() then
			return
		end
		local name = keyName(input)
		if not name then
			return
		end
		if name == normalizeKey(Window.ToggleKey) then
			Window:Toggle()
			return
		end
		for _, h in ipairs(Window._keyHandlers) do
			if h.key() == name then
				task.spawn(h.fn)
			end
		end
	end)

	function Window:Destroy()
		if self.Destroyed then
			return
		end
		self.Destroyed = true
		self:_closePopup()
		for _, c in ipairs(self._conns) do
			c:Disconnect()
		end
		gui:Destroy()
		if Library._notifHolder == notifs then
			Library._notifHolder = nil
		end
		local idx = table.find(Library.Windows, self)
		if idx then
			table.remove(Library.Windows, idx)
		end
		fire(opts.OnClose)
	end

	---------------------------------------------------------------- sections & tabs
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	function Window:Section(name)
		local s = create("Frame", {
			Name = "Section",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 26),
			LayoutOrder = nextOrder(),
			Parent = tabList,
		})
		text({
			Text = string.upper(name or ""),
			Font = Theme.FontBold,
			TextSize = 11,
			TextTransparency = 0.5,
			Position = UDim2.fromOffset(6, 8),
			Size = UDim2.new(1, -12, 0, 12),
			Parent = s,
		})
		local line = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -1),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundTransparency = 0.55,
			Parent = s,
		})
		paint(line, "BackgroundColor3", "Accent")
		fade(line, { { 0, 1 }, { 0.05, 0.21 }, { 0.5, 0 }, { 0.96, 0.17 }, { 1, 1 } }, 0)
		return s
	end

	function Window:Tab(topts)
		if type(topts) == "string" then
			topts = { Name = topts }
		end
		topts = topts or {}
		local Tab = setmetatable({ Window = Window, Name = topts.Name or "Tab", _sides = { Left = 0, Right = 0 } }, TabMeta)

		local btn = create("Frame", {
			Name = Tab.Name,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 32),
			LayoutOrder = nextOrder(),
			Parent = tabList,
		})
		local hl = create("Frame", { Name = "Highlight", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = btn })
		paint(hl, "BackgroundColor3", "Accent")
		round(hl, 5)
		local bar = create("Frame", {
			Name = "Bar",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(3, 0),
			Parent = btn,
		})
		paint(bar, "BackgroundColor3", "Accent")
		round(bar)

		local icon
		if topts.Icon then
			icon = create("ImageLabel", {
				Name = "Icon",
				BackgroundTransparency = 1,
				Image = asset(topts.Icon),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, 20, 0.5, 0),
				Size = UDim2.fromOffset(16, 16),
				ImageTransparency = 0.5,
				Parent = btn,
			})
			paint(icon, "ImageColor3", "Accent")
		else
			icon = create("Frame", {
				Name = "Icon",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, 20, 0.5, 0),
				Size = UDim2.fromOffset(6, 6),
				BackgroundTransparency = 0.5,
				Parent = btn,
			})
			paint(icon, "BackgroundColor3", "Accent")
			round(icon)
		end
		local lbl = text({
			Name = "Label",
			Text = Tab.Name,
			Font = Theme.FontMedium,
			TextSize = 13,
			TextTransparency = 0.5,
			Position = UDim2.fromOffset(36, 0),
			Size = UDim2.new(1, -40, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = btn,
		})
		local hit = hitbox(btn, 3)

		local page = create("ScrollingFrame", {
			Name = Tab.Name,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 2,
			ScrollBarImageTransparency = 0.7,
			Visible = false,
			Parent = pages,
		})
		paint(page, "ScrollBarImageColor3", "Accent")
		pad(page, 10, 10, 10, 10)
		local holder = create("Frame", {
			Name = "Columns",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = page,
		})
		list(holder, 8, true)

		local single = topts.Columns == 1
		local function column(name, ord)
			local c = create("Frame", {
				Name = name,
				BackgroundTransparency = 1,
				Size = single and UDim2.new(1, 0, 0, 0) or UDim2.new(0.5, -4, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = ord,
				Parent = holder,
			})
			list(c, 8)
			return c
		end
		Tab.Left = column("Left", 1)
		Tab.Right = single and Tab.Left or column("Right", 2)
		Tab._page = page
		Tab._holder = holder
		bind(page:GetPropertyChangedSignal("CanvasPosition"), function()
			Window:_closePopup()
		end)

		local active = false
		function Tab:_setActive(on)
			active = on
			page.Visible = on
			local t = 0.2
			tween(hl, { BackgroundTransparency = on and 0.82 or 1 }, t)
			tween(bar, { Size = UDim2.fromOffset(3, on and 16 or 0) }, t)
			tween(lbl, { TextTransparency = on and 0 or 0.5 }, t)
			if icon:IsA("ImageLabel") then
				tween(icon, { ImageTransparency = on and 0 or 0.5 }, t)
			else
				tween(icon, { BackgroundTransparency = on and 0 or 0.5 }, t)
			end
		end
		hit.MouseEnter:Connect(function()
			if not active then
				tween(hl, { BackgroundTransparency = 0.93 }, 0.15)
				tween(lbl, { TextTransparency = 0.25 }, 0.15)
			end
		end)
		hit.MouseLeave:Connect(function()
			if not active then
				tween(hl, { BackgroundTransparency = 1 }, 0.15)
				tween(lbl, { TextTransparency = 0.5 }, 0.15)
			end
		end)
		hit.MouseButton1Click:Connect(function()
			Window:SelectTab(Tab)
		end)

		table.insert(Window.Tabs, Tab)
		if not Window.ActiveTab then
			Window:SelectTab(Tab)
		end
		return Tab
	end

	function Window:SelectTab(tab)
		if type(tab) == "string" then
			for _, t in ipairs(self.Tabs) do
				if t.Name == tab then
					tab = t
					break
				end
			end
		end
		if type(tab) ~= "table" or self.ActiveTab == tab then
			return
		end
		self:_closePopup()
		self.ActiveTab = tab
		for _, t in ipairs(self.Tabs) do
			t:_setActive(t == tab)
		end
		pageTitle.Text = tab.Name
		tab._holder.Position = UDim2.fromOffset(0, 10)
		tween(tab._holder, { Position = UDim2.new() }, 0.25)
	end

	---------------------------------------------------------------- dialogs
	-- A pop-up window over the menu with its own title bar and close button.
	-- It works like a tab: dialog:Card({...}) takes the same cards and elements.
	function Window:Dialog(dopts)
		if type(dopts) == "string" then
			dopts = { Title = dopts }
		end
		dopts = dopts or {}
		local Dialog = setmetatable({
			Window = Window,
			Name = dopts.Title or "Dialog",
			Visible = false,
			_sides = { Left = 0, Right = 0 },
		}, TabMeta)

		local layer = create("Frame", {
			Name = "Dialog",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 20,
			Visible = false,
			Parent = root,
		})
		local shade = create("TextButton", {
			Name = "Shade",
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = BLACK,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = layer,
		})
		round(shade, 8)

		local w = math.min(dopts.Width or contentW, root.Size.X.Offset - 32)
		local h = math.min(dopts.Height or (height - 60), height - 32)
		local box = panel(layer, "Window", UDim2.fromOffset(w, h))
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.ZIndex = 2
		create("ImageLabel", {
			Name = "Shadow",
			BackgroundTransparency = 1,
			Image = "rbxassetid://6014261993",
			ImageColor3 = BLACK,
			ImageTransparency = 0.4,
			ScaleType = Enum.ScaleType.Slice,
			SliceCenter = Rect.new(49, 49, 450, 450),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 46, 1, 46),
			ZIndex = 0,
			Parent = box,
		})

		local bar = create("Frame", { Name = "Topbar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 42), Parent = box })
		local titleLbl = text({
			Name = "Title",
			Text = Dialog.Name,
			Font = Theme.FontBold,
			TextSize = 15,
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -60, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = bar,
		})
		local barControls = create("Frame", {
			Name = "Controls",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			Parent = bar,
		})
		list(barControls, 6, true, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
		local closeDialog = controlButton("×", 1, true, barControls)
		local line = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 42),
			Size = UDim2.new(1, -24, 0, 1),
			BackgroundColor3 = Theme.Divider,
			BackgroundTransparency = 0.4,
			Parent = box,
		})
		fade(line, { { 0, 1 }, { 0.1, 0.3 }, { 0.5, 0 }, { 0.9, 0.3 }, { 1, 1 } }, 0)

		local page = create("ScrollingFrame", {
			Name = "Page",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 43),
			Size = UDim2.new(1, 0, 1, -46),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 2,
			ScrollBarImageTransparency = 0.7,
			Parent = box,
		})
		paint(page, "ScrollBarImageColor3", "Accent")
		pad(page, 10, 10, 10, 10)
		local holder = create("Frame", {
			Name = "Columns",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = page,
		})
		list(holder, 8, true)
		local single = dopts.Columns == 1
		local function column(name, ord)
			local c = create("Frame", {
				Name = name,
				BackgroundTransparency = 1,
				Size = single and UDim2.new(1, 0, 0, 0) or UDim2.new(0.5, -4, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = ord,
				Parent = holder,
			})
			list(c, 8)
			return c
		end
		Dialog.Left = column("Left", 1)
		Dialog.Right = single and Dialog.Left or column("Right", 2)
		Dialog._page = page
		Dialog._holder = holder
		Dialog.Frame = box
		bind(page:GetPropertyChangedSignal("CanvasPosition"), function()
			Window:_closePopup()
		end)

		function Dialog:Open()
			if self.Visible then
				return
			end
			self.Visible = true
			Window:_closePopup()
			layer.Visible = true
			shade.BackgroundTransparency = 1
			box.Position = UDim2.new(0.5, 0, 0.5, 14)
			tween(shade, { BackgroundTransparency = 0.45 }, 0.2)
			tween(box, { Position = UDim2.fromScale(0.5, 0.5) }, 0.25, Enum.EasingStyle.Back)
			fire(dopts.OnOpen)
		end
		function Dialog:Close()
			if not self.Visible then
				return
			end
			self.Visible = false
			Window:_closePopup()
			tween(shade, { BackgroundTransparency = 1 }, 0.12)
			local tw = tween(box, { Position = UDim2.new(0.5, 0, 0.5, 14) }, 0.12, Enum.EasingStyle.Quad)
			tw.Completed:Connect(function()
				if not self.Visible then
					layer.Visible = false
				end
			end)
			fire(dopts.OnClose)
		end
		function Dialog:Toggle()
			if self.Visible then
				self:Close()
			else
				self:Open()
			end
		end
		function Dialog:SetTitle(t)
			titleLbl.Text = t
		end

		closeDialog.MouseButton1Click:Connect(function()
			Dialog:Close()
		end)
		if dopts.CloseOnShade ~= false then
			shade.MouseButton1Click:Connect(function()
				Dialog:Close()
			end)
		end
		return Dialog
	end

	gui.Parent = guiParent()
	table.insert(Library.Windows, Window)
	Window:SetVisible(true)
	return Window
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

function TabMeta:Card(copts)
	if type(copts) == "string" then
		copts = { Title = copts }
	end
	copts = copts or {}
	local window = self.Window

	local side = copts.Side
	if side ~= "Left" and side ~= "Right" then
		side = self._sides.Left <= self._sides.Right and "Left" or "Right"
	end
	self._sides[side] += 1
	local col = self[side]

	local frame = create("Frame", {
		Name = copts.Title or "Card",
		BackgroundColor3 = Theme.Panel,
		Size = UDim2.new(1, 0, 0, 38),
		ClipsDescendants = true,
		LayoutOrder = self._sides[side],
		Parent = col,
	})
	round(frame, 6)
	create("UIGradient", { Color = ColorSequence.new(WHITE, Color3.fromRGB(224, 224, 224)), Rotation = 90, Parent = frame })
	outline(frame, Theme.Stroke, 1.25, 0.55)

	local header = create("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), Parent = frame })
	local titleLbl = text({
		Name = "Title",
		Text = string.upper(copts.Title or "Card"),
		Font = Theme.FontBold,
		TextSize = 13,
		TextTransparency = 0.35,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -46, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = header,
	})
	local chevron = text({
		Name = "Chevron",
		Text = ">",
		Font = Theme.FontBold,
		TextSize = 13,
		TextTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -20, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		Rotation = 90,
		Parent = header,
	})

	local body = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})
	local layout = list(body, 4)

	local Card = setmetatable({ Window = window, Tab = self, Frame = frame, Collapsed = false, _body = body, _elements = {} }, CardMeta)

	local function height()
		if Card.Collapsed then
			return 38
		end
		-- AbsoluteContentSize is affected by the window's UIScale, so undo it
		return 38 + layout.AbsoluteContentSize.Y / math.max(window._scale.Scale, 0.01) + 8
	end
	local function refresh(t)
		tween(frame, { Size = UDim2.new(1, 0, 0, math.floor(height() + 0.5)) }, t)
	end
	window._bind(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
		refresh(0)
	end)

	function Card:SetCollapsed(v)
		Card.Collapsed = v
		tween(chevron, { Rotation = v and 0 or 90 }, 0.2)
		refresh(0.25)
	end
	function Card:SetTitle(t)
		titleLbl.Text = string.upper(t)
	end

	if copts.Collapsible ~= false then
		hitbox(header, 2).MouseButton1Click:Connect(function()
			Card:SetCollapsed(not Card.Collapsed)
		end)
	else
		chevron.Visible = false
	end
	if copts.Collapsed then
		Card.Collapsed = true
		chevron.Rotation = 0
	end
	refresh(0)
	return Card
end

-- Shared row scaffolding: title on the left, a right-aligned control strip,
-- and a divider that only shows between rows.
function CardMeta:_element(height, opts)
	opts = opts or {}
	local window = self.Window
	local frame = create("Frame", {
		Name = opts.Name or "Element",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = #self._elements + 1,
		Parent = self._body,
	})
	local el = { Frame = frame, Window = window, Card = self }

	el.Right = create("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -13, 0, 4),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 3,
		Parent = frame,
	})
	list(el.Right, 6, true, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)

	if opts.Name then
		el.Title = text({
			Name = "Title",
			Text = opts.Name,
			Font = Theme.FontMedium,
			TextSize = 13,
			TextTransparency = 0.08,
			Position = UDim2.fromOffset(14, 0),
			Size = UDim2.new(1, -28, 0, 26),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		})
		local function fit()
			local s = math.max(window._scale.Scale, 0.01)
			local w = el.Right.AbsoluteSize.X / s
			el.Title.Size = UDim2.new(1, -28 - (w > 0 and w + 6 or 0), 0, 26)
		end
		el.Right:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
		task.defer(fit)
	end

	if opts.Tooltip then
		infoIcon(window, el.Right, opts.Tooltip)
	end

	el.Divider = create("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(1, -26, 0, 1),
		BackgroundColor3 = Theme.Divider,
		BackgroundTransparency = 0.5,
		Visible = false,
		Parent = frame,
	})
	local prev = self._elements[#self._elements]
	if prev then
		prev.Divider.Visible = true
	end
	table.insert(self._elements, el)

	function el:SetTitle(t)
		if el.Title then
			el.Title.Text = t
		end
	end
	function el:SetVisible(v)
		frame.Visible = v
	end
	return el
end

--------------------------------------------------------------------------------
-- Elements
--------------------------------------------------------------------------------

function CardMeta:Toggle(opts)
	opts = opts or {}
	local window = self.Window
	local el = self:_element(32, opts)
	el.Type = "Toggle"
	el.Value = (opts.Default == true) or (opts.CurrentValue == true)

	local track = create("Frame", {
		Name = "Switch",
		Size = UDim2.fromOffset(36, 20),
		BackgroundColor3 = Theme.Field,
		LayoutOrder = 10,
		Parent = el.Right,
	})
	round(track)
	local trackStroke = outline(track, Theme.Stroke, 1.2, 0.2)
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = WHITE,
		Parent = track,
	})
	round(knob)
	create("UIGradient", { Color = ColorSequence.new(WHITE, Color3.fromRGB(225, 225, 225)), Rotation = 90, Parent = knob })

	local function render(t)
		local on = el.Value
		tween(track, { BackgroundColor3 = on and Theme.Accent or Theme.Field }, t)
		tween(trackStroke, { Color = on and Theme.AccentDark or Theme.Stroke, Transparency = on and 0.1 or 0.2 }, t)
		tween(knob, {
			Position = on and UDim2.new(0, 19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
			BackgroundTransparency = on and 0 or 0.3,
		}, t)
	end

	function el:Set(v, silent)
		el.Value = v == true
		setFlag(el)
		render(0.18)
		if not silent then
			fire(opts.Callback, el.Value)
		end
	end

	hitbox(el.Frame, 2).MouseButton1Click:Connect(function()
		el:Set(not el.Value)
	end)

	if opts.Keybind ~= nil then
		local kb = keybox(el.Right, opts.Keybind == true and "None" or opts.Keybind, 5)
		el.Keybind = kb
		table.insert(window._keyHandlers, {
			key = function()
				return kb.Key
			end,
			fn = function()
				el:Set(not el.Value)
			end,
		})
		if opts.Flag then
			local keyFlag = opts.Flag .. "_Key"
			Library.Flags[keyFlag] = kb.Key
			Library.Options[keyFlag] = {
				Type = "Keybind",
				Set = function(_, k)
					kb:Set(k)
				end,
			}
			kb.OnChanged = function(k)
				Library.Flags[keyFlag] = k
			end
		end
	end

	table.insert(Library._repaint, function()
		render(0)
	end)
	render(0)
	register(el, opts.Flag)
	return el
end

function CardMeta:Slider(opts)
	opts = opts or {}
	local window = self.Window
	local el = self:_element(46, opts)
	el.Type = "Slider"

	local min = opts.Min or (opts.Range and opts.Range[1]) or 0
	local max = opts.Max or (opts.Range and opts.Range[2]) or 100
	local inc = opts.Increment or 1
	local suffix = opts.Suffix or ""
	local decimals = 0
	do
		local s = tostring(inc)
		local dot = s:find(".", 1, true)
		if dot then
			decimals = #s - dot
		end
	end

	local function snap(v)
		v = math.clamp(v, min, max)
		v = min + math.floor((v - min) / inc + 0.5) * inc
		v = tonumber(string.format("%." .. decimals .. "f", v)) or v
		return math.clamp(v, min, max)
	end
	local function fmt(v)
		return string.format("%." .. decimals .. "f", v) .. suffix
	end

	local valueBtn = create("TextButton", {
		Name = "Value",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.FontMedium,
		TextSize = 12,
		TextColor3 = Theme.Text,
		TextTransparency = 0.35,
		Text = "",
		LayoutOrder = 5,
		ZIndex = 4,
		Parent = el.Right,
	})
	local valueBox = create("TextBox", {
		Name = "ValueInput",
		BackgroundColor3 = Theme.Field,
		Size = UDim2.fromOffset(56, 18),
		Font = Theme.FontMedium,
		TextSize = 12,
		TextColor3 = Theme.Text,
		Text = "",
		ClearTextOnFocus = false,
		Visible = false,
		LayoutOrder = 6,
		ZIndex = 4,
		Parent = el.Right,
	})
	round(valueBox, 4)
	paint(outline(valueBox, Theme.Accent, 1, 0.3), "Color", "Accent")

	local track = create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(1, -26, 0, 8),
		BackgroundColor3 = Theme.Field,
		Parent = el.Frame,
	})
	round(track)
	outline(track, Theme.Stroke, 1, 0.3)
	local fill = create("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), Parent = track })
	paint(fill, "BackgroundColor3", "Accent")
	round(fill)
	fade(fill, { { 0, 0.02 }, { 0.48, 0.16 }, { 1, 0.34 } })
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(12, 12),
		Parent = track,
	})
	paint(knob, "BackgroundColor3", "AccentLight")
	round(knob, 4)
	paint(outline(knob, Theme.AccentDark, 1.5, 0.16), "Color", "AccentDark")

	function el:Set(v, silent)
		v = snap(tonumber(v) or el.Value or min)
		el.Value = v
		setFlag(el)
		local a = (max == min) and 0 or (v - min) / (max - min)
		tween(fill, { Size = UDim2.fromScale(a, 1) }, 0.08)
		tween(knob, { Position = UDim2.fromScale(a, 0.5) }, 0.08)
		valueBtn.Text = fmt(v)
		if not silent then
			fire(opts.Callback, v)
		end
	end

	local dragging = false
	local function update(x)
		local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = snap(min + (max - min) * a)
		if v ~= el.Value then
			el:Set(v)
		end
	end
	local hit = create("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 10, 0, 22),
		ZIndex = 3,
		Parent = track,
	})
	hit.InputBegan:Connect(function(input)
		if isClick(input) then
			dragging = true
			update(input.Position.X)
		end
	end)
	window._bind(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input.Position.X)
		end
	end)
	window._bind(UserInputService.InputEnded, function(input)
		if isClick(input) then
			dragging = false
		end
	end)

	valueBtn.MouseButton1Click:Connect(function()
		valueBtn.Visible = false
		valueBox.Visible = true
		valueBox.Text = tostring(el.Value)
		valueBox:CaptureFocus()
	end)
	valueBox.FocusLost:Connect(function()
		local n = tonumber(valueBox.Text)
		valueBox.Visible = false
		valueBtn.Visible = true
		if n then
			el:Set(n)
		end
	end)

	el.Value = snap(opts.Default or opts.CurrentValue or min)
	el:Set(el.Value, true)
	register(el, opts.Flag)
	return el
end

function CardMeta:Dropdown(opts)
	opts = opts or {}
	local window = self.Window
	local el = self:_element(58, opts)
	el.Type = "Dropdown"
	local multi = opts.Multi == true
	local options = table.clone(opts.Options or {})
	el.Options = options

	local field = create("Frame", {
		Name = "Field",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -9),
		Size = UDim2.new(1, -26, 0, 22),
		BackgroundColor3 = Theme.Field,
		Parent = el.Frame,
	})
	round(field, 4)
	local fieldStroke = outline(field, Theme.Stroke, 1, 0.35)
	local shown = text({
		Name = "Selected",
		TextSize = 12,
		Position = UDim2.fromOffset(9, 0),
		Size = UDim2.new(1, -32, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = field,
	})
	local chev = text({
		Name = "Chevron",
		Text = ">",
		Font = Theme.FontBold,
		TextSize = 12,
		TextTransparency = 0.4,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -7, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		Rotation = 90,
		Parent = field,
	})
	local hit = hitbox(field, 3)

	local function selected(o)
		if multi then
			return table.find(el.Value, o) ~= nil
		end
		return el.Value == o
	end

	local function display()
		local empty
		if multi then
			local parts = {}
			for _, v in ipairs(el.Value) do
				table.insert(parts, tostring(v))
			end
			empty = #parts == 0
			shown.Text = empty and (opts.Placeholder or "None") or table.concat(parts, ", ")
		else
			empty = el.Value == nil
			shown.Text = empty and (opts.Placeholder or "None") or tostring(el.Value)
		end
		shown.TextTransparency = empty and 0.5 or 0.05
	end

	function el:Set(v, silent)
		if multi then
			local out = {}
			if type(v) == "table" then
				for _, x in ipairs(v) do
					if table.find(options, x) and not table.find(out, x) then
						table.insert(out, x)
					end
				end
			elseif v ~= nil and table.find(options, v) then
				out = { v }
			end
			el.Value = out
		else
			if type(v) == "table" then
				v = v[1]
			end
			el.Value = v
		end
		setFlag(el)
		display()
		if el._render then
			el._render()
		end
		if not silent then
			fire(opts.Callback, el.Value)
		end
	end

	function el:Refresh(newOptions, keepSelection)
		options = table.clone(newOptions or {})
		el.Options = options
		window:_closePopup()
		if keepSelection then
			if not multi and el.Value ~= nil and not table.find(options, el.Value) then
				el:Set(nil, true)
			else
				el:Set(el.Value, true)
			end
		else
			el:Set(multi and {} or nil, true)
		end
	end

	local function open()
		local overlay = window._overlay
		local rel = field.AbsolutePosition - overlay.AbsolutePosition
		local w = field.AbsoluteSize.X
		local rowH = 24
		local searchable = opts.Search == true or (#options > 8 and opts.Search ~= false)
		local top = searchable and 32 or 4
		local h = top + math.max(math.min(#options, 7), 1) * rowH + 4
		local y = rel.Y + field.AbsoluteSize.Y + 4
		if y + h > overlay.AbsoluteSize.Y - 8 then
			y = rel.Y - h - 4
		end

		local popup = create("Frame", {
			Name = "DropdownList",
			BackgroundColor3 = Theme.Background,
			Position = UDim2.fromOffset(rel.X, y),
			Size = UDim2.fromOffset(w, 0),
			ClipsDescendants = true,
		})
		round(popup, 5)
		outline(popup, Theme.AccentDark, 1.2, 0.25)

		local search
		if searchable then
			search = create("TextBox", {
				Name = "Search",
				BackgroundColor3 = Theme.Field,
				Position = UDim2.fromOffset(4, 4),
				Size = UDim2.new(1, -8, 0, 24),
				Font = Theme.Font,
				TextSize = 12,
				TextColor3 = Theme.Text,
				PlaceholderText = "Search...",
				PlaceholderColor3 = Theme.SubText,
				Text = "",
				ClearTextOnFocus = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = popup,
			})
			round(search, 4)
			pad(search, 8, 8, 0, 0)
		end

		local scroll = create("ScrollingFrame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, top),
			Size = UDim2.new(1, 0, 1, -top - 4),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 2,
			ScrollBarImageColor3 = Theme.Accent,
			Parent = popup,
		})
		list(scroll, 2)
		pad(scroll, 4, 4, 0, 0)

		local function render()
			for _, child in ipairs(scroll:GetChildren()) do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end
			local q = search and string.lower(search.Text) or ""
			for i, o in ipairs(options) do
				local name = tostring(o)
				if q == "" or string.find(string.lower(name), q, 1, true) then
					local sel = selected(o)
					local row = create("TextButton", {
						Name = name,
						AutoButtonColor = false,
						BackgroundColor3 = Theme.Accent,
						BackgroundTransparency = sel and 0.8 or 1,
						Size = UDim2.new(1, 0, 0, rowH - 2),
						Text = "",
						LayoutOrder = i,
						Parent = scroll,
					})
					round(row, 4)
					text({
						Text = name,
						TextSize = 12,
						TextTransparency = sel and 0 or 0.3,
						Font = sel and Theme.FontMedium or Theme.Font,
						Position = UDim2.fromOffset(8, 0),
						Size = UDim2.new(1, -26, 1, 0),
						TextTruncate = Enum.TextTruncate.AtEnd,
						Parent = row,
					})
					if sel then
						local dot = create("Frame", {
							AnchorPoint = Vector2.new(1, 0.5),
							Position = UDim2.new(1, -8, 0.5, 0),
							Size = UDim2.fromOffset(6, 6),
							BackgroundColor3 = Theme.AccentLight,
							Parent = row,
						})
						round(dot)
					end
					row.MouseEnter:Connect(function()
						if not sel then
							tween(row, { BackgroundTransparency = 0.92 }, 0.12)
						end
					end)
					row.MouseLeave:Connect(function()
						if not sel then
							tween(row, { BackgroundTransparency = 1 }, 0.12)
						end
					end)
					row.MouseButton1Click:Connect(function()
						if multi then
							local copy = table.clone(el.Value)
							local idx = table.find(copy, o)
							if idx then
								table.remove(copy, idx)
							else
								table.insert(copy, o)
							end
							el:Set(copy)
						else
							el:Set(o)
							window:_closePopup()
						end
					end)
				end
			end
		end
		render()
		el._render = render
		if search then
			search:GetPropertyChangedSignal("Text"):Connect(render)
		end

		window:_openPopup(popup, function()
			el._render = nil
			tween(chev, { Rotation = 90 }, 0.15)
			tween(fieldStroke, { Color = Theme.Stroke }, 0.15)
		end)
		tween(chev, { Rotation = -90 }, 0.15)
		tween(fieldStroke, { Color = Theme.Accent }, 0.15)
		tween(popup, { Size = UDim2.fromOffset(w, h) }, 0.18)
	end

	hit.MouseButton1Click:Connect(open)
	hit.MouseEnter:Connect(function()
		tween(fieldStroke, { Transparency = 0.1 }, 0.12)
	end)
	hit.MouseLeave:Connect(function()
		tween(fieldStroke, { Transparency = 0.35 }, 0.12)
	end)

	el.Value = multi and {} or nil
	el:Set(opts.Default, true)
	register(el, opts.Flag)
	return el
end

function CardMeta:Button(opts)
	opts = opts or {}
	local el = self:_element(40, {})
	el.Type = "Button"
	local secondary = opts.Style == "Secondary"

	local btn = create("TextButton", {
		Name = opts.Name or "Button",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -26, 0, 30),
		Text = "",
		ClipsDescendants = true,
		Parent = el.Frame,
	})
	round(btn, 5)
	local st
	if secondary then
		btn.BackgroundColor3 = Theme.Field
		st = outline(btn, Theme.Stroke, 1.25, 0.2)
	else
		paint(btn, "BackgroundColor3", "Accent")
		st = paint(outline(btn, Theme.AccentDark, 2, 0.3), "Color", "AccentDark")
		local sheen = create("Frame", { BackgroundColor3 = WHITE, Size = UDim2.fromScale(1, 1), Parent = btn })
		round(sheen, 5)
		fade(sheen, { { 0, 0.72 }, { 0.45, 0.98 }, { 1, 1 } })
	end
	local label = text({
		Text = opts.Name or "Button",
		Font = Theme.FontBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = btn,
	})
	if not secondary then
		paint(create("UIStroke", { Thickness = 1.5, Transparency = 0.25, Parent = label }), "Color", "AccentDeep")
	end
	local sc = create("UIScale", { Parent = btn })

	btn.MouseEnter:Connect(function()
		if secondary then
			tween(st, { Color = Theme.Accent, Transparency = 0.4 }, 0.15)
		else
			tween(btn, { BackgroundColor3 = Theme.AccentLight }, 0.15)
		end
	end)
	btn.MouseLeave:Connect(function()
		tween(sc, { Scale = 1 }, 0.12)
		if secondary then
			tween(st, { Color = Theme.Stroke, Transparency = 0.2 }, 0.15)
		else
			tween(btn, { BackgroundColor3 = Theme.Accent }, 0.15)
		end
	end)
	btn.MouseButton1Down:Connect(function()
		tween(sc, { Scale = 0.97 }, 0.08)
	end)
	btn.MouseButton1Up:Connect(function()
		tween(sc, { Scale = 1 }, 0.12)
	end)
	btn.MouseButton1Click:Connect(function()
		local ripple = create("Frame", {
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.7,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0, 0),
			Parent = btn,
		})
		round(ripple)
		create("UIAspectRatioConstraint", { AspectRatio = 1, AspectType = Enum.AspectType.ScaleWithParentSize, Parent = ripple })
		local tw = tween(ripple, { Size = UDim2.fromScale(1.2, 1.2), BackgroundTransparency = 1 }, 0.45)
		tw.Completed:Connect(function()
			ripple:Destroy()
		end)
		fire(opts.Callback)
	end)

	function el:SetText(t)
		label.Text = t
	end
	return el
end

function CardMeta:Input(opts)
	opts = opts or {}
	local el = self:_element(58, opts)
	el.Type = "Input"
	el.Value = tostring(opts.Default or "")

	local field = create("Frame", {
		Name = "Field",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -9),
		Size = UDim2.new(1, -26, 0, 22),
		BackgroundColor3 = Theme.Field,
		Parent = el.Frame,
	})
	round(field, 4)
	local fieldStroke = outline(field, Theme.Stroke, 1, 0.35)
	local box = create("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(9, 0),
		Size = UDim2.new(1, -18, 1, 0),
		Font = Theme.Font,
		TextSize = 12,
		TextColor3 = Theme.Text,
		PlaceholderText = opts.Placeholder or "Type here...",
		PlaceholderColor3 = Theme.SubText,
		Text = el.Value,
		ClearTextOnFocus = opts.ClearOnFocus == true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClipsDescendants = true,
		Parent = field,
	})

	local function output()
		if opts.Numeric then
			return tonumber(box.Text)
		end
		return box.Text
	end

	if opts.Numeric then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local cleaned = (box.Text:gsub("[^%d%.%-]", ""))
			if cleaned ~= box.Text then
				box.Text = cleaned
			end
		end)
	end
	box.Focused:Connect(function()
		tween(fieldStroke, { Color = Theme.Accent, Transparency = 0.1 }, 0.15)
	end)
	box.FocusLost:Connect(function(enter)
		tween(fieldStroke, { Color = Theme.Stroke, Transparency = 0.35 }, 0.15)
		el.Value = box.Text
		setFlag(el)
		if not opts.Live then
			fire(opts.Callback, output(), enter)
		end
	end)
	if opts.Live then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			el.Value = box.Text
			setFlag(el)
			fire(opts.Callback, output(), false)
		end)
	end

	function el:Set(v, silent)
		box.Text = tostring(v or "")
		el.Value = box.Text
		setFlag(el)
		if not silent and not opts.Live then
			fire(opts.Callback, output(), false)
		end
	end

	register(el, opts.Flag)
	return el
end

function CardMeta:Keybind(opts)
	opts = opts or {}
	local window = self.Window
	local el = self:_element(32, opts)
	el.Type = "Keybind"
	local kb = keybox(el.Right, opts.Default or "None", 5)
	el.Value = kb.Key
	kb.OnChanged = function(k)
		el.Value = k
		setFlag(el)
		fire(opts.ChangedCallback, k)
	end
	table.insert(window._keyHandlers, {
		key = function()
			return kb.Key
		end,
		fn = function()
			fire(opts.Callback, kb.Key)
		end,
	})
	function el:Set(k)
		kb:Set(k)
	end
	register(el, opts.Flag)
	return el
end

function CardMeta:Progress(opts)
	opts = opts or {}
	local el = self:_element(44, opts)
	el.Type = "Progress"
	local pct = text({
		Name = "Percent",
		Text = "0%",
		Font = Theme.FontMedium,
		TextSize = 12,
		TextTransparency = 0.35,
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 5,
		Parent = el.Right,
	})
	local track = create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(1, -26, 0, 8),
		BackgroundColor3 = Theme.Field,
		Parent = el.Frame,
	})
	round(track)
	outline(track, Theme.Stroke, 1, 0.3)
	local fill = create("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), Parent = track })
	paint(fill, "BackgroundColor3", "Accent")
	round(fill)
	fade(fill, { { 0, 0.02 }, { 0.48, 0.16 }, { 1, 0.34 } })

	function el:Set(alpha, label)
		alpha = math.clamp(tonumber(alpha) or 0, 0, 1)
		el.Value = alpha
		tween(fill, { Size = UDim2.fromScale(alpha, 1) }, 0.3)
		pct.Text = label or (math.floor(alpha * 100 + 0.5) .. "%")
	end
	el:Set(opts.Value or 0)
	return el
end

function CardMeta:Paragraph(opts)
	if type(opts) == "string" then
		opts = { Content = opts }
	end
	opts = opts or {}
	local el = self:_element(0, opts)
	el.Type = "Paragraph"
	el.Frame.AutomaticSize = Enum.AutomaticSize.Y
	local body = text({
		Name = "Body",
		Text = opts.Content or "",
		RichText = true,
		TextWrapped = true,
		TextSize = 12,
		TextTransparency = 0.45,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.15,
		Position = UDim2.fromOffset(14, opts.Name and 24 or 8),
		Size = UDim2.new(1, -28, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = el.Frame,
	})
	pad(body, 0, 0, 0, 10)
	function el:Set(content)
		body.Text = content
	end
	return el
end

function CardMeta:Label(content)
	local el = self:_element(26, {})
	el.Type = "Label"
	local lbl = text({
		Text = content or "",
		TextSize = 12,
		TextTransparency = 0.4,
		RichText = true,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -28, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = el.Frame,
	})
	function el:Set(t)
		lbl.Text = t
	end
	return el
end

--------------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------------

local notifCount = 0
function Library:Notify(opts)
	if type(opts) == "string" then
		opts = { Title = opts }
	end
	opts = opts or {}
	local holder = self._notifHolder
	if not holder then
		warn("[Ember] Notify needs a window to exist first")
		return
	end
	local duration = opts.Duration or 4
	notifCount += 1

	local wrap = create("Frame", {
		Name = "Notification",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = notifCount,
		Parent = holder,
	})
	local card = create("Frame", {
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = 0.04,
		Position = UDim2.fromOffset(320, 0),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = wrap,
	})
	round(card, 6)
	outline(card, Theme.AccentDark, 1.5, 0.45)
	local tint = create("Frame", { BackgroundColor3 = Theme.Accent, BackgroundTransparency = 0.9, Size = UDim2.fromScale(1, 1), Parent = card })
	round(tint, 6)
	fade(tint, { { 0, 0.1 }, { 1, 0.8 } }, 0)
	local accentBar = create("Frame", {
		BackgroundColor3 = Theme.Accent,
		Position = UDim2.fromOffset(8, 10),
		Size = UDim2.new(0, 3, 1, -20),
		Parent = card,
	})
	round(accentBar)

	local inner = create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card })
	pad(inner, 20, 12, 10, 12)
	list(inner, 3)
	text({
		Text = opts.Title or "Notification",
		Font = Theme.FontBold,
		TextSize = 13,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = inner,
	})
	if opts.Content then
		text({
			Text = opts.Content,
			TextSize = 12,
			TextTransparency = 0.35,
			TextWrapped = true,
			RichText = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = inner,
		})
	end
	local timer = create("Frame", {
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 0.3,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 2),
		Parent = card,
	})

	tween(card, { Position = UDim2.new() }, 0.35)
	tween(timer, { Size = UDim2.new(0, 0, 0, 2) }, duration, Enum.EasingStyle.Linear)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		local tw = tween(card, { Position = UDim2.fromOffset(320, 0) }, 0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
		tw.Completed:Connect(function()
			wrap:Destroy()
		end)
	end
	hitbox(card, 5).MouseButton1Click:Connect(close)
	task.delay(duration, close)
end

--------------------------------------------------------------------------------
-- Theme & configs
--------------------------------------------------------------------------------

function Library:SetAccent(color)
	if typeof(color) ~= "Color3" then
		color = self.AccentPresets[color]
	end
	if not color then
		return
	end
	Theme.Accent = color
	deriveAccent()
	local alive = {}
	for _, e in ipairs(self._painted) do
		local obj = e[1]
		if obj.Parent then
			obj[e[2]] = Theme[e[3]]
			table.insert(alive, e)
		end
	end
	self._painted = alive
	for _, fn in ipairs(self._repaint) do
		pcall(fn)
	end
end

local function fsAvailable()
	return writefile ~= nil and readfile ~= nil and isfile ~= nil
end

local function configPath(name)
	return Library.ConfigFolder .. "/" .. name .. ".json"
end

function Library:SaveConfig(name)
	if not fsAvailable() then
		return false, "File functions aren't available here."
	end
	if makefolder and isfolder and not isfolder(self.ConfigFolder) then
		makefolder(self.ConfigFolder)
	end
	local data = {}
	for flag in pairs(self.Options) do
		data[flag] = self.Flags[flag]
	end
	return pcall(writefile, configPath(name), HttpService:JSONEncode(data))
end

function Library:LoadConfig(name)
	if not fsAvailable() then
		return false, "File functions aren't available here."
	end
	local path = configPath(name)
	if not isfile(path) then
		return false, "Config '" .. tostring(name) .. "' not found."
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(path))
	end)
	if not ok or type(data) ~= "table" then
		return false, "Config file is corrupted."
	end
	for flag, value in pairs(data) do
		local opt = self.Options[flag]
		if opt and opt.Set then
			pcall(opt.Set, opt, value)
		end
	end
	return true
end

function Library:DeleteConfig(name)
	if not (delfile and isfile) then
		return false, "File functions aren't available here."
	end
	local path = configPath(name)
	if not isfile(path) then
		return false, "Config '" .. tostring(name) .. "' not found."
	end
	delfile(path)
	return true
end

function Library:ListConfigs()
	local out = {}
	if not (listfiles and isfolder) or not isfolder(self.ConfigFolder) then
		return out
	end
	for _, file in ipairs(listfiles(self.ConfigFolder)) do
		local n = string.match(file, "([^/\\]+)%.json$")
		if n then
			table.insert(out, n)
		end
	end
	table.sort(out)
	return out
end

-- Drop-in settings page: config save/load + accent picker + menu key + unload.
function Library:BuildSettings(tab)
	local window = tab.Window

	local cfg = tab:Card({ Title = "Configuration", Side = "Left" })
	local nameBox = cfg:Input({ Name = "Config Name", Placeholder = "my-config" })
	local saved = cfg:Dropdown({ Name = "Saved Configs", Options = self:ListConfigs(), Placeholder = "No configs" })

	cfg:Button({
		Name = "Save",
		Callback = function()
			local n = nameBox.Value ~= "" and nameBox.Value or saved.Value
			if not n or n == "" then
				self:Notify({ Title = "Config", Content = "Type a config name first." })
				return
			end
			local ok, err = self:SaveConfig(n)
			self:Notify({ Title = ok and "Config saved" or "Save failed", Content = ok and ("Saved '" .. n .. "'.") or tostring(err) })
			saved:Refresh(self:ListConfigs(), true)
		end,
	})
	cfg:Button({
		Name = "Load",
		Style = "Secondary",
		Callback = function()
			local n = saved.Value or (nameBox.Value ~= "" and nameBox.Value) or nil
			if not n then
				self:Notify({ Title = "Config", Content = "Pick a saved config first." })
				return
			end
			local ok, err = self:LoadConfig(n)
			self:Notify({ Title = ok and "Config loaded" or "Load failed", Content = ok and ("Loaded '" .. n .. "'.") or tostring(err) })
		end,
	})
	cfg:Button({
		Name = "Delete",
		Style = "Secondary",
		Callback = function()
			local n = saved.Value
			if not n then
				self:Notify({ Title = "Config", Content = "Pick a saved config first." })
				return
			end
			local ok, err = self:DeleteConfig(n)
			self:Notify({ Title = ok and "Config deleted" or "Delete failed", Content = ok and ("Deleted '" .. n .. "'.") or tostring(err) })
			saved:Refresh(self:ListConfigs(), false)
		end,
	})
	cfg:Button({
		Name = "Refresh List",
		Style = "Secondary",
		Callback = function()
			saved:Refresh(self:ListConfigs(), true)
		end,
	})

	local current
	for name, c in pairs(self.AccentPresets) do
		if c == Theme.Accent then
			current = name
		end
	end

	local ui = tab:Card({ Title = "Interface", Side = "Right" })
	ui:Dropdown({
		Name = "Accent",
		Options = self.AccentOrder,
		Default = current,
		Placeholder = "Custom",
		Flag = "Ember_Accent",
		Callback = function(v)
			if v then
				self:SetAccent(v)
			end
		end,
	})
	ui:Keybind({
		Name = "Menu Key",
		Default = window.ToggleKey,
		Flag = "Ember_MenuKey",
		ChangedCallback = function(k)
			window.ToggleKey = k
		end,
	})
	ui:Button({
		Name = "Unload",
		Callback = function()
			window:Destroy()
		end,
	})
	return cfg, ui
end

function Library:Destroy()
	for i = #self.Windows, 1, -1 do
		self.Windows[i]:Destroy()
	end
end

return Library

--[[
================================================================================
API REFERENCE
================================================================================

Ember:CreateWindow(options) -> Window
	Title           string     "Ember"
	Subtitle        string     ""
	Logo            assetId?   image in the corner; omit for an accent badge with the title's first letter
	Accent          Color3?    starting accent colour
	Width / Height  number     content panel size (520 x 460)
	SidebarWidth    number     170
	ToggleKey       KeyCode    RightShift
	ProfileText     string?    text under the player's name (default "@username"); RichText allowed
	ProfileColor    Color3?    colour for ProfileText
	ConfigFolder    string?    folder for saved configs (defaults to the title)
	ShowOpenButton  bool?      force the "Open" pill on/off when hidden (default: touch devices only)
	OnClose         function?  called after the window is destroyed

Window:Section(name)                         sidebar header
Window:Tab({ Name, Icon?, Columns? }) -> Tab Columns = 1 for a single full-width column
Window:SelectTab(tab | name)
Window:SetVisible(bool) / Window:Toggle()
Window:Dialog({ Title, Width?, Height?, Columns?, CloseOnShade?, OnOpen?, OnClose? }) -> Dialog
	a pop-up window over the menu; Dialog:Card({...}) works like Tab:Card
	Dialog:Open() / Dialog:Close() / Dialog:Toggle() / Dialog:SetTitle(text) / Dialog.Visible
Window:Destroy()

Tab:Card({ Title, Side?, Collapsible?, Collapsed? }) -> Card
	Side = "Left" | "Right"; omitted = whichever column has fewer cards
Card:SetCollapsed(bool) / Card:SetTitle(text)

Every element returns an object with :Set(value), .Value, :SetTitle(text), :SetVisible(bool).
Elements with a Flag are saved in configs and mirrored in Ember.Flags[Flag].

Card:Toggle({ Name, Default, Flag, Tooltip, Keybind, Callback(bool) })
	Keybind = true or "F" / Enum.KeyCode.F adds a key box that toggles it (saved as Flag.."_Key")
Card:Slider({ Name, Min, Max, Increment, Default, Suffix, Flag, Tooltip, Callback(number) })
	Click the number to type an exact value.
Card:Dropdown({ Name, Options, Default, Multi, Search, Placeholder, Flag, Tooltip, Callback(value) })
	Multi = true -> value is an array. Dropdown:Refresh(newOptions, keepSelection)
Card:Button({ Name, Style = "Primary" | "Secondary", Callback() })   :SetText(text)
Card:Input({ Name, Default, Placeholder, Numeric, Live, ClearOnFocus, Flag, Tooltip, Callback(text, enterPressed) })
Card:Keybind({ Name, Default, Flag, Tooltip, Callback(key), ChangedCallback(key) })
Card:Progress({ Name, Value, Tooltip })      :Set(alpha 0-1, label?)
Card:Paragraph({ Name?, Content })           :Set(content)   RichText, auto height
Card:Label(text)                             :Set(text)

Ember:Notify({ Title, Content?, Duration? })
Ember:SetAccent(Color3 | presetName)         presets: Crimson, Ocean, Violet, Emerald, Amber, Rose
Ember:SaveConfig(name) / LoadConfig(name) / DeleteConfig(name) / ListConfigs()
	(needs writefile/readfile/isfile/listfiles — executor only)
Ember:BuildSettings(tab)                     adds a ready-made Configuration + Interface page
Ember:Destroy()
]]
