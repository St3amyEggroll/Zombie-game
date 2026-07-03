--!nonstrict
-- SoundFXService.lua — the server's tiny sound horn. Services call `Emit(name, position?, maxDist?)` and
-- every client in range gets a SoundEvent; the CLIENT (SoundController) owns all actual playback, ids,
-- volumes, and fallbacks. Also owns the SetSoundSettings remote (volume sliders -> DataService.settings.vol).
--
-- Positional emits are distance-filtered here so 200 growling zombies don't spam every client with events
-- they'd never hear anyway.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Modules.Remotes)

local DataService = require(script.Parent.DataService)
local SecurityService = require(script.Parent.SecurityService)

local SoundFXService = {}

-- ===== TUNABLES =====
local DEFAULT_MAX_DIST = 140  -- studs: positional emits only reach players within this (×1.25 slack)

-- Broadcast a named sound. position = nil -> 2D for everyone; position set -> 3D, distance-filtered.
function SoundFXService.Emit(name: string, position: Vector3?, maxDist: number?)
	local remote = Remotes.Get("SoundEvent")
	if not position then
		remote:FireAllClients(name, nil)
		return
	end
	local reach = (maxDist or DEFAULT_MAX_DIST) * 1.25
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - position).Magnitude <= reach then
			remote:FireClient(player, name, position)
		end
	end
end

function SoundFXService.Start()
	-- Volume sliders. Validated + rate-limited like every other remote (CLAUDE.md §14).
	Remotes.Get("SetSoundSettings").OnServerEvent:Connect(function(player, vol)
		if not SecurityService.Allow(player, "Settings") then
			return
		end
		if typeof(vol) ~= "table" then
			return
		end
		local m, mu, s = tonumber(vol.master), tonumber(vol.music), tonumber(vol.sfx)
		if not m or not mu or not s or m ~= m or mu ~= mu or s ~= s then
			return
		end
		DataService.SetSetting(player, "vol", {
			master = math.clamp(m, 0, 1),
			music = math.clamp(mu, 0, 1),
			sfx = math.clamp(s, 0, 1),
		})
	end)
	print("[SoundFXService] started")
end

return SoundFXService
