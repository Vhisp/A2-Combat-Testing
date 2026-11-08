--!strict
-- Combat resolution types.
-- Types only: this module returns an empty table at runtime.

-- Values SkillService computes before calling CombatService. CombatService
-- applies them but never derives them, and still revalidates them.
export type ResolvedSkillParams = {
	damage: number,
}

-- Single named-argument table for CombatService.ResolveSkill.
export type ResolveSkillRequest = {
	attacker: Player,
	skillId: string,
	targetId: string,
	params: ResolvedSkillParams,
}

export type CombatResult = {
	ok: boolean,
	reason: string?, -- set when ok is false
	targetId: string,
	damage: number, -- damage actually applied; 0 when rejected
	targetDied: boolean,
}

return {}
