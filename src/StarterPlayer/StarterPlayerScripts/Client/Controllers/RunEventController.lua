--!nonstrict
-- RunEventController.lua — client side of the run's SURPRISES:
--   • RunEvent "announce" → the HUD announcement lane (event names ride the same queue as boss banners).
--   • RunEvent "fog"      → thick Lighting fog rolls in for a while, then burns back off (local FX only).
-- (The EXTRACTION card lived here until the continuous-horde pivot — the run has no cash-out windows
-- anymore, so the card, its remotes and its countdown are gone. PowerDraftController owns the run's
-- recurring choice now.)

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)

local HUDController = require(script.Parent.HUDController)

local RunEventController = {}

-- ===== TUNABLES =====
local FOG_END = 90            -- how close the fog closes in (studs)
local FOG_TWEEN = 3           -- seconds to roll in / burn off
local ANNOUNCE_SECONDS = 4

local COLORS = {
	gold = Color3.fromRGB(240, 196, 82),
	green = Color3.fromRGB(124, 219, 35),
	red = Color3.fromRGB(255, 96, 34),
	grey = Color3.fromRGB(180, 186, 168),
}

-- ===== FOG =====
local fogToken = 0
local function rollFog(seconds: number)
	fogToken += 1
	local myTok = fogToken
	local oldEnd, oldStart = Lighting.FogEnd, Lighting.FogStart
	local oldColor = Lighting.FogColor
	Lighting.FogColor = Color3.fromRGB(120, 128, 112)
	TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = FOG_END, FogStart = 12 }):Play()
	task.delay(math.max(1, seconds), function()
		if myTok ~= fogToken then
			return -- a newer fog event owns the Lighting now
		end
		local out = TweenService:Create(Lighting, TweenInfo.new(FOG_TWEEN), { FogEnd = oldEnd, FogStart = oldStart })
		out.Completed:Once(function()
			if myTok == fogToken then
				Lighting.FogColor = oldColor
			end
		end)
		out:Play()
	end)
end

function RunEventController.Start()
	Remotes.Get("RunEvent").OnClientEvent:Connect(function(kind, payload)
		payload = typeof(payload) == "table" and payload or {}
		if kind == "announce" and typeof(payload.text) == "string" then
			HUDController.Announce(payload.text, COLORS[payload.color] or COLORS.gold, ANNOUNCE_SECONDS)
		elseif kind == "fog" then
			rollFog(tonumber(payload.seconds) or 25)
		end
	end)

	print("[RunEventController] started")
end

return RunEventController
