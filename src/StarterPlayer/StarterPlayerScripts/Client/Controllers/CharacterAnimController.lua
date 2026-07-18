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
local holdTokens: { [Model]: number } = {} -- generation counter: a newer applyHold cancels older waits
local animCache: { [string]: Animation } = {}
local warnedIds: { [string]: boolean } = {} -- never-loaded assets we've already warned about

local function getAnim(id: string): Animation
	local a = animCache[id]
	if not a then
		a = Instance.new("Animation")
		a.AnimationId = id
		animCache[id] = a
	end
	return a
end

-- ===== PROCEDURAL HOLD FALLBACK ===== (NEW)
-- Roblox only plays animation assets UPLOADED BY THE GAME OWNER — a toolbox/catalog id loads a track
-- that silently never animates. When that happens (or a gun has no Hold id), pose the arms ourselves
-- with shoulder-joint C0 offsets. Animator tracks write Motor6D.Transform, never C0, so movement
-- animations still play on top of this pose. Style per gun: AnimationConfig.HoldStyles.
local PROC_POSES = {
	pistol = { r = 88, l = 12 }, -- gun arm raised, off hand relaxed
	rifle  = { r = 78, l = 62 }, -- both hands up on the gun
	heavy  = { r = 42, l = 42 }, -- low two-handed waist carry
}
local procBase: { [Model]: any } = {} -- [character] = { rs, ls, rsC0, lsC0 } original C0s to restore

local function findMotor(character: Model, names: { string }): Motor6D?
	for _, n in names do
		local j = character:FindFirstChild(n, true)
		if j and j:IsA("Motor6D") then
			return j
		end
	end
	return nil
end

local function clearProcPose(character: Model)
	local pb = procBase[character]
	if not pb then
		return
	end
	if pb.rs and pb.rs.Parent then
		pb.rs.C0 = pb.rsC0
	end
	if pb.ls and pb.ls.Parent then
		pb.ls.C0 = pb.lsC0
	end
	procBase[character] = nil
end

local function applyProcPose(character: Model)
	local weaponId = character:GetAttribute("HoldWeaponId")
	local style = (typeof(weaponId) == "string") and AnimationConfig.HoldStyles[weaponId] or nil
	if not style then
		clearProcPose(character)
		return
	end
	local pose = PROC_POSES[style] or PROC_POSES.rifle
	local pb = procBase[character]
	if not pb then -- capture the untouched C0s ONCE per character (restored by clearProcPose)
		local rs = findMotor(character, { "Right Shoulder", "RightShoulder" })
		local ls = findMotor(character, { "Left Shoulder", "LeftShoulder" })
		if not rs and not ls then
			return
		end
		pb = { rs = rs, ls = ls, rsC0 = rs and rs.C0, lsC0 = ls and ls.C0 }
		procBase[character] = pb
	end
	-- R6 shoulders: joint-space Z = the forward/back swing axis (mirrored). R15: X is the swing axis.
	local r6 = character:FindFirstChild("Torso") ~= nil
	if pb.rs and pb.rs.Parent then
		pb.rs.C0 = pb.rsC0 * (r6 and CFrame.Angles(0, 0, math.rad(pose.r)) or CFrame.Angles(-math.rad(pose.r), 0, 0))
	end
	if pb.ls and pb.ls.Parent then
		pb.ls.C0 = pb.lsC0 * (r6 and CFrame.Angles(0, 0, -math.rad(pose.l)) or CFrame.Angles(-math.rad(pose.l), 0, 0))
	end
end

