--!strict
-- Action-combat input, buffering, and client-side prediction.
--
-- Left click = Light chain, right click = Heavy chain, Dodge key = dodge (see CombatFeel.Keys).
-- Presses go into a short buffer and fire as soon as the shared ActionRules allow, so
-- mashing through a combo feels responsive. The action starts IMMEDIATELY on the client
-- (animation, lunge, facing) and the request goes to ActionCombatService, which validates
-- timing and applies damage. If the server refuses the newest action the client rolls back.
--
-- Tunables: Shared/Config/CombatFeel -> Combat, Dodge, Actions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)
local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)
local ActionRules = require(ReplicatedStorage.Shared.Formulas.ActionRules)

local IS_STUDIO = RunService:IsStudio()
local BIND_NAME = "A2CombatActions"

local player = Players.LocalPlayer

local ActionCombatController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local rules: ActionRules.State = ActionRules.NewState()
local buffer: { input: string, expiresAt: number }? = nil
local lastSeq = 0
local pending: { [number]: string } = {}
local selectedTargetId: string? = nil
local currentTrack: AnimationTrack? = nil
local lastReject = "-"
local lastCharacter: Model? = nil

local function log(...: any): ()
	if IS_STUDIO then
		print("[ActionCombatController]", ...)
	end
end

