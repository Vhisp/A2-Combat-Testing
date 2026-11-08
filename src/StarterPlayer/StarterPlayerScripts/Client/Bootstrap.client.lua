--!strict
-- The ONLY client entry point. Wires the loader, registers controllers in order,
-- and starts them. Contains no gameplay logic.

local StarterPlayer = game:GetService("StarterPlayer")
local StarterPlayerScripts = StarterPlayer:WaitForChild("StarterPlayerScripts", 10)

local ClientRoot = StarterPlayerScripts:WaitForChild("Client", 10)
local Framework = ClientRoot:WaitForChild("Framework", 10)
local Controllers = ClientRoot:WaitForChild("Controllers", 10)

local ControllerLoader = require(Framework:WaitForChild("ControllerLoader", 10))

ControllerLoader.Register("DiagnosticsController", require(Controllers:WaitForChild("DiagnosticsController", 10)))
ControllerLoader.Register("TargetingController", require(Controllers:WaitForChild("TargetingController", 10)))
ControllerLoader.Register("TargetingUIController", require(Controllers:WaitForChild("TargetingUIController", 10)))
ControllerLoader.Register("SkillController", require(Controllers:WaitForChild("SkillController", 10)))
-- Action-combat prototype. Appended last, existing order unchanged. They reach each other
-- through deps (MovementController <-> ActionCombatController, CombatFeedbackController).
ControllerLoader.Register("MovementController", require(Controllers:WaitForChild("MovementController", 10)))
ControllerLoader.Register("ActionCombatController", require(Controllers:WaitForChild("ActionCombatController", 10)))
ControllerLoader.Register("CameraController", require(Controllers:WaitForChild("CameraController", 10)))
ControllerLoader.Register("CombatFeedbackController", require(Controllers:WaitForChild("CombatFeedbackController", 10)))

ControllerLoader.Start()
