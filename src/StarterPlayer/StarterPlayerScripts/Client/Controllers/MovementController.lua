--!strict
-- Action-combat movement: camera-relative, with acceleration/deceleration, facing the
-- movement direction, and attack/dodge control over facing and speed.
--
-- It reads the default control module's move input but drives the Humanoid itself
-- (Humanoid:Move with a custom velocity), after the default controls each frame, so
-- jumping and the rest of PlayerModule keep working. Attack/dodge decisions live in
-- ActionCombatController; this controller only asks it for the current phase.
--
-- Tunables: Shared/Config/CombatFeel -> Movement, Dodge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)

local BIND_NAME = "A2CombatMovement"

local player = Players.LocalPlayer

local MovementController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local controls: any = nil

local velocity = Vector3.zero
local yaw = 0
local inputDirection = Vector3.zero -- world space, flat, magnitude <= 1 (last frame)
local actionFacing: Vector3? = nil
local lunge: { dir: Vector3, speed: number, startAt: number, endAt: number }? = nil
local dodge: { dir: Vector3, face: Vector3?, startAt: number, duration: number, distance: number }? = nil
local lastCharacter: Model? = nil

local function flatUnit(vector: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude < 1e-4 then
		return Vector3.zero
	end
	return flat.Unit
end

local function moveTowards(current: Vector3, target: Vector3, maxDelta: number): Vector3
	local delta = target - current
	local distance = delta.Magnitude
	if distance <= maxDelta or distance < 1e-5 then
		return target
	end
	return current + delta / distance * maxDelta
end

-- Raw move input as a world-space flat vector (magnitude <= 1).
local function readMoveInput(): Vector3
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.zero
	end

	local moveVector = Vector3.zero -- x: right(+)/left(-), z: back(+)/forward(-)
	if controls then
		local ok, result = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(result) == "Vector3" then
			moveVector = result
		end
	elseif not UserInputService:GetFocusedTextBox() then
		-- PlayerModule not resolved (yet): plain WASD fallback.
		local x = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
		local z = (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
		moveVector = Vector3.new(x, 0, z)
	end
	if moveVector.Magnitude < 0.01 then
		return Vector3.zero
	end

	local look = flatUnit(camera.CFrame.LookVector)
	if look == Vector3.zero then
		look = flatUnit(camera.CFrame.UpVector)
	end
	local right = flatUnit(camera.CFrame.RightVector)
	local world = right * moveVector.X + look * -moveVector.Z
	if world.Magnitude > 1 then
		world = world.Unit
	end
	return world
end

local function getParts(): (Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

local function resetMotion(): ()
	velocity = Vector3.zero
	actionFacing = nil
	lunge = nil
	dodge = nil
end

local function step(dt: number): ()
	inputDirection = readMoveInput()

	local humanoid, root = getParts()
	if not humanoid or not root then
		return
	end
	if player.Character ~= lastCharacter then
		-- New character: adopt its facing, drop any motion from the old one.
		lastCharacter = player.Character
		resetMotion()
		local _, startYaw, _ = root.CFrame:ToOrientation()
		yaw = startYaw
	end
	if humanoid.Health <= 0 or humanoid.Sit then
		resetMotion()
		return
	end

	local tuning = CombatFeel.Movement
	local now = os.clock()
	local actionController = deps.ActionCombatController
	local phase: string = if actionController then actionController.GetPhase() else "free"

	-- Velocity ---------------------------------------------------------------
	if dodge ~= nil then
		local t = (now - dodge.startAt) / dodge.duration
		if t >= 1 or phase ~= "dodge" then
			dodge = nil -- finished, or cancelled by an attack / server rollback
		else
			-- Linear ease-out: starts at 2x the average speed and decays to 0, covering `distance`.
			velocity = dodge.dir * (dodge.distance / dodge.duration * 2 * (1 - t))
		end
	end
	if dodge == nil then
		if lunge ~= nil and now > lunge.endAt then
			lunge = nil
		end
		if lunge ~= nil and now >= lunge.startAt and phase ~= "free" then
			velocity = lunge.dir * lunge.speed
		else
			local multiplier = 1
			if phase == "committed" then
				multiplier = tuning.CommittedMoveMultiplier
			elseif phase == "recovery" then
				multiplier = tuning.RecoveryMoveMultiplier
			end
			local desired = inputDirection * tuning.WalkSpeed * multiplier
			local rate = if desired.Magnitude > 0.05 then tuning.Acceleration else tuning.Deceleration
			velocity = moveTowards(velocity, desired, rate * dt)
		end
	end

	-- Facing -------------------------------------------------------------------
	local facing: Vector3? = nil
	local turnSpeed = tuning.TurnSpeed
	if dodge ~= nil then
		facing = dodge.face
		turnSpeed = tuning.AttackTurnSpeed
	elseif phase == "committed" and actionFacing ~= nil then
		facing = actionFacing
		turnSpeed = tuning.AttackTurnSpeed
	elseif inputDirection.Magnitude > 0.1 then
		facing = inputDirection.Unit
	end
	if phase == "free" then
		actionFacing = nil
	end
	if facing ~= nil then
		local target = math.atan2(-facing.X, -facing.Z)
		local difference = (target - yaw + math.pi) % (2 * math.pi) - math.pi
		yaw += difference * (1 - math.exp(-turnSpeed * dt))
	end

	-- Apply --------------------------------------------------------------------
	if humanoid.AutoRotate then
		humanoid.AutoRotate = false
	end
	local speed = velocity.Magnitude
	if speed > 0.05 then
		humanoid.WalkSpeed = speed
		humanoid:Move(velocity / speed, false)
	else
		velocity = Vector3.zero
		humanoid.WalkSpeed = tuning.WalkSpeed
		humanoid:Move(Vector3.zero, false)
	end
	if not tuning.AllowJumpDuringActions and phase ~= "free" then
		humanoid.Jump = false
	end

	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end

-- API ------------------------------------------------------------------------

-- Current move input (world space, flat, magnitude <= 1). Zero when nothing is held.
function MovementController.GetInputDirection(): Vector3
	return inputDirection
end

-- The direction the character is currently facing (flat unit vector).
function MovementController.GetFacing(): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

-- An attack started: lock facing to `aim` until the cancel window opens, and lunge.
function MovementController.BeginAction(aim: Vector3, lungeDef: CombatFeel.Lunge?, speedScale: number): ()
	actionFacing = flatUnit(aim)
	dodge = nil
	lunge = nil
	if lungeDef ~= nil and lungeDef.Time > 0 and lungeDef.Distance > 0 then
		local now = os.clock()
		local duration = lungeDef.Time / speedScale
		local startAt = now + lungeDef.Start / speedScale
		lunge = {
			dir = actionFacing,
			speed = lungeDef.Distance / duration,
			startAt = startAt,
			endAt = startAt + duration,
		}
	end
end

-- A dodge started: burst `distance` studs along `dir` over `duration`. `face` is the
-- direction to turn toward (nil keeps the current facing, used for backsteps).
function MovementController.BeginDodge(dir: Vector3, face: Vector3?, distance: number, duration: number): ()
	actionFacing = nil
	lunge = nil
	dodge = {
		dir = flatUnit(dir),
		face = if face ~= nil then flatUnit(face) else nil,
		startAt = os.clock(),
		duration = math.max(duration, 0.05),
		distance = distance,
	}
end

-- Server refused the action: drop the predicted motion.
function MovementController.CancelAction(): ()
	actionFacing = nil
	lunge = nil
	dodge = nil
end

function MovementController.Init(injected: { [string]: any }): ()
	deps = injected
end

function MovementController.Start(): ()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Character.Value + 1, step)

	-- Resolve the default control module without blocking the other controllers' Start.
	task.spawn(function()
		local playerScripts = player:WaitForChild("PlayerScripts")
		local module = playerScripts:WaitForChild("PlayerModule", 10)
		if module then
			local ok, result = pcall(function()
				return (require(module) :: any):GetControls()
			end)
			if ok then
				controls = result
			else
				warn("[MovementController] could not get PlayerModule controls, using WASD fallback:", result)
			end
		end
	end)
end

function MovementController.Destroy(): ()
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	resetMotion()
	deps = {}
end

return MovementController
