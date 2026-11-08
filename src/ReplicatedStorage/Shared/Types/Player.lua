--!strict
-- Runtime player state shape. No persistence, no stats, no currency yet.
-- Types only: this module returns an empty table at runtime.

export type PlayerState = {
	userId: number,
	player: Player,
	joinedAt: number,
	ready: boolean,
}

return {}
