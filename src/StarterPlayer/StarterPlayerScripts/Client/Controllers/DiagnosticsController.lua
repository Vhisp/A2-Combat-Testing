--!strict
-- Development diagnostics only. Sends one validated request at startup and checks
-- the reply against Constants.PROTOCOL_VERSION. Studio-gated verbose output.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Config.Constants)
local NetTypes = require(ReplicatedStorage.Shared.Types.Net)

local IS_STUDIO = RunService:IsStudio()

local DiagnosticsController = {}

local deps: { [string]: any } = {}
local connections: { RBXScriptConnection } = {}

function DiagnosticsController.Init(injected: { [string]: any }): ()
	deps = injected
end

function DiagnosticsController.Start(): ()
	local net = deps.Net

	table.insert(connections, net.OnClientEvent(Constants.REMOTES.DiagnosticsResult, function(payload: any)
		local result = payload :: NetTypes.DiagnosticsResult

		if type(result) ~= "table" then
			warn("[DiagnosticsController] malformed reply")
			return
		end

		if result.protocol ~= Constants.PROTOCOL_VERSION then
			warn(`[DiagnosticsController] protocol mismatch: got {result.protocol}`)
			return
		end

		if result.ok then
			if IS_STUDIO then
				print(`[DiagnosticsController] PASS | echoed="{result.echoedText or ""}" | serverTime={result.serverTime}`)
			end
		else
			warn(`[DiagnosticsController] server rejected the request: {result.reason}`)
		end
	end))

	-- One probe at startup. token proves the echo path; clientTime proves the time path.
	local request: NetTypes.DiagnosticsRequest = {
		protocol = Constants.PROTOCOL_VERSION,
		action = "echo",
		text = "hello from client",
		clientTime = os.clock(),
	}

	net.FireServer(Constants.REMOTES.RequestDiagnostics, request)
	if IS_STUDIO then
		print("[DiagnosticsController] probe sent")
	end
end

function DiagnosticsController.Destroy(): ()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return DiagnosticsController
