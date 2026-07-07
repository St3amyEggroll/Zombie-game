--!strict
-- SoundConfig.lua — every sound in the game lives HERE (CLAUDE.md §5: data-driven; code never hardcodes
-- an asset id). Each slot is `S(id, vol, dist, pitchLo, pitchHi, loop)` — paste a Roblox asset id into the
-- first argument ("rbxassetid://123" or just "123"). A BLANK id means "no sound yet": playback silently
-- skips it, and zombie voice slots FALL BACK to the `normal` set (see Voice + the fallback rules in
-- SoundController), so you can fill this in gradually and the game never errors.
--
-- vol      = base volume 0..1 (before the player's volume sliders)
-- dist     = 3D rolloff max distance in studs (only used for positional sounds)
-- pitchLo/pitchHi = random PlaybackSpeed range per play (1,1 = no variation)
-- loop     = true for looping tracks (music, alarms, heartbeat)

-- `id` may be ONE id ("123") or a LIST of ids ({"123", "456"}) — lists pick a random variant per play.
local function S(id: string | { string }, vol: number, dist: number, pitchLo: number, pitchHi: number, loop: boolean?)
	return { id = id, vol = vol, dist = dist, pitchLo = pitchLo, pitchHi = pitchHi, loop = loop or false }
end

local SoundConfig: { [string]: any } = {}

-- ===== TUNABLES ===== default slider positions for a brand-new player (0..1)
SoundConfig.DefaultVolumes = { master = 1, music = 0.6, sfx = 1 }
SoundConfig.MusicFadeSeconds = 1.4     -- crossfade time when the music state changes
SoundConfig.GrowlMinGap = 0.35         -- server: min seconds between ambient growl broadcasts (global)
SoundConfig.LowHealthRatio = 0.35      -- heartbeat loop kicks in below this fraction of max HP

-- =====================================================================================================
-- SOUND SLOTS — paste ids below. Names in [brackets] in the comments are what to search the Toolbox for.
-- =====================================================================================================
SoundConfig.Sounds = {
	-- ===== MUSIC (looping tracks) =====
	MusicCalm      = S("", 0.45, 0, 1, 1, true),   -- between waves / countdown [dark ambient loop]
	MusicCombat    = S("140604599195788", 0.5,  0, 1, 1, true),   -- while a wave is active [action/horror combat loop]
	MusicBoss      = S("", 0.55, 0, 1, 1, true),   -- while a boss is alive [epic boss battle loop]

	-- ===== GUN FIRE ===== (slot name = "Fire_" .. weaponId)
	Fire_pistol    = S("103589268560856", 0.6, 160, 0.97, 1.03),  -- [pistol gunshot]
	Fire_smg       = S("115515020371003", 0.5, 150, 0.97, 1.03),  -- [smg gunshot single]
	Fire_shotgun   = S("122727185777303", 0.7, 180, 0.96, 1.02),  -- [shotgun blast]
	Fire_minigun   = S("130050001949841", 0.45, 170, 0.97, 1.03), -- [minigun single shot] (played per bullet)
	Fire_raygun    = S("118709034685445", 0.6, 170, 0.95, 1.05),  -- [laser blaster zap]
	Fire_revolver  = S("", 0.65, 170, 0.97, 1.03), -- [revolver shot]
	Fire_crossbow  = S("", 0.6, 120, 0.97, 1.03),  -- [crossbow shot / bow release]
	Fire_freezeray = S("", 0.5, 150, 0.97, 1.03),  -- [ice ray / frost beam zap]
	FrostShatter   = S("", 0.75, 140, 0.95, 1.05), -- chilled zombie explodes [glass ice shatter]

	-- ===== COMBAT FEEDBACK (2D, local player only) =====
	Hitmarker      = S("80826043767749", 0.5, 0, 0.97, 1.03),    -- [hitmarker tick]
	KillConfirm    = S("130456049552264", 0.55, 0, 0.98, 1.02),   -- [kill confirm thud]
	Explosion      = S("139210252225248", 0.9, 220, 0.95, 1.05),  -- bomb zombie blast [explosion]
	BombFuse       = S("82308469908666", 0.8, 90,  1, 1),  -- 5s countdown beeps; the Explosion CUTS IT OFF at detonation (SoundController)

	-- ===== ZOMBIE VOICES ===== Growl = ambient idle; Attack = bite lands; Death = kill.
	-- Blank per-type slots FALL BACK to the _normal set (pitched by type), so only _normal is required.
	Growl_normal      = S({ "127809799844346", "129880060515122" }, 0.55, 70, 0.9, 1.1), -- random growl pair
	Attack_normal     = S("", 0.6, 80,  0.92, 1.08), -- [zombie bite / attack]
	Death_normal      = S("", 0.6, 90,  0.9, 1.1),   -- [zombie death groan]
	Growl_runner      = S("106124726539726", 0.55, 70, 1.05, 1.2),  -- speedy: the zombie scream
	Attack_runner     = S("", 0.6, 80,  1.05, 1.15),
	Death_runner      = S("", 0.6, 90,  1.05, 1.15),
	Growl_leaper      = S("", 0.55, 70, 0.95, 1.1),  -- [zombie snarl]
	Attack_leaper     = S("", 0.6, 80,  0.95, 1.1),  -- pounce bite [pounce roar]
	Death_leaper      = S("", 0.6, 90,  0.95, 1.1),
	Growl_tank        = S("133022591851008", 0.7, 90,  0.7, 0.85),  -- all tanks: the deep growl
	Attack_tank       = S("", 0.7, 100, 0.7, 0.85),  -- [heavy smash hit]
	Death_tank        = S("", 0.7, 110, 0.7, 0.85),  -- [large monster death]
	Growl_ghost       = S("", 0.5, 80,  0.95, 1.1),  -- [ghostly wail]
	Attack_ghost      = S("", 0.6, 80,  0.95, 1.1),
	Death_ghost       = S("", 0.6, 90,  0.95, 1.1),
	Growl_bomb        = S("", 0.6, 70,  1.0, 1.1),   -- frantic ticking gurgle [zombie gurgle]
	Growl_boss        = S("", 0.8, 130, 0.75, 0.9),  -- [boss monster growl]
	Attack_boss       = S("", 0.8, 130, 0.75, 0.9),
	Death_boss        = S("", 0.85, 160, 0.75, 0.9), -- [monster death roar]
	Roar_boss         = S("109528442570780", 0.9, 200, 0.9, 1.0),   -- boss ENTRANCE roar (once — ambient boss growls are muted)
	Growl_lumberjack  = S("", 0.8, 130, 0.7, 0.85),
	Attack_lumberjack = S("", 0.8, 130, 0.7, 0.85),  -- [axe swing hit]
	Death_lumberjack  = S("", 0.85, 160, 0.7, 0.85),
	Roar_lumberjack   = S("", 0.9, 200, 0.85, 0.95),
	Growl_necromancer = S("", 0.8, 130, 0.9, 1.0),   -- [evil chant murmur]
	Attack_necromancer = S("", 0.8, 130, 0.9, 1.0),
	Death_necromancer = S("", 0.85, 160, 0.9, 1.0),  -- [dark magic death]
	Roar_necromancer  = S("", 0.9, 200, 0.9, 1.0),   -- [evil laugh]
	SummonCast        = S("", 0.75, 140, 0.95, 1.05), -- necromancer raises adds [dark magic cast]

	-- ===== PLAYER (2D) =====
	PlayerHurt     = S("", 0.6, 0, 0.95, 1.05),    -- you took damage [hurt grunt]
	LowHealthLoop  = S("", 0.5, 0, 1, 1, true),    -- under 35% HP [heartbeat loop]
	DownedAlarm    = S("", 0.5, 0, 1, 1, true),    -- you are downed [alarm loop / flatline]
	ReviveComplete = S("", 0.7, 0, 1, 1),          -- you got back up [revive chime]

	-- ===== WAVES / MATCH (2D stingers) =====
	WaveStart          = S("137884319678560", 0.6, 0, 1, 1),      -- new wave [horde horn / air raid sting]
	WaveCleared        = S("", 0.6, 0, 1, 1),      -- wave done [success sting]
	FlawlessJingle     = S("", 0.7, 0, 1, 1),      -- flawless wave bonus [triumphant jingle]
	NewEnemySting      = S("", 0.65, 0, 1, 1),     -- first-ever enemy type [danger sting]
	BossDefeatedFanfare = S("", 0.75, 0, 1, 1),    -- [victory fanfare]
	CountdownTick      = S("", 0.5, 0, 1, 1),      -- pre-run countdown [clock tick]
	CountdownGo        = S("", 0.7, 0, 1, 1),      -- countdown hits zero [buzzer / GO]

	-- ===== PICKUPS / PROGRESSION (2D) =====
	PotionDrink    = S("", 0.65, 0, 0.98, 1.02),   -- [potion gulp]
	PotionExpire   = S("", 0.5, 0, 1, 1),          -- buff ran out [power down]
	PotionDrop     = S("", 0.6, 0, 1, 1),          -- elite dropped one [item drop sparkle]
	CaseDrop       = S("", 0.65, 0, 1, 1),         -- case collected [reward chest]
	LevelUp        = S("", 0.7, 0, 1, 1),          -- run level up (buff draft opens) [level up]
	BuffPick       = S("", 0.6, 0, 1, 1),          -- buff chosen [card select]
	StreakStinger  = S("", 0.55, 0, 1, 1),         -- killstreak (pitch rises with streak) [combo hit]

	-- ===== TRAPS =====
	TrapTrigger    = S("", 0.7, 120, 0.97, 1.03),  -- [electric zap / fire whoosh]

	-- ===== UI (2D) =====
	UiClick        = S("133915937837646", 0.4, 0, 0.98, 1.02),    -- any button
	UiOpen         = S("8968249401", 0.45, 0, 1, 1),              -- panel opens
	UiClose        = S("74657965144290", 0.45, 0, 1, 1),          -- panel closes
	UiError        = S("87519554692663", 0.5, 0, 1, 1),           -- can't afford / not allowed
}

-- ===== ZOMBIE VOICE MAP ===== typeId -> voice class (which Growl_*/Attack_*/Death_* set it uses).
SoundConfig.Voice = {
	default = "normal", lead = "normal",
	speedy = "runner",
	leaper = "leaper",
	tank = "tank", speedytank = "tank", leapertank = "tank", leadtank = "tank",
	ghost = "ghost",
	bombzombie = "bomb",
	boss = "boss", lumberjack = "lumberjack", necromancer = "necromancer",
}

-- Normalize a pasted id: accepts "123456" or "rbxassetid://123456"; "" stays "".
function SoundConfig.AssetId(raw: string): string
	if raw == "" then
		return ""
	end
	if string.find(raw, "://") then
		return raw
	end
	return "rbxassetid://" .. raw
end

return SoundConfig
