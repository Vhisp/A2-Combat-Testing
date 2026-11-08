--!strict
-- Targeting payload and state types.
-- Types only: this module returns an empty table at runtime.

export type TargetKind = "Combat" | "Interact"

-- Minimal public description of a target, sent to the owning client only.
export type TargetInfo = {
	id: string,
	name: string,
}

-- One remote, fired to the owner whenever either target changes.
-- Both fields are independent: setting one never clears the other.
export type TargetStateChanged = {
	combat: TargetInfo?,
	interaction: TargetInfo?,
}

export type RequestSelectTarget = {
	protocol: number,
	targetId: string,
}

export type RequestCycleTarget = {
	protocol: number,
}

export type RequestInteract = {
	protocol: number,
}

export type InteractionFeedback = {
	ok: boolean,
	targetId: string?,
	message: string?,
}

return {}
