--!strict
-- ============================================================================
-- COMBAT FEEL: every tunable for the action-combat prototype lives in this file.
-- Times are in SECONDS, distances in STUDS, angles in DEGREES.
-- Edit a value, press Play, feel the difference. Nothing else needs to change.
--
-- Controls (rebind in `Keys`):
--   Left click  = Light chain      Right click = Heavy / skill chain
--   LeftShift   = Dodge (toward the direction you hold; backstep if none)
--   Tab         = cycle target (existing system; the selected target gets aim-assist priority)
--   Hold LeftAlt = free the mouse cursor      Mouse wheel = camera zoom
--   1           = existing "Strike" skill (needs a Tab-selected target)
-- ============================================================================

export type Lunge = {
	Distance: number, -- studs travelled toward the aim direction
	Start: number, -- seconds after the action starts before the lunge begins
	Time: number, -- seconds the lunge lasts
}

export type ActionDef = {
	DisplayName: string,
	Duration: number, -- total time until the action is finished (movement fully restored)
	HitTime: number, -- when the hit connects (server resolves damage here)
	CancelTime: number, -- from here you may chain into the next action or dodge (cancel window opens)
	ComboWindow: number, -- extra time AFTER Duration in which the chain still continues
	DodgeCancelTime: number?, -- earliest dodge-cancel (defaults to HitTime)
	Damage: number, -- base power fed to the shared Damage formula
	Range: number, -- studs from the attacker's root
	Angle: number, -- full width of the hit cone, degrees (360 = all around)
	Lunge: Lunge?, -- small step forward during the attack
	Speed: number?, -- per-action speed multiplier (stacks with Combat.AttackSpeed)
	AnimationId: string, -- "rbxassetid://..." (empty = no animation, the slash VFX still plays)
	AnimationSpeed: number,
	Color: Color3, -- slash VFX colour
	Next: { [string]: string }, -- input ("Light"/"Heavy") -> action id to chain into
}

local CombatFeel = {}

CombatFeel.Keys = {
	Dodge = Enum.KeyCode.LeftShift,
	FreeCursor = Enum.KeyCode.LeftAlt,
}

CombatFeel.Movement = {
	WalkSpeed = 18, -- top speed (studs/s)
	Acceleration = 85, -- studs/s^2 while a direction is held
	Deceleration = 110, -- studs/s^2 once input is released (lower = slidier)
	TurnSpeed = 14, -- how fast the character turns to face movement (higher = snappier)
	AttackTurnSpeed = 30, -- how fast the character turns into an attack/dodge direction
	CommittedMoveMultiplier = 0.1, -- speed multiplier before an action's CancelTime (commitment)
	RecoveryMoveMultiplier = 0.6, -- speed multiplier between CancelTime and Duration (recovery)
	AllowJumpDuringActions = false,
	AllowAirActions = false, -- false = attacks/dodges only start while grounded
}

CombatFeel.Combat = {
	AttackSpeed = 1.0, -- global speed multiplier for ALL attack timings (1.25 = 25% faster)
	InputBufferTime = 0.35, -- an early press is remembered this long and fires when allowed
	LatencyTolerance = 0.12, -- server leniency on timing windows (covers ping/jitter)
	AimAssistRange = 12, -- studs; attacks bend toward the best target inside this range
	AimAssistAngle = 100, -- degrees (full cone around your input/camera direction)
	MaxHitTargets = 3, -- one swing hits at most this many targets
	TargetRadius = 2, -- studs added to Range so big/close targets still count
	HitHeight = 8, -- max vertical difference for a hit
}

CombatFeel.Dodge = {
	Distance = 15, -- studs
	Duration = 0.28, -- seconds of dodge movement
	Cooldown = 0.8, -- seconds from dodge start until the next dodge is allowed
	IFrameDuration = 0.22, -- invulnerable seconds (sets the "IFrames" attribute on the character)
	AttackCancelTime = 0.18, -- you may attack out of the dodge after this long
	BackstepWhenNoInput = true, -- no direction held = hop backwards without turning
	AnimationId = "",
	AnimationSpeed = 1,
}

