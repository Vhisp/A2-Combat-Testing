--!strict
-- Shared configuration constants. Pure data, no behaviour, no dependencies.

local Constants = {}

-- Bumped whenever a client/server payload shape changes.
Constants.PROTOCOL_VERSION = 1

-- Explorer folder names used by the framework.
Constants.FOLDERS = {
	Shared = "Shared",
	Remotes = "Remotes",
}

-- Remote instance names. The server creates these once at startup.
Constants.REMOTES = {
	RequestDiagnostics = "RequestDiagnostics",
	DiagnosticsResult = "DiagnosticsResult",
	RequestCycleTarget = "RequestCycleTarget",
	RequestSelectTarget = "RequestSelectTarget",
	RequestInteract = "RequestInteract",
	TargetStateChanged = "TargetStateChanged",
	InteractionFeedback = "InteractionFeedback",
	RequestUseSkill = "RequestUseSkill",
	SkillFeedback = "SkillFeedback",
	-- Action-combat prototype (ActionCombatService / ActionCombatController).
	RequestCombatAction = "RequestCombatAction",
	CombatActionResult = "CombatActionResult",
}

-- Seconds the client waits for the Remotes folder before failing.
Constants.REMOTE_RESOLVE_TIMEOUT = 10

-- Server-side, per-player rate limit buckets.
-- Global is applied to every inbound request BEFORE payload validation.
-- Action buckets are applied afterwards, per request type.
Constants.RATE_LIMITS = {
	-- Global is checked BEFORE payload inspection on every inbound request.
	Global = {
		MaxRequests = 60,
		WindowSeconds = 10,
	},
	Diagnostics = {
		MaxRequests = 5,
		WindowSeconds = 10,
	},
	-- Targeting is input-driven (Tab / click), so it needs more headroom than
	-- Diagnostics but stays tight against automation.
	Targeting = {
		MaxRequests = 20,
		WindowSeconds = 10,
	},
	Interact = {
		MaxRequests = 10,
		WindowSeconds = 10,
	},
	-- Skills are input-driven (hotkeys, later the action bar), so they get the same
	-- headroom as Targeting. Cooldowns are enforced separately by the server.
	Skill = {
		MaxRequests = 20,
		WindowSeconds = 10,
	},
	-- Action combat: attack/dodge presses. 12 requests/s sustained with a 120 burst, far above
	-- what a human can press (even with buffering), so it only stops floods. Timing and
	-- cooldowns are enforced separately by the server's action rules. Checked FIRST on every
	-- combat request (before payload inspection) in place of the shared Global bucket, so
	-- fast combos never starve or get starved by the slower targeting/skill buckets.
	Combat = {
		MaxRequests = 120,
		WindowSeconds = 10,
	},
}

-- Upper bound on the diagnostics echo string.
Constants.MAX_DIAGNOSTIC_TEXT_LENGTH = 256

-- Upper bound on a skill id string in a request. Ids are short lowercase names.
Constants.MAX_SKILL_ID_LENGTH = 32

-- One generic reason for every rejection, so clients learn nothing about why.
Constants.GENERIC_REJECTION = "request rejected"

return Constants