local function getParts(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return character, humanoid, root
	end
	return nil, nil, nil
end

-- Animation ---------------------------------------------------------------------

local function stopAnimation(): ()
	if currentTrack then
		currentTrack:Stop(0.08)
		currentTrack = nil
	end
end

-- Plays def.AnimationId on the character's Animator. An empty id means "no animation":
-- the slash VFX and lunge still play, so the combat is readable before animations exist.
local function playAnimation(def: any, speed: number): ()
	stopAnimation()
	local animationId = def.AnimationId
	if type(animationId) ~= "string" or animationId == "" then
		return
	end
	local _, humanoid = getParts()
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local track = animator:LoadAnimation(animation)
	animation:Destroy()
	track.Priority = Enum.AnimationPriority.Action
	track:Play(0.05, 1, (def.AnimationSpeed or 1) * speed)
	currentTrack = track
end

-- Aim -----------------------------------------------------------------------------

-- Direction of the attack: held movement direction, else camera direction, bent toward the
-- best target inside the aim-assist cone (the Tab-selected target gets priority).
local function chooseAim(): Vector3
	local movement = deps.MovementController
	local base: Vector3 = movement.GetInputDirection()
	if base.Magnitude < 0.1 then
		local camera = Workspace.CurrentCamera
		local look = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
		base = Vector3.new(look.X, 0, look.Z)
	end
	if base.Magnitude < 0.01 then
		base = movement.GetFacing()
	end
	base = base.Unit

	local character, _, root = getParts()
	if not character or not root then
		return base
	end

	local tuning = CombatFeel.Combat
	local halfAngle = math.rad(tuning.AimAssistAngle * 0.5)
	local bestDirection: Vector3? = nil
	local bestScore = math.huge

	for _, instance in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		if instance:IsA("Model") and instance ~= character then
			local humanoid = instance:FindFirstChildOfClass("Humanoid")
			local targetRoot = instance:FindFirstChild("HumanoidRootPart")
			if humanoid and humanoid.Health > 0 and targetRoot and targetRoot:IsA("BasePart") then
				local offset = targetRoot.Position - root.Position
				local flat = Vector3.new(offset.X, 0, offset.Z)
				local distance = flat.Magnitude
				if distance > 0.1 and distance <= tuning.AimAssistRange + tuning.TargetRadius then
					local angle = math.acos(math.clamp(flat.Unit:Dot(base), -1, 1))
					if angle <= halfAngle then
						local score = angle * 8 + distance
						if selectedTargetId ~= nil and instance:GetAttribute(TargetingConfig.ATTRIBUTE_ID) == selectedTargetId then
							score -= 20
						end
						if score < bestScore then
							bestScore = score
							bestDirection = flat.Unit
						end
					end
				end
			end
		end
	end

	return bestDirection or base
end

-- Starting actions ------------------------------------------------------------------

local function sendRequest(input: string, aim: Vector3): number
	lastSeq += 1
	pending[lastSeq] = input
	pending[lastSeq - 60] = nil
	deps.Net.FireServer(Constants.REMOTES.RequestCombatAction, {
		protocol = Constants.PROTOCOL_VERSION,
		input = input,
		seq = lastSeq,
		aim = aim,
	})
	return lastSeq
end

local function startAction(actionId: string, input: string): ()
	local now = os.clock()
	local movement = deps.MovementController

	if actionId == "Dodge" then
		local dodge = CombatFeel.Dodge
		local direction: Vector3 = movement.GetInputDirection()
		local face: Vector3? = nil
		if direction.Magnitude >= 0.1 then
			direction = direction.Unit
			face = direction
		elseif dodge.BackstepWhenNoInput then
			face = movement.GetFacing()
			direction = -face
		else
			direction = movement.GetFacing()
			face = direction
		end
		ActionRules.Begin(rules, "Dodge", now)
		sendRequest(input, direction)
		movement.BeginDodge(direction, face, dodge.Distance, dodge.Duration)
		playAnimation(dodge, 1)
		return
	end

	local def = CombatFeel.Actions[actionId]
	local speed = ActionRules.ActionSpeed(def)
	local aim = chooseAim()
	ActionRules.Begin(rules, actionId, now)
	sendRequest(input, aim)
	movement.BeginAction(aim, def.Lunge, speed)
	playAnimation(def, speed)
	deps.CombatFeedbackController.PlaySlash(def, aim, speed)
end

-- Fire the buffered input if the rules allow it right now.
local function tryBuffered(): ()
	local pendingInput = buffer
	if pendingInput == nil then
		return
	end
	local now = os.clock()
	if now > pendingInput.expiresAt then
		buffer = nil
		return
	end

	local _, humanoid = getParts()
	if not humanoid then
		buffer = nil
		return
	end
	if not CombatFeel.Movement.AllowAirActions and humanoid.FloorMaterial == Enum.Material.Air then
		return -- keep it buffered until we land
	end

	local actionId, reason = ActionRules.Evaluate(rules, pendingInput.input, now, 0)
	if actionId == nil then
		lastReject = reason or "-"
		return -- not allowed yet: stay buffered until it is, or it expires
	end

	buffer = nil
	startAction(actionId, pendingInput.input)
end

local function queueInput(input: string): ()
	buffer = { input = input, expiresAt = os.clock() + CombatFeel.Combat.InputBufferTime }
	tryBuffered() -- fire this frame if already allowed (no waiting for the next render step)
end

-- Server replies ----------------------------------------------------------------------

local function onResult(payload: any): ()
	if type(payload) ~= "table" or payload.type ~= "ack" then
		return
	end
	local seq = payload.seq
	if type(seq) ~= "number" then
		return
	end
	local sentInput = pending[seq]
	pending[seq] = nil

	if payload.ok == true then
		log(`ack #{seq} {sentInput or "?"} -> {tostring(payload.action)}`)
		return
	end

	lastReject = tostring(payload.reason)
	log(`server refused #{seq} {sentInput or "?"}: {lastReject}`)
	if seq == lastSeq then
		-- The newest predicted action was refused: undo it so client and server agree again.
		ActionRules.Reset(rules)
		deps.MovementController.CancelAction()
		stopAnimation()
	end
end

local function onTargetState(payload: any): ()
	if type(payload) ~= "table" then
		return
	end
	local combat = payload.combat
	if type(combat) == "table" and type(combat.id) == "string" then
		selectedTargetId = combat.id
	else
		selectedTargetId = nil
	end
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	local kind: string? = nil
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		kind = "Light"
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		kind = "Heavy"
	elseif input.KeyCode == CombatFeel.Keys.Dodge then
		kind = "Dodge"
	end
	if kind == nil then
		return
	end
	-- With the cursor freed (hold FreeCursor key) mouse clicks belong to the UI.
	if kind ~= "Dodge" and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		return
	end
	queueInput(kind)
end

local function step(): ()
	if player.Character ~= lastCharacter then
		-- Respawn: start clean.
		lastCharacter = player.Character
		rules = ActionRules.NewState()
		buffer = nil
		stopAnimation()
		deps.MovementController.CancelAction()
	end
	if buffer ~= nil then
		tryBuffered()
	end
end

-- API ---------------------------------------------------------------------------------

function ActionCombatController.GetPhase(): string
	return ActionRules.GetPhase(rules, os.clock())
end

function ActionCombatController.GetDebugInfo(): { [string]: any }
	local now = os.clock()
	local bufferedInput: string? = nil
	local bufferLeft = 0
	if buffer ~= nil and now <= buffer.expiresAt then
		bufferedInput = buffer.input
		bufferLeft = buffer.expiresAt - now
	end
	return {
		action = rules.current or (if now < rules.dodgeEndsAt then "Dodge" else "-"),
		phase = ActionRules.GetPhase(rules, now),
		comboOpen = rules.current ~= nil and now <= rules.comboUntil,
		buffered = bufferedInput,
		bufferLeft = bufferLeft,
		dodgeCooldown = math.max(rules.dodgeReadyAt - now, 0),
		lastReject = lastReject,
	}
end

function ActionCombatController.Init(injected: { [string]: any }): ()
	deps = injected
end

function ActionCombatController.Start(): ()
	local net = deps.Net
	table.insert(connections, net.OnClientEvent(Constants.REMOTES.CombatActionResult, onResult))
	table.insert(connections, net.OnClientEvent(Constants.REMOTES.TargetStateChanged, onTargetState))
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
	-- Before MovementController's step (Character + 1) so a press this frame is acted on this frame.
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Character.Value - 50, step)
end

function ActionCombatController.Destroy(): ()
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	stopAnimation()
	buffer = nil
	deps = {}
end

return ActionCombatController
