--!nonstrict
-- TelemetryService.lua — the LAUNCH FUNNEL. A thin, pcall'd wrapper over Roblox's AnalyticsService so
-- the rest of the server can log "what happened" in one line and never crash if the API hiccups.
--
-- What it records (Creator Hub -> Analytics):
--   ONBOARDING funnel (one lifetime ladder per player; the LOBBY logs the lobby steps — keep the step
--     numbers in sync with LobbyServer's LAUNCH.Onboard): joined lobby -> tutorial -> pressed play ->
--     first run -> cleared wave 1 -> reached wave 5 -> first crate -> first level-up -> second run.
--   RUN funnel (one session per player per run): run start -> wave 3 -> 5 -> 10 -> 15 -> 20 -> 30 -> 50.
--   ECONOMY: Coins sources per wave (kills + clear, aggregated — never per kill) and IAP grants.
--   CUSTOM "run_end": value = wave reached, with the world + how it ended.
-- Volume is kept low by design and a per-player / per-server budget drops overflow silently (Roblox
-- throttles AnalyticsService; a dropped analytics event must never cost gameplay).

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config").GameConfig)

local TelemetryService = {}

-- ===== TUNABLES =====
local ENABLED = GameConfig.Analytics ~= false
local PER_PLAYER_PER_MIN = 30   -- events one player may emit per minute (everything above is dropped)
local PER_SERVER_PER_MIN = 110  -- events the whole server may emit per minute (Roblox's cap is ~120)
local CURRENCY = "Coins"        -- the one economy currency we report (in-wave Points are legacy score)

-- The ONBOARDING ladder. Numbers are the funnel step; the lobby logs 1, 2, 3 and 7 with the SAME numbers.
TelemetryService.Onboard = {
	LobbyJoined = 1,
	TutorialDone = 2,
	RunLaunched = 3,
	RunStarted = 4,
	Wave1Cleared = 5,
	Wave5Reached = 6,
	FirstCrate = 7,
	FirstLevelUp = 8,
	SecondRun = 9,
}
local ONBOARD_NAMES = {
	[1] = "lobby_joined", [2] = "tutorial_done", [3] = "run_launched", [4] = "first_run_started",
	[5] = "first_wave_cleared", [6] = "reached_wave_5", [7] = "first_crate", [8] = "first_level_up",
	[9] = "second_run",
}

-- RUN funnel: cleared wave -> step. Step 1 is "run_start" (logged by MatchService.startRunFor).
local RUN_STEPS = { [3] = 2, [5] = 3, [10] = 4, [15] = 5, [20] = 6, [30] = 7, [50] = 8 }

-- ===== STATE =====
local playerBudget: { [number]: { n: number, at: number } } = {}
local serverBudget = { n = 0, at = 0 }
local droppedSinceWarn = 0
local lastWarn = 0

-- Custom-field keys: Roblox wants the enum's .Name ("customField01"..); fall back to the literals so a
-- renamed enum can't break logging.
local FIELD_KEYS = { "customField01", "customField02", "customField03" }
pcall(function()
	FIELD_KEYS[1] = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
	FIELD_KEYS[2] = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
	FIELD_KEYS[3] = Enum.AnalyticsCustomFieldKeys.CustomField03.Name
end)

local function fields(a: any, b: any, c: any): { [string]: string }?
	if a == nil and b == nil and c == nil then
		return nil
	end
	local t = {}
	if a ~= nil then t[FIELD_KEYS[1]] = tostring(a) end
	if b ~= nil then t[FIELD_KEYS[2]] = tostring(b) end
	if c ~= nil then t[FIELD_KEYS[3]] = tostring(c) end
	return t
end

-- Budget check: true = this event may go out. Windows are per minute, reset lazily.
local function allow(player: Player): boolean
	local now = os.clock()
	if now - serverBudget.at >= 60 then
		serverBudget.n, serverBudget.at = 0, now
	end
	local pb = playerBudget[player.UserId]
	if not pb then
		pb = { n = 0, at = now }
		playerBudget[player.UserId] = pb
	elseif now - pb.at >= 60 then
		pb.n, pb.at = 0, now
	end
	if serverBudget.n >= PER_SERVER_PER_MIN or pb.n >= PER_PLAYER_PER_MIN then
		droppedSinceWarn += 1
		if now - lastWarn > 60 then
			lastWarn = now
			warn(("[TelemetryService] dropped %d analytics events (over budget)"):format(droppedSinceWarn))
			droppedSinceWarn = 0
		end
		return false
	end
	serverBudget.n += 1
	pb.n += 1
	return true
end

-- Every call funnels through here: enabled? player still here? budget? then the pcall'd API call.
local function send(player: Player, what: string, fn: () -> ())
	if not ENABLED or typeof(player) ~= "Instance" or not player.Parent then
		return
	end
	if not allow(player) then
		return
	end
	task.spawn(function()
		local ok, err = pcall(fn)
		if not ok then
			warn(("[TelemetryService] %s failed: %s"):format(what, tostring(err)))
		end
	end)
end

-- ===== PUBLIC API =====

-- Onboarding step (see TelemetryService.Onboard). Roblox counts each step once per player, so calling
-- it again for a veteran is harmless — but callers still guard with profile counters to save budget.
function TelemetryService.Onboarding(player: Player, step: number, f1: any)
	local name = ONBOARD_NAMES[step] or ("step_" .. tostring(step))
	send(player, "onboarding " .. name, function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, name, fields(f1))
	end)
end

-- A step of a named funnel. sessionId groups the steps of ONE attempt (one run = one session).
function TelemetryService.Funnel(player: Player, funnel: string, sessionId: string?, step: number, stepName: string, f1: any)
	send(player, "funnel " .. funnel .. "/" .. stepName, function()
		AnalyticsService:LogFunnelStepEvent(player, funnel, sessionId, step, stepName, fields(f1))
	end)
end

-- RUN funnel helper: the step (if any) that clearing `wave` represents; nil = not a milestone.
function TelemetryService.RunStepFor(wave: number): (number?, string?)
	local step = RUN_STEPS[wave]
	if step then
		return step, "wave_" .. tostring(wave)
	end
	return nil, nil
end

-- Coins in or out. flow = "Source" | "Sink"; txType = "Gameplay" | "IAP" | "TimedReward" | "Shop" |
-- "Onboarding" | "ContextualPurchase" (Enum.AnalyticsEconomyTransactionType names). amount > 0.
function TelemetryService.Economy(player: Player, flow: string, amount: number, balance: number, txType: string, sku: string?, f1: any)
	amount = math.floor(tonumber(amount) or 0)
	if amount < 1 then
		return
	end
	balance = math.max(0, math.floor(tonumber(balance) or 0))
	send(player, "economy " .. flow .. "/" .. tostring(sku), function()
		local flowEnum = (flow == "Sink") and Enum.AnalyticsEconomyFlowType.Sink or Enum.AnalyticsEconomyFlowType.Source
		local txEnum = Enum.AnalyticsEconomyTransactionType[txType] or Enum.AnalyticsEconomyTransactionType.Gameplay
		AnalyticsService:LogEconomyEvent(player, flowEnum, CURRENCY, amount, balance, txEnum.Name, sku, fields(f1))
	end)
end

-- Free-form event with a numeric value (+ up to three string fields).
function TelemetryService.Custom(player: Player, name: string, value: number?, f1: any, f2: any, f3: any)
	send(player, "custom " .. name, function()
		AnalyticsService:LogCustomEvent(player, name, value, fields(f1, f2, f3))
	end)
end

-- ===== LIFECYCLE =====
function TelemetryService.Start()
	Players.PlayerRemoving:Connect(function(player)
		playerBudget[player.UserId] = nil
	end)
	print(("[TelemetryService] started (%s)"):format(ENABLED and "AnalyticsService on" or "disabled by GameConfig.Analytics"))
end

return TelemetryService
