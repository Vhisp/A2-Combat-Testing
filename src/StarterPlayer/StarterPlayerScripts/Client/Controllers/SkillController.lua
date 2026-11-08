--!strict
-- Client skill input. Sends REQUESTS only: the request carries the protocol version and a
-- skill id, nothing else. The server decides the target, the damage, the range, the
-- cooldown, and whether the skill succeeds. Feedback is consumed for logging only; there
-- is no action bar or HUD yet.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local SkillsConfig = require(ReplicatedStorage.Shared.Config.Skills)
local SkillTypes = require(ReplicatedStorage.Shared.Types.Skills)

local IS_STUDIO = RunService:IsStudio()

local SkillController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

-- KeyCode -> skill id, built from Config.Skills.KEYBINDS in Init (not at require time).
local skillIdByKey: { [Enum.KeyCode]: string } = {}

local function log(...: any): ()
	if IS_STUDIO then
		print("[SkillController]", ...)
	end
end

local function requestSkill(skillId: string): ()
	deps.Net.FireServer(Constants.REMOTES.RequestUseSkill, {
		protocol = Constants.PROTOCOL_VERSION,
		skillId = skillId,
	})
end

local function onFeedback(payload: any): ()
	if type(payload) ~= "table" or type(payload.skillId) ~= "string" or type(payload.ok) ~= "boolean" then
		return
	end
	local feedback = payload :: SkillTypes.SkillFeedback
	if feedback.ok then
		log(`{feedback.skillId}: ok`)
	else
		log(`{feedback.skillId}: rejected ({tostring(feedback.reason)})`)
	end
end

function SkillController.Init(injected: { [string]: any }): ()
	deps = injected

	table.clear(skillIdByKey)
	for _, keybind in SkillsConfig.KEYBINDS do
		if skillIdByKey[keybind.key] == nil then
			skillIdByKey[keybind.key] = keybind.skillId
		else
			warn(`[SkillController] {keybind.key.Name} is bound twice; ignoring the duplicate for '{keybind.skillId}'`)
		end
	end
end

function SkillController.Start(): ()
	table.insert(connections, deps.Net.OnClientEvent(Constants.REMOTES.SkillFeedback, onFeedback))

	-- InputBegan fires once per physical key press (a held key does not repeat it), so one
	-- press sends one request. gameProcessed skips keys the engine or a GUI already used.
	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		local skillId = skillIdByKey[input.KeyCode]
		if skillId then
			requestSkill(skillId)
		end
	end))
end

function SkillController.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(skillIdByKey)
end

return SkillController
