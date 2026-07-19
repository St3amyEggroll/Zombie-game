--!nonstrict
-- PlayerTagService.lua — the floating text over every player's head ("N WINS" on top, "LVL n" under it —
-- plain text, no panel) plus the WINS column on the Roblox leaderboard. Pure presentation: reads wins/xp
-- from DataService and converts XP -> level with ProgressionConfig. Rebuilt on every (re)spawn; the values
-- only change between runs (a win banks on the way back to the lobby), so spawn-time refresh is enough.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProgressionConfig = require(Shared.Config.ProgressionConfig)

local DataService = require(script.Parent.DataService)

local PlayerTagService = {}

-- ===== TUNABLES =====
local TAG_OFFSET   = Vector3.new(0, 2.5, 0) -- studs above the head (sits above the default name)
local TAG_MAX_DIST = 90                     -- studs the tag stays readable from
-- STUDS-based size: the tag lives IN the world, so it scales with the character — bigger as you zoom
-- in, smaller as you zoom out (a pixel-based tag stayed constant, which read backwards).
local TAG_W_STUDS  = 6
local TAG_H_STUDS  = 2.1                    -- three rows now: TITLE (VIP) / WINS / LVL
local TITLE_COLOR  = Color3.fromRGB(230, 180, 76) -- the top TITLE line (VIP for now; titles system next)
local WINS_COLOR   = Color3.fromRGB(230, 180, 76) -- gold
local LVL_COLOR    = Color3.fromRGB(255, 255, 255)
local BLACK        = Color3.new(0, 0, 0)

local function stickerText(parent, name, yScale, hScale, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = UDim2.fromScale(0, yScale)
	l.Size = UDim2.fromScale(1, hScale)
	l.BackgroundTransparency = 1
	l.FontFace = Font.fromEnum(Enum.Font.FredokaOne) -- same chunky face as the rest of the UI
	l.TextScaled = true -- the billboard is studs-sized; the text fills whatever that renders as
	l.TextColor3 = color
	l.Text = ""
	l.Parent = parent
	local st = Instance.new("UIStroke")
	st.Color = BLACK
	st.Thickness = 2
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	st.Parent = l
	return l
end

-- Build (or fetch) the tag on a character; JUST the two text lines, no background.
local function ensureTag(character)
	local head = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not head then
		return nil
	end
	local bb = head:FindFirstChild("PlayerTag")
	if not bb then
		bb = Instance.new("BillboardGui")
		bb.Name = "PlayerTag"
		bb.Size = UDim2.new(TAG_W_STUDS, 0, TAG_H_STUDS, 0) -- scale components = STUDS on a billboard
		bb.StudsOffset = TAG_OFFSET
		bb.MaxDistance = TAG_MAX_DIST
		bb.AlwaysOnTop = false
		bb.Parent = head
		-- CHANGED (owner): VIP rides its OWN line ON TOP of the wins (was a suffix on the LVL line).
		-- This top line is the TITLE slot — the switchable-titles system lands here next.
		stickerText(bb, "Title", 0, 0.34, TITLE_COLOR)
		stickerText(bb, "Wins", 0.34, 0.33, WINS_COLOR)
		stickerText(bb, "Level", 0.67, 0.33, LVL_COLOR)
	elseif not bb:FindFirstChild("Title") then
		bb:Destroy() -- an old two-line tag from before the restructure: rebuild it fresh
		return ensureTag(character)
	end
	return bb
end

function PlayerTagService.Refresh(player: Player)
	local data = DataService.Get(player)
	if not data then
		return
	end
	local wins = tonumber(data.wins) or 0
	local level = ProgressionConfig.LevelForXP(tonumber(data.xp) or 0)
	-- Leaderboard column.
	local ls = player:FindFirstChild("leaderstats")
	local winsStat = ls and ls:FindFirstChild("Wins")
	if winsStat then
		winsStat.Value = wins
	end
	-- Overhead text.
	local character = player.Character
	local bb = character and ensureTag(character)
	if bb then
		bb.Title.Text = player:GetAttribute("VIPPass") and "VIP" or ""
		bb.Wins.Text = ("%d WINS"):format(wins)
		bb.Level.Text = ("LVL %d"):format(level)
	end
end

local function onJoin(player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = player
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = ls

	player.CharacterAdded:Connect(function()
		task.defer(PlayerTagService.Refresh, player)
	end)
	player:GetAttributeChangedSignal("VIPPass"):Connect(function()
		PlayerTagService.Refresh(player) -- pass check resolved (or a fresh purchase): stamp the tag
	end)
	task.spawn(function()
		DataService.WaitFor(player) -- always resolves (falls back to the template on store failure)
		PlayerTagService.Refresh(player)
	end)
end

function PlayerTagService.Start()
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
	Players.PlayerAdded:Connect(onJoin)
	print("[PlayerTagService] started (overhead wins/level + Wins leaderboard)")
end

return PlayerTagService
