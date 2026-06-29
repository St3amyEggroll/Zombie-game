--!strict
-- MysteryBoxConfig.lua — the gamble. Spend points, roll a random weapon.
-- Reuse the case-opening roll animation + juice here. Weights are RELATIVE.

local MysteryBoxConfig = {}

MysteryBoxConfig.Cost = 950

-- ===== WEAPON POOL (weighted) ===== rare/strong = low weight
-- raygun is the low-weight "wonder weapon" jackpot pull.
MysteryBoxConfig.Pool = {
	smg     = 100,
	shotgun = 80,
	rifle   = 45,
	lmg     = 20,
	raygun  = 3,   -- jackpot
}

-- ===== ROLL ANIMATION (the roller feel) =====
MysteryBoxConfig.SpinCount   = 12     -- how many weapons flash past before landing
MysteryBoxConfig.SpinSeconds = 3.0    -- total roll duration

-- ===== BOX BEHAVIOR =====
MysteryBoxConfig.GrabSeconds   = 6    -- how long the won weapon hovers for pickup
MysteryBoxConfig.MoveChance    = 0.10 -- chance the box "teleports" to a new location after a roll (0 = never)

return MysteryBoxConfig
