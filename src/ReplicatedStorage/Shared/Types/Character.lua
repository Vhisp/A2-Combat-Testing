--!strict
-- Server-owned character runtime state shape.
-- Lifecycle information ONLY: no health, stats, class, resources, or combat data.
-- Types only: this module returns an empty table at runtime.

export type CharacterState = {
	player: Player,
	character: Model,
	humanoid: Humanoid,
	generation: number, -- increments per spawn; guards against stale character events
	spawnedAt: number,
}

return {}
