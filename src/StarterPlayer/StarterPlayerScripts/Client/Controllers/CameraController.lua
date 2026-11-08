--!strict
-- Action-combat camera: mouse-look with the cursor locked to the centre, an over-the-shoulder
-- offset, smooth follow, wheel zoom, and collision pull-in. Replaces the default camera
-- (CameraType = Scriptable) while this controller runs.
--
-- Hold CombatFeel.Keys.FreeCursor (LeftAlt) to release the cursor for UI / Studio buttons.
-- Tunables: Shared/Config/CombatFeel -> Camera.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local TargetingConfig = require(ReplicatedStorage.Shared.Config.Targeting)
local CombatFeel = require(ReplicatedStorage.Shared.Config.CombatFeel)

local BIND_NAME = "A2CombatCamera"

local player = Players.LocalPlayer

local CameraController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

local yaw = 0
local pitch = math.rad(CombatFeel.Camera.StartPitch)
local distance = CombatFeel.Camera.Distance
local focus: Vector3? = nil
local initialised = false
local cursorFree = false

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function step(dt: number): ()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local tuning = CombatFeel.Camera

	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.FieldOfView = tuning.FieldOfView

	if not initialised then
		-- Start looking the way the default camera was looking.
		initialised = true
		local look = camera.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
	end

	-- Cursor: locked to the centre for mouse-look, free while the key is held or a menu is open.
	cursorFree = UserInputService:IsKeyDown(CombatFeel.Keys.FreeCursor) or GuiService.MenuIsOpen
	UserInputService.MouseBehavior = if cursorFree then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = cursorFree

	if not cursorFree then
		local delta = UserInputService:GetMouseDelta()
		local sensitivity = math.rad(tuning.Sensitivity)
		yaw -= delta.X * sensitivity
		pitch = math.clamp(pitch - delta.Y * sensitivity, math.rad(tuning.MinPitch), math.rad(tuning.MaxPitch))
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	-- Focus point follows the character (smoothed; snaps after a teleport/respawn).
	local targetFocus = root.Position + Vector3.new(0, tuning.Height, 0)
	if focus == nil or (targetFocus - focus).Magnitude > 60 or tuning.FollowSmoothing <= 0 then
		focus = targetFocus
	else
		focus = focus:Lerp(targetFocus, 1 - math.exp(-tuning.FollowSmoothing * dt))
	end

	local rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	local pivot = focus + rotation.RightVector * tuning.ShoulderOffset
	local desired = pivot - rotation.LookVector * distance

	-- Pull the camera in front of walls (ignore the character and combat targets).
	local ignore: { Instance } = { character :: Instance }
	for _, tagged in CollectionService:GetTagged(TargetingConfig.TAG_COMBAT) do
		table.insert(ignore, tagged)
	end
	raycastParams.FilterDescendantsInstances = ignore
	local toCamera = desired - pivot
	local hit = Workspace:Raycast(pivot, toCamera, raycastParams)
	if hit then
		local clipped = math.max(hit.Distance - tuning.CollisionPadding, 0.5)
		desired = pivot + toCamera.Unit * clipped
	end

	camera.CFrame = CFrame.new(desired) * rotation
end

-- API -----------------------------------------------------------------------------

function CameraController.IsCursorLocked(): boolean
	return not cursorFree
end

function CameraController.Init(injected: { [string]: any }): ()
	deps = injected
end

function CameraController.Start(): ()
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)

	table.insert(connections, UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end
		local tuning = CombatFeel.Camera
		distance = math.clamp(distance - input.Position.Z * tuning.ZoomStep, tuning.MinDistance, tuning.MaxDistance)
	end))
end

function CameraController.Destroy(): ()
	pcall(function()
		RunService:UnbindFromRenderStep(BIND_NAME)
	end)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
	deps = {}
end

return CameraController
