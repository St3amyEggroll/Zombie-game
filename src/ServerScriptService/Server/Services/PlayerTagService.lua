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
local TAG_OFFSET   = Vector3.new(0, 2.1, 0) -- studs above the head (sits above the default name)
local TAG_MAX_DIST = 90                     -- studs the tag stays readable from
local WINS_SIZE    = 16
local LVL_SIZE     = 13
local WINS_COLOR   = Color3.fromRGB(230, 180, 76) -- gold
local LVL_COLOR    = Color3.fromRGB(255, 255, 255)
local BLACK        = Color3.new(0, 0, 0)

local function stickerText(parent, name, y, h, size, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = UDim2.fromOffset(0, y)
	l.Size = UDim2.new(1, 0, 0, h)
	l.BackgroundTransparency = 1
	l.FontFace = Font.fromEnum(Enum.Font.FredokaOne) -- same chunky face as the rest of the UI
	l.TextSize = size
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
		bb.Size = UDim2.fromOffset(200, 40)
		bb.StudsOffset = TAG_OFFSET
		bb.MaxDistance = TAG_MAX_DIST
		bb.AlwaysOnTop = false
		bb.Parent = head
		stickerText(bb, "Wins", 0, 20, WINS_SIZE, WINS_COLOR)
		stickerText(bb, "Level", 20, 16, LVL_SIZE, LVL_COLOR)
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
