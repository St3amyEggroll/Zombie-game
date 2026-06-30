-- init.client.lua — client bootstrap. Auto-discovers every Controller in Controllers/ and Start()s
-- it. Controllers are independent, so each starts in its own thread; one erroring can't block the
-- others. Phase 0 ships no controllers yet — they arrive with their phases (Input/Camera in Phase 1,
-- HUD/BuyPrompt in Phase 3, etc.) and will be picked up automatically.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Make sure shared modules have replicated before any controller requires them.
local Shared = ReplicatedStorage:WaitForChild("Shared")
ReplicatedStorage:WaitForChild("Remotes")

local Places = require(Shared:WaitForChild("Config"):WaitForChild("Places"))

-- In the LIVE lobby place, run ONLY the lobby UI (no crosshair/HUD/combat controllers). Everywhere else —
-- the game place, or Studio testing either place — run all controllers; LobbyController self-gates so it
-- stays dormant in the live game place.
local liveLobby = Places.IsLobby and not RunService:IsStudio()

local localPlayer = Players.LocalPlayer

local controllersFolder = script:FindFirstChild("Controllers")
if not controllersFolder then
	print("[client] no Controllers/ yet — nothing to start (Phase 0)")
	return
end

local function startController(moduleScript: ModuleScript)
	local ok, controller = pcall(require, moduleScript)
	if not ok then
		warn(("[client] failed to require %s: %s"):format(moduleScript.Name, tostring(controller)))
		return
	end
	if type(controller) ~= "table" or type(controller.Start) ~= "function" then
		return
	end
	task.spawn(function()
		local sOk, err = pcall(controller.Start)
		if not sOk then
			warn(("[client] %s.Start() errored: %s"):format(moduleScript.Name, tostring(err)))
		end
	end)
end

for _, module in controllersFolder:GetChildren() do
	if module:IsA("ModuleScript") then
		if (not liveLobby) or module.Name == "LobbyController" then
			startController(module)
		end
	end
end

print(("[client] controllers started for %s"):format(localPlayer.Name))
