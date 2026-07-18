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

-- ===== PROCEDURAL HOLD FALLBACK =====
-- Roblox only plays animation assets UPLOADED BY THE GAME OWNER — a toolbox/catalog id loads a track
-- that silently never animates. When that happens (or a gun has no Hold id), pose the arms ourselves.
-- CHANGED: the pose is now a PER-FRAME arm LOCK on Motor6D.Transform (written after the animation
-- step, same technique as the zombies) — a static C0 offset raised the arms but the walk animation
-- still SWUNG them around the raised position ("swinging the minigun while walking").
local PROC_POSES = {
	pistol = { r = 88, l = 12 }, -- gun arm raised, off hand relaxed
	rifle  = { r = 78, l = 62 }, -- both hands up on the gun
	heavy  = { r = 42, l = 42 }, -- low two-handed waist carry
}
local procActive: { [Model]: any } = {} -- [character] = { rs, ls, r6, pose } — written every frame

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
	local e = procActive[character]
	procActive[character] = nil
	if e then -- hand the joints back to the Animator cleanly (it rewrites Transform next frame anyway)
		if e.rs and e.rs.Parent then
			e.rs.Transform = CFrame.identity
		end
		if e.ls and e.ls.Parent then
			e.ls.Transform = CFrame.identity
		end
	end
end

local function applyProcPose(character: Model)
	local weaponId = character:GetAttribute("HoldWeaponId")
	local style = (typeof(weaponId) == "string") and AnimationConfig.HoldStyles[weaponId] or nil
	if not style then
		clearProcPose(character)
		return
	end
	local rs = findMotor(character, { "Right Shoulder", "RightShoulder" })
	local ls = findMotor(character, { "Left Shoulder", "LeftShoulder" })
	if not rs and not ls then
		return
	end
	procActive[character] = {
		rs = rs,
		ls = ls,
		r6 = character:FindFirstChild("Torso") ~= nil,
		pose = PROC_POSES[style] or PROC_POSES.rifle,
	}
end

-- The per-frame lock: runs AFTER the engine's animation step (RenderPriority.Character + 1), so it
-- overwrites whatever arm swing the walk/idle tracks just wrote. Legs are untouched — walking still
-- looks like walking, just with the arms pinned on the gun.
local function stepProcPoses()
	for character, e in procActive do
		if not character.Parent then
			procActive[character] = nil
			continue
		end
		local p = e.pose
		-- R6 shoulders: joint-space Z = the forward/back swing axis (mirrored). R15: X is the axis.
		if e.rs and e.rs.Parent then
			e.rs.Transform = e.r6 and CFrame.Angles(0, 0, math.rad(p.r)) or CFrame.Angles(-math.rad(p.r), 0, 0)
		end
		if e.ls and e.ls.Parent then
			e.ls.Transform = e.r6 and CFrame.Angles(0, 0, -math.rad(p.l)) or CFrame.Angles(-math.rad(p.l), 0, 0)
		end
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
	-- CHANGED BACK: play on the humanoid's ACTIVE Animator (the first one — the engine animates through
	-- it on this client; the server's replica is inert here, tracks on it play invisibly). The old
	-- "pose dies / turns into walking" bug was never the Animator: it's the PRIORITY reset below.
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		local t0 = os.clock()
		repeat
			task.wait(0.1)
			animator = hum:FindFirstChildOfClass("Animator")
		until animator or os.clock() - t0 > 5 or holdTokens[character] ~= token
		if holdTokens[character] ~= token then
			return -- a newer equip superseded this one while we waited
		end
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
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

	-- Properties set before the asset loads get RESET to the animation's baked values when it finishes
	-- loading — Looped AND Priority. A hold pose baked at Core priority then loses the arms to the walk
	-- animation as soon as you move (the "turns into the walking animation" bug; after a gun switch the
	-- asset was already cached, so the pre-Play values stuck and it looked fixed). Re-assert BOTH once
	-- the asset has actually loaded (Length > 0).
	-- Length staying 0 past the wait = the asset NEVER loaded (almost always: the animation isn't owned
	-- by the game owner, which Roblox silently refuses to play) — procedural stance instead.
	task.spawn(function()
		local t0 = os.clock()
		while track.Length == 0 and os.clock() - t0 < 3 and holdTracks[character] == track do
			task.wait()
		end
		if holdTracks[character] ~= track then
			return -- a newer equip superseded this one
		end
		if track.Length > 0 then
			track.Priority = Enum.AnimationPriority.Action -- the load reset this to the baked value
			track.Looped = true
			if not track.IsPlaying then
				track:Play(0)
			end
			clearProcPose(character) -- the real uploaded animation owns the pose now
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
			procActive[character] = nil -- joints died with the character; stop writing them
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
	-- Procedural-stance arm lock: after the animation step each frame, so it beats the walk swing.
	local RunService = game:GetService("RunService")
	RunService:BindToRenderStep("HoldProcPose", Enum.RenderPriority.Character.Value + 1, stepProcPoses)
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
