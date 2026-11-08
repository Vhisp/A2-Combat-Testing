--!strict
-- Runtime stats types (Mana only for now).
-- Types only: this module returns an empty table at runtime.

-- Read-only COPY of one character generation's Mana. Never the live internal state.
export type ManaSnapshot = {
	generation: number,
	current: number,
	max: number,
}

-- Result of a Mana mutation. Rejection reasons are internal (RuntimeStatsService.Reasons).
export type ManaResult = {
	ok: boolean,
	reason: string?, -- set when ok is false
	generation: number?, -- generation the state belongs to; nil when there is no state
	current: number?, -- Mana after the call (unchanged when rejected); nil when there is no state
	max: number?, -- maximum Mana after the call; nil when there is no state
	applied: number, -- Mana actually consumed or restored; 0 when rejected, already full, or a max change
}

return {}