CombatFeel.Camera = {
	Distance = 13, -- starting distance behind the character
	MinDistance = 5,
	MaxDistance = 30,
	ZoomStep = 2, -- studs per mouse-wheel notch
	Height = 3.2, -- focus height above the character root
	ShoulderOffset = 1.5, -- sideways offset (positive = camera shifts right)
	FieldOfView = 70,
	Sensitivity = 0.25, -- degrees per mouse pixel
	MinPitch = -55, -- degrees (looking down)
	MaxPitch = 65, -- degrees (looking up)
	StartPitch = -12,
	FollowSmoothing = 18, -- higher = tighter follow, 0 = rigid
	CollisionPadding = 0.6,
}

-- Training dummies: tagged CombatTarget models with a Humanoid cannot die, they
-- "go down" at 0 HP and get refilled after RespawnTime so you can keep testing.
CombatFeel.Dummy = {
	Enabled = true,
	RespawnTime = 3,
}

CombatFeel.Debug = {
	ShowHud = true, -- top-left readout: current action, phase, buffer, dodge cooldown
}

-- ----------------------------------------------------------------------------
-- ACTIONS. Chains are a small graph: each action lists what each input leads to.
-- Start = what Light/Heavy do from idle (or after the combo window expires).
-- To reshape a combo, edit `Next`. "Dodge" is a reserved id, don't use it here.
-- ----------------------------------------------------------------------------
local actions: { [string]: ActionDef } = {
	Slash1 = {
		DisplayName = "Slash I",
		Duration = 0.50, HitTime = 0.13, CancelTime = 0.24, ComboWindow = 0.45,
		Damage = 10, Range = 7, Angle = 110,
		Lunge = { Distance = 3, Start = 0.02, Time = 0.14 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(150, 210, 255),
		Next = { Light = "Slash2", Heavy = "Heavy1" },
	},
	Slash2 = {
		DisplayName = "Slash II",
		Duration = 0.50, HitTime = 0.13, CancelTime = 0.24, ComboWindow = 0.45,
		Damage = 10, Range = 7, Angle = 120,
		Lunge = { Distance = 3, Start = 0.02, Time = 0.14 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(150, 210, 255),
		Next = { Light = "Slash3", Heavy = "Heavy2" },
	},
	Slash3 = {
		DisplayName = "Slash III",
		Duration = 0.55, HitTime = 0.16, CancelTime = 0.28, ComboWindow = 0.45,
		Damage = 12, Range = 7.5, Angle = 130,
		Lunge = { Distance = 3.5, Start = 0.02, Time = 0.16 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(190, 230, 255),
		Next = { Light = "Slash4", Heavy = "Heavy3" },
	},
	Slash4 = { -- light finisher: committed, then only a heavy can follow
		DisplayName = "Slash IV (finisher)",
		Duration = 0.80, HitTime = 0.24, CancelTime = 0.50, ComboWindow = 0.30,
		Damage = 22, Range = 9, Angle = 150,
		Lunge = { Distance = 5, Start = 0.05, Time = 0.18 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(255, 255, 255),
		Next = { Heavy = "Heavy3" },
	},
	Heavy1 = {
		DisplayName = "Rising Slash",
		Duration = 0.70, HitTime = 0.22, CancelTime = 0.42, ComboWindow = 0.40,
		Damage = 18, Range = 8, Angle = 90,
		Lunge = { Distance = 4, Start = 0.04, Time = 0.16 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(255, 170, 80),
		Next = { Heavy = "Heavy2", Light = "Slash2" },
	},
	Heavy2 = {
		DisplayName = "Wide Sweep",
		Duration = 0.75, HitTime = 0.25, CancelTime = 0.45, ComboWindow = 0.40,
		Damage = 20, Range = 9, Angle = 180,
		Lunge = { Distance = 2, Start = 0.04, Time = 0.16 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(255, 140, 60),
		Next = { Heavy = "Heavy3", Light = "Slash3" },
	},
	Heavy3 = { -- heavy finisher
		DisplayName = "Smash",
		Duration = 1.00, HitTime = 0.35, CancelTime = 0.70, ComboWindow = 0.30,
		Damage = 35, Range = 8, Angle = 120,
		Lunge = { Distance = 5, Start = 0.06, Time = 0.20 },
		AnimationId = "", AnimationSpeed = 1,
		Color = Color3.fromRGB(255, 100, 40),
		Next = { Light = "Slash1" },
	},
}

local start: { [string]: string } = {
	Light = "Slash1",
	Heavy = "Heavy1",
}

CombatFeel.Actions = actions
CombatFeel.Start = start

return CombatFeel
