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
	MusicNightmare = S("88275367596456", 0.55, 0, 1, 1, true), -- Nightmare-difficulty combat loop
	MusicBloodMoon = S("74581933230860", 0.55, 0, 1, 1, true), -- BLOOD MOON wave (event roller) — outranks combat, yields to boss

	-- ===== GUN FIRE ===== (slot name = "Fire_" .. weaponId)
	Fire_pistol    = S("103589268560856", 0.6, 160, 0.97, 1.03),  -- [pistol gunshot]
	Fire_smg       = S("115515020371003", 0.5, 150, 0.97, 1.03),  -- [smg gunshot single]
	Fire_shotgun   = S("122727185777303", 0.7, 180, 0.96, 1.02),  -- [shotgun blast]
	Fire_minigun   = S("130050001949841", 0.45, 170, 0.97, 1.03), -- [minigun single shot] (played per bullet)
	Fire_raygun    = S("118709034685445", 0.6, 170, 0.95, 1.05),  -- [laser blaster zap]
	Fire_revolver  = S("", 0.65, 170, 0.97, 1.03), -- [revolver shot]
	Fire_crossbow  = S("111893570400598", 0.6, 120, 0.97, 1.03),  -- [crossbow shot / bow release]
	Fire_freezeray = S("5536159516", 0.5, 150, 0.97, 1.03),  -- [ice ray / frost beam zap]
	Fire_ak47      = S("123111065763587", 0.6, 170, 0.97, 1.03),  -- [ak47 gunshot]
	Fire_tommygun  = S("105103592803331", 0.55, 160, 0.97, 1.03), -- [tommy gun shot]
	Fire_plasma    = S("117910836796315", 0.6, 170, 0.95, 1.05),  -- [plasma rifle shot]
	Fire_sniper    = S("138854039966754", 0.75, 220, 0.98, 1.02), -- [sniper shot]
	Fire_honeybadger = S("", 0.55, 160, 0.97, 1.03), -- [suppressed rifle shot]
	Fire_m4        = S("", 0.6, 170, 0.97, 1.03),  -- [m4 gunshot]
	Fire_p90       = S("", 0.55, 160, 0.97, 1.03), -- [p90 gunshot]
	Fire_flamethrower = S("98379420278014", 0.55, 120, 0.97, 1.03), -- [flamethrower whoosh, ~1s]
	Fire_rocket    = S("", 0.7, 200, 0.97, 1.03),  -- [rocket launch]
	GunEquip       = S("93254619475991", 0.55, 0, 0.98, 1.02), -- switching to / spawning with a gun (2D, local)
	ZombieFrozen   = S("103076518786222", 0.6, 110, 1, 1),     -- Freeze Ray encases a zombie in ice (~4s clip)
	IceBreak       = S("126045403165222", 0.6, 110, 0.97, 1.03), -- the ice breaks (freeze wears off)
	FrostShatter   = S("126045403165222", 0.75, 140, 0.95, 1.05), -- frozen zombie dies -> frost nova [glass ice shatter]

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
	RareScream        = S("134322721932099", 0.7, 180, 0.95, 1.05), -- a RARE (special) zombie spawns — its entrance scream

	-- ===== PLAYER (2D) =====
	PlayerHurt     = S("", 0.6, 0, 0.95, 1.05),    -- you took damage [hurt grunt]
	LowHealthLoop  = S("", 0.5, 0, 1, 1, true),    -- under 35% HP [heartbeat loop]
	PlayerDeath    = S("", 0.7, 0, 0.9, 1.05),     -- you died → spectate [death sting]

	-- ===== WAVES / MATCH (2D stingers) =====
	WaveStart          = S("137884319678560", 0.6, 0, 1, 1),      -- round start (wave 1) [horde horn / air raid sting]
	WaveBell           = S("114277108838919", 0.6, 0, 1, 1),      -- bell at the start of EVERY wave
	WaveCleared        = S("", 0.6, 0, 1, 1),      -- wave done [success sting]
	NewEnemySting      = S("", 0.65, 0, 1, 1),     -- first-ever enemy type [danger sting]
	BossDefeatedFanfare = S("", 0.75, 0, 1, 1),    -- [victory fanfare]
	CountdownTick      = S("", 0.5, 0, 1, 1),      -- pre-run countdown [clock tick]
	CountdownGo        = S("", 0.7, 0, 1, 1),      -- countdown hits zero [buzzer / GO]
	WheelSpin          = S("9120657420", 0.6, 0, 1, 1),   -- the EVENT ROLLER's flashing (~1.5s clip, re-played across the roll)
	WheelLock          = S("79662193870612", 0.7, 0, 1, 1), -- the roller LOCKS next wave's fate

	-- ===== PICKUPS / PROGRESSION (2D) =====
	CaseDrop       = S("", 0.65, 0, 1, 1),         -- case collected [reward chest]
	GunBought      = S("", 0.7, 0, 1, 1),          -- mid-run gun purchase [cha-ching / unlock]

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
