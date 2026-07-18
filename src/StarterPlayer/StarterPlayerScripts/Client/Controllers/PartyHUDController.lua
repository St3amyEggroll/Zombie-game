--!nonstrict
-- PartyHUDController.lua — the in-run PARTY display (HUD renovation): round avatar chips top-left,
-- one per player in the run (you first), each with a colored RING that tracks that player's live
-- health — toxic green when healthy, gold when hurt, blood orange when critical — and a DOWNED state
-- driven by the server's DownedChanged broadcast. With the persistent health bar retired, YOUR chip's
-- ring is your own at-a-glance health too.
--
-- All client-side: teammate Humanoid.Health replicates natively, avatars come from the thumbnail API,
-- and one light poll recolors the rings. No new remotes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)
local UITheme = require(Shared.Modules.UITheme)

local PartyHUDController = {}

-- ===== TUNABLES =====
local CHIP        = 56    -- avatar circle size
local RING        = 4     -- ring thickness
local GAP         = 12
local MAX_CHIPS   = 6
local POLL        = 0.4   -- seconds between ring refreshes
local COL_FULL    = UITheme.TOXIC
local COL_HURT    = UITheme.GOLD
local COL_CRIT    = UITheme.ORANGE
local COL_DEAD    = Color3.fromRGB(120, 60, 40)

local localPlayer = Players.LocalPlayer

local row -- the chips container
local chips: { [number]: any } = {} -- userId -> { holder, ring, name, player }
local downed: { [number]: boolean } = {}

local function healthColor(frac: number): Color3
	if frac > 0.66 then
		return COL_FULL
	elseif frac > 0.33 then
		return COL_HURT
	end
	return COL_CRIT
end

local function relayout()
	local order = {}
	for _, pl in Players:GetPlayers() do
		table.insert(order, pl)
	end
	table.sort(order, function(a, b)
		if (a == localPlayer) ~= (b == localPlayer) then
			return a == localPlayer -- you first (top of the column)
		end
		return a.UserId < b.UserId
	end)
	local i = 0
	for _, pl in order do
		local c = chips[pl.UserId]
		if c then
			c.holder.Visible = i < MAX_CHIPS
			c.holder.LayoutOrder = i -- the column's UIListLayout stacks by this
			i += 1
		end
	end
end

local function makeChip(pl: Player)
	if chips[pl.UserId] then
		return
	end
	local holder = Instance.new("Frame")
	holder.Name = "Chip_" .. pl.Name
	holder.Size = UDim2.fromOffset(CHIP, CHIP + 18)
	holder.BackgroundTransparency = 1
	holder.Parent = row

	local ava = Instance.new("ImageLabel")
	ava.Name = "Avatar"
	ava.Size = UDim2.fromOffset(CHIP, CHIP)
	ava.BackgroundColor3 = UITheme.PANEL2
	ava.BorderSizePixel = 0
	ava.Parent = holder
	UITheme.Corner(ava, 999)
	local ring = Instance.new("UIStroke")
	ring.Color = COL_FULL
	ring.Thickness = RING
	ring.Parent = ava
	local edge = Instance.new("UIStroke") -- thin black seat under the colored ring
	edge.Color = UITheme.BLACK
	edge.Thickness = 1
	edge.Parent = holder

	local name = Instance.new("TextLabel")
	name.Name = "Nm"
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.new(0.5, 0, 1, 0)
	name.Size = UDim2.fromOffset(CHIP + 22, 14)
	name.BackgroundTransparency = 1
	name.FontFace = UITheme.BodyBoldFace
	name.TextSize = 11
	name.TextColor3 = UITheme.TEXT
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = pl.DisplayName
	name.Parent = holder
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(0, 0, 0)
	st.Transparency = 0.35
	st.Thickness = 1.5
	st.Parent = name

	chips[pl.UserId] = { holder = holder, ring = ring, name = name, player = pl }
	task.spawn(function() -- avatar headshot (pcall: the thumbnail API can hiccup)
		local ok, img = pcall(function()
			return Players:GetUserThumbnailAsync(pl.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and img and ava.Parent then
			ava.Image = img
		end
	end)
	relayout()
end

local function dropChip(userId: number)
	local c = chips[userId]
	if c then
		c.holder:Destroy()
		chips[userId] = nil
	end
	downed[userId] = nil
	relayout()
end

local function refresh()
	for userId, c in chips do
		local pl = c.player
		if downed[userId] then
			c.ring.Color = COL_DEAD
			c.name.Text = "DOWNED"
			c.name.TextColor3 = COL_CRIT
		else
			c.name.Text = pl.DisplayName
			c.name.TextColor3 = UITheme.TEXT
			local char = pl.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				c.ring.Color = healthColor(hum.Health / math.max(1, hum.MaxHealth))
			else
				c.ring.Color = COL_DEAD
			end
		end
	end
end

function PartyHUDController.Start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "PartyHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.Layer.HUD
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	UITheme.Attach(gui)

	-- CHANGED (owner): a COLUMN on the RIGHT EDGE, vertically centered — mirrors the lobby's party
	-- placement. AutomaticSize + the centered anchor keep the stack centered as players come and go.
	row = Instance.new("Frame")
	row.Name = "PartyColumn"
	row.AnchorPoint = Vector2.new(1, 0.5)
	row.Position = UDim2.new(1, -14, 0.5, 0)
	row.Size = UDim2.fromOffset(CHIP + 24, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	row.Parent = gui
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, GAP)
	list.Parent = row

	for _, pl in Players:GetPlayers() do
		makeChip(pl)
	end
	Players.PlayerAdded:Connect(makeChip)
	Players.PlayerRemoving:Connect(function(pl)
		dropChip(pl.UserId)
	end)

	-- DOWNED state rides the existing broadcast: (userId, isOut) — a revive/respawn clears it.
	Remotes.Get("DownedChanged").OnClientEvent:Connect(function(userId, isOut)
		userId = tonumber(userId)
		if userId then
			downed[userId] = isOut == true or nil
			refresh()
		end
	end)

	task.spawn(function()
		while true do
			refresh()
			task.wait(POLL)
		end
	end)
	print("[PartyHUDController] started (party chips + health rings)")
end

return PartyHUDController
