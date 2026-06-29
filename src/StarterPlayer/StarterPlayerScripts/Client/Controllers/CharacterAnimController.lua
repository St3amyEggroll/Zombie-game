--!nonstrict
-- CharacterAnimController.lua — player walking/running animations.
--
-- Roblox already animates walking + running by default, so this does NOTHING unless you fill in custom
-- ids in AnimationConfig.Player. When you do, it swaps them into the default "Animate" script so your
-- character uses your animations. Safe/no-op if the ids are blank or the Animate structure isn't found.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local AnimationConfig = require(Config.AnimationConfig)

local CharacterAnimController = {}

local localPlayer = Players.LocalPlayer

-- Map config keys -> the (category, child) nodes under the default R15 Animate script.
local MAP = {
	Idle = { "idle", "Animation1" },
	Walk = { "walk", "WalkAnim" },
	Run = { "run", "RunAnim" },
	Jump = { "jump", "JumpAnim" },
}

local function applyOverrides(character: Model)
	local hasAny = false
	for _, id in AnimationConfig.Player do
		if AnimationConfig.Resolve(id) then
			hasAny = true
			break
		end
	end
	if not hasAny then
		return -- nothing custom to apply; defaults handle walk/run
	end

	local animate = character:WaitForChild("Animate", 10)
	if not animate then
		return
	end
	for key, path in MAP do
		local resolved = AnimationConfig.Resolve(AnimationConfig.Player[key])
		if resolved then
			local category = animate:FindFirstChild(path[1])
			local node = category and category:FindFirstChild(path[2])
			if node and node:IsA("Animation") then
				node.AnimationId = resolved
			end
		end
	end
end

function CharacterAnimController.Start()
	if localPlayer.Character then
		task.spawn(applyOverrides, localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(function(character)
		task.spawn(applyOverrides, character)
	end)
	print("[CharacterAnimController] started")
end

return CharacterAnimController
