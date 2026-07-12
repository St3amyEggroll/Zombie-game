--!strict
-- ClassConfig.lua — the C1 passive kit classes. Picked in the LOBBY's class showcase (saved to the
-- shared profile as `class`); this place applies the passives server-side at the four hook points:
-- damage (CombatService), max HP + move speed (PlayerStateService), run coins (ProgressionService).
-- The lobby place carries a hand-mirrored copy of these numbers for its showcase UI — change one,
-- change both. Adding a class = add a table entry here + a card in the lobby's showcase list.

export type ClassDef = {
	name: string,
	desc: string,
	damageMult: number?, -- multiplies gun damage
	healthBonus: number?, -- added to max HP
	speedMult: number?, -- multiplies base walk speed (sprint stacks on top)
	coinsMult: number?, -- multiplies coins earned during runs
}

local ClassConfig = {}

ClassConfig.Order = { "soldier", "juggernaut", "runner", "scavenger" }

ClassConfig.Classes = {
	soldier = { name = "Soldier", desc = "+12% gun damage", damageMult = 1.12 },
	juggernaut = { name = "Juggernaut", desc = "+50 max HP", healthBonus = 50 },
	runner = { name = "Runner", desc = "+15% move speed", speedMult = 1.15 },
	scavenger = { name = "Scavenger", desc = "+25% coins from runs", coinsMult = 1.25 },
} :: { [string]: ClassDef }

-- The player's class def (nil when none equipped / unknown id).
function ClassConfig.Get(classId: string?): ClassDef?
	if typeof(classId) == "string" then
		return ClassConfig.Classes[classId]
	end
	return nil
end

return ClassConfig