local function applyHold(character: Model)
	local token = (holdTokens[character] or 0) + 1
	holdTokens[character] = token
	local prev = holdTracks[character]
	if prev then
		prev:Stop(0) -- instant swap (no cross-fade) so switching guns changes the pose immediately
		holdTracks[character] = nil
	end
	local id = character:GetAttribute("HoldAnimId")
	if typeof(id) ~= "string" or id == "" then
		applyProcPose(character) -- no uploaded pose for this gun — procedural stance (or clear if unarmed)
		return
	end
	-- INSTANT stance: the procedural pose needs no Animator, so it shows the moment you spawn/equip.
	-- The real uploaded animation takes over (clearProcPose) as soon as its track confirms playing.
	applyProcPose(character)
	local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not hum or holdTokens[character] ~= token then
		return
	end
	-- CHANGED: play ONLY on the SERVER's Animator (attribute-tagged by WeaponModelService). The client's
	-- own Animate script can make a duplicate Animator first; a track loaded into that one dies whenever
	-- the server's replica arrives — even SECONDS later on a heavy load-in — which is how the pose
	-- silently turned back into the default walk. The tagged replica can never be superseded.
	local function serverAnimator(): Animator?
		for _, ch in hum:GetChildren() do
			if ch:IsA("Animator") and ch:GetAttribute("ServerAnimator") == true then
				return ch
			end
		end
		return nil
	end
	local animator = serverAnimator()
	if not animator then
		local t0 = os.clock()
		repeat
			task.wait(0.1)
			animator = serverAnimator()
		until animator or os.clock() - t0 > 8 or holdTokens[character] ~= token
		if holdTokens[character] ~= token then
			return -- a newer equip superseded this one while we waited
		end
		if not animator then
			-- Server replica never showed (shouldn't happen) — last resort: any Animator, else make one.
			animator = hum:FindFirstChildOfClass("Animator")
			if not animator then
				animator = Instance.new("Animator")
				animator.Parent = hum
			end
		end
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(getAnim(id))
	end)
	if not ok or not track then
		warn("[CharacterAnimController] hold animation failed to load: " .. tostring(id))
		applyProcPose(character) -- NEW: still show a stance
		return
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0) -- instant (asset is preloaded at Start, so the pose appears immediately)
	holdTracks[character] = track

	-- Setting Looped before the asset loads can be reset to the animation's baked value (play-once), so
	-- re-assert it once the asset has actually loaded (Length > 0) — keeps the pose held indefinitely.
	-- CHANGED: Length staying 0 past the wait = the asset NEVER loaded (almost always: the animation
	-- isn't owned by the game owner, which Roblox silently refuses to play) — procedural stance instead.
	task.spawn(function()
		local t0 = os.clock()
		while track.Length == 0 and os.clock() - t0 < 3 and holdTracks[character] == track do
			task.wait()
		end
		if holdTracks[character] ~= track then
			return -- a newer equip superseded this one
		end
		if track.Length > 0 then
			clearProcPose(character) -- the real uploaded animation owns the pose
			track.Looped = true
			if not track.IsPlaying then
				track:Play(0)
			end
		else
			if not warnedIds[id] then -- once per asset, not per re-assert
				warnedIds[id] = true
				warn(("[CharacterAnimController] hold animation %s never loaded — is it uploaded by the GAME OWNER? Using the procedural stance."):format(id))
			end
			track:Stop(0)
			applyProcPose(character)
		end
	end)
end

local function watchCharacter(character: Model)
	task.spawn(applyHold, character) -- apply whatever's already stamped (late joiners see current poses)
	-- (The old timed re-asserts are gone: applyHold now waits for the SERVER's tagged Animator, which
	-- can't be superseded, and the procedural stance covers the wait — nothing left to rescue.)
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
			holdTokens[character] = nil
			procBase[character] = nil -- joints died with the character; nothing to restore
		end
	end)
	-- Diagnostic: if the server never stamps ANY hold attribute, the problem is upstream of playback
	-- (attach/equip never ran) — say so instead of failing silently.
	task.delay(6, function()
		if character.Parent and character:GetAttribute("HoldAnimId") == nil and character:GetAttribute("HoldWeaponId") == nil then
			warn(("[CharacterAnimController] %s has no hold attributes after 6s — the server never ran attach/playHold"):format(character.Name))
		end
	end)
end

local function watchPlayer(pl: Player)
	if pl.Character then
		watchCharacter(pl.Character)
	end
	pl.CharacterAdded:Connect(watchCharacter)
end

-- Preload every configured hold animation so the FIRST time a gun is equipped the pose is instant (without
-- this, LoadAnimation fetches the asset over the network on first use — the ~1s "it takes a second to load").
local function preloadHolds()
	local ContentProvider = game:GetService("ContentProvider")
	local anims = {}
	for _, cfg in AnimationConfig.Weapons do
		local id = cfg and AnimationConfig.Resolve(cfg.Hold)
		if id then
			table.insert(anims, getAnim(id)) -- reuses the same cached Animation instances applyHold plays
		end
	end
	if #anims > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(anims)
		end)
	end
end

function CharacterAnimController.Start()
	task.spawn(preloadHolds)
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
