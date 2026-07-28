--!nonstrict
-- TitleFXController.lua — animates the fancy TITLE styles on everyone's overhead tag. The server
-- (PlayerTagService) writes the title text/color and stamps a "TitleStyle" attribute on the player;
-- this runs the styles locally on every client (billboard text edits don't need to replicate):
--   rainbow — the hue cycles (VIP / LEGEND)      pulse — brightness breathes (GOD, UNKILLABLE...)
--   flicker — unstable random dips (NIGHTMARE)   static/none — left alone entirely.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local TitleFXController = {}

-- ===== TUNABLES =====
local TICK = 0.08          -- seconds between animation steps (cheap: a handful of label writes)
local RAINBOW_SPEED = 0.35 -- hue cycles per second
local PULSE_SPEED = 2.2    -- radians/sec of the breathe
local FLICKER_CHANCE = 0.22 -- per tick: chance a flickering title dips

local baseColor: { [number]: Color3 } = {} -- userId -> the title's stamped color (pulse returns to it)

local function titleLabel(player: Player): TextLabel?
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local bb = head and head:FindFirstChild("PlayerTag")
	local l = bb and bb:FindFirstChild("Title")
	return (l and l:IsA("TextLabel")) and l or nil
end

local function step(now: number)
	for _, player in Players:GetPlayers() do
		local style = player:GetAttribute("TitleStyle")
		if style == "rainbow" or style == "pulse" or style == "flicker" then
			local l = titleLabel(player)
			if l and l.Text ~= "" then
				if style == "rainbow" then
					-- offset per player so a crowd of VIPs doesn't strobe in sync
					l.TextColor3 = Color3.fromHSV((now * RAINBOW_SPEED + (player.UserId % 97) / 97) % 1, 0.8, 1)
				elseif style == "pulse" then
					local base = baseColor[player.UserId]
					if not base or l.TextTransparency == 0 then
						base = l.TextColor3 -- capture the server-stamped color once
						baseColor[player.UserId] = base
					end
					local k = 0.78 + 0.22 * math.sin(now * PULSE_SPEED + player.UserId % 7)
					l.TextColor3 = Color3.new(base.R * k, base.G * k, base.B * k)
					l.TextTransparency = 0.05 -- marks "captured" (see above) without visible change
				elseif style == "flicker" then
					l.TextTransparency = (math.random() < FLICKER_CHANCE) and (0.35 + math.random() * 0.4) or 0
				end
			end
		end
	end
end

function TitleFXController.Start()
	Players.PlayerRemoving:Connect(function(player)
		baseColor[player.UserId] = nil
	end)
	task.spawn(function()
		while true do
			step(os.clock())
			task.wait(TICK)
		end
	end)
	print("[TitleFXController] started (rainbow/pulse/flicker titles)")
end

return TitleFXController
