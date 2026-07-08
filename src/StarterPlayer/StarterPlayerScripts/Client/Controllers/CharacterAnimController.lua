--!nonstrict
-- CharacterAnimController.lua — player animations:
--   * walk/run overrides: fill ids in AnimationConfig.Player and they swap into the default Animate
--     script (no-op while blank — Roblox's defaults already animate movement).
--   * WEAPON HOLD POSES: the server stamps character:SetAttribute("HoldAnimId", ...) on equip
--     (WeaponModelService); THIS controller plays that track locally on every character it sees.
--     Local playback needs no replication rules, so the pose shows for everyone, reliably.

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

-- ===== WEAPON HOLD POSES (attribute-driven, played locally for EVERY character) =====
local holdTracks: { [Model]: AnimationTrack } = {}
local animCache: { [string]: Animation } = {}

local function getAnim(id: string): Animation
	local a = animCache[id]
	if not a then
		a = Instance.new("Animation")
		a.AnimationId = id
		animCache[id] = a
	end
	return a
end

local function applyHold(character: Model)
	local prev = holdTracks[character]
	if prev then
		prev:Stop(0.1)
		holdTracks[character] = nil
	end
	local id = character:GetAttribute("HoldAnimId")
	if typeof(id) ~= "string" or id == "" then
		return
	end
	local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not hum then
		return
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(getAnim(id))
	end)
	if not ok or not track then
		warn("[CharacterAnimController] hold animation failed to load: " .. tostring(id))
		return
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.1)
	holdTracks[character] = track

	-- KEEP THE POSE HELD. Two safeguards, because setting Looped before the asset loads can be reset to the
	-- animation's baked (non-looped) value — which makes it play ONCE and stop:
	--   1) re-assert Looped once the asset has actually loaded (Length > 0), and
	--   2) if the track ever Stops while it's still the active pose, restart it.
	task.spawn(function()
		local t0 = os.clock()
		while track.Length == 0 and os.clock() - t0 < 3 and holdTracks[character] == track do
			task.wait()
		end
		if holdTracks[character] == track then
			track.Looped = true
			if not track.IsPlaying then
				track:Play(0.1)
			end
		end
	end)
	track.Stopped:Connect(function()
		if holdTracks[character] == track then -- still the equipped pose → keep holding it
			track.Looped = true
			track:Play(0.1)
		end
	end)
	print(("[CharacterAnimController] playing hold %s on %s"):format(id, character.Name))
end

local function watchCharacter(character: Model)
	task.spawn(applyHold, character) -- apply whatever's already stamped (late joiners see current poses)
	character:GetAttributeChangedSignal("HoldAnimId"):Connect(function()
		task.spawn(applyHold, character)
	end)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			local t = holdTracks[character]
			if t then
				t:Stop()
			end
			holdTracks[character] = nil
		end
	end)
end

local function watchPlayer(pl: Player)
	if pl.Character then
		watchCharacter(pl.Character)
	end
	pl.CharacterAdded:Connect(watchCharacter)
end

function CharacterAnimController.Start()
	if localPlayer.Character then
		task.spawn(applyOverrides, localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(function(character)
		task.spawn(applyOverrides, character)
	end)

	-- Hold poses: watch every character in the server (local player included).
	for _, pl in Players:GetPlayers() do
		watchPlayer(pl)
	end
	Players.PlayerAdded:Connect(watchPlayer)

	print("[CharacterAnimController] started (movement overrides + hold poses)")
end

return CharacterAnimController
