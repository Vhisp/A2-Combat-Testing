--!strict
-- Targeting and interaction tuning. Pure data, no behaviour, no dependencies.
-- Tags, ranges, and keybinds live here so they can be changed in one place.

local Targeting = {}

-- CollectionService tags.
Targeting.TAG_COMBAT = "CombatTarget"
Targeting.TAG_INTERACTABLE = "Interactable"

-- Attribute written on registered instances so clients can identify them.
Targeting.ATTRIBUTE_ID = "TargetId"

-- Left-click target selection. Disabled for the action-combat prototype, where left click
-- attacks. Tab cycling and the server-side registry are unaffected. Set true to restore.
Targeting.CLICK_SELECT_ENABLED = false

-- Combat ranges (studs).
-- Acquire: maximum distance at which a NEW target may be selected.
-- Retention: maximum distance at which an EXISTING target is kept. Larger than
-- acquire so a target at the boundary does not flicker on and off.
Targeting.MAX_ACQUIRE_RANGE = 40
Targeting.MAX_RETENTION_RANGE = 55

-- Interaction ranges (studs).
-- Interact: verified on the server for EVERY F request, independently of retention.
-- InteractRetention: how far the player may walk before the interaction target clears.
Targeting.MAX_INTERACT_RANGE = 12
Targeting.MAX_INTERACT_RETENTION_RANGE = 20

-- Seconds between retention checks. Each tick validates only the player's OWN
-- current targets (O(players)), never a scan of all registered targets.
Targeting.VALIDATION_INTERVAL = 0.25

-- Input keybinds. Configurable so they can be replaced later.
-- Escape is deliberately absent: Roblox reserves it for the system menu.
Targeting.KEYBINDS = {
	CycleTarget = Enum.KeyCode.Tab,
	Interact = Enum.KeyCode.F,
}

-- Bounded retry for SetCoreGuiEnabled at client startup.
Targeting.COREGUI_RETRY_ATTEMPTS = 10
Targeting.COREGUI_RETRY_DELAY = 0.1

return Targeting
