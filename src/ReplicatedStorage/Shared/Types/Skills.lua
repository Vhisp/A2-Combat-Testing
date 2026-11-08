--!strict
-- Skill definition, keybind, and request types.
-- Types only: this module returns an empty table at runtime.

export type SkillDamage = {
	power: number, -- base damage power passed to Shared/Formulas/Damage
}

export type SkillDefinition = {
	displayName: string,
	cooldown: number, -- seconds
	range: number, -- studs
	damage: SkillDamage,
}

-- One keyboard key bound to one skill id.
export type SkillKeybind = {
	key: Enum.KeyCode,
	skillId: string,
}

-- Codes a caster may be told about for a well-formed request.
-- Unknown skill ids and malformed requests are never reported to the client.
export type SkillRejectionReason = "cooldown" | "no_target" | "invalid_target" | "out_of_range"

-- Server -> owning client, for a well-formed request for a known skill that reached a
-- gameplay decision. Success carries no reason; a rejection always carries one.
export type SkillFeedback = {
	skillId: string,
	ok: boolean,
	reason: SkillRejectionReason?,
}

-- The client sends only the skill id. The target and the damage are decided by
-- the server, so neither appears in this payload.
export type RequestUseSkill = {
	protocol: number,
	skillId: string,
}

return {}
